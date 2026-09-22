--[[
	ShipService
	Autoridade do servidor sobre naves: posse, módulos, ciclo de vida da
	instância, Configurations, entrada no assento, decolagem e warp.

	O client nunca manda preço, nível ou stat — só ids. Toda resposta de ação é
	(ok: boolean, code: string); o estado completo chega pelo ShipStateChanged.

	Lógica de voo e tiro NÃO mora aqui: fica no PlaneScript/LocalPlaneScript do
	modelo, que lê o Configurations que este serviço escreve no spawn.

	CICLO DE VIDA DA INSTÂNCIA
	  Espaço (Hub/luas)
	    nasce:   prompt LANÇAR de um pad do HangarPads → naquele pad, jogador já sentado
	             botão LANÇAR do HUD (terminal) → primeiro pad livre, jogador já sentado
	             chegada de planeta (teleporte) → marcador orbital, sentado
	    some:    GUARDAR NAVE (fora do assento, nave dentro da HangarZone)
	             IDLE_DESPAWN_TIME longe da nave
	             novo LANÇAR (substitui a anterior)
	  Planeta
	    nasce:   ao entrar no Place, pousada no LandingPad, jogador ao lado
	    some:    NUNCA enquanto o jogador estiver no Place (ver _despawn)
	  Sempre
	    some:    PlayerRemoving — nave órfã ficaria com NetworkOwner de um
	             jogador que não existe mais

	Local: src/server/Services/ShipService.luau
]]

local Knit = require(game:GetService("ReplicatedStorage").Packages.Knit)
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local CollectionService = game:GetService("CollectionService")
local TeleportService = game:GetService("TeleportService")
local RunService = game:GetService("RunService")

local ShipData = require(ReplicatedStorage.Shared.ShipData)
local PlaceConfig = require(ReplicatedStorage.Shared.PlaceConfig)
local WarpModule = require(ReplicatedStorage.Shared.WarpModule)
local MapConfig = require(ReplicatedStorage.Shared.MapConfig)
local InventoryModule = require(ReplicatedStorage.Shared.InventoryModule)

local ACTION_COOLDOWN = 0.5
local SHIP_SPACING = 6 -- studs entre naves lado a lado no LandingPad
local CHARACTER_SIDE_GAP = 5 -- studs entre a nave pousada e o jogador
local RESPAWN_DELAY = 3
local MAINTENANCE_INTERVAL = 0.5 -- também é o ritmo da checagem de pouso

-- Folga entre a base da nave e o topo do pad, pra ela não nascer encaixada nele
local DOCK_CLEARANCE = 0.1

-- Por quanto tempo a ancoragem é reafirmada frame a frame depois que alguém
-- senta (o PlaneScript desancora tudo nesse momento)
local DOCK_HOLD_TIME = 1

-- Por que a nave está sumindo. Só PLAYER_REMOVING é aceito em planeta.
local Reason = {
	PLAYER_REMOVING = "PLAYER_REMOVING",
	STOW = "STOW",
	IDLE = "IDLE",
	RELAUNCH = "RELAUNCH",
}

-- Comandos de teste no chat. Só no Studio ou pra estes nomes.
local TEST_PLAYERS = { einsteinburro = true }

-- Folder de runtime onde as instâncias spawnadas ficam
local SHIPS_FOLDER = "Ships"

local Codes = {
	OK = "OK",
	NOT_LOADED = "NOT_LOADED",
	COOLDOWN = "COOLDOWN",
	INVALID_SHIP = "INVALID_SHIP",
	INVALID_MODULE = "INVALID_MODULE",
	NOT_OWNED = "NOT_OWNED",
	ALREADY_OWNED = "ALREADY_OWNED",
	ALREADY_EQUIPPED = "ALREADY_EQUIPPED",
	MAX_LEVEL = "MAX_LEVEL",
	MISSING_RESOURCES = "MISSING_RESOURCES",
	NOT_ENOUGH_LUMENS = "NOT_ENOUGH_LUMENS",
	TOO_FAR_FROM_SHIP = "TOO_FAR_FROM_SHIP",
	NOT_IN_HANGAR = "NOT_IN_HANGAR",
	INVALID_PAD = "INVALID_PAD",
	NO_FREE_PAD = "NO_FREE_PAD",
	NOT_IN_SPACE = "NOT_IN_SPACE",
	PAD_OCCUPIED = "PAD_OCCUPIED",
	TOO_FAR_FROM_PAD = "TOO_FAR_FROM_PAD",
	SEATED = "SEATED",
	SHIP_NOT_IN_HANGAR = "SHIP_NOT_IN_HANGAR",
	SHIP_NOT_DOCKED = "SHIP_NOT_DOCKED",
	NO_SHIP = "NO_SHIP",
	NOT_YOUR_SHIP = "NOT_YOUR_SHIP",
	SHIP_OCCUPIED = "SHIP_OCCUPIED",
	NOT_ON_PLANET = "NOT_ON_PLANET",
	TELEPORT_FAILED = "TELEPORT_FAILED",
	NOT_PILOTING = "NOT_PILOTING",
	WARP_NO_DESTINATION = "WARP_NO_DESTINATION",
	WARP_OUT_OF_RANGE = "WARP_OUT_OF_RANGE",
	WARP_TOO_CLOSE = "WARP_TOO_CLOSE",
	WARP_ALREADY_CHARGING = "WARP_ALREADY_CHARGING",
	WARP_INTERRUPTED = "WARP_INTERRUPTED",
	WARP_SHIP_DOCKED = "WARP_SHIP_DOCKED",
	NOT_IMPLEMENTED = "NOT_IMPLEMENTED",
}

type ShipRecord = {
	model: Model,
	ownerId: number,
	pad: BasePart?, -- pad do hangar que esta nave ocupa
	docked: boolean, -- pousada e ancorada no pad
	spawnedAt: number, -- os.clock() do spawn (carência antes de poder ancorar)
	holding: boolean?, -- reafirmando a ancoragem frame a frame
	dockingPad: BasePart?, -- pad sobre o qual a contagem de pouso está correndo
	dockingAt: number?, -- tempo do servidor em que a ancoragem se completa
	lastNear: number, -- os.clock() da última vez que o dono estava perto
	conns: { RBXScriptConnection },
}

local ShipService = Knit.CreateService({
	Name = "ShipService",

	Client = {
		-- (state) — estado completo, ver _buildState
		ShipStateChanged = Knit.CreateSignal(),
		-- (status: "charging" | "completed" | "cancelled", info: { destinationId, reason?, chargeTime? })
		WarpStatus = Knit.CreateSignal(),
	},

	Codes = Codes,

	_ships = {} :: { [number]: ShipRecord },
	_padOwners = {} :: { [BasePart]: number }, -- pad do hangar → userId
	_slots = {} :: { [number]: number }, -- userId → posição no LandingPad
	_lastAction = {} :: { [number]: number },
	_warps = {} :: { [number]: any },
	_travels = {} :: { [number]: boolean }, -- dentro do túnel: não aceita outro warp
	_arrivals = {} :: { [number]: string }, -- marcador orbital de chegada (teleporte)
	_placedOnLanding = {} :: { [number]: boolean },
})

-- ═══════════════════════════════════════════════════════════
-- Helpers
-- ═══════════════════════════════════════════════════════════

local function getRoot(player: Player): BasePart?
	local character = player.Character
	local root = character and character:FindFirstChild("HumanoidRootPart")
	return if root and root:IsA("BasePart") then root else nil
end

local function getHumanoid(player: Player): Humanoid?
	local character = player.Character
	return character and character:FindFirstChildOfClass("Humanoid")
end

local function getShipsFolder(): Folder
	local folder = workspace:FindFirstChild(SHIPS_FOLDER)
	if not folder then
		folder = Instance.new("Folder")
		folder.Name = SHIPS_FOLDER
		folder.Parent = workspace
	end
	return folder :: Folder
end

local function getModelsFolder(): Instance?
	local assets = ReplicatedStorage:FindFirstChild(ShipData.ASSETS_FOLDER)
	return assets and assets:FindFirstChild(ShipData.MODELS_FOLDER)
end

local function getSeat(model: Model): Seat | VehicleSeat | nil
	local seat = model:FindFirstChild(ShipData.PARTS.seat, true)
	if seat and (seat:IsA("VehicleSeat") or seat:IsA("Seat")) then
		return seat
	end
	return nil
end

--- Ponto de referência da nave pra distância: Body, ou o pivô.
local function getShipPosition(model: Model): Vector3
	local body = model:FindFirstChild(ShipData.PARTS.body)
	if body and body:IsA("BasePart") then
		return body.Position
	end
	return model:GetPivot().Position
end

--- CFrame que apoia a base do modelo no topo da Part, deslocado offsetX no
--- eixo X dela. A rotação da nave segue a da Part.
local function restOnTop(part: BasePart, model: Model, offsetX: number): CFrame
	local pivot = model:GetPivot()
	local boxCf, boxSize = model:GetBoundingBox()
	local lift = pivot.Position.Y - (boxCf.Position.Y - boxSize.Y / 2)
	return part.CFrame * CFrame.new(offsetX, part.Size.Y / 2 + lift, 0)
