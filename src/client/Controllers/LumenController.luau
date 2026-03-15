local Knit = require(game:GetService("ReplicatedStorage").Packages.Knit)

local LumenController = Knit.CreateController({
	Name = "LumenController",
})

function LumenController:KnitInit()
end

function LumenController:KnitStart()
	local LumenService = Knit.GetService("LumenService")

	LumenService.LumensChanged:Connect(function(_newAmount: number)
		-- Lumen UI removed; server leaderboard handles display
	end)
end

return LumenController
