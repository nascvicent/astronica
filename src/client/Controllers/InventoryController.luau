local Knit = require(game:GetService("ReplicatedStorage").Packages.Knit)
local UserInputService = game:GetService("UserInputService")

local InventoryHUD = require(script.Parent.Parent.UI.InventoryHUD)

local TOGGLE_KEY = Enum.KeyCode.I

local InventoryController = Knit.CreateController({
	Name = "InventoryController",
})

function InventoryController:KnitInit()
	self._inventory = { slots = {}, maxSlots = 20 }
	self._hud = InventoryHUD.new()
end

function InventoryController:KnitStart()
	local InventoryService = Knit.GetService("InventoryService")

	InventoryService.InventoryChanged:Connect(function(data)
		self._inventory = data
		self._hud:UpdateAll(data)
	end)

	InventoryService.SlotUpdated:Connect(function(slotIndex: number, slotData)
		if slotData then
			self._inventory.slots[slotIndex] = slotData
		else
			self._inventory.slots[slotIndex] = nil
		end
		self._hud:UpdateSlot(slotIndex, slotData)
	end)

	InventoryService:GetInventory():andThen(function(data)
		self._inventory = data
		self._hud:UpdateAll(data)
	end):catch(function(err)
		warn("[InventoryController] Failed to get initial inventory:", err)
	end)

	-- Toggle inventário completo com tecla I
	UserInputService.InputBegan:Connect(function(input, processed)
		if processed then return end
		if input.KeyCode == TOGGLE_KEY then
			self._hud:Toggle()
		end
	end)
end

function InventoryController:GetInventory()
	return self._inventory
end

function InventoryController:GetSlot(slotIndex: number)
	return self._inventory.slots[slotIndex]
end

return InventoryController