end

function ShipService:_checkCooldown(player: Player): boolean
	local now = os.clock()
	local last = self._lastAction[player.UserId] or 0
	if now - last < ACTION_COOLDOWN then
		return false
	end
	self._lastAction[player.UserId] = now
	return true
end

function ShipService:_getModel(player: Player): Model?
	local record = self._ships[player.UserId]
	return if record and record.model.Parent then record.model else nil
end

--- No hangar: dentro da HangarZone ou encostado no terminal. A zona sozinha não
--- serve pra tudo (trocar de nave é no terminal), mas pra melhoria vale.
function ShipService:_isAtHangar(player: Player): boolean
	local root = getRoot(player)
	if root and PlaceConfig.IsInHangarZone(root.Position) then
		return true
	end
	return self:_isAtTerminal(player)
end

--- Perto do HangarTerminal: onde se troca de nave e melhora pelo HUD.
function ShipService:_isAtTerminal(player: Player): boolean
	local terminal = PlaceConfig.GetHangarTerminal()
	local root = getRoot(player)
	if not terminal or not root then
		return false
	end
	local reach = terminal.Size.Magnitude / 2 + ShipData.HANGAR_INTERACT_DISTANCE
	return (root.Position - terminal.Position).Magnitude <= reach
end

function ShipService:_isNearOwnShip(player: Player): boolean
	local model = self:_getModel(player)
	local root = getRoot(player)
	return model ~= nil
		and root ~= nil
		and (root.Position - getShipPosition(model)).Magnitude <= ShipData.UPGRADE_DISTANCE
end

-- ═══════════════════════════════════════════════════════════
-- Perfil
-- ═══════════════════════════════════════════════════════════

function ShipService:_getShipsProfile(player: Player)
	local profile = self._playerData:GetProfile(player)
	return profile and profile.ships
end

--- Níveis da nave, ou nil se o jogador não a possui (ou é id órfão).
function ShipService:_getOwnedLevels(player: Player, shipId: string)
	local ships = self:_getShipsProfile(player)
	if not ships or not ShipData.IsValidShip(shipId) then
		return nil
	end
	local levels = ships.owned[shipId]
	return if typeof(levels) == "table" then levels else nil
end

function ShipService:GetEquippedShipId(player: Player): string?
	local ships = self:_getShipsProfile(player)
	return ships and ships.equipped
end

function ShipService:GetEquippedStats(player: Player)
	local shipId = self:GetEquippedShipId(player)
	if not shipId then
		return nil
	end
	return ShipData.ComputeStats(shipId, self:_getOwnedLevels(player, shipId))
end

--- Stats da nave que está spawnada (pode não ser a equipada: trocar de nave
--- no hangar não recolhe a que já está lançada).
function ShipService:_getInstanceStats(player: Player, model: Model)
	local shipId = model:GetAttribute(ShipData.SHIP_ID_ATTRIBUTE)
	if typeof(shipId) ~= "string" then
		return nil
	end
	return ShipData.ComputeStats(shipId, self:_getOwnedLevels(player, shipId))
end

--- Qualidade de mineração da nave equipada (0 sem perfil carregado).
function ShipService:GetMiningQuality(player: Player): number
	local stats = self:GetEquippedStats(player)
	return if stats then stats.miningQuality else 0
end

function ShipService:_buildState(player: Player)
	local ships = self:_getShipsProfile(player)
	if not ships then
		return { loaded = false }
	end

	-- Id órfão não vai pro client: pra UI ele não existe
	local owned = {}
	for shipId, levels in ships.owned do
		if ShipData.IsValidShip(shipId) and typeof(levels) == "table" then
			owned[shipId] = {
				engine = levels.engine,
				weapon = levels.weapon,
				drill = levels.drill,
				plating = levels.plating,
				skin = levels.skin,
			}
		end
	end

	return {
		loaded = true,
		equipped = ships.equipped,
		owned = owned,
		instance = self:_getModel(player),
		isPlanet = PlaceConfig.IsPlanet(),
		hasHangar = PlaceConfig.HasHangar(),
	}
end

function ShipService:_pushState(player: Player)
	self.Client.ShipStateChanged:Fire(player, self:_buildState(player))
end

-- ═══════════════════════════════════════════════════════════
-- Configurations
-- ═══════════════════════════════════════════════════════════

local warnedMissing: { [string]: boolean } = {}

--- Escreve os stats resolvidos no Configurations do modelo. Value ausente no
--- modelo não é erro: a nave continua com o fallback digitado no Studio.
local function writeConfigurations(model: Model, stats, keepHullDamage: boolean?)
	local config = model:FindFirstChild(ShipData.PARTS.configurations)
	if not config then
		if not warnedMissing[model.Name] then
			warnedMissing[model.Name] = true
			warn(string.format("[ShipService] %s sem Configurations — usando valores do modelo", model.Name))
		end
		return
	end

	-- Upgrade de blindagem com a nave avariada: mantém o dano sofrido
	local hullValue = config:FindFirstChild("Hull")
	local maxHullValue = config:FindFirstChild("MaxHull")
	local oldHull = if hullValue and hullValue:IsA("NumberValue") then hullValue.Value else nil
	local oldMax = if maxHullValue and maxHullValue:IsA("NumberValue") then maxHullValue.Value else nil

	for _, field in ShipData.CONFIG_FIELDS do
		local value = config:FindFirstChild(field.name)
		if value and value:IsA(field.class) then
			(value :: any).Value = stats[field.stat]
		elseif not warnedMissing[model.Name .. field.name] then
			warnedMissing[model.Name .. field.name] = true
			warn(string.format("[ShipService] %s.Configurations sem %s (%s)", model.Name, field.name, field.class))
		end
	end

	if keepHullDamage and hullValue and hullValue:IsA("NumberValue") and oldHull and oldMax then
		local damage = math.max(oldMax - oldHull, 0)
		hullValue.Value = math.max(stats.maxHull - damage, 1)
	end
end

-- ═══════════════════════════════════════════════════════════
-- Spawn / despawn
-- ═══════════════════════════════════════════════════════════

--- A lógica de voo é do PlaneScript, dentro do modelo. Um modelo sem Script (ou
--- com ele Disabled) spawna normal e não voa: o jogador senta e nada acontece.
local checkedModels: { [string]: boolean } = {}

local function checkShipScripts(model: Model)
	if checkedModels[model.Name] then
		return
	end
	checkedModels[model.Name] = true

	local enabled, disabled = 0, 0
	for _, inst in model:GetDescendants() do
		if inst:IsA("Script") and inst.RunContext ~= Enum.RunContext.Client then
			if inst.Disabled then
				disabled += 1
			else
				enabled += 1
			end
		end
	end

	if enabled == 0 then
		warn(string.format(
			"[ShipService] %s não tem nenhum Script de servidor ativo (%d desabilitado(s)) — "
				.. "o PlaneScript é quem dá controle da nave; sem ele o jogador senta e não voa",
			model.Name,
			disabled
		))
	end
end

--- Com GunsEnabled o PlaneScript espera a pasta Guns (com Muzzle em cada arma)
--- e o LocalPlaneScript chama plane.Shoot:FireServer ao soltar o botão — sem o
--- RemoteEvent isso vira erro no client a cada clique.
local function checkGunSetup(model: Model, gunsEnabled: boolean)
	if not gunsEnabled or checkedModels[model.Name .. "_guns"] then
		return
	end
	checkedModels[model.Name .. "_guns"] = true

	local missing = {}
	local guns = model:FindFirstChild("Guns")
	if not guns then
		table.insert(missing, "a pasta Guns")
	elseif not guns:FindFirstChild("Muzzle", true) then
		table.insert(missing, "o Attachment/Part Muzzle dentro de Guns")
	end
	if not model:FindFirstChild("Shoot") then
		table.insert(missing, "o RemoteEvent Shoot")
	end

	if #missing > 0 then
		warn(string.format(
			"[ShipService] %s tem GunsEnabled = true mas falta %s — o tiro não funciona",
			model.Name,
			table.concat(missing, " e ")
		))
	end
end

function ShipService:_getTemplate(shipId: string): Model?
	local def = ShipData.GetShip(shipId)
	local folder = getModelsFolder()
	if not def or not folder then
		warn(string.format("[ShipService] ReplicatedStorage.%s.%s não existe", ShipData.ASSETS_FOLDER, ShipData.MODELS_FOLDER))
		return nil
	end

	local template = folder:FindFirstChild(def.modelName)
	if template and template:IsA("Model") then
		return template
	end

	-- Modelo ainda não feito no Studio: usa o da nave padrão e, se nem ele
	-- existir, qualquer modelo da pasta. Os stats continuam os da nave certa —
	-- é melhor voar com o casco errado do que não ter nave nenhuma.
	local fallbackDef = ShipData.GetShip(ShipData.DEFAULT_SHIP)
	local fallback = fallbackDef and folder:FindFirstChild(fallbackDef.modelName)
	if not (fallback and fallback:IsA("Model")) then
		fallback = folder:FindFirstChildWhichIsA("Model")
	end

	if fallback and fallback:IsA("Model") then
		warn(string.format(
			"[ShipService] Modelo %s não existe em %s — usando %s no lugar",
			def.modelName,
			ShipData.MODELS_FOLDER,
			fallback.Name
		))
		return fallback
	end

	warn(string.format("[ShipService] Modelo %s não encontrado e a pasta %s está vazia", def.modelName, ShipData.MODELS_FOLDER))
	return nil
