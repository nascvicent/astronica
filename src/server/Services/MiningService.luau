--[[
	MiningService
	Autoridade do servidor pra pistola laser.

	O client só manda pra onde está mirando. O servidor faz o próprio raycast
	a partir do muzzle real da arma, aplica o dano e entrega o recurso.
	Cheat de posição/alcance não passa daqui.

	Local: src/server/Services/MiningService.luau

	SETUP DOS NODES:
		- Part/MeshPart no workspace
		- CollectionService tag "OreNode"
		- Attribute "ResourceId" = "iron_ore" | "crystal_shard" (default: iron_ore)
]]

local Knit = require(game:GetService("ReplicatedStorage").Packages.Knit)
local Players = game:GetService("Players")
local CollectionService = game:GetService("CollectionService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local LaserConfig = require(ReplicatedStorage.Shared.LaserConfig)
local ShipData = require(ReplicatedStorage.Shared.ShipData)

local NODE_TAG = LaserConfig.NODE_TAG

local MiningService = Knit.CreateService({
	Name = "MiningService",

	Client = {
		-- client → server
		FireLaser = Knit.CreateSignal(), -- (aimPoint: Vector3, mode: string)
		StopLaser = Knit.CreateSignal(), -- ()

		-- server → client
		NodeProgress = Knit.CreateSignal(), -- (node: BasePart, progress: number 0-1)
		NodeDepleted = Knit.CreateSignal(), -- (node: BasePart, itemId: string, amount: number)
		MiningFailed = Knit.CreateSignal(), -- (reason: string)

		-- server → todos os outros clients (quem atirou já desenha o próprio feixe)
		LaserBeam = Knit.CreateSignal(), -- (shooter: Player, endPoint: Vector3, mode: string, hit: boolean)
		LaserBeamStopped = Knit.CreateSignal(), -- (shooter: Player)
	},

	_nodes = {} :: { [BasePart]: any },
	_lastTick = {} :: { [number]: number },
	_lastFail = {} :: { [number]: number },
	_firing = {} :: { [Player]: number },
})

-- Intervalo mínimo (s) entre dois MiningFailed pro mesmo jogador.
-- Sem isso, minerar com inventário cheio avisa a 10 pacotes por segundo.
local FAIL_COOLDOWN = 2

-- Tempo (s) sem tick depois do qual o feixe replicado é desligado sozinho.
-- Cobre os casos em que o StopLaser não chega: morte, queda de conexão, lag.
local BEAM_TIMEOUT = LaserConfig.TICK_RATE * 4

-- ═══════════════════════════════════════════════════════════
-- Nodes
-- ═══════════════════════════════════════════════════════════

--- miningQuality da nave equipada do jogador (§2.2).
function MiningService:_getMiningQuality(player: Player): number
	return if self._ships then self._ships:GetMiningQuality(player) else 0
end

function MiningService:_registerNode(node: Instance)
	if not node:IsA("BasePart") then
		return
	end
	if self._nodes[node] then
		return
	end

	local itemId = node:GetAttribute("ResourceId") or LaserConfig.DEFAULT_NODE
	local def = LaserConfig.GetNodeDef(itemId)

	self._nodes[node] = {
		itemId = itemId,
		def = def,
		hp = def.hardness,
		active = true,
		origTransparency = node.Transparency,
		origCanCollide = node.CanCollide,
		origCanQuery = node.CanQuery,
	}

	node:SetAttribute("Integrity", 1)
end

function MiningService:_unregisterNode(node: Instance)
	self._nodes[node] = nil
end

function MiningService:_depleteNode(player: Player, node: BasePart, state)
	local amount = math.random(state.def.dropMin, state.def.dropMax)

	-- Broca da nave equipada: chance de uma unidade a mais
	if math.random() < ShipData.ExtraUnitChance(self:_getMiningQuality(player)) then
		amount += 1
	end

	local ok, msg = self._inventory:AddItem(player, state.itemId, amount)
	if not ok then
		-- Inventário cheio: node não some, jogador é avisado
		state.hp = math.max(state.hp, state.def.hardness * 0.05)

		local now = os.clock()
		if now - (self._lastFail[player.UserId] or 0) >= FAIL_COOLDOWN then
			self._lastFail[player.UserId] = now
			self.Client.MiningFailed:Fire(player, msg)
		end
		return
	end

	state.active = false
	state.hp = 0

	node:SetAttribute("Integrity", 0)
	node.Transparency = 1
	node.CanCollide = false
	node.CanQuery = false

	self.Client.NodeDepleted:Fire(player, node, state.itemId, amount)

	task.delay(state.def.respawn, function()
		if not node:IsDescendantOf(workspace) or not self._nodes[node] then
			return
		end
		state.hp = state.def.hardness
		state.active = true
		node.Transparency = state.origTransparency
		node.CanCollide = state.origCanCollide
		node.CanQuery = state.origCanQuery
		node:SetAttribute("Integrity", 1)
	end)
end

function MiningService:_damageNode(player: Player, node: BasePart, damage: number)
	local state = self._nodes[node]
	if not state or not state.active then
		return
	end

	state.hp -= damage

	if state.hp <= 0 then
		self:_depleteNode(player, node, state)
	else
		local progress = 1 - (state.hp / state.def.hardness)
		node:SetAttribute("Integrity", state.hp / state.def.hardness)
		self.Client.NodeProgress:Fire(player, node, progress)
	end
end

-- ═══════════════════════════════════════════════════════════
-- Disparo
-- ═══════════════════════════════════════════════════════════

--- Espelha o feixe para os outros jogadores. O client do atirador desenha o
--- feixe localmente, então ele fica de fora do broadcast.
function MiningService:_broadcastBeam(player: Player, endPoint: Vector3, modeName: string, hit: boolean)
	self._firing[player] = os.clock()
	self.Client.LaserBeam:FireExcept(player, player, endPoint, modeName, hit)
end

function MiningService:_stopBeam(player: Player)
	if not self._firing[player] then
		return
	end
	self._firing[player] = nil
	self.Client.LaserBeamStopped:FireExcept(player, player)
end

function MiningService:_getMuzzle(player: Player): (Tool?, BasePart?, Vector3?)
	local character = player.Character
	if not character then
		return nil
	end

	local tool = character:FindFirstChildOfClass("Tool")
	if not tool or not tool:GetAttribute(LaserConfig.TOOL_ATTRIBUTE) then
		return nil
	end

	local handle = tool:FindFirstChild("Handle")
	if not handle or not handle:IsA("BasePart") then
		return nil
	end

	local muzzle = LaserConfig.FindMuzzle(tool)
	local origin = if muzzle then muzzle.WorldPosition else handle.Position

	return tool, handle, origin
end

function MiningService:_onFire(player: Player, aimPoint: Vector3, modeName: string)
	if typeof(aimPoint) ~= "Vector3" or typeof(modeName) ~= "string" then
		return
	end

	local userId = player.UserId
	local now = os.clock()
	local last = self._lastTick[userId] or 0
	local dt = now - last

	-- Anti-spam: ignora pacotes mais rápidos que metade do tick
	if dt < LaserConfig.TICK_RATE * 0.5 then
		return
	end
	self._lastTick[userId] = now

	-- Limita o dt pra evitar burst depois de lag/pausa
	dt = math.clamp(dt, 0, LaserConfig.TICK_RATE * 2)

	local mode = LaserConfig.GetMode(modeName)

	local tool, _handle, origin = self:_getMuzzle(player)
	if not tool or not origin then
		return
	end

	local delta = aimPoint - origin
	if delta.Magnitude < 0.1 then
		return
	end

	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	params.FilterDescendantsInstances = { player.Character }
	params.IgnoreWater = true

	local result = workspace:Raycast(origin, delta.Unit * mode.Range, params)

	-- O feixe existe mesmo sem acerto: replica antes de sair
	local endPoint = if result then result.Position else origin + delta.Unit * mode.Range
	self:_broadcastBeam(player, endPoint, modeName, result ~= nil)

	if not result then
		return
	end

	self:_resolveHit(player, result, mode, dt)
end

--- Ponto único de resolução de acerto.
--- Quando o modo de combate entrar, é só adicionar branches aqui.
function MiningService:_resolveHit(player: Player, result: RaycastResult, mode, dt: number)
	local hit = result.Instance
	local damage = mode.DamagePerSecond * dt

	-- Node de recurso
	if mode.CanMine and self._nodes[hit] then
		-- Tempo de mineração menor = mais dano por segundo no node
		local timeMultiplier = ShipData.MiningTimeMultiplier(self:_getMiningQuality(player))
		self:_damageNode(player, hit, damage / timeMultiplier)
		return
	end

	-- Criatura / player
	if mode.CanDamageCreatures then
		local model = hit:FindFirstAncestorOfClass("Model")
		local humanoid = model and model:FindFirstChildOfClass("Humanoid")
		if humanoid and humanoid.Health > 0 then
			humanoid:TakeDamage(damage)
			return
		end
	end
end

-- ═══════════════════════════════════════════════════════════
-- Knit Lifecycle
-- ═══════════════════════════════════════════════════════════

function MiningService:KnitInit()
	for _, node in CollectionService:GetTagged(NODE_TAG) do
		self:_registerNode(node)
	end

	CollectionService:GetInstanceAddedSignal(NODE_TAG):Connect(function(node)
		self:_registerNode(node)
	end)

	CollectionService:GetInstanceRemovedSignal(NODE_TAG):Connect(function(node)
		self:_unregisterNode(node)
	end)

	Players.PlayerRemoving:Connect(function(player)
		self._lastTick[player.UserId] = nil
		self._lastFail[player.UserId] = nil
		self:_stopBeam(player)
	end)
end

function MiningService:KnitStart()
	self._inventory = Knit.GetService("InventoryService")
	self._ships = Knit.GetService("ShipService")

	self.Client.FireLaser:Connect(function(player, aimPoint, modeName)
		self:_onFire(player, aimPoint, modeName)
	end)

	self.Client.StopLaser:Connect(function(player)
		self:_stopBeam(player)
	end)

	-- Watchdog: desliga o feixe de quem parou de mandar tick sem avisar
	task.spawn(function()
		while true do
			task.wait(LaserConfig.TICK_RATE)
			local now = os.clock()
			for firingPlayer, last in self._firing do
				if now - last > BEAM_TIMEOUT then
					self:_stopBeam(firingPlayer)
				end
			end
		end
	end)

	local count = 0
	for _ in self._nodes do
		count += 1
	end
	print(string.format("[MiningService] Started — %d nodes registrados", count))
end

return MiningService
