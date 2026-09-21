--[[
	ShipData
	Catálogo de naves + fórmulas. Fonte da verdade dos números da nave.

	Server (ShipService) e client (menus, hangar) leem daqui. Nada aqui guarda
	estado de jogador: quem é dono de quê e em que nível fica no PlayerData;
	o valor resolvido de uma instância fica no Configurations do modelo.

		DataStore (níveis) + ShipData (base) → ComputeStats → Configurations

	Local: src/shared/ShipData.luau
]]

local ShipData = {}

-- ═══════════════════════════════════════════════════════════
-- Constantes
-- ═══════════════════════════════════════════════════════════

-- Nave que todo jogador tem e pra onde cai quem ficou com id órfão
ShipData.DEFAULT_SHIP = "dispatcher"

-- Onde ficam os modelos (ReplicatedStorage/Assets/ShipModels/<modelName>)
ShipData.ASSETS_FOLDER = "Assets"
ShipData.MODELS_FOLDER = "ShipModels"

-- Nomes de parte que o ShipService espera dentro do modelo
ShipData.PARTS = {
	body = "Body",
	seat = "Seat",
	configurations = "Configurations",
	enterPrompt = "EnterPrompt",
	menuPrompt = "MenuPrompt",
}

-- Atributos postos no modelo em runtime
ShipData.OWNER_ATTRIBUTE = "OwnerUserId"
ShipData.SHIP_ID_ATTRIBUTE = "ShipId"
ShipData.WARP_CHARGE_ATTRIBUTE = "WarpCharge" -- 0..1 enquanto carrega, nil fora disso
ShipData.DOCKED_ATTRIBUTE = "Docked" -- nave ancorada numa plataforma do hangar
ShipData.DOCKING_ATTRIBUTE = "DockingAt" -- hora (tempo do servidor) em que a ancoragem termina

-- Tag das naves spawnadas pelo ShipService (client acha as naves por ela)
ShipData.SHIP_TAG = "PlayerShip"

-- Distâncias de validação (studs)
-- Alcance de TODOS os prompts do sistema (nave, terminal, pads). O client
-- aplica em cada prompt, inclusive nos feitos no Studio. As validações do
-- servidor abaixo derivam daqui: aumentar só o prompt faria a ação ser recusada.
ShipData.PROMPT_DISTANCE = 30
local VALIDATION_SLACK = 8 -- lag + prompt fora do centro da parte medida

ShipData.ENTER_DISTANCE = ShipData.PROMPT_DISTANCE + VALIDATION_SLACK -- do assento
ShipData.UPGRADE_DISTANCE = ShipData.PROMPT_DISTANCE + VALIDATION_SLACK -- da própria nave
ShipData.HANGAR_INTERACT_DISTANCE = ShipData.PROMPT_DISTANCE + VALIDATION_SLACK -- do terminal / da borda do pad

-- Ciclo de vida no espaço (Hub/luas). Em planeta NADA disso vale: lá a nave
-- é a única saída e nunca despawna enquanto o jogador estiver no Place.
ShipData.IDLE_DESPAWN_TIME = 180 -- s longe da nave até ela sumir sozinha
ShipData.IDLE_NEAR_DISTANCE = 150 -- abaixo disso o jogador conta como "perto"
ShipData.PAD_CLEAR_DISTANCE = 40 -- nave além disso do pad libera o pad

-- Pouso: a nave gruda na plataforma quando chega devagar e por cima dela
ShipData.DOCK_SPEED_LIMIT = 14 -- studs/s: acima disso ainda está manobrando
ShipData.DOCK_MARGIN = 20 -- folga além da borda do pad, no plano
ShipData.DOCK_HEIGHT = 30 -- altura máxima acima do topo do pad
-- Tempo parado sobre o pad antes de grudar. Existe pra a ancoragem ser vista
-- acontecendo (e pra dar tempo de sair, se não era isso que o jogador queria)
ShipData.DOCK_DELAY = 2
-- Carência depois do spawn: a nave lançada nasce parada em cima do pad e não
-- pode grudar nele antes de o piloto ter chance de decolar
ShipData.DOCK_SPAWN_GRACE = 5

