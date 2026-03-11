local Knit = require(game:GetService("ReplicatedStorage").Packages.Knit)
local HealthHUD = require(script.Parent.Parent.UI.HealthHUD)

local HealthController = Knit.CreateController({
	Name = "HealthController",
})

function HealthController:KnitInit()
	self._hud = HealthHUD.new()
end

function HealthController:KnitStart()
	local HealthService = Knit.GetService("HealthService")

	HealthService.HealthChanged:Connect(function(health, maxHealth)
		self._hud:Update(health, maxHealth)
	end)

	-- Fetch initial health
	local health, maxHealth = HealthService:GetHealth()
	self._hud:Update(health, maxHealth)
end

return HealthController
