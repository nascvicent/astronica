--[[
	ShipMiningService
	Mineração pelas armas da nave. Autoridade total do servidor: acerto, dano
	de mineração, quem recebe e quanto.

	Não existe tiro próprio: os projéteis são os do CombatService. Ele pergunta
	aqui se o projétil passou por alguma rocha (CastOres) e, se passou, avisa o
	acerto (HitOre) com o dano de mineração da nave que atirou.

	ROCHAS
	  Workspace/Ores (ver OreConfig). Cada rocha ganha a tag ShipOre e os
	  atributos que o client usa pra animar: minério, semente, centro, raio.
	  As Parts ficam ANCORADAS e PARADAS no servidor; quem as faz flutuar é o
	  client. Pro acerto bater com o que o jogador vê, o tiro é levado pro
	  referencial da rocha em repouso (inverso da pose animada naquele instante)
	  e testado lá.

	RECOMPENSA
	  Ao quebrar, todo mundo que causou pelo menos MIN_SHARE do dano leva a
	  própria rolagem, com a MiningQuality da própria nave. Só entra o que cabe
	  no inventário; se não coube nada pra ninguém, a rocha não quebra (fica por
	  um fio, como o node da pistola).

	Local: src/server/Services/ShipMiningService.luau
]]

local Knit = require(game:GetService("ReplicatedStorage").Packages.Knit)
local Players = game:GetService("Players")
local CollectionService = game:GetService("CollectionService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local OreConfig = require(ReplicatedStorage.Shared.OreConfig)
local InventoryModule = require(ReplicatedStorage.Shared.InventoryModule)

-- Intervalo mínimo entre dois OreHit da mesma rocha pros clients (lascas e
-- tremor). O dano conta todo projétil; só o efeito é agrupado
local HIT_BROADCAST_INTERVAL = 0.08

-- Intervalo mínimo entre dois avisos de inventário cheio pro mesmo jogador
local FAIL_COOLDOWN = 2

-- Passo mínimo pra republicar a integridade (evita um atributo por projétil)
local INTEGRITY_STEP = 0.01

type Contribution = { damage: number, quality: number }

type OreState = {
	root: Instance, -- Model ou BasePart
	oreId: string,
	def: OreConfig.OreDef,
	motion: OreConfig.Motion,
	parts: { BasePart },
	original: { [BasePart]: { canCollide: boolean, canQuery: boolean } },
	center: Vector3,
	radius: number,
	seed: number,
	params: RaycastParams,
	hp: number,
	active: boolean,
	contrib: { [Player]: Contribution },
	lastHitAt: number,
	lastBroadcast: number,
	publishedIntegrity: number,
}

local ShipMiningService = Knit.CreateService({
	Name = "ShipMiningService",

	Client = {
		-- (root, position: Vector3, shooter: Player) — todos, agrupado por rocha
		OreHit = Knit.CreateSignal(),
		-- (root) — todos: a rocha estilhaçou
		OreDepleted = Knit.CreateSignal(),
		-- (root, itemId, amount) — só pra quem recebeu
		OreCollected = Knit.CreateSignal(),
		-- (message) — só pra quem não recebeu tudo
		OreFailed = Knit.CreateSignal(),
	},

	_ores = {} :: { [Instance]: OreState },
	_roots = {} :: { Instance },
	_lastFail = {} :: { [Player]: number },
})

-- ═══════════════════════════════════════════════════════════
-- Registro
-- ═══════════════════════════════════════════════════════════

local function collectParts(root: Instance): { BasePart }
	if root:IsA("BasePart") then
		return { root }
	end
	local parts = {}
	for _, inst in root:GetDescendants() do
		if inst:IsA("BasePart") then
			table.insert(parts, inst)
		end
	end
	return parts
end

local function bounds(root: Instance): (Vector3, number)
	if root:IsA("Model") then
		local cf, size = root:GetBoundingBox()
		return cf.Position, size.Magnitude / 2
	end
	local part = root :: BasePart
	return part.Position, part.Size.Magnitude / 2
end

function ShipMiningService:_rebuildRoots()
	local roots = {}
	for root in self._ores do
		table.insert(roots, root)
	end
	self._roots = roots
end

function ShipMiningService:_register(root: Instance)
	if self._ores[root] or not (root:IsA("Model") or root:IsA("BasePart")) then
		return
	end

	local oreId = OreConfig.ResolveOreId(root)
	local def = OreConfig.Get(oreId)
	if not oreId or not def then
		warn(string.format(
			"[ShipMiningService] %s sem minério reconhecido — ponha um atributo com o itemId (ex.: OreId = \"gravitita\")",
			root:GetFullName()
		))
		return
	end
	if not InventoryModule.IsValidItem(oreId) then
		warn(string.format("[ShipMiningService] minério %s não existe no InventoryModule.Items", oreId))
		return
	end

	local parts = collectParts(root)
	if #parts == 0 then
		return
	end

	local original = {}
	for _, part in parts do
		-- Ancorada: a rocha é movida só no client, e solta ela cairia/derivaria
		part.Anchored = true
		original[part] = { canCollide = part.CanCollide, canQuery = part.CanQuery }
	end

	-- Chega inteira no client: com as Parts chegando aos poucos, as que
	-- chegassem depois nasceriam fora da pose animada por um frame
	if root:IsA("Model") then
		pcall(function()
			root.ModelStreamingMode = Enum.ModelStreamingMode.Atomic
		end)
	end

	local center, radius = bounds(root)
	local seed = math.random()

	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Include
	params.FilterDescendantsInstances = { root }

	self._ores[root] = {
		root = root,
		oreId = oreId,
		def = def,
		motion = OreConfig.GetMotion(oreId),
		parts = parts,
		original = original,
		center = center,
		radius = radius,
		seed = seed,
		params = params,
		hp = def.hardness,
		active = true,
		contrib = {},
		lastHitAt = 0,
		lastBroadcast = 0,
		publishedIntegrity = 1,
	}

	root:SetAttribute(OreConfig.ID_ATTRIBUTE, oreId)
	root:SetAttribute(OreConfig.SEED_ATTRIBUTE, seed)
	root:SetAttribute(OreConfig.CENTER_ATTRIBUTE, center)
	root:SetAttribute(OreConfig.RADIUS_ATTRIBUTE, radius)
	root:SetAttribute(OreConfig.ACTIVE_ATTRIBUTE, true)
	root:SetAttribute(OreConfig.INTEGRITY_ATTRIBUTE, 1)
	CollectionService:AddTag(root, OreConfig.TAG)

	self:_rebuildRoots()
end

function ShipMiningService:_unregister(root: Instance)
	if not self._ores[root] then
		return
	end
	self._ores[root] = nil
	self:_rebuildRoots()
end

--- Rochas dentro de Workspace/Ores. Pasta dentro da pasta é só organização:
--- desce nela. Qualquer outra coisa (Model/Part) é uma rocha.
function ShipMiningService:_scan(container: Instance)
	for _, child in container:GetChildren() do
		if child:IsA("Folder") then
			self:_watchFolder(child)
		else
			self:_register(child)
		end
	end
end

function ShipMiningService:_watchFolder(folder: Instance)
	self:_scan(folder)
	folder.ChildAdded:Connect(function(child)
		-- Um frame pra rocha chegar com as Parts e atributos
		task.defer(function()
			if child.Parent ~= folder then
				return
			end
			if child:IsA("Folder") then
				self:_watchFolder(child)
			else
				self:_register(child)
			end
		end)
	end)
	folder.ChildRemoved:Connect(function(child)
		self:_unregister(child)
	end)
end

-- ═══════════════════════════════════════════════════════════
-- Acerto (chamado pelo CombatService)
-- ═══════════════════════════════════════════════════════════

--- Raízes de todas as rochas: o CombatService tira elas do traçado normal do
--- tiro (lá elas estão paradas, e o acerto certo é o de CastOres).
function ShipMiningService:GetOreRoots(): { Instance }
	return self._roots
end

--[[
	Primeira rocha ativa no caminho origin → origin + displacement, na pose
	animada do instante atual. Devolve (rocha, ponto de acerto no mundo,
	distância percorrida) ou nil.
]]
function ShipMiningService:CastOres(origin: Vector3, displacement: Vector3, radius: number): (Instance?, Vector3?, number?)
	local length = displacement.Magnitude
	if length <= 0 then
		return nil
	end
	local direction = displacement / length
	local now = workspace:GetServerTimeNow()

	local bestRoot, bestPosition, bestDistance = nil, nil, math.huge

	for root, state in self._ores do
		if not state.active then
			continue
		end

		-- Descarte barato: esfera da rocha (com folga da flutuação) x segmento
		local toCenter = state.center - origin
		local along = math.clamp(toCenter:Dot(direction), 0, length)
		local reach = state.radius + radius + state.motion.bob
		if (state.center - (origin + direction * along)).Magnitude > reach then
			continue
		end

		-- Leva o tiro pro referencial da rocha parada
		local motion = OreConfig.GetMotionCFrame(state.center, state.seed, state.motion, now)
		local inverse = motion:Inverse()
		local result = workspace:Spherecast(inverse * origin, radius, inverse:VectorToWorldSpace(displacement), state.params)
		if result and result.Distance < bestDistance then
			bestRoot = root
			bestPosition = motion * result.Position
			bestDistance = result.Distance
		end
	end

	if bestRoot then
		return bestRoot, bestPosition, bestDistance
	end
	return nil
end

function ShipMiningService:_publishIntegrity(state: OreState, force: boolean?)
	local integrity = math.clamp(state.hp / state.def.hardness, 0, 1)
	if force or math.abs(integrity - state.publishedIntegrity) >= INTEGRITY_STEP then
		state.publishedIntegrity = integrity
		state.root:SetAttribute(OreConfig.INTEGRITY_ATTRIBUTE, integrity)
	end
end

function ShipMiningService:HitOre(root: Instance, shooter: Player, damage: number, miningQuality: number, position: Vector3)
	local state = self._ores[root]
	if not state or not state.active or damage <= 0 or not shooter.Parent then
		return
	end

	local now = os.clock()
	state.hp -= damage
	state.lastHitAt = now

	local contribution = state.contrib[shooter]
	if contribution then
		contribution.damage += damage
		contribution.quality = miningQuality
	else
		state.contrib[shooter] = { damage = damage, quality = miningQuality }
	end

	if now - state.lastBroadcast >= HIT_BROADCAST_INTERVAL then
		state.lastBroadcast = now
		self.Client.OreHit:FireAll(root, position, shooter)
	end

	if state.hp <= 0 then
		self:_deplete(state)
	else
		self:_publishIntegrity(state)
	end
end

-- ═══════════════════════════════════════════════════════════
-- Quebra e renascimento
-- ═══════════════════════════════════════════════════════════

function ShipMiningService:_fail(player: Player, message: string)
	local now = os.clock()
	if now - (self._lastFail[player] or 0) < FAIL_COOLDOWN then
		return
	end
	self._lastFail[player] = now
	self.Client.OreFailed:Fire(player, message)
end

function ShipMiningService:_deplete(state: OreState)
	local itemId = state.oreId
	local itemName = InventoryModule.Items[itemId].name

	local total = 0
	for _, contribution in state.contrib do
		total += contribution.damage
	end

	local recipients = 0
	local awarded: { [Player]: number } = {}
	local anyAwarded = false

	for player, contribution in state.contrib do
		if not player.Parent or total <= 0 or contribution.damage / total < OreConfig.MIN_SHARE then
			continue
		end
		recipients += 1

		local amount = OreConfig.RollYield(itemId, contribution.quality)
		local give = math.min(amount, self._inventory:GetSpaceFor(player, itemId))
		if give > 0 then
			local ok = self._inventory:AddItem(player, itemId, give)
			if ok then
				awarded[player] = give
				anyAwarded = true
			else
				give = 0
			end
		end
		if give < amount then
			self:_fail(player, string.format("Inventário cheio — %d %s ficou para trás", amount - give, itemName))
		end
	end

	-- Ninguém conseguiu levar nada: a rocha fica por um fio esperando espaço
	if recipients > 0 and not anyAwarded then
		state.hp = math.max(state.def.hardness * 0.05, 1)
		self:_publishIntegrity(state, true)
		return
	end

	state.active = false
	state.hp = 0
	table.clear(state.contrib)

	for _, part in state.parts do
		part.CanCollide = false
		part.CanQuery = false
	end
	state.root:SetAttribute(OreConfig.INTEGRITY_ATTRIBUTE, 0)
	state.root:SetAttribute(OreConfig.ACTIVE_ATTRIBUTE, false)
	state.publishedIntegrity = 0

	self.Client.OreDepleted:FireAll(state.root)
	for player, amount in awarded do
		self.Client.OreCollected:Fire(player, state.root, itemId, amount)
		-- Objetivo "minerar todos os tipos" (libera traje)
		self._suits:RecordOreMined(player, itemId)
	end

	task.delay(state.def.respawn, function()
		if self._ores[state.root] ~= state then
			return
		end
		self:_respawn(state)
	end)
end

function ShipMiningService:_respawn(state: OreState)
	state.hp = state.def.hardness
	state.active = true
	state.lastHitAt = 0
	table.clear(state.contrib)

	for _, part in state.parts do
		local original = state.original[part]
		if original and part.Parent then
			part.CanCollide = original.canCollide
			part.CanQuery = original.canQuery
		end
	end
	self:_publishIntegrity(state, true)
	state.root:SetAttribute(OreConfig.ACTIVE_ATTRIBUTE, true)
end

--- Rocha largada pela metade volta inteira: sem isso dava pra deixar todas
--- as raras a um tiro de quebrar e voltar depois pra colher.
function ShipMiningService:_regenerate()
	local now = os.clock()
	for _, state in self._ores do
		if state.active and state.hp < state.def.hardness and now - state.lastHitAt >= OreConfig.REGEN_DELAY then
			state.hp = state.def.hardness
			table.clear(state.contrib)
			self:_publishIntegrity(state, true)
		end
	end
end

-- ═══════════════════════════════════════════════════════════
-- Knit Lifecycle
-- ═══════════════════════════════════════════════════════════

function ShipMiningService:KnitStart()
	self._inventory = Knit.GetService("InventoryService")
	self._suits = Knit.GetService("SuitService")

	local folder = workspace:FindFirstChild(OreConfig.FOLDER)
	if folder then
		self:_watchFolder(folder)
	else
		workspace.ChildAdded:Connect(function(child)
			if child.Name == OreConfig.FOLDER and not self._oreFolder then
				self._oreFolder = child
				self:_watchFolder(child)
			end
		end)
	end
	self._oreFolder = folder

	-- Rocha fora da pasta também vale, se alguém puser a tag na mão
	for _, root in CollectionService:GetTagged(OreConfig.TAG) do
		self:_register(root)
	end
	CollectionService:GetInstanceAddedSignal(OreConfig.TAG):Connect(function(root)
		self:_register(root)
	end)
	CollectionService:GetInstanceRemovedSignal(OreConfig.TAG):Connect(function(root)
		self:_unregister(root)
	end)

	Players.PlayerRemoving:Connect(function(player)
		self._lastFail[player] = nil
		for _, state in self._ores do
			state.contrib[player] = nil
		end
	end)

	local regenTimer = 0
	RunService.Heartbeat:Connect(function(dt)
		regenTimer += dt
		if regenTimer >= 1 then
			regenTimer = 0
			self:_regenerate()
		end
	end)

	local count = 0
	for _ in self._ores do
		count += 1
	end
	print(string.format("[ShipMiningService] Started — %d rochas registradas", count))
end

return ShipMiningService
