local Knit = require(game:GetService("ReplicatedStorage").Packages.Knit)

local InventoryHUD = require(script.Parent.Parent.UI.InventoryHUD)

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
end

function InventoryController:GetInventory()
	return self._inventory
end

function InventoryController:GetSlot(slotIndex: number)
	return self._inventory.slots[slotIndex]
end

return InventoryController