end

--- Cria a instância da nave equipada. place(model) devolve o CFrame do pivô
--- (recebe o clone ainda fora do workspace, pra medir o tamanho).
function ShipService:_spawn(player: Player, place: (Model) -> CFrame?, pad: BasePart?): Model?
	local shipId = self:GetEquippedShipId(player)
	local stats = shipId and ShipData.ComputeStats(shipId, self:_getOwnedLevels(player, shipId))
	local template = shipId and self:_getTemplate(shipId)
	if not stats or not template then
		return nil
	end

	local model = template:Clone()
	local cframe = place(model)
	if not cframe then
		model:Destroy()
		return nil
	end

	-- Tudo antes do Parent: o PlaneScript do modelo começa a rodar quando a
	-- nave entra no workspace e já precisa encontrar os valores certos
	writeConfigurations(model, stats)
	model:SetAttribute(ShipData.OWNER_ATTRIBUTE, player.UserId)
	model:SetAttribute(ShipData.SHIP_ID_ATTRIBUTE, shipId)
	CollectionService:AddTag(model, ShipData.SHIP_TAG)
	model:PivotTo(cframe)

	local seat = getSeat(model)
	if seat and PlaceConfig.IsPlanet() then
		-- Em planeta a nave não voa: sentar por qualquer caminho prenderia o jogador
		seat.Disabled = true
	end

	model.Parent = getShipsFolder()
	checkShipScripts(model)
	checkGunSetup(model, stats.gunsEnabled)

	local record: ShipRecord = {
		model = model,
		ownerId = player.UserId,
		pad = pad,
		docked = false,
		spawnedAt = os.clock(),
		lastNear = os.clock(),
		conns = {},
	}
	self._ships[player.UserId] = record
	if pad then
		self._padOwners[pad] = player.UserId
		pad:SetAttribute(PlaceConfig.PAD_OCCUPIED_ATTRIBUTE, player.UserId)
	end

	self:_bindInstance(player, record)
	self:_pushState(player)

	return model
end

