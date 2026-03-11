--[[
	InventoryModule
	Definições de itens, constantes e funções utilitárias para o sistema de inventário.
	Usado por server (InventoryService) e client (InventoryController).
]]

local InventoryModule = {}

-- Constantes
InventoryModule.DEFAULT_SLOTS = 20
InventoryModule.MAX_STACK = 64

-- Catálogo de itens
InventoryModule.Items = {
	iron_ore = {
		name = "Iron Ore",
		maxStack = 64,
		category = "resource",
	},
	crystal_shard = {
		name = "Crystal Shard",
		maxStack = 32,
		category = "resource",
	},
	health_potion = {
		name = "Health Potion",
		maxStack = 16,
		category = "consumable",
	},
	laser_pickaxe = {
		name = "Laser Pickaxe",
		maxStack = 1,
		category = "tool",
	},
	star_map = {
		name = "Star Map",
		maxStack = 1,
		category = "quest",
	},
}

function InventoryModule.GetItemDef(itemId: string): { name: string, maxStack: number, category: string }?
	return InventoryModule.Items[itemId]
end

function InventoryModule.GetMaxStack(itemId: string): number
	local def = InventoryModule.Items[itemId]
	if def and def.maxStack then
		return def.maxStack
	end
	return InventoryModule.MAX_STACK
end

function InventoryModule.IsValidItem(itemId: string): boolean
	return InventoryModule.Items[itemId] ~= nil
end

function InventoryModule.CreateSlot(itemId: string, quantity: number, metadata: { [string]: any }?)
	return {
		itemId = itemId,
		quantity = quantity,
		metadata = metadata or {},
	}
end

function InventoryModule.MetadataMatch(a: { [string]: any }, b: { [string]: any }): boolean
	if a == b then
		return true
	end

	for key, value in a do
		if b[key] ~= value then
			return false
		end
	end

	for key, _ in b do
		if a[key] == nil then
			return false
		end
	end

	return true
end

return InventoryModule
