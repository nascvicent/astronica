local Knit = require(game:GetService("ReplicatedStorage").Packages.Knit)
local LumenDisplay = require(script.Parent.Parent.UI.LumenDisplay)

local LumenController = Knit.CreateController({
	Name = "LumenController",
})

function LumenController:KnitInit()
	self._display = LumenDisplay.new()
end

function LumenController:KnitStart()
	local LumenService = Knit.GetService("LumenService")

	LumenService.LumensChanged:Connect(function(newAmount: number)
		self._display:Update(newAmount)
	end)

	LumenService:GetLumens():andThen(function(lumens: number)
		self._display:Update(lumens)
	end):catch(function(err)
		warn("[LumenController] Failed to get initial lumens:", err)
	end)
end

return LumenController
