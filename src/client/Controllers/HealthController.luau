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

	HealthService.ToggleHUD:Connect(function(show)
		print(string.format("[HealthController] ToggleHUD received — show: %s", tostring(show)))
		self._hud:SetVisible(show)
	end)

	-- Fetch initial health
	HealthService:GetHealth():andThen(function(health, maxHealth)
		self._hud:Update(health, maxHealth)
	end)
end

return HealthController