-- O LocalPlaneScript lê config.TurnSpeed.Value na unidade que ele usa. Os
-- perfis abaixo estão na escala 0–100 do documento; se o script espera outra
-- grandeza, ajuste só este fator.
ShipData.TURN_SPEED_UNIT = 1

-- ═══════════════════════════════════════════════════════════
-- Raridade (puramente visual)
-- ═══════════════════════════════════════════════════════════

ShipData.Rarities = {
	common = { tier = 1, name = "Comum", color = Color3.fromHex("#8A9BA8") },
	uncommon = { tier = 2, name = "Incomum", color = Color3.fromHex("#4ADE80") },
	rare = { tier = 3, name = "Raro", color = Color3.fromHex("#22D3EE") },
	epic = { tier = 4, name = "Épico", color = Color3.fromHex("#A855F7") },
	legendary = { tier = 5, name = "Lendário", color = Color3.fromHex("#FBBF24") },
}

-- ═══════════════════════════════════════════════════════════
-- Tipos (em que a nave é boa)
-- ═══════════════════════════════════════════════════════════

-- Perfil 0–100 por eixo (§2.1), overheat (§4), warp (§3.3) e manobra (§3.6).
-- warp.range em studs; 0 = ilimitado. Valores de TESTE: quando o Hub fechar,
-- trocar por fração da maior distância entre destinos.
ShipData.Types = {
	combat = {
		name = "Combate",
		profile = { damage = 100, speed = 70, miningQuality = 25, hull = 100, turnSpeed = 35 },
		maxShots = 30,
		cooldownTime = 2,
		fireRate = 0.08,
		warp = { range = 4000, chargeTime = 3 },
	},
	miner = {
		name = "Minerador",
		profile = { damage = 30, speed = 65, miningQuality = 100, hull = 85, turnSpeed = 25 },
		maxShots = 10,
		cooldownTime = 5,
		fireRate = 0.15,
		warp = { range = 1500, chargeTime = 2 },
	},
	explorer = {
		name = "Explorador",
		profile = { damage = 45, speed = 100, miningQuality = 55, hull = 60, turnSpeed = 45 },
		maxShots = 18,
		cooldownTime = 3.5,
		fireRate = 0.12,
		warp = { range = 0, chargeTime = 6 },
	},
}

-- ═══════════════════════════════════════════════════════════
-- Módulos (§6)
-- ═══════════════════════════════════════════════════════════

ShipData.MODULE_ORDER = { "engine", "weapon", "drill", "plating" }

-- Custos usam só recursos que existem hoje no InventoryModule. Quando
-- Circuitos / Xenolite / Cristais de Gelo e Magma entrarem, é trocar o itemId aqui.
ShipData.Modules = {
	engine = {
		name = "Motor",
		description = "Velocidade máxima e manobra.",
		cost = { { itemId = "iron_ore", quantity = 6 }, { itemId = "crystal_shard", quantity = 2 } },
	},
	weapon = {
		name = "Armamento",
		description = "Dano por disparo e tiros antes do superaquecimento.",
		cost = { { itemId = "crystal_shard", quantity = 4 }, { itemId = "iron_ore", quantity = 3 } },
	},
	drill = {
		name = "Broca",
		description = "Mineração mais rápida e chance de unidade extra.",
		cost = { { itemId = "iron_ore", quantity = 8 }, { itemId = "crystal_shard", quantity = 1 } },
	},
	plating = {
		name = "Blindagem",
		description = "Integridade máxima do casco.",
		cost = { { itemId = "crystal_shard", quantity = 3 }, { itemId = "iron_ore", quantity = 5 } },
	},
}

