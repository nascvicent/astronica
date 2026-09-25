--[[
	SuitConfig
	Catálogo de trajes + lanterna. Server e client leem daqui.

	Local: src/shared/SuitConfig.luau

	Cada traje aponta pra uma pasta em ReplicatedStorage/Assets/Suits/<modelFolder>
	que contém um personagem completo (Model com Humanoid) chamado <character>.
	No spawn o personagem do player é trocado por esse modelo, mantendo a
	cabeça e o cabelo originais do player.

	unlock:
	  { kind = "default" }                        → todo player tem
	  { kind = "price", price = 500 }             → compra com Lúmens
	  { kind = "objective", objective = "<id>" }  → libera sozinho ao cumprir
	                                                 SuitConfig.Objectives[<id>]

	Visor: o capacete (HELMET_NAME) de todo traje tem uma Union DISPLAY_NAME
	dentro, que é pintada com a cor escolhida. Cor é POR TRAJE: a defaultVisor
	do traje já vem liberada nele; as outras são compradas (Lúmens) pra aquele
	traje específico.
]]

local SuitConfig = {}

SuitConfig.ASSETS_FOLDER = "Assets"
SuitConfig.SUITS_FOLDER = "Suits"
SuitConfig.DEFAULT_SUIT = "pathfinder"

-- Attributes
SuitConfig.SUIT_ATTRIBUTE = "SuitId" -- Player e personagem de traje
SuitConfig.FLASHLIGHT_ATTRIBUTE = "FlashlightOn" -- Player

-- Capacete: Accessory/Model com a Union do visor dentro
SuitConfig.HELMET_NAME = "Space Helmet"
SuitConfig.DISPLAY_NAME = "Display"

-- Mochila: Accessory com um SpecialMesh dentro. O Scale.Y dele acompanha o
-- nível da mochila (InventoryModule.BackpackLevels)
SuitConfig.BACKPACK_NAME = "oxygen"

-- Lanterna: qualquer SpotLight/SurfaceLight/PointLight dentro do personagem do traje
SuitConfig.FLASHLIGHT_KEY = Enum.KeyCode.L
SuitConfig.FLASHLIGHT_GAMEPAD = Enum.KeyCode.DPadUp

SuitConfig.Suits = {
	pathfinder = {
		order = 1,
		displayName = "Pathfinder",
		description = "Traje padrão de exploração. Leve, confiável e com lanterna no capacete.",
		rarity = "common",
		modelFolder = "Pathfinder",
		character = "StarterCharacter",
		unlock = { kind = "default" },
		defaultVisor = "gold",
	},
	prospector = {
		order = 2,
		displayName = "Prospector",
		description = "Traje de campo dos mineradores veteranos. Só quem já extraiu de tudo tem um.",
		rarity = "epic",
		modelFolder = "Prospector",
		character = "StarterCharacter",
		unlock = { kind = "objective", objective = "mine_all_ores" },
		defaultVisor = "black",
	},
}

-- Cores do visor. price = custo pra liberar num traje (a defaultVisor do
-- traje sai de graça nele).
SuitConfig.VisorColors = {
	gold = { order = 1, name = "Dourado", color = Color3.fromRGB(255, 190, 60), price = 250 },
	black = { order = 2, name = "Preto", color = Color3.fromRGB(22, 22, 26), price = 150 },
	silver = { order = 3, name = "Prata", color = Color3.fromRGB(200, 206, 216), price = 150 },
	orange = { order = 4, name = "Laranja", color = Color3.fromRGB(255, 140, 40), price = 250 },
	red = { order = 5, name = "Vermelho", color = Color3.fromRGB(230, 60, 60), price = 250 },
	green = { order = 6, name = "Verde", color = Color3.fromRGB(70, 210, 120), price = 250 },
	blue = { order = 7, name = "Azul", color = Color3.fromRGB(60, 150, 255), price = 250 },
	cyan = { order = 8, name = "Ciano", color = Color3.fromRGB(60, 230, 230), price = 400 },
	purple = { order = 9, name = "Roxo", color = Color3.fromRGB(160, 90, 240), price = 400 },
	pink = { order = 10, name = "Rosa", color = Color3.fromRGB(255, 110, 190), price = 400 },
}

-- Objetivos que liberam trajes. Quem mede o progresso é o SuitService.
SuitConfig.Objectives = {
	mine_all_ores = {
		text = "Minere todos os tipos de minério",
	},
}

function SuitConfig.Get(suitId: string?)
	return if suitId then SuitConfig.Suits[suitId] else nil
end

--- Ids em ordem de exibição.
function SuitConfig.GetOrdered(): { string }
	local ids = {}
	for id in SuitConfig.Suits do
		table.insert(ids, id)
	end
	table.sort(ids, function(a, b)
		return SuitConfig.Suits[a].order < SuitConfig.Suits[b].order
	end)
	return ids
end

function SuitConfig.GetVisorColor(colorId: string?)
	return if colorId then SuitConfig.VisorColors[colorId] else nil
end

--- Cores do visor em ordem de exibição.
function SuitConfig.GetOrderedVisorColors(): { string }
	local ids = {}
	for id in SuitConfig.VisorColors do
		table.insert(ids, id)
	end
	table.sort(ids, function(a, b)
		return SuitConfig.VisorColors[a].order < SuitConfig.VisorColors[b].order
	end)
	return ids
end

--- Cor que já vem liberada naquele traje (a padrão dele).
function SuitConfig.IsDefaultVisor(suitId: string, colorId: string): boolean
	local suit = SuitConfig.Suits[suitId]
	return suit ~= nil and suit.defaultVisor == colorId
end

return SuitConfig
