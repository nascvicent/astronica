--[[
	GravityService
	Simula gravidade quase-zero para jogadores que NÃO estão dentro de estações espaciais.
	Usa BodyForce individual no HumanoidRootPart de cada jogador.

	Partes das estações devem estar em workspace.SpaceStations (Folder).
]]

local Knit = require(game:GetService("ReplicatedStorage").Packages.Knit)
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")

local GravityService = Knit.CreateService({
	Name = "GravityService",
})

-- Fração da gravidade que permanece fora das estações (0.05 = 5% da gravidade normal)
local LOW_GRAVITY_FACTOR = 0.05

-- Intervalo de checagem (segundos)
local CHECK_INTERVAL = 0.5

-- Delay antes de ativar gravidade zero ao sair da estação (segundos)
local EXIT_STATION_DELAY = 3

-- Estado por jogador
local playerStates: { [Player]: {
	bodyForce: BodyForce?,
	inStation: boolean,
	touchCount: number,
	connections: { RBXScriptConnection },
} } = {}

-- ═══════════════════════════════════════════════════════════
-- Helpers
-- ═══════════════════════════════════════════════════════════

local function getStationParts(): { BasePart }
	local folder = workspace:FindFirstChild("SpaceStations")
	if not folder then return {} end

	local parts = {}
	for _, desc in folder:GetDescendants() do
		if desc:IsA("BasePart") then
			table.insert(parts, desc)
		end
	end
	return parts
end

local function updateBodyForce(state)
	if not state or not state.bodyForce then return end

	if state.inStation then
		-- Dentro da estação: gravidade normal (sem força compensatória)
		state.bodyForce.Force = Vector3.zero
	else
		-- Fora da estação: compensa quase toda a gravidade
		local rootPart = state.bodyForce.Parent
		if rootPart and rootPart:IsA("BasePart") then
			local mass = 0
			local character = rootPart.Parent
			if character then
				for _, part in character:GetDescendants() do
					if part:IsA("BasePart") then
						mass += part:GetMass()
					end
				end
			end
			-- Força para cima = massa * gravidade * (1 - fator_baixo)
			local counterForce = mass * workspace.Gravity * (1 - LOW_GRAVITY_FACTOR)
			state.bodyForce.Force = Vector3.new(0, counterForce, 0)
		end
	end
end

-- ═══════════════════════════════════════════════════════════
-- Setup por jogador
-- ═══════════════════════════════════════════════════════════

local function setupCharacter(player: Player, character: Model)
	-- Limpa estado anterior
	local oldState = playerStates[player]
	if oldState then
		for _, conn in oldState.connections do
			conn:Disconnect()
		end
	end

	local rootPart = character:WaitForChild("HumanoidRootPart", 10)
	if not rootPart then return end

	-- Cria BodyForce
	local bodyForce = Instance.new("BodyForce")
	bodyForce.Name = "ZeroGravityForce"
	bodyForce.Force = Vector3.zero
	bodyForce.Parent = rootPart

	local state = {
		bodyForce = bodyForce,
		inStation = false,
		touchCount = 0,
		connections = {},
	}
	playerStates[player] = state

	-- Conecta Touch/TouchEnded em todas as partes das estações
	local function connectStationPart(part: BasePart)
		local touchConn = part.Touched:Connect(function(hit)
			if not hit:IsDescendantOf(character) then return end
			state.touchCount += 1
			state._exitTime = nil -- cancela timer de saída pendente
			if not state.inStation then
				state.inStation = true
				updateBodyForce(state)
			end
		end)

		local endConn = part.TouchEnded:Connect(function(hit)
			if not hit:IsDescendantOf(character) then return end
			state.touchCount = math.max(0, state.touchCount - 1)
			if state.touchCount == 0 and state.inStation then
				state._exitTime = tick()
				task.delay(EXIT_STATION_DELAY, function()
					if state._exitTime and (tick() - state._exitTime) >= EXIT_STATION_DELAY - 0.1 and state.touchCount == 0 then
						state.inStation = false
						state._exitTime = nil
						updateBodyForce(state)
					end
				end)
			end
		end)

		table.insert(state.connections, touchConn)
		table.insert(state.connections, endConn)
	end

	for _, part in getStationParts() do
		connectStationPart(part)
	end

	-- Observa novas partes adicionadas às estações
	local folder = workspace:FindFirstChild("SpaceStations")
	if folder then
		local addedConn = folder.DescendantAdded:Connect(function(desc)
			if desc:IsA("BasePart") then
				connectStationPart(desc)
			end
		end)
		table.insert(state.connections, addedConn)
	end

	-- Começa fora da estação (gravidade quase-zero)
	updateBodyForce(state)

	-- Atualiza a força periodicamente (massa pode mudar com acessórios etc.)
	local updateConn = RunService.Heartbeat:Connect(function()
		-- Throttle: só atualiza a cada CHECK_INTERVAL
		if not state._lastUpdate or (tick() - state._lastUpdate) >= CHECK_INTERVAL then
			state._lastUpdate = tick()
			updateBodyForce(state)
		end
	end)
	table.insert(state.connections, updateConn)
end

local function cleanupPlayer(player: Player)
	local state = playerStates[player]
	if not state then return end

	for _, conn in state.connections do
		conn:Disconnect()
	end

	if state.bodyForce then
		state.bodyForce:Destroy()
	end

	playerStates[player] = nil
end

-- ═══════════════════════════════════════════════════════════
-- Knit lifecycle
-- ═══════════════════════════════════════════════════════════

function GravityService:KnitStart()
	Players.PlayerAdded:Connect(function(player)
		player.CharacterAdded:Connect(function(character)
			setupCharacter(player, character)
		end)

		-- Caso o character já exista
		if player.Character then
			setupCharacter(player, player.Character)
		end
	end)

	-- Jogadores que já estão no jogo
	for _, player in Players:GetPlayers() do
		player.CharacterAdded:Connect(function(character)
			setupCharacter(player, character)
		end)

		if player.Character then
			setupCharacter(player, player.Character)
		end
	end

	Players.PlayerRemoving:Connect(cleanupPlayer)

	print("[GravityService] Started — low gravity outside SpaceStations")
end

return GravityService