-- Ganho por nível (nível 1 = base)
local ENGINE_SPEED_GAIN = 0.15
local ENGINE_TURN_GAIN = 0.08
local WEAPON_DAMAGE_GAIN = 0.25
local WEAPON_SHOTS_GAIN = 3
local DRILL_QUALITY_GAIN = 15
local PLATING_HULL_GAIN = 40

local MINING_QUALITY_MAX = 100

-- Cadência de tiro (segundos entre disparos). Nave sem o valor cai no padrão
-- antigo do PlaneScript, e nada desce abaixo do piso.
local DEFAULT_FIRE_RATE = 0.1
local MIN_FIRE_RATE = 0.05

-- ═══════════════════════════════════════════════════════════
-- Catálogo
-- ═══════════════════════════════════════════════════════════

export type Stats = {
	damage: number,
	speed: number,
	miningQuality: number,
	hull: number,
	turnSpeed: number,
	maxShots: number,
	cooldownTime: number,
	fireRate: number,
}

export type ShipDef = {
	id: string,
	displayName: string,
	description: string,
	tier: number,
	shipType: string,
	rarity: string,
	modelName: string,
	baseStats: Stats,
	gunsEnabled: boolean,
	warp: { range: number, chargeTime: number },
	cost: { lumens: number },
	unlockRequirement: { [string]: any }?,
	maxModuleLevel: { engine: number, weapon: number, drill: number, plating: number },
}

-- Escala por tier aplicada sobre o perfil do tipo. miningQuality tem teto de
-- 100, então cresce por pontos em vez de multiplicar.
local TIER_SCALE = { 1.0, 1.25, 1.55, 1.9 }
local TIER_MINING = { 0.4, 0.55, 0.7, 0.85 }
-- Manobra cresce devagar com o tier: o LocalPlaneScript usa TurnSpeed / 10 como
-- fator da sensibilidade do mouse, então dobrar esse número deixa a nave
-- incontrolável em vez de ágil
local TIER_TURN = { 1.0, 1.1, 1.2, 1.3 }
local TIER_RARITY = { "common", "uncommon", "rare", "epic" }
local TIER_PRICE = { 500, 2500, 9000, 25000 }
local TIER_NAME = { "Scout", "Vanguard", "Sentinel", "Apex" }

local function round(x: number): number
	return math.floor(x + 0.5)
end

local function fromType(tier: number, shipType: string, overrides: { [string]: any }?): ShipDef
	local typeDef = ShipData.Types[shipType]
	local p = typeDef.profile
	local scale = TIER_SCALE[tier]
	local tierName = TIER_NAME[tier]
	local maxLevel = tier + 2

	local def = {
		id = string.lower(tierName) .. "_" .. shipType,
		displayName = tierName .. " " .. typeDef.name,
		description = "",
		tier = tier,
		shipType = shipType,
		rarity = TIER_RARITY[tier],
		modelName = "Ship_" .. tierName .. "_" .. string.upper(string.sub(shipType, 1, 1)) .. string.sub(shipType, 2),
		baseStats = {
			damage = round(p.damage * scale),
			speed = round(p.speed * scale),
			miningQuality = round(p.miningQuality * TIER_MINING[tier]),
			hull = round(p.hull * scale),
			turnSpeed = round(p.turnSpeed * TIER_TURN[tier]),
			maxShots = typeDef.maxShots,
			cooldownTime = typeDef.cooldownTime,
			fireRate = typeDef.fireRate,
		},
		gunsEnabled = true,
		warp = { range = typeDef.warp.range, chargeTime = typeDef.warp.chargeTime },
		cost = { lumens = TIER_PRICE[tier] },
		unlockRequirement = nil,
		maxModuleLevel = { engine = maxLevel, weapon = maxLevel, drill = maxLevel, plating = maxLevel },
	}

	if overrides then
		for key, value in overrides do
			def[key] = value
		end
	end

	return def
end

