--[[
	InventoryModule
	Definições de itens, constantes e funções utilitárias para o sistema de inventário.
	Usado por server (InventoryService) e client (InventoryController).
]]

local InventoryModule = {}

-- Constantes
InventoryModule.DEFAULT_SLOTS = 10
InventoryModule.MAX_STACK = 64

-- Mochila: cada nível dá mais slots e deixa a mochila do traje mais alta
-- (Scale.Y do SpecialMesh dela, ver SuitConfig.BACKPACK_NAME).
-- price = Lúmens pra subir PRA este nível.
InventoryModule.BackpackLevels = {
	{ slots = 10, height = 0.6, price = 0 },
	{ slots = 15, height = 0.7, price = 500 },
	{ slots = 20, height = 0.8, price = 1500 },
	{ slots = 25, height = 0.9, price = 3500 },
	{ slots = 30, height = 1.0, price = 7500 },
}
InventoryModule.MAX_BACKPACK_LEVEL = #InventoryModule.BackpackLevels
InventoryModule.MAX_SLOTS = InventoryModule.BackpackLevels[InventoryModule.MAX_BACKPACK_LEVEL].slots

-- Nível da mochila espelhado no Player (o SuitService e o preview leem daqui)
InventoryModule.BACKPACK_ATTRIBUTE = "BackpackLevel"

-- Quantos slots do começo do inventário formam a hotbar (teclas 1..N).
-- Client (HUD + teclas) e server (ToolService) leem daqui.
InventoryModule.HOTBAR_SLOTS = 3

-- Itens que todo jogador começa tendo
InventoryModule.STARTING_ITEMS = {
	{ itemId = "laser_pickaxe", quantity = 1 },
}

-- Suba este número sempre que mudar STARTING_ITEMS: quem já tem save recebe
-- os itens novos uma vez, em vez de só valer pra conta criada do zero.
InventoryModule.STARTING_ITEMS_VERSION = 1

-- Raridades, da mais comum para a mais rara. tier cresce com a raridade e é
-- o que a UI usa para decidir o quanto o item brilha.
InventoryModule.DEFAULT_RARITY = "common"

InventoryModule.Rarities = {
	common = {
		tier = 1,
		name = "Comum",
		color = Color3.fromRGB(200, 204, 212),
	},
	uncommon = {
		tier = 2,
		name = "Incomum",
		color = Color3.fromRGB(90, 220, 130),
	},
	rare = {
		tier = 3,
		name = "Raro",
		color = Color3.fromRGB(70, 160, 255),
	},
	epic = {
		tier = 4,
		name = "Épico",
		color = Color3.fromRGB(185, 105, 255),
	},
	legendary = {
		tier = 5,
		name = "Lendário",
		color = Color3.fromRGB(255, 185, 60),
	},
}

export type RarityDef = { tier: number, name: string, color: Color3 }

export type ItemDef = {
	name: string,
	description: string,
	rarity: string,
	maxStack: number,
	category: string,
	toolTemplate: string?,
}

-- Catálogo de itens
InventoryModule.Items = {
	iron_ore = {
		name = "Iron Ore",
		description = "Minério bruto de ferro extraído de asteroides. Matéria-prima básica para reparos e fabricação.",
		rarity = "common",
		maxStack = 64,
		category = "resource",
	},
	crystal_shard = {
		name = "Crystal Shard",
		description = "Fragmento cristalino que guarda energia residual. Usado em componentes de precisão.",
		rarity = "uncommon",
		maxStack = 32,
		category = "resource",
	},
	gravitita = {
		name = "Gravitita",
		description = "Minério raro que dobra a gravidade à sua volta: flutua sozinho e puxa poeira para a própria órbita. Cobiçado para motores de warp e estabilizadores.",
		rarity = "rare",
		maxStack = 16,
		category = "resource",
	},
	health_potion = {
		name = "Health Potion",
		description = "Dose de nanogel regenerativo. Recupera parte da vida ao ser consumida.",
		rarity = "common",
		maxStack = 16,
		category = "consumable",
	},
	laser_pickaxe = {
		name = "Laser Pickaxe",
		description = "Ferramenta de mineração a laser. Aquece os minérios até derreterem e envia os fragmentos direto para o inventário.",
		rarity = "rare",
		maxStack = 1,
		category = "tool",
		-- Nome da Tool em ServerStorage.Tools que este item equipa
		toolTemplate = "LaserPistol",
		-- Ferramenta inicial: descartar deixaria o jogador sem como minerar
		canDelete = false,
	},
	star_map = {
		name = "Star Map",
		description = "Mapa estelar antigo com rotas que não aparecem em nenhum registro oficial.",
		rarity = "legendary",
		maxStack = 1,
		category = "quest",
	},
}

function InventoryModule.GetItemDef(itemId: string): ItemDef?
	return InventoryModule.Items[itemId]
end

--- Raridade do item. Item sem raridade definida (ou com nome inválido) é comum.
function InventoryModule.GetRarity(itemId: string): RarityDef
	local def = InventoryModule.Items[itemId]
	local rarity = def and InventoryModule.Rarities[def.rarity]
	return rarity or InventoryModule.Rarities[InventoryModule.DEFAULT_RARITY]
end

function InventoryModule.GetDescription(itemId: string): string
	local def = InventoryModule.Items[itemId]
	return def and def.description or ""
end

function InventoryModule.GetMaxStack(itemId: string): number
	local def = InventoryModule.Items[itemId]
	if def and def.maxStack then
		return def.maxStack
	end
	return InventoryModule.MAX_STACK
end

--- Nome da Tool que este item equipa, ou nil se o item não for equipável.
function InventoryModule.GetToolTemplate(itemId: string): string?
	local def = InventoryModule.Items[itemId]
	return def and (def :: any).toolTemplate or nil
end

--- Item pode ser descartado do inventário (padrão: sim).
function InventoryModule.CanDelete(itemId: string): boolean
	local def = InventoryModule.Items[itemId]
	return def ~= nil and (def :: any).canDelete ~= false
end

function InventoryModule.ClampBackpackLevel(level: any): number
	if typeof(level) ~= "number" or level ~= level then
		return 1
	end
	return math.clamp(math.floor(level), 1, InventoryModule.MAX_BACKPACK_LEVEL)
end

function InventoryModule.GetBackpackLevel(level: number)
	return InventoryModule.BackpackLevels[InventoryModule.ClampBackpackLevel(level)]
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
