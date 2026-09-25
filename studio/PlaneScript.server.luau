-- PlaneScript (Server) - Astronica Ship Controller
--
-- CÓPIA DE REFERÊNCIA — este arquivo NÃO é sincronizado pelo Rojo. O script de
-- verdade mora dentro de cada modelo em ReplicatedStorage/Assets/ShipModels.
-- Ao mudar aqui, cole por cima do PlaneScript de TODOS os modelos no Studio.
--
-- Tiro, superaquecimento e dano saíram daqui: agora são do CombatService
-- (src/server/Services/CombatService.luau), que escuta o mesmo RemoteEvent
-- Shoot. Este script cuida só de: assento, controle de voo (LocalPlaneScript),
-- motor e prompts. O LocalPlaneScript não muda.

local TweenService = game:GetService("TweenService")

local plane = script.Parent
local config = plane.Configurations
local seat = plane.Seat

local Knit = require(game:GetService("ReplicatedStorage").Packages.Knit)
local HealthService
local InventoryService
Knit.OnStart():andThen(function()
	HealthService = Knit.GetService("HealthService")
	InventoryService = Knit.GetService("InventoryService")
end)

-- ============================================================
-- Armas: nave sem arma não mostra os canos
-- ============================================================
-- O disparo em si é do CombatService. O RemoteEvent Shoot continua no
-- modelo: é por ele que o LocalPlaneScript avisa que está atirando.

local gunsEnabled = config:FindFirstChild("GunsEnabled")
if not (gunsEnabled and gunsEnabled.Value) then
	if plane:FindFirstChild("Guns") then plane.Guns:Destroy() end
	if plane:FindFirstChild("AimPart") then plane.AimPart:Destroy() end
end

local function Engine(on)
	for _, thruster in pairs(plane.Engine:GetDescendants()) do
		if thruster:IsA("Beam") and thruster.Name == "ThrusterBeam" then
			thruster.Enabled = on
		end
	end
end

-- ============================================================
-- Cor do motor (replicada pra todos os jogadores)
-- ============================================================
-- O piloto manda a potência (0..1) e o servidor aplica a cor no Engine
-- DESTA nave. O piloto já vê a cor instantaneamente no cliente dele;
-- o valor do servidor chega igual e não conflita.

local enginePart = plane.Engine

local COLOR_OFF = Color3.new(0, 0, 0)
local COLOR_MID = Color3.fromRGB(216, 173, 18)
local COLOR_MAX = Color3.new(1, 1, 1)

local engineRemote = plane:FindFirstChild("EngineColor")
if not engineRemote then
	engineRemote = Instance.new("RemoteEvent")
	engineRemote.Name = "EngineColor"
	engineRemote.Parent = plane
end

local function colorFromPower(power: number): Color3
	if power < 0.5 then
		return COLOR_OFF:Lerp(COLOR_MID, power * 2)
	end
	return COLOR_MID:Lerp(COLOR_MAX, (power - 0.5) * 2)
end

local engineTween: Tween? = nil
local function setEngineColor(power: number)
	if engineTween then engineTween:Cancel() end
	engineTween = TweenService:Create(
		enginePart,
		TweenInfo.new(0.15, Enum.EasingStyle.Linear),
		{ Color = colorFromPower(power) }
	)
	engineTween:Play()
end

engineRemote.OnServerEvent:Connect(function(player, power)
	-- Só aceita número válido, vindo de quem está sentado NESTA nave
	if typeof(power) ~= "number" or power ~= power then return end

	local occupant = seat.Occupant
	if not occupant or game.Players:GetPlayerFromCharacter(occupant.Parent) ~= player then
		return
	end

	setEngineColor(math.clamp(power, 0, 1))
end)

-- ============================================================
-- Entrada / saída do assento
-- ============================================================

local currentPlayer = nil

local function setPromptsEnabled(enabled: boolean)
	-- Prompts não devem aparecer com o jogador pilotando (§9.2 dos requisitos)
	for _, prompt in plane:GetDescendants() do
		if prompt:IsA("ProximityPrompt") then
			prompt.Enabled = enabled
		end
	end
end

seat.Changed:Connect(function(p)
	if p ~= "Occupant" then return end

	local occupant = seat.Occupant
	if occupant then
		Engine(true)
		local player = game.Players:GetPlayerFromCharacter(occupant.Parent)
		if player then
			currentPlayer = player
			setPromptsEnabled(false)

			if HealthService then
				HealthService:ToggleHUD(player, false)
			end
			if InventoryService then
				InventoryService:ToggleHUD(player, false)
			end

			for _, part in pairs(plane:GetDescendants()) do
				if part:IsA("BasePart") then
					part.Anchored = false
				end
			end

			plane.Body:SetNetworkOwner(player)
			local localPlaneScript = script.LocalPlaneScript:Clone()
			localPlaneScript.Parent = player.PlayerGui
			localPlaneScript.Plane.Value = plane
			localPlaneScript.Disabled = false
		end
	else
		Engine(false)
		setEngineColor(0) -- apaga o motor pra todos (cobre saída, morte e desconexão)
		setPromptsEnabled(true)

		if currentPlayer then
			if HealthService then
				HealthService:ToggleHUD(currentPlayer, true)
			end
			if InventoryService then
				InventoryService:ToggleHUD(currentPlayer, true)
			end
			currentPlayer = nil
		end
	end
end)