local DESCRIPTIONS = {
	combat = "Pressão contínua: mais tiros antes de superaquecer e casco pra aguentar a troca.",
	miner = "Extrai rápido e com mais rendimento. Warp curto, mas sai num piscar.",
	explorer = "Vai a qualquer lugar de onde estiver. A carga longa do warp é o preço.",
}

ShipData.Ships = {} :: { [string]: ShipDef }

-- modelName segue o nome da pasta em ReplicatedStorage/Assets/ShipModels.
-- Renomear a nave aqui não renomeia o modelo no Studio: os dois andam juntos.
ShipData.Ships.dispatcher = {
	id = "dispatcher",
	displayName = "Dispatcher",
	description = "Cápsula de saída armada. Tiro leve, e warpa de qualquer lugar.",
	tier = 1,
	shipType = "explorer",
	rarity = "common",
	modelName = "Dispatcher",
	baseStats = {
		damage = 40,
		speed = 115,
		miningQuality = 35,
		hull = 85,
		turnSpeed = 25,
		maxShots = 16,
		cooldownTime = 3.5,
		fireRate = 0.12,
	},
	gunsEnabled = true,
	warp = { range = 0, chargeTime = 6 },
	cost = { lumens = 0 },
	unlockRequirement = nil,
	maxModuleLevel = { engine = 4, weapon = 4, drill = 4, plating = 4 },
}

-- Mineradora de entrada: extrai muito melhor que a Dispatcher e se defende em
-- rajada curta. Warp curto e rápido, como todo minerador (§3.3). Não vem com o
-- jogador — entra por GrantShip (ou pela Loja, quando ela existir).
ShipData.Ships.deimos = {
	id = "deimos",
	displayName = "Deimos",
	description = "Mineradora da frota velha. Precisa chegar perto pra warpar, mas some num piscar.",
	tier = 1,
	shipType = "miner",
	rarity = "common",
	modelName = "Deimos",
	baseStats = {
		damage = 25,
		speed = 100,
		miningQuality = 45,
		hull = 70,
		turnSpeed = 25,
		maxShots = 10,
		cooldownTime = 5,
		fireRate = 0.15,
	},
	gunsEnabled = true,
	warp = { range = 3500, chargeTime = 2 },
	cost = { lumens = 400 },
	unlockRequirement = nil,
	maxModuleLevel = { engine = 3, weapon = 3, drill = 4, plating = 3 },
}

for tier = 1, 4 do
	for _, shipType in { "explorer", "combat", "miner" } do
		local overrides = { description = DESCRIPTIONS[shipType] }
		if tier == 4 then
			-- Tier 4 exige progresso além de Lúmens (checagem vem com a Loja)
			overrides.unlockRequirement = { planetsVisited = 3 }
		end
		local def = fromType(tier, shipType, overrides)
		ShipData.Ships[def.id] = def
	end
end

-- Ordem estável pra listas de UI: tier, depois tipo
local TYPE_ORDER = { explorer = 1, combat = 2, miner = 3 }

function ShipData.GetSortedIds(ids: { string }?): { string }
	local list = {}
	if ids then
		for _, id in ids do
			if ShipData.Ships[id] then
				table.insert(list, id)
			end
		end
	else
		for id in ShipData.Ships do
			table.insert(list, id)
		end
	end

	table.sort(list, function(a, b)
		local da, db = ShipData.Ships[a], ShipData.Ships[b]
		if a == b then
			return false
		elseif da.id == ShipData.DEFAULT_SHIP then
			return true
		elseif db.id == ShipData.DEFAULT_SHIP then
			return false
		end
		if da.tier ~= db.tier then
			return da.tier < db.tier
		end
		local ta, tb = TYPE_ORDER[da.shipType] or 9, TYPE_ORDER[db.shipType] or 9
		if ta ~= tb then
			return ta < tb
		end
		-- Duas naves do mesmo tier e tipo: ordem estável pelo id
		return da.id < db.id
	end)

	return list
end

-- ═══════════════════════════════════════════════════════════
-- Consultas
-- ═══════════════════════════════════════════════════════════

