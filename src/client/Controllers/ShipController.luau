--[[
	ShipController
	Liga o estado das naves (ShipService) às HUDs: prompts, menu da nave,
	hangar, warp e a aba "Nave" do inventário.

	Nada aqui decide resultado: toda ação vira chamada ao servidor, e a UI só
	muda quando o ShipStateChanged volta.

	Local: src/client/Controllers/ShipController.luau
]]

local Knit = require(game:GetService("ReplicatedStorage").Packages.Knit)
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local ProximityPromptService = game:GetService("ProximityPromptService")
local CollectionService = game:GetService("CollectionService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local ShipData = require(ReplicatedStorage.Shared.ShipData)
local PlaceConfig = require(ReplicatedStorage.Shared.PlaceConfig)
local WarpModule = require(ReplicatedStorage.Shared.WarpModule)
local InventoryModule = require(ReplicatedStorage.Shared.InventoryModule)
local MapConfig = require(ReplicatedStorage.Shared.MapConfig)
local FlightLimits = require(ReplicatedStorage.Shared.FlightLimits)

local UI = script.Parent.Parent.UI
local ShipPrompts = require(UI.ShipPrompts)
local ShipMenuHUD = require(UI.ShipMenuHUD)
local HangarHUD = require(UI.HangarHUD)
local WarpHUD = require(UI.WarpHUD)
local WarpTunnel = require(UI.WarpTunnel)
local WarpAimHUD = require(UI.WarpAimHUD)
local ShipToast = require(UI.ShipToast)
local UIStyle = require(UI.UIStyle)

local player = Players.LocalPlayer

-- Afastar-se além disso fecha o menu da nave (servidor valida com 25)
local MENU_CLOSE_DISTANCE = ShipData.UPGRADE_DISTANCE + 6
local DESTINATIONS_REFRESH = 0.25

-- Brilho da carga do warp, visível pra todo mundo por perto
local WARP_FX_COLOR = Color3.fromHex("#45C7FF")
local WARP_FX_LIGHT_RANGE = 24

-- Velocidade com que a nave vira pro destino durante a carga, em 1/s. Baixo
-- de propósito: o giro é parte do "carregando", não um snap.
local ALIGN_RATE = 1.2
-- Na viagem o eixo trava de vez: fecha o que sobrou da carga e não deixa o
-- mouse virar a nave
local TRAVEL_ALIGN_RATE = 5

-- Arrancada: até o teleporte a nave anda DE VERDADE, pra paisagem passar.
-- Tudo em studs e segundos.
local BOOST_MAX_SPEED = 650
local BOOST_RAMP = 0.9 -- tempo até a velocidade de cruzeiro
-- Teto da distância. Também é o teto do Spherecast (1024), então não sobe
local BOOST_MAX_DISTANCE = 1000
local BOOST_DEST_FRACTION = 0.5 -- nunca passa da metade do caminho até o destino
local BOOST_SAFETY_MARGIN = 80 -- folga antes de qualquer obstáculo
local BOOST_LOOKAHEAD = 0.4 -- quanto tempo à frente o frame confere
local BOOST_BRAKE_TIME = 0.25 -- freia pra parar no fim do orçamento, não bater nele
-- Salto de posição maior que isso num frame = o PivotTo do servidor chegou
local BOOST_TELEPORT_JUMP = 250
-- Se o teleporte não chegar nesse tempo além do previsto, solta a arrancada
local BOOST_TELEPORT_TIMEOUT = 1

-- Depois de chegar, o eixo continua travado por este tempo, com a nave parada
-- de frente: dá tempo da velocidade do kit de voo assentar antes do piloto
-- voltar a mandar
local ARRIVAL_HOLD = 1

-- Mirar num marcador de warp: ângulo (graus) entre o centro da câmera e o
-- marcador pra ele virar alvo, e o ângulo maior pra continuar sendo (sem
-- piscar na borda). Abaixo de WarpModule.MIN_DISTANCE não oferece: é voar.
local AIM_ENTER_ANGLE = 5
local AIM_KEEP_ANGLE = 8

-- Limites de voo (FlightLimits): de quanto em quanto tempo relê a posição de
-- Solara, e a cor do aviso de sinal fraco
local SOLARA_REFRESH = 2
local LIMIT_WARN_COLOR = Color3.fromRGB(255, 190, 80)

-- Texto do aviso por limite (id do FlightLimits.Nearest) e faixa
local LIMIT_MESSAGES = {
	floor = {
		warn = "SINAL DA CENTRAL FRACO",
		lost = "CONTATO PERDIDO COM A CENTRAL  ·  RETORNE",
	},
	solara = {
		warn = "TEMPERATURA DO CASCO SUBINDO",
		lost = "TEMPERATURA CRÍTICA  ·  CASCO DESINTEGRANDO",
	},
}

local MESSAGES = {
	OK = "Pronto.",
	NOT_LOADED = "Dados ainda carregando. Tente de novo.",
	COOLDOWN = "Calma — uma ação por vez.",
	INVALID_SHIP = "Nave inválida.",
	INVALID_MODULE = "Módulo inválido.",
	NOT_OWNED = "Você não possui essa nave.",
	ALREADY_OWNED = "Você já possui essa nave.",
	ALREADY_EQUIPPED = "Essa nave já está equipada.",
	MAX_LEVEL = "Módulo já está no nível máximo.",
	MISSING_RESOURCES = "Recursos insuficientes.",
	NOT_ENOUGH_LUMENS = "Lúmens insuficientes.",
	TOO_FAR_FROM_SHIP = "Chegue mais perto da nave.",
	NOT_IN_HANGAR = "Isso só funciona dentro do hangar.",
	INVALID_PAD = "Plataforma inválida.",
	NO_FREE_PAD = "Todas as plataformas estão ocupadas. Aguarde alguns segundos.",
	NOT_IN_SPACE = "Não dá pra lançar nave em planeta.",
	PAD_OCCUPIED = "Essa plataforma está ocupada. Use outra.",
	TOO_FAR_FROM_PAD = "Chegue mais perto da plataforma.",
	SEATED = "Saia do assento primeiro.",
	SHIP_NOT_IN_HANGAR = "Traga a nave pra dentro do hangar.",
	SHIP_NOT_DOCKED = "Ancore a nave numa plataforma do hangar primeiro.",
	NO_SHIP = "Nenhuma nave disponível.",
	NOT_YOUR_SHIP = "Essa nave não é sua.",
	SHIP_OCCUPIED = "A nave está ocupada.",
	NOT_ON_PLANET = "Só é possível decolar de um planeta.",
	TELEPORT_FAILED = "Não foi possível decolar agora.",
	NOT_PILOTING = "Você precisa estar pilotando.",
	WARP_NO_DESTINATION = "Destino inválido.",
	WARP_OUT_OF_RANGE = "Fora do alcance do warp. Voe mais perto.",
	WARP_TOO_CLOSE = "Perto demais pra warpar. Siga voando.",
	WARP_ALREADY_CHARGING = "O warp já está carregando.",
	WARP_INTERRUPTED = "Warp interrompido.",
	WARP_SHIP_DOCKED = "Desancore a nave antes de warpar.",
	CANCELLED = "Warp cancelado.",
	NOT_IMPLEMENTED = "Em breve.",
}

local function message(code: string?): string
	return MESSAGES[code or ""] or tostring(code)
end

local ShipController = Knit.CreateController({
	Name = "ShipController",
})

-- ═══════════════════════════════════════════════════════════
-- Setup
-- ═══════════════════════════════════════════════════════════

function ShipController:KnitInit()
	self._state = { loaded = false }
	self._isPlanet = PlaceConfig.IsPlanet()
	self._piloting = false
	self._seated = false
	self._destinationsTimer = 0
	self._warpFx = {} :: { [Model]: any }

	self._prompts = ShipPrompts.new()
	self._menu = ShipMenuHUD.new()
	self._hangar = HangarHUD.new()
	self._warp = WarpHUD.new()
	self._tunnel = WarpTunnel.new()
	self._aim = WarpAimHUD.new()
	self._destinations = {}
	self._toast = ShipToast.new()
end

function ShipController:KnitStart()
	self._service = Knit.GetService("ShipService")
	self._inventoryService = Knit.GetService("InventoryService")

	self._service.ShipStateChanged:Connect(function(state)
		self:_setState(state)
	end)

	self._service:GetState():andThen(function(state)
		self:_setState(state)
	end):catch(function(err)
		warn("[ShipController] GetState failed:", err)
	end)

	self._service.WarpStatus:Connect(function(status, info)
		self:_onWarpStatus(status, info)
	end)

	-- Inventário: o InventoryController mantém o cache; lê depois dele atualizar
	local function refreshInventory()
		task.defer(function()
			local inventoryController = Knit.GetController("InventoryController")
			self._menu:SetInventory(inventoryController:GetInventory())
		end)
	end
	self._inventoryService.InventoryChanged:Connect(refreshInventory)
	self._inventoryService.SlotUpdated:Connect(refreshInventory)
	refreshInventory()

	self:_bindHandlers()
	self:_bindPrompts()
	self:_bindInput()
	self:_bindWarpFx()

	-- Stepped: logo antes do passo de física, depois do kit de voo escrever
	-- a velocidade (mesmo motivo do alinhamento do warp)
	RunService.Stepped:Connect(function()
		self:_stepLimits()
	end)

	RunService.Heartbeat:Connect(function(dt)
		self:_update(dt)
	end)
end

-- ═══════════════════════════════════════════════════════════
-- Estado
-- ═══════════════════════════════════════════════════════════

function ShipController:_setState(state)
	if typeof(state) ~= "table" then
		return
	end
	self._state = state

	self._menu:SetState(state)
	self._hangar:SetState(state)
	-- O servidor é quem sabe o tipo do Place (o client pode não ter recebido
	-- LandingPad/pads por streaming)
	if state.loaded then
		self._isPlanet = state.isPlanet == true
		self._prompts:SetPlanet(self._isPlanet)
		if not self._isPlanet then
			self._prompts:SetupHangar()
		end
	end

	local equippedDef = state.loaded and ShipData.GetShip(state.equipped)
	self._prompts:SetEquippedName(if equippedDef then equippedDef.displayName else nil)
	self._prompts:Refresh()

	local inventoryController = Knit.GetController("InventoryController")
	if inventoryController and inventoryController.SetShipInfo then
		inventoryController:SetShipInfo(state)
	end
end

function ShipController:GetState()
	return self._state
end

--- Instância da nave do jogador local. O state pode chegar antes do modelo
--- replicar, então cai numa busca pela tag.
function ShipController:GetOwnShip(): Model?
	local instance = self._state.instance
	if typeof(instance) == "Instance" and instance.Parent then
		return instance :: Model
	end
	for _, model in CollectionService:GetTagged(ShipData.SHIP_TAG) do
		if model:IsA("Model") and model:GetAttribute(ShipData.OWNER_ATTRIBUTE) == player.UserId then
			return model
		end
	end
	return nil
end

function ShipController:GetEquippedStats()
	local state = self._state
	if not state.loaded then
		return nil
	end
	return ShipData.ComputeStats(state.equipped, state.owned[state.equipped])
end

-- ═══════════════════════════════════════════════════════════
-- Handlers das HUDs
-- ═══════════════════════════════════════════════════════════

--- Painel aberto solta o cursor da mira do laser (senão nada é clicável).
function ShipController:_refreshAimLock()
	local laser = Knit.GetController("LaserToolController")
	if laser then
		local anyOpen = self._menu:IsOpen() or self._hangar:IsOpen() or self._menu:IsConfirmOpen()
		laser:SetAimLocked(not anyOpen)
	end
end

function ShipController:_bindHandlers()
	self._menu:SetUpgradeHandler(function(moduleId)
		self._service:UpgradeModule(moduleId):andThen(function(ok, code)
			self._menu:ShowMessage(if ok then "Módulo melhorado." else message(code), not ok)
		end):catch(function(err)
			warn("[ShipController] UpgradeModule failed:", err)
		end)
	end)

	self._menu:SetCloseHandler(function()
		self:_refreshAimLock()
	end)

	self._hangar:SetEquipHandler(function(shipId)
		self._service:EquipShip(shipId):andThen(function(ok, code)
			self._hangar:ShowMessage(if ok then "Nave equipada." else message(code), not ok)
		end):catch(function(err)
			warn("[ShipController] EquipShip failed:", err)
		end)
	end)

	self._hangar:SetLaunchHandler(function()
		self._service:LaunchShip():andThen(function(ok, code)
			if ok then
				-- O servidor senta o jogador; fecha já pra não esperar o seated
				self._hangar:Close()
			else
				self._hangar:ShowMessage(message(code), true)
			end
		end):catch(function(err)
			warn("[ShipController] LaunchShip failed:", err)
		end)
	end)

	self._hangar:SetUpgradeHandler(function()
		self._hangar:Close()
		self._menu:Open(self:GetOwnShip(), ShipMenuHUD.TAB_UPGRADES)
		self:_refreshAimLock()
	end)

	self._hangar:SetToggleHandler(function()
		self:_refreshAimLock()
	end)

	self._warp:SetCancelHandler(function()
		self._service:CancelWarp()
	end)

	self._aim:SetActivateHandler(function()
		self:_activateAim()
	end)
end

function ShipController:OpenHangar()
	if self._seated or not self:_isNearTerminal() then
		return
	end
	self._menu:Close()
	self._hangar:Open()
end

function ShipController:LaunchFromPad(pad: BasePart)
	self._service:LaunchShip(pad):andThen(function(ok, code)
		-- Sucesso: o servidor senta o jogador, e o seated fecha qualquer painel
		if not ok then
			warn("[ShipController] Launch: " .. message(code))
		end
	end):catch(function(err)
		warn("[ShipController] LaunchShip failed:", err)
	end)
end

--- Solta a nave do pad a pedido do piloto. O servidor devolve a posse de rede.
function ShipController:RequestUndock()
	if self._undockPending then
		return
	end
	self._undockPending = true

	self._service:RequestUndock():andThen(function(ok, code)
		self._undockPending = false
		if not ok then
			self._toast:Flash(message(code), 1.5, UIStyle.C.negative)
		end
	end):catch(function(err)
		self._undockPending = false
		warn("[ShipController] RequestUndock failed:", err)
	end)
end

function ShipController:RequestWarp(destinationId: string)
	self._service:RequestWarp(destinationId):andThen(function(ok, code)
		if not ok then
			self._warp:ShowMessage(message(code), true)
		end
	end):catch(function(err)
		warn("[ShipController] RequestWarp failed:", err)
	end)
end

-- ═══════════════════════════════════════════════════════════
-- Prompts
-- ═══════════════════════════════════════════════════════════

local function ownerOf(prompt: ProximityPrompt): Model?
	local model: Instance? = prompt.Parent
	while model and not (model:IsA("Model") and CollectionService:HasTag(model, ShipData.SHIP_TAG)) do
		model = model.Parent
	end
	if model and model:GetAttribute(ShipData.OWNER_ATTRIBUTE) == player.UserId then
		return model :: Model
	end
	return nil
end

function ShipController:_bindPrompts()
	ProximityPromptService.PromptTriggered:Connect(function(prompt, triggeringPlayer)
		if triggeringPlayer ~= player then
			return
		end

		-- Hangar: terminal abre o HUD; pad lança direto
		if self._prompts:IsTerminalPrompt(prompt) then
			self:OpenHangar()
			return
		end
		local pad = self._prompts:GetPadForPrompt(prompt)
		if pad then
			self:LaunchFromPad(pad)
			return
		end

		local model = ownerOf(prompt)
		if not model then
			return
		end

		if prompt.Name == ShipData.PARTS.menuPrompt then
			if self._prompts:IsStowMode() then
				self:_openStow(model)
				return
			end
			self._hangar:Close()
			self._menu:Open(model)
			self:_refreshAimLock()
		elseif prompt.Name == ShipData.PARTS.enterPrompt then
			if self._isPlanet then
				self:_openTakeoff()
			else
				self._service:EnterShip(model):andThen(function(ok, code)
					if not ok then
						warn("[ShipController] EnterShip: " .. message(code))
					end
				end)
			end
		end
	end)
end

function ShipController:_openTakeoff()
	local inventoryController = Knit.GetController("InventoryController")
	local inventory = inventoryController:GetInventory()
	local empty = true
	for _, slot in inventory.slots do
		if slot then
			-- A ferramenta inicial não conta como "coletou algo"
			local def = InventoryModule.GetItemDef(slot.itemId)
			if not def or def.category ~= "tool" then
				empty = false
				break
			end
		end
	end

	local planetId = PlaceConfig.GetPlanetId()
	local planetName = if planetId
		then string.upper(string.sub(planetId, 1, 1)) .. string.sub(planetId, 2)
		else "este planeta"

	self._menu:Close()
	self._menu:OpenConfirm({
		title = string.format("Decolar de %s?", planetName),
		body = "Você voltará ao espaço.",
		warning = if empty then "Você não coletou nada ainda." else nil,
		confirmText = "DECOLAR",
		busyText = "DECOLANDO",
	}, function()
		self._service:RequestTakeoff():andThen(function(ok, code)
			if not ok then
				warn("[ShipController] Takeoff: " .. message(code))
				self._menu:CloseConfirm()
				self:_refreshAimLock()
			end
			-- Sucesso: a tela de teleporte assume
		end)
	end)
	self:_refreshAimLock()
end

function ShipController:_openStow(model: Model)
	local def = ShipData.GetShip(model:GetAttribute(ShipData.SHIP_ID_ATTRIBUTE))

	self._menu:Close()
	self._hangar:Close()
	self._menu:OpenConfirm({
		title = string.format("Guardar a %s?", if def then def.displayName else "nave"),
		body = "Ela volta pro hangar e libera a plataforma. Para sair de novo, use LANÇAR.",
		confirmText = "GUARDAR",
		busyText = "GUARDANDO",
	}, function()
		self._service:StowShip():andThen(function(ok, code)
			self._menu:CloseConfirm()
			self:_refreshAimLock()
			if not ok then
				warn("[ShipController] Stow: " .. message(code))
			end
		end)
	end)
	self:_refreshAimLock()
end

-- ═══════════════════════════════════════════════════════════
-- Pouso
-- ═══════════════════════════════════════════════════════════

--- Acompanha a ancoragem pelos atributos da nave. O prazo vem no relógio do
--- servidor, então a contagem corre lisa aqui mesmo com a checagem de pouso
--- rodando a cada meio segundo lá.
function ShipController:_updateDockToast(ship: Model?)
	local previous = self._dockState

	if not ship then
		if previous then
			self._dockState = nil
			self._toast:Hide()
		end
		return
	end

	if ship:GetAttribute(ShipData.DOCKED_ATTRIBUTE) == true then
		-- Ancorada com o piloto dentro, o aviso fica de pé e vira o jeito de
		-- soltar (no mobile é o único, já que lá não há tecla). Fora do assento
		-- ele é só confirmação e some sozinho.
		local state = if self._seated then "dockedSeated" else "docked"
		-- Com o piloto dentro o botão de soltar tem que estar SEMPRE lá: se algo
		-- tirou ele da tela (um aviso de erro por cima, um Flash antigo que
		-- venceu), volta no frame seguinte
		local lost = state == "dockedSeated" and not self._toast:IsShowing()
		if state ~= previous or lost then
			self._dockState = state
			if state == "dockedSeated" then
				self._toast:Show(
					if UIStyle.IS_MOBILE then "NAVE ANCORADA  ·  TOQUE PARA SOLTAR" else "NAVE ANCORADA  ·  ACELERE PARA SOLTAR",
					UIStyle.C.positive,
					function()
						self:RequestUndock()
					end
				)
			else
				self._toast:Flash("NAVE ANCORADA", 2.5, UIStyle.C.positive)
			end
		end
		return
	end

	local dockingAt = ship:GetAttribute(ShipData.DOCKING_ATTRIBUTE)
	if typeof(dockingAt) == "number" then
		self._dockState = "docking"
		local remaining = math.max(dockingAt - workspace:GetServerTimeNow(), 0)
		self._toast:Show(string.format("ANCORANDO  %.1fs", remaining))
		return
	end

	if previous == "docking" then
		self._toast:Flash("ANCORAGEM INTERROMPIDA", 1.5, UIStyle.C.negative)
	elseif previous == "docked" or previous == "dockedSeated" then
		self._toast:Flash("NAVE LIBERADA", 1.5)
	end
	self._dockState = nil
end

-- ═══════════════════════════════════════════════════════════
-- Diagnóstico de voo
-- ═══════════════════════════════════════════════════════════

--[[
	"Sentou mas não controla" tem poucas causas, e todas dá pra ver do client:

	  LocalPlaneScript na PlayerGui  — o PlaneScript clona ao sentar. Sem ele,
	                                   nada de teclado, câmera nem física
	  Plane.Value preenchido         — o LocalPlaneScript morre logo no início
	                                   se a referência da nave não chegou
	  BodyVelocity/BodyGyro no Body  — provam que o loop de voo começou. O loop
	                                   só roda enquanto Seat.Occupant == humanoid
	  Configurations.Speed > 0       — com Speed = 0 o script faz speed/0, o
	                                   power vira NaN e a nave trava parada
]]
function ShipController:_diagnoseFlight(ship: Model)
	task.delay(1.5, function()
		local character = player.Character
		local humanoid = character and character:FindFirstChildOfClass("Humanoid")
		local seat = ship:FindFirstChild(ShipData.PARTS.seat, true)
		if not humanoid or not seat or humanoid.SeatPart ~= seat then
			return -- saiu do assento nesse meio tempo
		end

		local playerGui = player:FindFirstChildOfClass("PlayerGui")
		local flightScript: LocalScript? = nil
		if playerGui then
			for _, inst in playerGui:GetChildren() do
				if inst:IsA("LocalScript") and inst:FindFirstChild("Plane") then
					flightScript = inst
					break
				end
			end
		end

		local body = ship:FindFirstChild(ShipData.PARTS.body)
		local hasMovers = body ~= nil
			and body:FindFirstChildWhichIsA("BodyVelocity") ~= nil
			and body:FindFirstChildWhichIsA("BodyGyro") ~= nil
		if hasMovers then
			return -- o loop de voo está rodando
		end

		local config = ship:FindFirstChild(ShipData.PARTS.configurations)
		local speedValue = config and config:FindFirstChild("Speed")
		local speed = if speedValue and speedValue:IsA("NumberValue") then speedValue.Value else nil

		local planeValue = flightScript and flightScript:FindFirstChild("Plane")
		local reason
		if not flightScript then
			reason = "o PlaneScript não clonou o LocalPlaneScript na PlayerGui — confira se ele existe dentro do "
				.. "PlaneScript, se não está Disabled, e se o SetNetworkOwner do Body não deu erro antes do clone"
		elseif planeValue and (planeValue :: ObjectValue).Value == nil then
			reason = "o LocalPlaneScript chegou, mas Plane.Value está vazio — ele morre na primeira linha"
		elseif speed ~= nil and speed <= 0 then
			reason = string.format(
				"Configurations.Speed = %s — o LocalPlaneScript divide por esse valor (power = speed/Speed) e "
					.. "trava a nave com NaN",
				tostring(speed)
			)
		else
			reason = "o LocalPlaneScript rodou mas o loop de voo não começou — ele só roda enquanto "
				.. "Seat.Occupant for o seu Humanoid no CLIENT; se o assento replicou depois do script iniciar, "
				.. "ele sai na hora e se destrói"
		end

		warn(string.format(
			"[ShipController] Sentado sem controle da nave: %s (LocalPlaneScript: %s · Speed: %s · câmera: %s)",
			reason,
			if flightScript then "presente" else "ausente",
			tostring(speed),
			workspace.CurrentCamera.CameraType.Name
		))
	end)
end

-- ═══════════════════════════════════════════════════════════
-- Input
-- ═══════════════════════════════════════════════════════════

function ShipController:_bindInput()
	UserInputService.InputBegan:Connect(function(input, gameProcessed)
		if gameProcessed then
			return
		end

		local key = input.KeyCode

		-- Com o mapa aberto o [F] é do mapa (warp pro corpo selecionado)
		local mapController = Knit.GetController("MapController")
		local mapOpen = mapController ~= nil and mapController:IsOpen()

		-- Acelerar com a nave ancorada solta ela do pad. Espaço fica de fora de
		-- propósito: é a tecla de sair do assento, e sair não é decolar.
		if
			self._seated
			and (key == Enum.KeyCode.W or key == Enum.KeyCode.S)
			and self._dockState == "dockedSeated"
		then
			self:RequestUndock()
			return
		end

		if key == Enum.KeyCode.F and self._aim:GetTarget() and not mapOpen then
			self:_activateAim()
		elseif key == Enum.KeyCode.X and self._warp:IsCharging() then
			self._service:CancelWarp()
		elseif key == Enum.KeyCode.Escape then
			if self._menu:IsConfirmOpen() then
				self._menu:CloseConfirm()
				self:_refreshAimLock()
			end
		end
	end)
end

-- ═══════════════════════════════════════════════════════════
-- Warp
-- ═══════════════════════════════════════════════════════════

function ShipController:_onWarpStatus(status: string, info)
	local destinationId = typeof(info) == "table" and info.destinationId or nil

	if status == "charging" then
		-- A tela vai ser do túnel: o mapa não fica por cima
		local mapController = Knit.GetController("MapController")
		if mapController then
			mapController:Close()
		end
		self._warp:SetCharging(destinationId)
		self._tunnel:SetShip(self:GetOwnShip())
		-- A carga varia por nave: o túnel usa ela pra casar o segundo 12 da
		-- trilha com o teleporte
		local chargeTime = (typeof(info) == "table" and tonumber(info.chargeTime)) or 0
		self._tunnel:BeginCharge(chargeTime, WarpModule.TRAVEL_JUMP_AT)
		self:_startAlign(destinationId)
	elseif status == "travelling" then
		-- Daqui até "completed" a tela é do túnel; o PivotTo cai em jumpAt.
		-- O eixo continua travado (agora mais firme) e a nave arranca até lá.
		local travelTime = (typeof(info) == "table" and info.travelTime) or WarpModule.TRAVEL_TIME
		local jumpAt = (typeof(info) == "table" and info.jumpAt) or WarpModule.TRAVEL_JUMP_AT
		self._warp:SetTravelling(tostring(destinationId), travelTime)
		self._tunnel:SetShip(self:GetOwnShip())
		self._tunnel:Play(travelTime, jumpAt)
		if not self._align then
			self:_startAlign(destinationId) -- a carga pode ter vindo antes da nave carregar
		end
		self:_startBoost(jumpAt)
	elseif status == "completed" then
		-- Normalmente a trava da chegada já está correndo (começa no teleporte);
		-- se o teleporte não foi visto, ela começa agora
		local align = self._align
		if align and not align.releaseAt then
			align.boost = nil
			align.releaseAt = os.clock() + ARRIVAL_HOLD
		end
		self._warp:SetCharging(nil)
		self._warp:ShowMessage("Chegada: " .. string.upper(tostring(destinationId)), false)
	elseif status == "cancelled" then
		self:_stopAlign()
		self._warp:SetCharging(nil)
		self._tunnel:Stop()
		self._warp:ShowMessage(message(info and info.reason), true)
	end
end

--[[
	Alinhamento da carga: a nave vira devagar até apontar pro destino.

	Quem gira é o BodyGyro do próprio kit de voo — a gente só move o ALVO dele,
	e devagar. Sai suave de graça, a física continua sendo a do PlaneScript, e
	como o piloto tem a posse de rede da nave, os outros jogadores veem o giro
	acontecer (é a leitura de "aquela nave vai saltar pra lá", §3.4).

	Roda no Stepped, logo antes do passo de física: mesmo que o LocalPlaneScript
	escreva o gyro no RenderStepped ou no Heartbeat, o último valor a valer no
	passo é o nosso.
]]
function ShipController:_startAlign(destinationId: string?)
	self:_stopAlign()

	local ship = self:GetOwnShip()
	local destination = if typeof(destinationId) == "string" then WarpModule.GetDestination(destinationId) else nil
	local body = ship and ship:FindFirstChild(ShipData.PARTS.body)
	if not ship or not destination or not body or not body:IsA("BasePart") then
		return
	end

	self._align = {
		ship = ship,
		body = body :: BasePart,
		target = destination.position,
		current = body.CFrame.Rotation,
	}
	self._alignConn = RunService.Stepped:Connect(function(_, dt)
		self:_stepAlign(dt)
	end)
end

function ShipController:_stepAlign(dt: number)
	local align = self._align
	if not align then
		return
	end

	local body = align.body
	if not body.Parent or not align.ship.Parent then
		self:_stopAlign()
		return
	end

	-- Sem gyro o loop de voo não está rodando (ainda ou mais): não força nada,
	-- girar a nave na unha brigaria com a física
	local gyro = body:FindFirstChildWhichIsA("BodyGyro")
	if not gyro then
		return
	end

	if align.releaseAt and os.clock() >= align.releaseAt then
		self:_stopAlign() -- fim da trava da chegada: o piloto volta a mandar
		return
	end

	-- Na carga a nave mira o PONTO do marcador. Da viagem em diante mira um
	-- RUMO fixo: depois do teleporte ela chega ainda embalada, passa do
	-- marcador, e "olhar pro marcador" viraria olhar pra trás — era o giro de
	-- 180° na chegada.
	local desired
	if align.heading then
		desired = CFrame.lookAt(Vector3.zero, align.heading).Rotation
	else
		local offset = align.target - body.Position
		if offset.Magnitude < 1 then
			return -- em cima do marcador: não há direção pra apontar
		end
		desired = CFrame.lookAt(body.Position, align.target).Rotation
	end

	local rate = if align.locked then TRAVEL_ALIGN_RATE else ALIGN_RATE
	align.current = align.current:Lerp(desired, 1 - math.exp(-dt * rate))
	gyro.CFrame = align.current

	if align.boost then
		self:_stepBoost(align, align.boost)
	end
end

-- ═══════════════════════════════════════════════════════════
-- Arrancada do warp
-- ═══════════════════════════════════════════════════════════

--- Quanto dá pra andar em linha reta até encostar em algo, já descontada a
--- margem. Só conta o que colide (RespectCanCollide): marcador, zona e o
--- próprio túnel (CanQuery false) não seguram a nave.
local function clearance(origin: Vector3, direction: Vector3, distance: number, radius: number, params: RaycastParams): number
	if distance <= 0 then
		return 0
	end
	local hit = workspace:Spherecast(origin, radius, direction * math.min(distance, BOOST_MAX_DISTANCE), params)
	if not hit then
		return distance
	end
	return math.max(hit.Distance - BOOST_SAFETY_MARGIN, 0)
end

--[[
	A nave anda de verdade entre a entrada no túnel e o teleporte — é o que
	faz planeta e estação passarem pela janela em vez de ficarem parados.

	A distância é um ORÇAMENTO, decidido antes de sair e revisto a cada frame:

	  · no máximo BOOST_MAX_DISTANCE
	  · no máximo metade do caminho até o destino (não passa do marcador)
	  · no máximo até BOOST_SAFETY_MARGIN antes do primeiro obstáculo na
	    frente, medido com um Spherecast do tamanho da nave

	Perto do fim do orçamento a velocidade cai sozinha (remaining / BRAKE_TIME),
	então a nave freia em vez de bater. Com um planeta logo à frente o
	orçamento é zero e ela simplesmente não arranca — o túnel continua igual.

	Quem escreve a velocidade é o piloto, que já tem a posse de rede: é o mesmo
	caminho que o kit de voo usa, e os outros jogadores veem a nave disparar.
]]
function ShipController:_startBoost(jumpAt: number)
	local align = self._align
	if not align then
		return
	end
	align.locked = true

	local ship, body = align.ship, align.body

	-- O rumo trava aqui, na direção do marcador vista de onde a nave está. O
	-- servidor calcula a chegada sobre essa mesma linha, então ela chega
	-- apontando pra onde já estava indo.
	local toMarker = align.target - body.Position
	align.heading = if toMarker.Magnitude > 1 then toMarker.Unit else align.current.LookVector
	local direction = align.heading

	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	local exclude: { Instance } = { ship }
	if player.Character then
		table.insert(exclude, player.Character)
	end
	params.FilterDescendantsInstances = exclude
	params.RespectCanCollide = true

	local radius = math.max(ship:GetExtentsSize().Magnitude / 2, 4)
	local toTarget = (align.target - body.Position).Magnitude
	local budget = math.min(BOOST_MAX_DISTANCE, toTarget * BOOST_DEST_FRACTION)
	budget = clearance(body.Position, direction, budget, radius, params)

	-- Cruzeiro que cobre o orçamento no tempo que tem (a rampa quadrática
	-- anda 1/3 do que andaria em velocidade cheia)
	local duration = math.max(jumpAt, 0.2)
	local startSpeed = math.max(body.AssemblyLinearVelocity:Dot(direction), 0)
	local cruise = budget / math.max(duration - BOOST_RAMP * 2 / 3, 0.2)
	cruise = math.min(math.max(cruise, startSpeed), BOOST_MAX_SPEED)

	align.boost = {
		started = os.clock(),
		duration = duration,
		budget = budget,
		travelled = 0,
		lastPosition = body.Position,
		startSpeed = startSpeed,
		cruise = cruise,
		radius = radius,
		params = params,
	}
end

function ShipController:_stepBoost(align, boost)
	local body = align.body
	local position = body.Position
	local moved = position - boost.lastPosition
	boost.lastPosition = position

	-- O PivotTo do servidor chegou: a nave chega PARADA e de frente, e o eixo
	-- segue travado por ARRIVAL_HOLD. Antes a arrancada soltava a velocidade
	-- um pouco antes do teleporte e a nave chegava embalada.
	if moved.Magnitude > BOOST_TELEPORT_JUMP then
		align.boost = nil
		align.releaseAt = os.clock() + ARRIVAL_HOLD
		body.AssemblyLinearVelocity = Vector3.zero
		body.AssemblyAngularVelocity = Vector3.zero
		local mover = body:FindFirstChildWhichIsA("BodyVelocity")
		if mover then
			mover.Velocity = Vector3.zero
		end
		return
	end

	-- O teleporte não veio (warp caiu no servidor): solta sem esperar mais
	local elapsed = os.clock() - boost.started
	if elapsed >= boost.duration + BOOST_TELEPORT_TIMEOUT then
		align.boost = nil
		return
	end

	local direction = align.current.LookVector
	boost.travelled += math.max(moved:Dot(direction), 0)

	local ramp = math.min(elapsed / BOOST_RAMP, 1)
	local speed = boost.startSpeed + (boost.cruise - boost.startSpeed) * ramp * ramp

	-- Olha um pouco à frente: obstáculo que apareceu agora (outra nave
	-- cruzando) encurta o orçamento, e a frenagem abaixo cuida do resto
	local lookahead = speed * BOOST_LOOKAHEAD + BOOST_SAFETY_MARGIN
	local room = clearance(position, direction, lookahead, boost.radius, boost.params)
	if room < lookahead then
		boost.budget = math.min(boost.budget, boost.travelled + room)
	end

	local remaining = math.max(boost.budget - boost.travelled, 0)
	speed = math.min(speed, remaining / BOOST_BRAKE_TIME)

	local velocity = direction * speed
	body.AssemblyLinearVelocity = velocity
	-- O BodyVelocity do kit puxaria de volta pro throttle do piloto
	local mover = body:FindFirstChildWhichIsA("BodyVelocity")
	if mover then
		mover.Velocity = velocity
	end
end

function ShipController:_stopAlign()
	if self._alignConn then
		self._alignConn:Disconnect()
		self._alignConn = nil
	end
	self._align = nil
end

--- Warp em andamento: carga, túnel ou a trava da chegada.
function ShipController:IsWarpBusy(): boolean
	return self._warp:IsBusy() or self._align ~= nil
end

function ShipController:_refreshDestinations(ship: Model)
	local stats = self:GetEquippedStats()
	if not stats then
		return
	end

	local body = ship:FindFirstChild(ShipData.PARTS.body)
	local from = if body and body:IsA("BasePart") then body.Position else ship:GetPivot().Position

	local list = {}
	for _, dest in WarpModule.GetDestinations() do
		if not MapConfig.IsWarpable(dest.id) then
			continue -- só de mapa (Solara)
		end
		local distance = (dest.position - from).Magnitude
		table.insert(list, {
			id = dest.id,
			position = dest.position,
			distance = distance,
			inRange = WarpModule.IsInRange(stats.warpRange, from, dest.position),
		})
	end
	table.sort(list, function(a, b)
		return a.distance < b.distance
	end)

	self._destinations = list
end

--[[
	Alvo da mira: o marcador de warp mais perto do centro da tela, dentro de
	AIM_ENTER_ANGLE (ou AIM_KEEP_ANGLE, se já era o alvo). A direção é a da
	câmera, não a do nariz da nave: é "pra onde o piloto está olhando".
	Alcance e distância vêm da última atualização da lista (_refreshDestinations).
]]
function ShipController:_updateAimTarget(active: boolean)
	if not active then
		self._aim:SetTarget(nil)
		return
	end

	local camera = workspace.CurrentCamera
	local origin = camera.CFrame.Position
	local look = camera.CFrame.LookVector
	local current = self._aim:GetTarget()

	local best, bestAngle = nil, math.huge
	for _, dest in self._destinations do
		if dest.distance < WarpModule.MIN_DISTANCE then
			continue
		end
		local offset = dest.position - origin
		local length = offset.Magnitude
		if length < 1 then
			continue
		end
		local angle = math.deg(math.acos(math.clamp(look:Dot(offset / length), -1, 1)))
		local limit = if current and current.id == dest.id then AIM_KEEP_ANGLE else AIM_ENTER_ANGLE
		if angle <= limit and angle < bestAngle then
			best, bestAngle = dest, angle
		end
	end

	if not best then
		self._aim:SetTarget(nil)
		return
	end

	self._aim:SetTarget({
		id = best.id,
		name = MapConfig.GetDisplayName(best.id),
		position = best.position,
		distance = best.distance,
		inRange = best.inRange,
	})
end

function ShipController:_activateAim()
	local target = self._aim:GetTarget()
	if not target then
		return
	end
	if not target.inRange then
		self._warp:ShowMessage(message("WARP_OUT_OF_RANGE"), true)
		return
	end
	self._aim:SetTarget(nil)
	self:RequestWarp(target.id)
end

--- Brilho crescente no casco de QUALQUER nave carregando warp. É o que deixa
--- um combat ver o explorer carregando e decidir interceptar (§3.4).
function ShipController:_bindWarpFx()
	local function onShip(model: Instance)
		if not model:IsA("Model") or self._warpFx[model] then
			return
		end

		local fx = { conns = {} }
		self._warpFx[model] = fx

		local function apply()
			local mine = model:GetAttribute(ShipData.OWNER_ATTRIBUTE) == player.UserId
			local alpha = model:GetAttribute(ShipData.WARP_CHARGE_ATTRIBUTE)
			if typeof(alpha) ~= "number" then
				if fx.highlight then
					fx.highlight:Destroy()
					fx.highlight = nil
				end
				if fx.light then
					fx.light:Destroy()
					fx.light = nil
				end
				if mine then
					self._tunnel:SetCharge(0)
				end
				return
			end

			if not fx.highlight then
				local highlight = Instance.new("Highlight")
				highlight.Name = "WarpChargeFx"
				highlight.FillColor = WARP_FX_COLOR
				highlight.OutlineColor = WARP_FX_COLOR
				highlight.DepthMode = Enum.HighlightDepthMode.Occluded
				highlight.Adornee = model
				highlight.Parent = model
				fx.highlight = highlight

				local body = model:FindFirstChild(ShipData.PARTS.body)
				if body and body:IsA("BasePart") then
					local light = Instance.new("PointLight")
					light.Name = "WarpChargeLight"
					light.Color = WARP_FX_COLOR
					light.Range = WARP_FX_LIGHT_RANGE
					light.Parent = body
					fx.light = light
				end
			end

			fx.highlight.FillTransparency = 1 - 0.55 * alpha
			fx.highlight.OutlineTransparency = 1 - alpha
			if fx.light then
				fx.light.Brightness = 4 * alpha
			end

			if mine then
				self._warp:SetProgress(alpha)
				-- Build-up na tela do piloto: o túnel já começa a insinuar
				self._tunnel:SetCharge(alpha)
			end
		end

		table.insert(fx.conns, model:GetAttributeChangedSignal(ShipData.WARP_CHARGE_ATTRIBUTE):Connect(apply))
		apply()
	end

	for _, model in CollectionService:GetTagged(ShipData.SHIP_TAG) do
		onShip(model)
	end
	CollectionService:GetInstanceAddedSignal(ShipData.SHIP_TAG):Connect(onShip)
	CollectionService:GetInstanceRemovedSignal(ShipData.SHIP_TAG):Connect(function(model)
		local fx = self._warpFx[model]
		if not fx then
			return
		end
		self._warpFx[model] = nil
		for _, conn in fx.conns do
			conn:Disconnect()
		end
		if fx.highlight then
			fx.highlight:Destroy()
		end
		if fx.light then
			fx.light:Destroy()
		end
	end)
end

-- ═══════════════════════════════════════════════════════════
-- Limites de voo
-- ═══════════════════════════════════════════════════════════

--[[
	Fundo do mapa e Solara: a nave freia ao chegar perto e para no limite, em
	vez de cair no vazio ou entrar na estrela. Só no espaço, pilotando, e fora
	do warp (a arrancada e a trava da chegada mandam na velocidade ali).
]]
function ShipController:_updateLimits(dt: number, ship: Model?, piloting: boolean)
	local body = ship and ship:FindFirstChild(ShipData.PARTS.body)
	local active = piloting and not self._isPlanet and self._align == nil and body ~= nil and body:IsA("BasePart")

	if not active then
		self._limitBody = nil
		self._limit = nil
		self:_setLimitToast(nil)
		return
	end

	self._solaraTimer = (self._solaraTimer or 0) - dt
	if self._solaraTimer <= 0 then
		self._solaraTimer = SOLARA_REFRESH
		self._solaraPosition = FlightLimits.GetSolaraPosition()
	end

	self._limitBody = body :: BasePart
	local limit = FlightLimits.Nearest((body :: BasePart).Position, self._solaraPosition)
	self._limit = limit

	if limit.distance <= 5 then
		self:_setLimitToast("lost", limit.id)
	elseif limit.distance < FlightLimits.WARN_DISTANCE then
		self:_setLimitToast("warn", limit.id)
	else
		self:_setLimitToast(nil)
	end
end

function ShipController:_setLimitToast(band: string?, limitId: string?)
	local state = if band then band .. ":" .. tostring(limitId) else nil
	-- Mesmo estado não repinta, a menos que outro aviso (um Flash da
	-- ancoragem) tenha tirado este da tela
	if state == self._limitToast and (state == nil or self._toast:IsShowing()) then
		return
	end
	local previous = self._limitToast
	self._limitToast = state

	local messages = LIMIT_MESSAGES[limitId or ""] or LIMIT_MESSAGES.floor
	if band == "lost" then
		self._toast:Show(messages.lost, UIStyle.C.negative)
	elseif band == "warn" then
		self._toast:Show(messages.warn, LIMIT_WARN_COLOR)
	elseif previous then
		self._toast:Hide()
	end
end

function ShipController:_stepLimits()
	local body = self._limitBody
	local limit = self._limit
	if not body or not limit or not body.Parent or self._align then
		return
	end

	-- Atualiza a distância com a posição deste passo (o _update é do frame
	-- anterior)
	limit = FlightLimits.Nearest(body.Position, self._solaraPosition)
	if limit.distance >= FlightLimits.WARN_DISTANCE then
		return
	end

	local velocity = body.AssemblyLinearVelocity
	local clamped = FlightLimits.Clamp(velocity, limit)
	if clamped ~= velocity then
		body.AssemblyLinearVelocity = clamped
	end

	-- O BodyVelocity do kit puxaria de volta pro throttle do piloto
	local mover = body:FindFirstChildWhichIsA("BodyVelocity")
	if mover then
		mover.Velocity = FlightLimits.Clamp(mover.Velocity, limit)
	end
end

-- ═══════════════════════════════════════════════════════════
-- Loop
-- ═══════════════════════════════════════════════════════════

--- Perto do HangarTerminal (mesmo alcance que o servidor valida).
function ShipController:_isNearTerminal(): boolean
	local terminal = PlaceConfig.GetHangarTerminal()
	local character = player.Character
	local root = character and character:FindFirstChild("HumanoidRootPart")
	if not terminal or not root then
		return false
	end
	local reach = terminal.Size.Magnitude / 2 + ShipData.HANGAR_INTERACT_DISTANCE
	return ((root :: BasePart).Position - terminal.Position).Magnitude <= reach
end

local function shipPosition(model: Model): Vector3
	local body = model:FindFirstChild(ShipData.PARTS.body)
	return if body and body:IsA("BasePart") then body.Position else model:GetPivot().Position
end

function ShipController:_update(dt: number)
	local character = player.Character
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	local root = character and character:FindFirstChild("HumanoidRootPart")
	local seatPart = humanoid and humanoid.SeatPart

	local seated = seatPart ~= nil
	local ship = self:GetOwnShip()
	local piloting = seated and ship ~= nil and seatPart:IsDescendantOf(ship)

	if seated ~= self._seated then
		self._seated = seated
		self._prompts:SetSeated(seated)
		if seated then
			self._menu:Close()
			self._hangar:Close()
			if piloting and ship then
				self:_diagnoseFlight(ship)
			end
		end
	end

	-- Warp: só pilotando a própria nave, num Place com destinos
	local canWarp = piloting and workspace:FindFirstChild(PlaceConfig.WARP_DESTINATIONS) ~= nil
	self._warp:SetVisible(canWarp)
	if canWarp and ship then
		self._destinationsTimer -= dt
		if self._destinationsTimer <= 0 then
			self._destinationsTimer = DESTINATIONS_REFRESH
			self:_refreshDestinations(ship)
		end
	end

	-- Mira de warp: pilotando, sem warp em andamento e sem o mapa por cima
	local mapController = Knit.GetController("MapController")
	local mapOpen = mapController ~= nil and mapController:IsOpen()
	self:_updateAimTarget(canWarp and not self:IsWarpBusy() and not mapOpen)

	-- Menu aberto e o jogador se afastou (da nave e do terminal): fecha.
	-- A distância é medida pelo Body, nunca pelo pivô: Model sem PrimaryPart
	-- guarda o pivô onde foi posicionado e ele não acompanha a nave em voo.
	local nearTerminal = self:_isNearTerminal()
	local inHangar = root ~= nil and PlaceConfig.IsInHangarZone((root :: BasePart).Position)

	if self._menu:IsOpen() and root then
		local model = self._menu:GetModel()
		if model then
			local distance = ((root :: BasePart).Position - shipPosition(model)).Magnitude
			if not model.Parent or (distance > MENU_CLOSE_DISTANCE and not nearTerminal) then
				self._menu:Close()
			end
		end
	end

	-- Melhoria é serviço de hangar: jogador no hangar e nave pousada lá (ou
	-- guardada). STATUS continua disponível de qualquer lugar.
	-- Nave guardada conta como no hangar; lançada, precisa estar ancorada no pad
	local shipDocked = ship == nil or ship:GetAttribute(ShipData.DOCKED_ATTRIBUTE) == true
	self._menu:SetUpgradeAvailable((inHangar or nearTerminal) and shipDocked)

	-- HUD do hangar aberto pelo terminal: afastar-se dele fecha
	if self._hangar:IsOpen() and not nearTerminal then
		self._hangar:Close()
	end

	self:_updateDockToast(ship)
	self:_updateLimits(dt, ship, piloting)

	-- Nave fora do assento dentro do hangar: MenuPrompt vira GUARDAR NAVE.
	-- É o único uso de jogabilidade da HangarZone; o resto é ambiência.
	self._prompts:SetStowMode(ship ~= nil and not seated and PlaceConfig.IsInHangarZone(shipPosition(ship)))
end

return ShipController