--[[
	Remove a nave do jogador.

	CRITÉRIO DE ACEITE — em Place de planeta a nave NUNCA despawna enquanto o
	jogador estiver lá. Ela é a única saída: se sumir, ele fica preso sem rota e
	sem aviso. Qualquer limpeza (timeout, inatividade, "cleanup de objetos
	antigos") tem que passar por aqui, e aqui ela é recusada. A única exceção é
	o próprio jogador saindo do servidor.
]]
function ShipService:_despawn(player: Player, reason: string): boolean
	local userId = player.UserId
	local record = self._ships[userId]
	if not record then
		return true
	end

	if PlaceConfig.IsPlanet() and reason ~= Reason.PLAYER_REMOVING then
		warn(string.format(
			"[ShipService] Despawn da nave de %s RECUSADO em planeta (motivo: %s) — a nave é a única saída",
			player.Name,
			reason
		))
		return false
	end

	self:_cancelWarp(player, "CANCELLED")

	-- Tira o registro antes do Destroy: o AncestryChanged não pode tratar
	-- isto como "nave destruída por fora"
	self._ships[userId] = nil
	record.docked = false
	self:_releasePad(record)
	for _, conn in record.conns do
		conn:Disconnect()
	end
	record.model:Destroy()

	return true
end

function ShipService:_releasePad(record: ShipRecord)
	local pad = record.pad
	if pad then
		record.pad = nil
		self._padOwners[pad] = nil
		pad:SetAttribute(PlaceConfig.PAD_OCCUPIED_ATTRIBUTE, nil)
	end
end

function ShipService:_bindInstance(player: Player, record: ShipRecord)
	local userId = player.UserId
	local model = record.model
	local conns = record.conns

	local seat = getSeat(model)
	if seat then
		-- Só o dono senta na própria nave (o Touched do assento senta qualquer um)
		table.insert(conns, seat:GetPropertyChangedSignal("Occupant"):Connect(function()
			local occupant = seat.Occupant
			if not occupant then
				self:_cancelWarp(player, Codes.WARP_INTERRUPTED)
				return
			end

			-- Sentar não solta a nave: quem solta é o piloto, acelerando.
			-- O PlaneScript desancora tudo ao entrar no assento e o
			-- LocalPlaneScript já começa a girar a nave pelo BodyGyro, então
			-- reancorar uma vez só deixava a nave voando no intervalo.
			if record.docked then
				self:_holdDocked(record)
			end
			local occupantPlayer = Players:GetPlayerFromCharacter(occupant.Parent)
			if occupantPlayer ~= player then
				local weld = seat:FindFirstChild("SeatWeld")
				if weld then
					weld:Destroy()
				end
				occupant.Sit = false
			end
		end))
	end

	-- Dano no casco interrompe a carga do warp
	local config = model:FindFirstChild(ShipData.PARTS.configurations)
	local hull = config and config:FindFirstChild("Hull")
	if hull and hull:IsA("NumberValue") then
		local last = hull.Value
		table.insert(conns, hull.Changed:Connect(function(value)
			if value < last then
				self:_cancelWarp(player, Codes.WARP_INTERRUPTED)
			end
			last = value
		end))
	end

	table.insert(conns, model.AncestryChanged:Connect(function()
		if model.Parent or self._ships[userId] ~= record then
			return
		end

		-- Nave destruída por fora (casco zerado, caiu do mapa)
		self._ships[userId] = nil
		self:_releasePad(record)
		for _, conn in conns do
			conn:Disconnect()
		end
		self:_cancelWarp(player, "CANCELLED")
		self:_pushState(player)

		-- Em planeta a nave é a única saída: volta sozinha
		if PlaceConfig.IsPlanet() then
			task.delay(RESPAWN_DELAY, function()
				if player.Parent and not self._ships[userId] then
					self:SpawnOnLanding(player)
				end
			end)
		end
	end))
end

--[[
	Senta o dono assim que der. Não basta chamar Sit uma vez:

	  - o personagem pode não existir ainda (chegada por teleporte)
	  - Seat.Disabled = true faz o Sit ser ignorado em silêncio. O modelo pode
	    vir com o assento desabilitado do Studio (é o pedido pra planeta, §9.4),
	    e no espaço ele precisa estar ligado
	  - o Sit é desfeito se o personagem estiver pulando/caindo no mesmo instante

	Então: tenta, confere se pegou (humanoid.SeatPart) e repete. Se desistir,
	diz no Output o estado de cada coisa, pra não virar "simplesmente não pega".
]]
local SEAT_ATTEMPTS = 8
local SEAT_RETRY = 0.35

-- Respiro entre criar a nave e sentar o jogador nela
local SPAWN_SETTLE = 0.5

-- Quanto esperar pra conferir se o PlaneScript entregou o controle, e quantas
-- vezes re-sentar quando não entregou
local CONTROL_CHECK_DELAY = 1
local CONTROL_RESEAT_ATTEMPTS = 3

function ShipService:_seatWhenReady(player: Player, model: Model, onSeated: (() -> ())?)
	task.spawn(function()
		-- Só é chamado em nave recém-criada. O PlaneScript dela começa a rodar
		-- agora e precisa chegar no seat.Changed:Connect antes de alguém sentar,
		-- senão a troca de ocupante acontece sem ninguém escutando.
		task.wait(SPAWN_SETTLE)

		local deadline = os.clock() + 15
		local attempts = 0
		local seat: (Seat | VehicleSeat)? = nil

		while os.clock() < deadline and player.Parent and model.Parent and attempts < SEAT_ATTEMPTS do
			local humanoid = getHumanoid(player)
			seat = getSeat(model)

			if not seat then
				break -- modelo sem assento: nada a tentar
			end

			if humanoid and humanoid.Health > 0 and getRoot(player) then
				if humanoid.SeatPart == seat then
					if onSeated then
						onSeated()
					end
					return -- já sentado
				end

				-- Em planeta o assento fica desabilitado de propósito (a nave não voa)
				if seat.Disabled and not PlaceConfig.IsPlanet() then
					seat.Disabled = false
				end

				-- Sentado em outro lugar: sair primeiro, senão o Sit é ignorado
				if humanoid.SeatPart and humanoid.SeatPart ~= seat then
					humanoid.Sit = false
					task.wait(0.1)
				end

				seat:Sit(humanoid)
				attempts += 1

				task.wait(SEAT_RETRY)
				if humanoid.SeatPart == seat then
					self:_verifyControl(player, model, seat)
					if onSeated then
						onSeated()
					end
					return
				end
			else
				task.wait(0.2)
			end
		end

		local humanoid = getHumanoid(player)
		warn(string.format(
			"[ShipService] Não consegui sentar %s na nave após %d tentativas — assento: %s · Disabled: %s · "
				.. "ocupante: %s · humanoid: %s · estado: %s",
			player.Name,
			attempts,
			if seat then seat:GetFullName() else "NÃO ENCONTRADO (o modelo precisa de uma parte chamada " .. ShipData.PARTS.seat .. ")",
			if seat then tostring(seat.Disabled) else "-",
			if seat and seat.Occupant then seat.Occupant:GetFullName() else "nenhum",
			if humanoid then "ok" else "sem Humanoid",
			if humanoid then humanoid:GetState().Name else "-"
		))
	end)
end

--[[
	Sentar é só metade: quem dá controle é o PlaneScript do modelo, reagindo a
	seat.Occupant. Ele faz duas coisas que o voo depende:

	  Body:SetNetworkOwner(player)  — sem isso o BodyVelocity criado no client
	                                  não tem autoridade e a nave não sai do lugar
	  clona o LocalPlaneScript      — é ele que lê o teclado/toque

	Se o jogador senta e não controla, é uma dessas duas. Aqui a gente confere e,
	no caso da posse de rede, corrige — é idempotente e o PlaneScript não se
	incomoda de ela já estar dada.
]]
--- O PlaneScript clona o LocalPlaneScript na PlayerGui ao sentar. Ele é a
--- prova, visível do servidor, de que o controle da nave foi entregue.
local function hasFlightScript(player: Player): boolean
	local playerGui = player:FindFirstChildOfClass("PlayerGui")
	if not playerGui then
		return false
	end
	for _, inst in playerGui:GetChildren() do
		if inst:IsA("LocalScript") and inst:FindFirstChild("Plane") and not inst.Disabled then
			return true
		end
	end
	return false
end

function ShipService:_verifyControl(player: Player, model: Model, seat: Seat | VehicleSeat, attempt: number?)
	local attemptNumber = attempt or 1

	task.delay(CONTROL_CHECK_DELAY, function()
		local humanoid = getHumanoid(player)
		if not humanoid or humanoid.SeatPart ~= seat or not model.Parent then
			return -- saiu do assento nesse meio tempo
		end
		if PlaceConfig.IsPlanet() then
			return -- em planeta a nave não voa de propósito
		end

		local body = model:FindFirstChild(ShipData.PARTS.body)

		if hasFlightScript(player) then
			-- Controle entregue. Garante só a posse de rede, que é o que faz o
			-- BodyVelocity do client ter autoridade.
			if body and body:IsA("BasePart") and not body.Anchored then
				local owner: Player? = nil
				local readable = pcall(function()
					owner = body:GetNetworkOwner()
				end)
				if readable and owner ~= player then
					pcall(function()
						body:SetNetworkOwner(player)
					end)
					warn(string.format(
						"[ShipService] Posse de rede de %s dada pelo serviço — o PlaneScript não fez isso ao sentar",
						model.Name
					))
				end
			end
			return
		end

		-- Nave recém-criada: o PlaneScript pode não ter chegado no
		-- seat.Changed:Connect quando sentamos, e aí a troca de ocupante
		-- aconteceu sem ninguém escutando. Re-sentar dispara o evento de novo.
		if attemptNumber <= CONTROL_RESEAT_ATTEMPTS then
			humanoid.Sit = false
			task.wait(0.4)
			if not model.Parent or not player.Parent then
				return
			end
			seat:Sit(humanoid)
			self:_verifyControl(player, model, seat, attemptNumber + 1)
			return
		end

		warn(string.format(
			"[ShipService] %s sentou e o PlaneScript não entregou o controle em %d tentativas — "
				.. "confira se o LocalPlaneScript existe dentro do PlaneScript, se não está Disabled, e se o "
				.. "SetNetworkOwner do Body (%s) não está dando erro antes do clone",
			player.Name,
			attemptNumber,
			if body and body:IsA("BasePart") then
				(if body.Anchored then "ainda Anchored" else "ok")
			else
				"parte " .. ShipData.PARTS.body .. " não encontrada"
		))
	end)
end

-- ── Planeta ────────────────────────────────────────────────

--- Posição livre no LandingPad (0, 1, -1, 2, -2...) pra naves de jogadores
--- diferentes não nascerem uma dentro da outra.
function ShipService:_claimSlot(userId: number): number
	if self._slots[userId] then
		return self._slots[userId]
	end

	local used = {}
	for _, slot in self._slots do
		used[slot] = true
	end

	local i = 0
	while true do
		local candidate = if i % 2 == 0 then i // 2 else -((i + 1) // 2)
		if not used[candidate] then
			self._slots[userId] = candidate
			return candidate
		end
		i += 1
	end
end

--- Planeta: nave pousada no LandingPad. Se já existe, devolve a mesma.
function ShipService:SpawnOnLanding(player: Player): Model?
	local existing = self:_getModel(player)
	if existing then
		return existing
	end

	local pad = PlaceConfig.GetLandingPad()
	if not pad then
		warn("[ShipService] Place de planeta sem LandingPad — a nave não tem onde pousar")
		return nil
	end

	local model = self:_spawn(player, function(clone)
		local _, size = clone:GetBoundingBox()
		return restOnTop(pad, clone, self:_claimSlot(player.UserId) * (size.X + SHIP_SPACING))
	end)

	if model and not self._placedOnLanding[player.UserId] then
		self:_placeCharacterBeside(player, model, pad)
	end

	return model
end

--- "Como se tivesse pousado": o jogador aparece ao lado da nave, uma vez por
--- entrada no Place.
function ShipService:_placeCharacterBeside(player: Player, model: Model, pad: BasePart)
	self._placedOnLanding[player.UserId] = true

	task.spawn(function()
		local character = player.Character or player.CharacterAdded:Wait()
		local root = character:WaitForChild("HumanoidRootPart", 10)
		if not root or not model.Parent then
			return
		end
		-- Deixa o spawn padrão terminar de posicionar antes de mover
		task.wait()

		local boxCf, size = model:GetBoundingBox()
		local right = pad.CFrame.RightVector
		local topY = pad.Position.Y + pad.Size.Y / 2
		local position = Vector3.new(boxCf.Position.X, topY + 3, boxCf.Position.Z) + right * (size.X / 2 + CHARACTER_SIDE_GAP)

		character:PivotTo(CFrame.lookAt(position, position + pad.CFrame.LookVector))
	end)
end

-- ── Espaço ────────────────────────────────────────────────

--- Chegada de planeta: nasce na órbita dele, já sentado.
function ShipService:SpawnAtArrival(player: Player, markerId: string): Model?
	local destination = WarpModule.GetDestination(markerId)
	if not destination then
		warn(string.format("[ShipService] Marcador orbital '%s' não existe neste Place", markerId))
		return nil
	end

	self:_despawn(player, Reason.RELAUNCH)

	local model = self:_spawn(player, function()
		local from = destination.position - destination.part.CFrame.LookVector
		return WarpModule.GetArrivalCFrame(from, destination.part)
	end)

	if model then
		self:_seatWhenReady(player, model)
	end
	return model
end

-- ═══════════════════════════════════════════════════════════
-- Pouso (ancoragem na plataforma)
-- ═══════════════════════════════════════════════════════════

--[[
	A nave encosta na plataforma e gruda: assenta no topo, alinha com o pad e
	ancora. É esse estado que libera as melhorias — o hangar é oficina, e não
	dá pra trabalhar numa nave flutuando.

	Sai do modo ancorado ao sentar: o PlaneScript já desancora tudo quando o
	ocupante entra, e aqui a gente faz o mesmo antes dele, pra não depender da
	ordem.
]]

--- Topo do pad e raio dele, medidos no mundo. Não dá pra usar os eixos locais
--- da Part: num cilindro o "pra cima" é o X local, e num pad girado o Y local
--- aponta pro lado. ExtentsSize já vem alinhado ao mundo, seja qual for a
--- forma (cilindro, bloco, mesh) ou a rotação.
--- Centro (em X/Z) e ponto mais baixo da nave, contando só o que aparece na
--- tela. Model:GetBoundingBox() inclui hitbox e parte invisível, e uma caixa
--- maior que a nave faz ela pousar flutuando.
local function visibleBase(model: Model): (Vector3, number)
	local minY, maxY = math.huge, -math.huge
	local minX, maxX = math.huge, -math.huge
	local minZ, maxZ = math.huge, -math.huge
	local found = false

	local function measure(part: BasePart)
		local cf, size = part.CFrame, part.Size / 2
		-- Meia-extensão da parte já rotacionada, projetada em cada eixo do mundo
		local ext = Vector3.new(
			math.abs(cf.RightVector.X) * size.X + math.abs(cf.UpVector.X) * size.Y + math.abs(cf.LookVector.X) * size.Z,
			math.abs(cf.RightVector.Y) * size.X + math.abs(cf.UpVector.Y) * size.Y + math.abs(cf.LookVector.Y) * size.Z,
			math.abs(cf.RightVector.Z) * size.X + math.abs(cf.UpVector.Z) * size.Y + math.abs(cf.LookVector.Z) * size.Z
		)
		minY = math.min(minY, cf.Position.Y - ext.Y)
		maxY = math.max(maxY, cf.Position.Y + ext.Y)
		minX = math.min(minX, cf.Position.X - ext.X)
		maxX = math.max(maxX, cf.Position.X + ext.X)
		minZ = math.min(minZ, cf.Position.Z - ext.Z)
		maxZ = math.max(maxZ, cf.Position.Z + ext.Z)
		found = true
	end

	for _, part in model:GetDescendants() do
		if part:IsA("BasePart") and part.Transparency < 1 then
			measure(part)
		end
	end

	-- Nave toda invisível (ou só hitbox): vale a caixa cheia
	if not found then
		local boxCf, size = model:GetBoundingBox()
		return boxCf.Position, boxCf.Position.Y - size.Y / 2
	end

	return Vector3.new((minX + maxX) / 2, (minY + maxY) / 2, (minZ + maxZ) / 2), minY
end

local function padBounds(pad: BasePart): (number, number)
	local extents = pad.ExtentsSize
	return pad.Position.Y + extents.Y / 2, math.max(extents.X, extents.Z) / 2
end

--- Pad embaixo da nave, se ela estiver dentro da área e da altura dele.
function ShipService:_padUnder(record: ShipRecord, position: Vector3): BasePart?
	for _, pad in PlaceConfig.GetHangarPads() do
		local owner = self._padOwners[pad]
		if not owner or owner == record.ownerId then
			local top, radius = padBounds(pad)
			local flat = (Vector3.new(position.X, 0, position.Z) - Vector3.new(pad.Position.X, 0, pad.Position.Z)).Magnitude
			local height = position.Y - top

			if
				flat <= radius + ShipData.DOCK_MARGIN
				and height >= -pad.ExtentsSize.Y
				and height <= ShipData.DOCK_HEIGHT
			then
				return pad
			end
		end
	end
	return nil
end

--- Cancela a contagem de ancoragem (e some com o aviso no client).
function ShipService:_clearDocking(record: ShipRecord)
	record.dockingPad = nil
	record.dockingAt = nil
	if record.model.Parent then
		record.model:SetAttribute(ShipData.DOCKING_ATTRIBUTE, nil)
	end
end

--- Trava a nave onde ela está. Fica separado porque precisa ser reaplicado: o
--- PlaneScript desancora tudo quando alguém senta, e sentar numa nave ancorada
--- não é decolar — quem solta é o piloto, acelerando.
function ShipService:_applyDockedPhysics(record: ShipRecord)
	local model = record.model
	if not model.Parent then
		return
	end

	-- Posse de rede volta pro servidor: parte ancorada não tem dono, e o client
	-- não pode seguir empurrando uma nave presa
	local body = model:FindFirstChild(ShipData.PARTS.body)
	if body and body:IsA("BasePart") then
		pcall(function()
			body:SetNetworkOwner(nil)
		end)
	end

	for _, part in model:GetDescendants() do
		if part:IsA("BasePart") then
			part.AssemblyLinearVelocity = Vector3.zero
			part.AssemblyAngularVelocity = Vector3.zero
			part.Anchored = true
		end
	end
end

--- Reancora a cada frame por um instante. É a resposta ao PlaneScript, que
--- desancora tudo ao alguém sentar: sem insistir, a nave escapa no intervalo
--- entre o desancorar dele e o reancorar nosso.
function ShipService:_holdDocked(record: ShipRecord)
	if record.holding then
		return
	end
	record.holding = true

	task.spawn(function()
		local deadline = os.clock() + DOCK_HOLD_TIME
		while os.clock() < deadline and record.docked and record.model.Parent do
			self:_applyDockedPhysics(record)
			RunService.Heartbeat:Wait()
		end
		record.holding = false
	end)
end

function ShipService:_dock(player: Player, record: ShipRecord, pad: BasePart)
	local model = record.model
	local body = model:FindFirstChild(ShipData.PARTS.body)

	-- Nivela a nave mantendo a direção pra onde ela estava apontando. A
	-- referência é o Body, não o pivô: o pivô de um Model sem PrimaryPart fica
	-- onde foi posto e pode estar torto em relação ao casco — nivelar por ele
	-- deixava a nave inclinada, e a caixa de uma nave inclinada é mais alta do
	-- que ela, o que fazia a nave assentar no ar.
	if body and body:IsA("BasePart") then
		local current = body.CFrame
		local look = Vector3.new(current.LookVector.X, 0, current.LookVector.Z)
		if look.Magnitude < 0.01 then
			look = Vector3.new(0, 0, -1)
		end
		local levelled = CFrame.lookAt(current.Position, current.Position + look.Unit)
		-- A mesma transformação rígida vale pro modelo inteiro
		model:PivotTo(levelled * current:Inverse() * model:GetPivot())
	end

	-- Assenta a base visível no topo do pad
	local center, bottom = visibleBase(model)
	local top = padBounds(pad)
	model:PivotTo(model:GetPivot() + Vector3.new(
		pad.Position.X - center.X,
		top + DOCK_CLEARANCE - bottom,
		pad.Position.Z - center.Z
	))

	self:_applyDockedPhysics(record)

	-- Mesma regra do RequestWarp: ancorou no meio da carga, o warp cai
	self:_cancelWarp(player, Codes.WARP_SHIP_DOCKED)

	record.docked = true
	record.pad = pad
	self._padOwners[pad] = player.UserId
	pad:SetAttribute(PlaceConfig.PAD_OCCUPIED_ATTRIBUTE, player.UserId)
	model:SetAttribute(ShipData.DOCKED_ATTRIBUTE, true)

	self:_pushState(player)
end

function ShipService:_undock(player: Player?, record: ShipRecord)
	self:_clearDocking(record)
	if not record.docked then
		return
	end
	record.docked = false

	local model = record.model
	if model.Parent then
		model:SetAttribute(ShipData.DOCKED_ATTRIBUTE, nil)
		for _, part in model:GetDescendants() do
			if part:IsA("BasePart") then
				part.Anchored = false
			end
		end

		-- Ancorar tira a posse de rede (parte ancorada não tem dono). Sem
		-- devolver, o BodyVelocity do client perde a autoridade e a nave fica
		-- colada no pad mesmo desancorada.
		local seat = getSeat(model)
		local occupant = seat and seat.Occupant
		local pilot = occupant and Players:GetPlayerFromCharacter(occupant.Parent)
		local body = model:FindFirstChild(ShipData.PARTS.body)
		if pilot and body and body:IsA("BasePart") then
			pcall(function()
				body:SetNetworkOwner(pilot)
			end)
		end
	end

	if player then
		self:_pushState(player)
	end
end

--- Soltar a nave do pad a pedido do piloto (acelerar com ela ancorada).
function ShipService:RequestUndock(player: Player): (boolean, string)
	local record = self._ships[player.UserId]
	if not record or not record.model.Parent then
		return false, Codes.NO_SHIP
	end
	if not record.docked then
		return true, Codes.OK
	end

	local seat = getSeat(record.model)
	local occupant = seat and seat.Occupant
	local humanoid = getHumanoid(player)
	if occupant and occupant ~= humanoid then
		return false, Codes.SHIP_OCCUPIED
	end

	self:_undock(player, record)
	return true, Codes.OK
end

--- Libera pads cujas naves já saíram de cima, e recolhe naves abandonadas.
function ShipService:_maintain()
	local planet = PlaceConfig.IsPlanet()
	local now = os.clock()

	for userId, record in self._ships do
		local player = Players:GetPlayerByUserId(userId)
		local model = record.model
		if not player or not model.Parent then
			continue
		end

		local position = getShipPosition(model)
		local seat = getSeat(model)
		local humanoid = getHumanoid(player)
		local root = getRoot(player)
		local piloting = seat ~= nil and humanoid ~= nil and seat.Occupant == humanoid

		-- Pouso: parada por cima de um pad livre, a nave gruda depois da contagem.
		-- Vale com o piloto dentro: pousar é manobra, não precisa sair antes.
		-- A carência evita ancorar a nave recém-lançada antes de ela decolar.
		local settled = os.clock() - record.spawnedAt >= ShipData.DOCK_SPAWN_GRACE
		if not planet and not record.docked and settled then
			local body = model:FindFirstChild(ShipData.PARTS.body)
			local velocity = if body and body:IsA("BasePart") then body.AssemblyLinearVelocity.Magnitude else 0
			local pad = if velocity <= ShipData.DOCK_SPEED_LIMIT then self:_padUnder(record, position) else nil

			if pad then
				if record.dockingPad ~= pad then
					-- Começou agora: o client mostra a contagem a partir do atributo,
					-- que vai no relógio do servidor (o mesmo pros dois lados)
					record.dockingPad = pad
					record.dockingAt = workspace:GetServerTimeNow() + ShipData.DOCK_DELAY
					model:SetAttribute(ShipData.DOCKING_ATTRIBUTE, record.dockingAt)
				elseif workspace:GetServerTimeNow() >= record.dockingAt then
					self:_clearDocking(record)
					self:_dock(player, record, pad)
				end
			elseif record.dockingPad then
				-- Saiu de cima ou acelerou: a contagem recomeça do zero na próxima
				self:_clearDocking(record)
			end
		elseif record.dockingPad then
			self:_clearDocking(record)
		end

		-- Nave saiu do pad: libera pra próxima (ancorada, ela não sai sozinha)
		if
			record.pad
			and not record.docked
			and (position - record.pad.Position).Magnitude > ShipData.PAD_CLEAR_DISTANCE
		then
			self:_releasePad(record)
		end

		-- Planeta: nunca expira (ver _despawn)
		if planet then
			continue
		end

		local near = root ~= nil and (root.Position - position).Magnitude <= ShipData.IDLE_NEAR_DISTANCE

		-- Nave ancorada no hangar não expira: ela está guardada, não abandonada
		if record.docked then
			record.lastNear = now
		elseif piloting or near then
			record.lastNear = now
		elseif now - record.lastNear >= ShipData.IDLE_DESPAWN_TIME then
			if self:_despawn(player, Reason.IDLE) then
				self:_pushState(player)
			end
		end
	end
end

-- ═══════════════════════════════════════════════════════════
-- API (server)
-- ═══════════════════════════════════════════════════════════

--- Concede uma nave sem custo (teste / marco de progressão).
function ShipService:GrantShip(player: Player, shipId: string): (boolean, string)
	local ships = self:_getShipsProfile(player)
	if not ships then
		return false, Codes.NOT_LOADED
	end
	if not ShipData.IsValidShip(shipId) then
		return false, Codes.INVALID_SHIP
	end
	if typeof(ships.owned[shipId]) == "table" then
		return false, Codes.ALREADY_OWNED
	end

	ships.owned[shipId] = ShipData.DefaultModuleLevels(shipId)
	self:_pushState(player)
	return true, Codes.OK
end

function ShipService:UpgradeModule(player: Player, moduleId: any): (boolean, string)
	local ships = self:_getShipsProfile(player)
	if not ships then
		return false, Codes.NOT_LOADED
	end
	if not ShipData.IsValidModule(moduleId) then
		return false, Codes.INVALID_MODULE
	end
	if not self:_checkCooldown(player) then
		return false, Codes.COOLDOWN
	end

	-- Melhoria é serviço de hangar: o jogador dentro dele (zona ou terminal) e a
	-- nave pousada lá. Nave lançada fora do hangar não recebe upgrade — e em
	-- planeta, que não tem hangar, não há melhoria nenhuma.
	if not self:_isAtHangar(player) then
		return false, Codes.NOT_IN_HANGAR
	end

	-- Nave lançada só recebe upgrade ancorada numa plataforma. Sem nave lançada
	-- (guardada) ela está no hangar de qualquer jeito.
	local record = self._ships[player.UserId]
	if record and record.model.Parent and not record.docked then
		return false, Codes.SHIP_NOT_DOCKED
	end

	local shipId = ships.equipped
	local levels = self:_getOwnedLevels(player, shipId)
	if not levels then
		return false, Codes.NOT_OWNED
	end

	local current = levels[moduleId]
	local cost = ShipData.GetUpgradeCost(shipId, moduleId, current)
	if not cost then
		return false, Codes.MAX_LEVEL
	end

	-- Débito atômico: confere tudo, remove tudo, só então aplica. Nada aqui
	-- cede a thread entre a checagem e a remoção.
	local plan = self:_planRemoval(player, cost)
	if not plan then
		return false, Codes.MISSING_RESOURCES
	end

	for _, step in plan do
		local ok, msg = self._inventory:RemoveItem(player, step.slot, step.quantity)
		if not ok then
			-- Não deveria acontecer depois do plano; se acontecer, não aplica
			warn(string.format("[ShipService] RemoveItem falhou no upgrade de %s: %s", player.Name, msg))
			return false, Codes.MISSING_RESOURCES
		end
	end

	levels[moduleId] = current + 1

	-- Nave lançada é desta mesma nave: stats novos valem na hora
	local model = self:_getModel(player)
	if model and model:GetAttribute(ShipData.SHIP_ID_ATTRIBUTE) == shipId then
		local stats = self:_getInstanceStats(player, model)
		if stats then
			writeConfigurations(model, stats, true)
		end
	end

	self:_pushState(player)
	return true, Codes.OK
end

--- De quais slots sai cada unidade do custo, ou nil se falta algo.
function ShipService:_planRemoval(player: Player, cost)
	local inventory = self._inventory:GetInventory(player)
	local plan = {}

	for _, entry in cost do
		local remaining = entry.quantity
		for slotIndex = 1, inventory.maxSlots do
			if remaining <= 0 then
				break
			end
			local slot = inventory.slots[slotIndex]
			if slot and slot.itemId == entry.itemId and slot.quantity > 0 then
				local take = math.min(slot.quantity, remaining)
				table.insert(plan, { slot = slotIndex, quantity = take })
				remaining -= take
			end
		end
		if remaining > 0 then
			return nil
		end
	end

	return plan
end

--- Troca a nave equipada. Não mexe na nave já lançada: a nova sai no
--- próximo LANÇAR.
function ShipService:EquipShip(player: Player, shipId: any): (boolean, string)
	local ships = self:_getShipsProfile(player)
	if not ships then
		return false, Codes.NOT_LOADED
	end
	if not ShipData.IsValidShip(shipId) then
		return false, Codes.INVALID_SHIP
	end
	if not self:_checkCooldown(player) then
		return false, Codes.COOLDOWN
	end
	if not self:_getOwnedLevels(player, shipId) then
		return false, Codes.NOT_OWNED
	end
	if not self:_isAtTerminal(player) then
		return false, Codes.NOT_IN_HANGAR
	end
	if ships.equipped == shipId then
		return false, Codes.ALREADY_EQUIPPED
	end

	ships.equipped = shipId
	self:_pushState(player)
	return true, Codes.OK
end

--[[
	LANÇAR: nave equipada num pad do hangar, jogador já sentado.
	  pad informado — prompt LANÇAR do pad: o caminho de quem já sabe o que quer
	  pad = nil     — botão LANÇAR do HUD do terminal: usa o primeiro pad livre
]]
function ShipService:LaunchShip(player: Player, pad: any): (boolean, string)
	if not self:_getShipsProfile(player) then
		return false, Codes.NOT_LOADED
	end
	if not self:_checkCooldown(player) then
		return false, Codes.COOLDOWN
	end
	if PlaceConfig.IsPlanet() then
		warn(string.format(
			"[ShipService] LANÇAR de %s recusado: este Place é planeta (%s). Em Place de espaço, "
				.. "defina o atributo PlaceType = \"space\" no Workspace ou remova o LandingPad",
			player.Name,
			if workspace:GetAttribute("PlaceType") then "atributo PlaceType" else "inferido pelo LandingPad"
		))
		return false, Codes.NOT_IN_SPACE
	end

	local root = getRoot(player)
	if not root then
		return false, Codes.NO_SHIP
	end

	if pad == nil then
		if not self:_isAtTerminal(player) then
			return false, Codes.NOT_IN_HANGAR
		end
		pad = self:_findFreePad(player)
		if not pad then
			return false, Codes.NO_FREE_PAD
		end
	else
		if not PlaceConfig.IsHangarPad(pad) then
			warn(string.format(
				"[ShipService] LANÇAR de %s recusado: %s não é filho direto de Workspace.%s",
				player.Name,
				if typeof(pad) == "Instance" then pad:GetFullName() else typeof(pad),
				PlaceConfig.HANGAR_PADS
			))
			return false, Codes.INVALID_PAD
		end
		local reach = pad.Size.Magnitude / 2 + ShipData.HANGAR_INTERACT_DISTANCE
		if (root.Position - pad.Position).Magnitude > reach then
			return false, Codes.TOO_FAR_FROM_PAD
		end
	end

	local humanoid = getHumanoid(player)
	if not humanoid or humanoid.Health <= 0 then
		return false, Codes.NO_SHIP
	end
	if humanoid.SeatPart then
		return false, Codes.SEATED
	end

	-- Relançar recolhe a anterior (e libera o pad dela) antes de checar o pad:
	-- relançar no mesmo pad em que a nave antiga ainda está tem que funcionar
	local owner = self._padOwners[pad]
	if owner and owner ~= player.UserId then
		return false, Codes.PAD_OCCUPIED
	end
	self:_despawn(player, Reason.RELAUNCH)

	local model = self:_spawn(player, function(clone)
		return restOnTop(pad, clone, 0)
	end, pad)
	if not model then
		return false, Codes.NO_SHIP
	end

	-- A nave sai do hangar já ancorada, antes mesmo de o piloto sentar: assim
	-- ela não tem um só frame solta. Quando ele senta, o PlaneScript desancora
	-- tudo, e o _holdDocked reafirma a ancoragem frame a frame até ele acelerar.
	local record = self._ships[player.UserId]
	if record then
		self:_dock(player, record, pad)
	end

	self:_seatWhenReady(player, model)
	return true, Codes.OK
end

--- Primeiro pad livre (ou o que já é do próprio jogador: relançar no lugar).
function ShipService:_findFreePad(player: Player): BasePart?
	for _, pad in PlaceConfig.GetHangarPads() do
		local owner = self._padOwners[pad]
		if not owner or owner == player.UserId then
			return pad
		end
	end
	return nil
end

--- GUARDAR NAVE: fora do assento, com a nave dentro da HangarZone.
function ShipService:StowShip(player: Player): (boolean, string)
	if not self:_checkCooldown(player) then
		return false, Codes.COOLDOWN
	end
	if PlaceConfig.IsPlanet() then
		return false, Codes.NOT_IN_HANGAR
	end

	local model = self:_getModel(player)
	if not model then
		return false, Codes.NO_SHIP
	end

	local humanoid = getHumanoid(player)
	if humanoid and humanoid.SeatPart then
		return false, Codes.SEATED
	end
	if not PlaceConfig.IsInHangarZone(getShipPosition(model)) then
		return false, Codes.SHIP_NOT_IN_HANGAR
	end
	if not self:_isNearOwnShip(player) then
		return false, Codes.TOO_FAR_FROM_SHIP
	end

	if not self:_despawn(player, Reason.STOW) then
		return false, Codes.NOT_IN_HANGAR
	end
	self:_pushState(player)
	return true, Codes.OK
end

--- Loja fora do escopo desta entrega (§0).
function ShipService:PurchaseShip(_player: Player, _shipId: any): (boolean, string)
	return false, Codes.NOT_IMPLEMENTED
end

--- EnterPrompt no espaço: senta o dono. Em planeta a saída é RequestTakeoff.
function ShipService:EnterShip(player: Player, model: any): (boolean, string)
	if typeof(model) ~= "Instance" or model ~= self:_getModel(player) then
		return false, Codes.NOT_YOUR_SHIP
	end
	if PlaceConfig.IsPlanet() then
		return false, Codes.NOT_ON_PLANET
	end

	local humanoid = getHumanoid(player)
	local root = getRoot(player)
	local seat = getSeat(model)
	if not humanoid or humanoid.Health <= 0 or not root or not seat then
		return false, Codes.NO_SHIP
	end
	if (root.Position - seat.Position).Magnitude > ShipData.ENTER_DISTANCE then
		return false, Codes.TOO_FAR_FROM_SHIP
	end
	if seat.Occupant then
		return false, Codes.SHIP_OCCUPIED
	end

	seat:Sit(humanoid)
	return true, Codes.OK
end

--- DECOLAR no planeta: volta pro Hub, na órbita do planeta de onde saiu.
function ShipService:RequestTakeoff(player: Player): (boolean, string)
	if not PlaceConfig.IsPlanet() then
		return false, Codes.NOT_ON_PLANET
	end
	if not self:_checkCooldown(player) then
		return false, Codes.COOLDOWN
	end
	if not self:_isNearOwnShip(player) then
		return false, Codes.TOO_FAR_FROM_SHIP
	end

	local hubId = PlaceConfig.HUB_PLACE_ID
	if hubId == 0 or RunService:IsStudio() then
		warn(string.format(
			"[ShipService] Decolagem de %s: teleporte desligado (%s)",
			player.Name,
			if hubId == 0 then "PlaceConfig.HUB_PLACE_ID não configurado" else "Studio"
		))
		return false, Codes.TELEPORT_FAILED
	end

	local options = Instance.new("TeleportOptions")
	options:SetTeleportData({ [PlaceConfig.ARRIVAL_KEY] = PlaceConfig.GetPlanetId() })

	local ok, err = pcall(function()
		TeleportService:TeleportAsync(hubId, { player }, options)
	end)
	if not ok then
		warn(string.format("[ShipService] Teleporte de %s falhou: %s", player.Name, tostring(err)))
		return false, Codes.TELEPORT_FAILED
	end

	return true, Codes.OK
end

-- ═══════════════════════════════════════════════════════════
-- Warp
-- ═══════════════════════════════════════════════════════════

function ShipService:_isPiloting(player: Player, model: Model?): boolean
	local seat = model and getSeat(model)
	local humanoid = getHumanoid(player)
	return seat ~= nil and humanoid ~= nil and seat.Occupant == humanoid
end

function ShipService:RequestWarp(player: Player, destinationId: any): (boolean, string)
	if typeof(destinationId) ~= "string" then
		return false, Codes.WARP_NO_DESTINATION
	end
	if not self:_checkCooldown(player) then
		return false, Codes.COOLDOWN
	end

	local userId = player.UserId
	local model = self:_getModel(player)
	if not model then
		return false, Codes.NO_SHIP
	end
	if not self:_isPiloting(player, model) then
		return false, Codes.NOT_PILOTING
	end
	if self._warps[userId] or self._travels[userId] then
		return false, Codes.WARP_ALREADY_CHARGING
	end
	-- Ancorada no pad: o teleporte arrancaria a nave do hangar presa
	local record = self._ships[userId]
	if record and record.docked then
		return false, Codes.WARP_SHIP_DOCKED
	end

	local destination = WarpModule.GetDestination(destinationId)
	-- Marcador só de mapa (Solara): existe, mas não é destino
	if not destination or not MapConfig.IsWarpable(destination.id) then
		return false, Codes.WARP_NO_DESTINATION
	end

	local stats = self:_getInstanceStats(player, model)
	if not stats then
		return false, Codes.NOT_LOADED
	end

	local shipPosition = getShipPosition(model)
	if WarpModule.IsTooClose(shipPosition, destination.position) then
		return false, Codes.WARP_TOO_CLOSE
	end
	if not WarpModule.IsInRange(stats.warpRange, shipPosition, destination.position) then
		return false, Codes.WARP_OUT_OF_RANGE
	end

	-- Dano no piloto também interrompe (o casco é vigiado no _bindInstance)
	local humanoid = getHumanoid(player)
	local healthConn
	if humanoid then
		local last = humanoid.Health
		healthConn = humanoid.HealthChanged:Connect(function(health)
			if health < last then
				self:_cancelWarp(player, Codes.WARP_INTERRUPTED)
			end
			last = health
		end)
	end

	local info = { destinationId = destination.id, chargeTime = stats.warpChargeTime }

	local charge
	charge = WarpModule.StartCharge({
		model = model,
		chargeTime = stats.warpChargeTime,
		progressAttribute = ShipData.WARP_CHARGE_ATTRIBUTE,
		onComplete = function()
			if healthConn then
				healthConn:Disconnect()
			end
			if self._warps[userId] == charge then
				self._warps[userId] = nil
			end

			-- Revalida no fim: o alvo pode ter sido removido durante a carga
			local target = WarpModule.GetDestination(destination.id)
			if not target or not model.Parent or not self:_isPiloting(player, model) then
				self.Client.WarpStatus:Fire(player, "cancelled", { destinationId = destination.id, reason = Codes.WARP_INTERRUPTED })
				return
			end

			self:_travel(player, model, destination.id)
		end,
		onCancel = function(reason)
			if healthConn then
				healthConn:Disconnect()
			end
			if self._warps[userId] == charge then
				self._warps[userId] = nil
			end
			self.Client.WarpStatus:Fire(player, "cancelled", { destinationId = destination.id, reason = reason })
		end,
	})

	self._warps[userId] = charge
	self.Client.WarpStatus:Fire(player, "charging", info)

	return true, Codes.OK
end

--[[
	Viagem: o trecho em que o piloto está dentro do túnel.

	O salto continua sendo um PivotTo só, mas ele cai no FIM da viagem, coberto
	pelo flash do WarpTunnel — é o clímax, e é onde o estouro toca. Depois dele
	sobra só a dissolução do túnel. Aqui já não dá pra cancelar: quem
	interrompe interrompe a carga, não o salto.
]]
function ShipService:_travel(player: Player, model: Model, destinationId: string)
	local userId = player.UserId
	self._travels[userId] = true

	self.Client.WarpStatus:Fire(player, "travelling", {
		destinationId = destinationId,
		travelTime = WarpModule.TRAVEL_TIME,
		-- Quando a nave troca de lugar: o client casa o flash e o estouro com
		-- esse instante, em vez de chutar o fim do túnel
		jumpAt = WarpModule.TRAVEL_JUMP_AT,
	})

	task.delay(WarpModule.TRAVEL_JUMP_AT, function()
		if not player.Parent then
			self._travels[userId] = nil
			return
		end

		-- Revalida de novo: entre a carga cheia e o salto passou mais um tempo
		local target = WarpModule.GetDestination(destinationId)
		if not target or not model.Parent or self:_getModel(player) ~= model then
			self._travels[userId] = nil
			self.Client.WarpStatus:Fire(player, "cancelled", { destinationId = destinationId, reason = Codes.WARP_INTERRUPTED })
			return
		end

		model:PivotTo(WarpModule.GetArrivalCFrame(getShipPosition(model), target.part))
		for _, part in model:GetDescendants() do
			if part:IsA("BasePart") then
				part.AssemblyLinearVelocity = Vector3.zero
				part.AssemblyAngularVelocity = Vector3.zero
			end
		end

		task.delay(WarpModule.TRAVEL_TIME - WarpModule.TRAVEL_JUMP_AT, function()
			self._travels[userId] = nil
			if player.Parent then
				self.Client.WarpStatus:Fire(player, "completed", { destinationId = destinationId })
			end
		end)
	end)
end

function ShipService:_cancelWarp(player: Player, reason: string)
	local charge = self._warps[player.UserId]
	if charge then
		charge:Cancel(reason)
	end
end

-- ═══════════════════════════════════════════════════════════
-- Client
-- ═══════════════════════════════════════════════════════════

function ShipService.Client:GetState(player: Player)
	self.Server._playerData:WaitForProfile(player)
	return self.Server:_buildState(player)
end

function ShipService.Client:GetCatalog(_player: Player)
	return ShipData.Ships
end

function ShipService.Client:UpgradeModule(player: Player, moduleId: any)
	return self.Server:UpgradeModule(player, moduleId)
end

function ShipService.Client:EquipShip(player: Player, shipId: any)
	return self.Server:EquipShip(player, shipId)
end

function ShipService.Client:LaunchShip(player: Player, pad: any)
	return self.Server:LaunchShip(player, pad)
end

function ShipService.Client:RequestUndock(player: Player)
	return self.Server:RequestUndock(player)
end

function ShipService.Client:StowShip(player: Player)
	return self.Server:StowShip(player)
end

function ShipService.Client:PurchaseShip(player: Player, shipId: any)
	return self.Server:PurchaseShip(player, shipId)
end

function ShipService.Client:EnterShip(player: Player, model: any)
	return self.Server:EnterShip(player, model)
end

function ShipService.Client:RequestTakeoff(player: Player)
	return self.Server:RequestTakeoff(player)
end

function ShipService.Client:RequestWarp(player: Player, destinationId: any)
	return self.Server:RequestWarp(player, destinationId)
end

function ShipService.Client:CancelWarp(player: Player)
	self.Server:_cancelWarp(player, "CANCELLED")
	return true, Codes.OK
end

-- ═══════════════════════════════════════════════════════════
-- Knit Lifecycle
-- ═══════════════════════════════════════════════════════════

function ShipService:_onPlayerAdded(player: Player)
	-- Chegada vinda de um planeta: nasce na órbita dele
	local joinData = player:GetJoinData()
	local teleportData = joinData and joinData.TeleportData
	if typeof(teleportData) == "table" and typeof(teleportData[PlaceConfig.ARRIVAL_KEY]) == "string" then
		self._arrivals[player.UserId] = teleportData[PlaceConfig.ARRIVAL_KEY]
	end

	-- Planeta: a nave tem que existir sempre que o jogador existir
	player.CharacterAdded:Connect(function()
		if PlaceConfig.IsPlanet() and self._playerData:IsLoaded(player) and not self:_getModel(player) then
			self:SpawnOnLanding(player)
		end
	end)

	player.Chatted:Connect(function(message)
		self:_onChat(player, message)
	end)
end

function ShipService:_onProfileLoaded(player: Player)
	if PlaceConfig.IsPlanet() then
		self:SpawnOnLanding(player)
	else
		local arrival = self._arrivals[player.UserId]
		self._arrivals[player.UserId] = nil
		if arrival then
			self:SpawnAtArrival(player, arrival)
		end
	end
	self:_pushState(player)
end

function ShipService:_onChat(player: Player, message: string)
	if not RunService:IsStudio() and not TEST_PLAYERS[player.Name] then
		return
	end

	local shipId = string.match(message, "^/grantship%s+(%S+)")
	if shipId then
		print(string.format("[ShipService] /grantship %s → %s", shipId, select(2, self:GrantShip(player, shipId))))
		return
	end

	-- Troca de nave fora do hangar, só pra testar sem montar o lobby
	shipId = string.match(message, "^/equipship%s+(%S+)")
	if shipId then
		local ships = self:_getShipsProfile(player)
		if ships and self:_getOwnedLevels(player, shipId) then
			ships.equipped = shipId
			self:_pushState(player)
			print(string.format("[ShipService] /equipship %s → OK (vale no próximo spawn)", shipId))
		else
			print(string.format("[ShipService] /equipship %s → NOT_OWNED", shipId))
		end
		return
	end

	-- Por que a nave não gruda na plataforma
	if message == "/dockinfo" then
		local record = self._ships[player.UserId]
		if not record or not record.model.Parent then
			print("[ShipService] /dockinfo → nenhuma nave lançada")
			return
		end

		local model = record.model
		local position = getShipPosition(model)
		local body = model:FindFirstChild(ShipData.PARTS.body)
		local velocity = if body and body:IsA("BasePart") then body.AssemblyLinearVelocity.Magnitude else -1
		local seat = getSeat(model)

		print(string.format(
			"[ShipService] /dockinfo → ancorada: %s · velocidade: %.1f (limite %d) · ocupante: %s · pads: %d",
			tostring(record.docked),
			velocity,
			ShipData.DOCK_SPEED_LIMIT,
			if seat and seat.Occupant then "sim (pouso só com o assento vazio)" else "não",
			#PlaceConfig.GetHangarPads()
		))

		for _, pad in PlaceConfig.GetHangarPads() do
			local top, radius = padBounds(pad)
			local flat = (Vector3.new(position.X, 0, position.Z) - Vector3.new(pad.Position.X, 0, pad.Position.Z)).Magnitude
			local owner = self._padOwners[pad]
			print(string.format(
				"   %s: distância %.1f (máx %.1f) · altura %.1f (máx %d) · dono: %s",
				pad.Name,
				flat,
				radius + ShipData.DOCK_MARGIN,
				position.Y - top,
				ShipData.DOCK_HEIGHT,
				if owner then tostring(owner) else "livre"
			))
		end
		return
	end

	-- Nave na frente do jogador, já sentado, sem precisar do hangar (só espaço)
	if message == "/spawnship" then
		local root = getRoot(player)
		if PlaceConfig.IsPlanet() or not root then
			print("[ShipService] /spawnship → só no espaço, com personagem")
			return
		end
		self:_despawn(player, Reason.RELAUNCH)
		local model = self:_spawn(player, function()
			return CFrame.new(root.Position + root.CFrame.LookVector * 25 + Vector3.new(0, 4, 0))
				* root.CFrame.Rotation
		end)
		if model then
			self:_seatWhenReady(player, model)
		end
		print("[ShipService] /spawnship → " .. (if model then "OK" else "falhou"))
	end
end

function ShipService:KnitStart()
	self._playerData = Knit.GetService("PlayerDataService")
	self._inventory = Knit.GetService("InventoryService")

	if not getModelsFolder() then
		warn(string.format(
			"[ShipService] ReplicatedStorage.%s.%s não existe — nenhuma nave vai spawnar",
			ShipData.ASSETS_FOLDER,
			ShipData.MODELS_FOLDER
		))
	end

	-- Custos de upgrade precisam apontar pra itens reais
	for moduleId, module in ShipData.Modules do
		for _, entry in module.cost do
			if not InventoryModule.IsValidItem(entry.itemId) then
				warn(string.format("[ShipService] Custo de %s usa item inexistente: %s", moduleId, entry.itemId))
			end
		end
	end

	Players.PlayerAdded:Connect(function(player)
		self:_onPlayerAdded(player)
	end)
	for _, player in Players:GetPlayers() do
		self:_onPlayerAdded(player)
	end

	self._playerData:OnProfileLoaded(function(player)
		self:_onProfileLoaded(player)
	end)

	Players.PlayerRemoving:Connect(function(player)
		-- Sempre limpa, inclusive em planeta: nave órfã ficaria com NetworkOwner
		-- de um jogador que não existe mais
		self:_despawn(player, Reason.PLAYER_REMOVING)
		local userId = player.UserId
		self._slots[userId] = nil
		self._lastAction[userId] = nil
		self._arrivals[userId] = nil
		self._travels[userId] = nil
		self._placedOnLanding[userId] = nil
	end)

	task.spawn(function()
		while true do
			task.wait(MAINTENANCE_INTERVAL)
			self:_maintain()
		end
	end)

	print(string.format(
		"[ShipService] Started — place: %s · hangar: %s · pads: %d",
		PlaceConfig.GetPlaceType(),
		tostring(PlaceConfig.HasHangar()),
		#PlaceConfig.GetHangarPads()
	))
end

return ShipService
