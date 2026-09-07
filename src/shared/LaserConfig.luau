--[[
	LaserConfig
	Configuração compartilhada da pistola laser (mineração + combate).
	Server e client leem daqui — nunca duplique número em dois lugares.

	Local: src/shared/LaserConfig.luau
]]

local LaserConfig = {}

-- Tag do CollectionService usada nos nodes de recurso
LaserConfig.NODE_TAG = "OreNode"

-- Atributo que marca uma Tool como pistola laser
LaserConfig.TOOL_ATTRIBUTE = "IsLaserTool"

-- Nome do Attachment de onde o feixe nasce
LaserConfig.MUZZLE_NAME = "Muzzle"

--- Procura o Attachment de muzzle em qualquer lugar da Tool — não precisa
--- estar no Handle, pode estar na ponta do cano ou em qualquer outra BasePart.
--- Só vale um Attachment dentro de uma BasePart: fora disso ele não tem
--- WorldPosition que acompanhe a arma.
function LaserConfig.FindMuzzle(tool: Instance): Attachment?
	for _, child in tool:GetDescendants() do
		if
			child.Name == LaserConfig.MUZZLE_NAME
			and child:IsA("Attachment")
			and child.Parent
			and child.Parent:IsA("BasePart")
		then
			return child
		end
	end
	return nil
end

-- Intervalo (s) em que o client reporta o tiro pro servidor.
-- Dano é calculado por tempo real decorrido, então mudar isso não muda o DPS.
LaserConfig.TICK_RATE = 0.1

-- ═══════════════════════════════════════════════════════════
-- Modos de disparo
-- ═══════════════════════════════════════════════════════════

export type Mode = {
	DamagePerSecond: number,
	Range: number,
	Color: Color3,
	BeamWidth: number,
	CanMine: boolean,
	CanDamageCreatures: boolean,
}

LaserConfig.Modes = {
	Mining = {
		DamagePerSecond = 30,
		Range = 40,
		Color = Color3.fromRGB(0, 200, 240),
		BeamWidth = 0.22,
		CanMine = true,
		CanDamageCreatures = false,
	},

	-- Já deixado pronto pro combate: mesma pipeline, resolver de hit diferente
	Combat = {
		DamagePerSecond = 45,
		Range = 70,
		Color = Color3.fromRGB(255, 90, 40),
		BeamWidth = 0.16,
		CanMine = false,
		CanDamageCreatures = true,
	},
}

LaserConfig.DEFAULT_MODE = "Mining"

function LaserConfig.GetMode(name: string?): Mode
	return LaserConfig.Modes[name or ""] or LaserConfig.Modes[LaserConfig.DEFAULT_MODE]
end

-- ═══════════════════════════════════════════════════════════
-- Nodes de recurso
-- itemId precisa existir no InventoryModule.Items
-- ═══════════════════════════════════════════════════════════

LaserConfig.Nodes = {
	iron_ore = {
		hardness = 100,   -- HP do node
		dropMin = 2,
		dropMax = 4,
		respawn = 45,     -- segundos
		color = Color3.fromRGB(180, 140, 100),
	},
	crystal_shard = {
		hardness = 200,
		dropMin = 1,
		dropMax = 2,
		respawn = 90,
		color = Color3.fromRGB(120, 220, 255),
	},
}

LaserConfig.DEFAULT_NODE = "iron_ore"

function LaserConfig.GetNodeDef(itemId: string?)
	return LaserConfig.Nodes[itemId or ""] or LaserConfig.Nodes[LaserConfig.DEFAULT_NODE]
end

return LaserConfig