function ShipData.GetShip(shipId: string?): ShipDef?
	return if shipId then ShipData.Ships[shipId] else nil
end

function ShipData.IsValidShip(shipId: any): boolean
	return typeof(shipId) == "string" and ShipData.Ships[shipId] ~= nil
end

function ShipData.IsValidModule(moduleId: any): boolean
	return typeof(moduleId) == "string" and ShipData.Modules[moduleId] ~= nil
end

function ShipData.GetRarity(shipId: string)
	local def = ShipData.Ships[shipId]
	return ShipData.Rarities[def and def.rarity or "common"] or ShipData.Rarities.common
end

function ShipData.GetTypeName(shipType: string): string
	local typeDef = ShipData.Types[shipType]
	return if typeDef then typeDef.name else shipType
end

--- Menor nível possível do módulo: 0 pra módulo que a nave não tem (arma da Dispatcher).
function ShipData.GetMinModuleLevel(shipId: string, moduleId: string): number
	local def = ShipData.Ships[shipId]
	if not def then
		return 0
	end
	return if (def.maxModuleLevel[moduleId] or 0) > 0 then 1 else 0
end

function ShipData.GetMaxModuleLevel(shipId: string, moduleId: string): number
	local def = ShipData.Ships[shipId]
	return if def then def.maxModuleLevel[moduleId] or 0 else 0
end

--- Níveis de uma nave recém-concedida.
function ShipData.DefaultModuleLevels(shipId: string)
	return {
		engine = ShipData.GetMinModuleLevel(shipId, "engine"),
		weapon = ShipData.GetMinModuleLevel(shipId, "weapon"),
		drill = ShipData.GetMinModuleLevel(shipId, "drill"),
		plating = ShipData.GetMinModuleLevel(shipId, "plating"),
		skin = "default",
	}
end

--- Nível válido pra esta nave: dentro de [min, max]. Save antigo com nível
--- acima do teto atual (rebalanceamento) é rebaixado em vez de dar erro.
function ShipData.ClampModuleLevel(shipId: string, moduleId: string, level: any): number
	local min = ShipData.GetMinModuleLevel(shipId, moduleId)
	local max = ShipData.GetMaxModuleLevel(shipId, moduleId)
	if typeof(level) ~= "number" or level ~= level then
		return min
	end
	return math.clamp(math.floor(level), min, max)
end

-- ═══════════════════════════════════════════════════════════
-- Fórmulas (função pura: roda igual no client e no server)
-- ═══════════════════════════════════════════════════════════

export type ComputedStats = {
	shipId: string,
	shipType: string,
	damage: number,
	speed: number,
	turnSpeed: number,
	maxShots: number,
	cooldownTime: number,
	fireRate: number,
	miningQuality: number,
	hull: number,
	maxHull: number,
	gunsEnabled: boolean,
	warpRange: number,
	warpChargeTime: number,
}

