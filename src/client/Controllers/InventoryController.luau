local Knit = require(game:GetService("ReplicatedStorage").Packages.Knit)
local StarterGui = game:GetService("StarterGui")
local UserInputService = game:GetService("UserInputService")

local InventoryHUD = require(script.Parent.Parent.UI.InventoryHUD)
local InventoryModule = require(game:GetService("ReplicatedStorage").Shared.InventoryModule)

-- Teclas da hotbar, na ordem dos slots
local NUMBER_KEYS = {
	Enum.KeyCode.One,
	Enum.KeyCode.Two,
	Enum.KeyCode.Three,
	Enum.KeyCode.Four,
	Enum.KeyCode.Five,
	Enum.KeyCode.Six,
	Enum.KeyCode.Seven,
	Enum.KeyCode.Eight,
	Enum.KeyCode.Nine,
}

--- A CoreGui não fica pronta na hora em que o Knit sobe, então tenta algumas
--- vezes em vez de assumir que a primeira chamada funciona.
local function disableDefaultBackpack(): boolean
	for _ = 1, 10 do
		local ok = pcall(function()
			StarterGui:SetCoreGuiEnabled(Enum.CoreGuiType.Backpack, false)
		end)

		if ok then
			return true
		end

		task.wait(0.2)
	end

	return false
end

local InventoryController = Knit.CreateController({
	Name = "InventoryController",
})

function InventoryController:KnitInit()
	self._inventory = { slots = {}, maxSlots = 20 }
	self._equippedSlot = 0
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

	InventoryService.ToggleHUD:Connect(function(show)
		self._hud:SetVisible(show)
	end)

	InventoryService:GetInventory():andThen(function(data)
		self._inventory = data
		self._hud:UpdateAll(data)
	end):catch(function(err)
		warn("[InventoryController] Failed to get initial inventory:", err)
	end)

	-- Clicar num item e depois num slot move/troca. Quem valida é o servidor.
	self._hud:SetMoveHandler(function(fromSlot: number, toSlot: number)
		InventoryService:MoveItem(fromSlot, toSlot):andThen(function(ok: boolean, msg: string)
			if not ok then
				warn(string.format("[InventoryController] MoveItem %d -> %d: %s", fromSlot, toSlot, tostring(msg)))
			end
		end):catch(function(err)
			warn("[InventoryController] MoveItem failed:", err)
		end)
	end)

	self:_setupHotbar()
end

-- ============================================================
-- Hotbar — slots 1..N do inventário no lugar da Backpack padrão
-- ============================================================

function InventoryController:_setupHotbar()
	local ToolService = Knit.GetService("ToolService")
	self._toolService = ToolService

	-- Desligar a Backpack da CoreGui tira a única forma nativa de equipar,
	-- então quem passa a chamar o equip são as teclas abaixo.
	task.spawn(function()
		if not disableDefaultBackpack() then
			warn("[InventoryController] Não foi possível esconder a Backpack padrão")
		end
	end)

	-- Mobile não tem tecla 1..N: o clique é o único caminho lá
	self._hud:SetHotbarHandler(function(slotIndex: number)
		self:EquipSlot(slotIndex)
	end)

	-- Com a arma equipada o cursor fica preso no centro, então o inventário
	-- abriria clicável só na aparência. Soltar enquanto o painel está aberto.
	self._hud:SetToggleHandler(function(isOpen: boolean)
		local laser = Knit.GetController("LaserToolController")
		if laser then
			laser:SetAimLocked(not isOpen)
		end
	end)

	ToolService.SlotEquipped:Connect(function(slotIndex: number)
		self._equippedSlot = slotIndex
		self._hud:SetEquippedSlot(slotIndex)
	end)

	ToolService:GetEquippedSlot():andThen(function(slotIndex: number)
		self._equippedSlot = slotIndex
		self._hud:SetEquippedSlot(slotIndex)
	end):catch(function(err)
		warn("[InventoryController] Failed to get equipped slot:", err)
	end)

	local keyToSlot = {}
	for i = 1, math.min(InventoryModule.HOTBAR_SLOTS, #NUMBER_KEYS) do
		keyToSlot[NUMBER_KEYS[i]] = i
	end

	UserInputService.InputBegan:Connect(function(input, gameProcessed)
		if gameProcessed then
			return
		end

		local slotIndex = keyToSlot[input.KeyCode]
		if slotIndex then
			self:EquipSlot(slotIndex)
		end
	end)
end

--- Pede pro servidor equipar aquele slot. Apertar o slot já equipado desequipa.
function InventoryController:EquipSlot(slotIndex: number)
	if not self._toolService then
		return
	end

	self._toolService:EquipSlot(slotIndex):catch(function(err)
		warn("[InventoryController] EquipSlot failed:", err)
	end)
end

function InventoryController:GetEquippedSlot(): number
	return self._equippedSlot or 0
end

function InventoryController:GetInventory()
	return self._inventory
end

function InventoryController:GetSlot(slotIndex: number)
	return self._inventory.slots[slotIndex]
end

return InventoryController
