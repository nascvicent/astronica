local Knit = require(game:GetService("ReplicatedStorage").Packages.Knit)
local Players = game:GetService("Players")
local HealthModule = require(game:GetService("ReplicatedStorage").Shared.HealthModule)

local HealthService = Knit.CreateService({
	Name = "HealthService",

	Client = {
		HealthChanged = Knit.CreateSignal(), -- (health, maxHealth)
		ToggleHUD = Knit.CreateSignal(),     -- (show: boolean)
	},
})

function HealthService.Client:GetHealth(player: Player): (number, number)
	local humanoid = self.Server:_getHumanoid(player)
	if humanoid then
		return humanoid.Health, humanoid.MaxHealth
	end
	return 0, HealthModule.DEFAULT_MAX_HEALTH
end

function HealthService:ToggleHUD(player: Player, show: boolean)
	print(string.format("[HealthService] ToggleHUD firing for %s — show: %s", player.Name, tostring(show)))
	self.Client.ToggleHUD:Fire(player, show)
end

function HealthService:_getHumanoid(player: Player): Humanoid?
	local character = player.Character
	if character then
		return character:FindFirstChildOfClass("Humanoid")
	end
	return nil
end

function HealthService:_setupCharacter(player: Player, character: Model)
	local humanoid = character:WaitForChild("Humanoid", 10)
	if not humanoid then
		return
	end

	humanoid.MaxHealth = HealthModule.DEFAULT_MAX_HEALTH
	humanoid.Health = humanoid.MaxHealth

	humanoid.HealthChanged:Connect(function(newHealth)
		self.Client.HealthChanged:Fire(player, newHealth, humanoid.MaxHealth)
	end)

	-- Fire initial state
	self.Client.HealthChanged:Fire(player, humanoid.Health, humanoid.MaxHealth)
end

function HealthService:KnitInit()
	Players.PlayerAdded:Connect(function(player)
		player.CharacterAdded:Connect(function(character)
			self:_setupCharacter(player, character)
		end)

		if player.Character then
			task.spawn(function()
				self:_setupCharacter(player, player.Character)
			end)
		end
	end)

	for _, player in Players:GetPlayers() do
		player.CharacterAdded:Connect(function(character)
			self:_setupCharacter(player, character)
		end)

		if player.Character then
			task.spawn(function()
				self:_setupCharacter(player, player.Character)
			end)
		end
	end
end

return HealthService