function ShipData.ComputeStats(shipId: string, moduleLevels: { [string]: any }?): ComputedStats?
	local def = ShipData.Ships[shipId]
	if not def then
		return nil
	end

	local levels = moduleLevels or {}
	local base = def.baseStats

	local engine = ShipData.ClampModuleLevel(shipId, "engine", levels.engine)
	local weapon = ShipData.ClampModuleLevel(shipId, "weapon", levels.weapon)
	local drill = ShipData.ClampModuleLevel(shipId, "drill", levels.drill)
	local plating = ShipData.ClampModuleLevel(shipId, "plating", levels.plating)

	-- Nível 0 (módulo inexistente) não pode virar bônus negativo
	local engineSteps = math.max(engine - 1, 0)
	local weaponSteps = math.max(weapon - 1, 0)
	local drillSteps = math.max(drill - 1, 0)
	local platingSteps = math.max(plating - 1, 0)

	local hull = base.hull + PLATING_HULL_GAIN * platingSteps
	local guns = def.gunsEnabled and weapon > 0

	return {
		shipId = shipId,
		shipType = def.shipType,
		speed = round(base.speed * (1 + ENGINE_SPEED_GAIN * engineSteps)),
		turnSpeed = base.turnSpeed * (1 + ENGINE_TURN_GAIN * engineSteps) * ShipData.TURN_SPEED_UNIT,
		damage = if guns then round(base.damage * (1 + WEAPON_DAMAGE_GAIN * weaponSteps)) else 0,
		maxShots = if guns then base.maxShots + WEAPON_SHOTS_GAIN * weaponSteps else 0,
		cooldownTime = base.cooldownTime,
		-- Intervalo entre tiros, em segundos. O loop do PlaneScript espera esse
		-- tempo: zero deixaria ele girando sem pausa
		fireRate = math.max(base.fireRate or DEFAULT_FIRE_RATE, MIN_FIRE_RATE),
		miningQuality = math.min(base.miningQuality + DRILL_QUALITY_GAIN * drillSteps, MINING_QUALITY_MAX),
		hull = hull,
		maxHull = hull,
		gunsEnabled = guns,
		warpRange = def.warp.range,
		warpChargeTime = def.warp.chargeTime,
	}
end

--- Multiplicador do tempo de mineração: teto de -50% (§2.2).
function ShipData.MiningTimeMultiplier(miningQuality: number): number
	return 1 - math.clamp(miningQuality, 0, MINING_QUALITY_MAX) / 200
end

--- Chance de unidade extra ao esgotar um node: teto de 40% (§2.2).
function ShipData.ExtraUnitChance(miningQuality: number): number
	return math.clamp(miningQuality, 0, MINING_QUALITY_MAX) / 250
end

--- Custo pra levar o módulo do nível atual pro próximo, ou nil se já está no
--- teto (ou a nave não tem o módulo). Escala com o nível alvo e com o tier.
function ShipData.GetUpgradeCost(shipId: string, moduleId: string, currentLevel: number): { { itemId: string, quantity: number } }?
	local def = ShipData.Ships[shipId]
	local module = ShipData.Modules[moduleId]
	if not def or not module then
		return nil
	end

	local max = ShipData.GetMaxModuleLevel(shipId, moduleId)
	if max <= 0 or currentLevel >= max then
		return nil
	end

	local step = math.max(currentLevel, 1) -- 1→2 é o primeiro degrau
	local tierFactor = 1 + 0.5 * (def.tier - 1)

	local cost = {}
	for _, entry in module.cost do
		table.insert(cost, {
			itemId = entry.itemId,
			quantity = math.max(1, round(entry.quantity * step * tierFactor)),
		})
	end
	return cost
end

--- Mapeamento stat → Value dentro do Configurations (§5). Classe esperada ao lado.
ShipData.CONFIG_FIELDS = {
	{ name = "ShipId", class = "StringValue", stat = "shipId" },
	{ name = "ShipType", class = "StringValue", stat = "shipType" },
	{ name = "GunsEnabled", class = "BoolValue", stat = "gunsEnabled" },
	{ name = "Speed", class = "NumberValue", stat = "speed" },
	{ name = "TurnSpeed", class = "NumberValue", stat = "turnSpeed" },
	{ name = "Damage", class = "NumberValue", stat = "damage" },
	{ name = "MiningQuality", class = "NumberValue", stat = "miningQuality" },
	{ name = "Hull", class = "NumberValue", stat = "hull" },
	{ name = "MaxHull", class = "NumberValue", stat = "maxHull" },
	{ name = "MaxShots", class = "NumberValue", stat = "maxShots" },
	{ name = "CooldownTime", class = "NumberValue", stat = "cooldownTime" },
	{ name = "FireRate", class = "NumberValue", stat = "fireRate" },
	{ name = "WarpRange", class = "NumberValue", stat = "warpRange" },
	{ name = "WarpChargeTime", class = "NumberValue", stat = "warpChargeTime" },
}

return ShipData
