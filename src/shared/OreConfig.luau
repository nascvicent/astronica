--[[
	OreConfig
	Minérios do espaço, minerados pelas armas da nave. Server (ShipMiningService,
	CombatService) e client (ShipMiningController) leem daqui.

	A pistola laser continua com os nodes dela (LaserConfig / OreNode). Isto é
	só o que a nave quebra: rochas grandes flutuando no vácuo.

	SETUP NO STUDIO
	  Workspace/Ores/<minério>   Model (várias Parts) ou uma Part sozinha.
	                             Subpastas dentro de Ores também valem.
	  Qual minério ele é sai de um atributo de texto no Model: o valor é o
	  itemId (ex.: "gravitita"). Qualquer nome de atributo serve; os de
	  ID_ATTRIBUTES têm prioridade. Sem atributo, vale o nome do Model.

	FLUTUAÇÃO
	  A pose é função pura do relógio do servidor (GetServerTimeNow) e de uma
	  semente por rocha: todo client vê a rocha no mesmo lugar sem o servidor
	  replicar CFrame nenhum. O servidor não move as Parts; pra saber se o
	  tiro acertou, ele leva o tiro pro referencial da rocha (ver GetMotion).

	MINERAÇÃO
	  Cada ponto de MiningQuality da nave é 1 de dano de mineração por segundo
	  de fogo contínuo. O rendimento cresce com a mesma stat (YieldMultiplier).

	Local: src/shared/OreConfig.luau
]]

local OreConfig = {}

OreConfig.FOLDER = "Ores"
-- Posto pelo servidor em cada rocha registrada: é por ele que o client acha
-- as rochas (e sabe quando uma entra/sai do streaming)
OreConfig.TAG = "ShipOre"

-- Atributos escritos pelo servidor na raiz da rocha
OreConfig.ID_ATTRIBUTE = "OreId"
OreConfig.SEED_ATTRIBUTE = "OreSeed" -- 0..1, fase da flutuação
OreConfig.CENTER_ATTRIBUTE = "OreCenter" -- Vector3, centro de giro
OreConfig.RADIUS_ATTRIBUTE = "OreRadius"
OreConfig.ACTIVE_ATTRIBUTE = "OreActive" -- false enquanto espera renascer
OreConfig.INTEGRITY_ATTRIBUTE = "Integrity" -- 0..1

-- Onde procurar o minério da rocha, nesta ordem (sem diferenciar maiúsculas)
OreConfig.ID_ATTRIBUTES = { "OreId", "ResourceId", "Ore", "Minerio", "Minério", "ItemId", "Item", "Resource" }

-- ═══════════════════════════════════════════════════════════
-- Minérios
-- itemId precisa existir no InventoryModule.Items
-- ═══════════════════════════════════════════════════════════

export type Motion = {
	bob: number, -- studs pra cima e pra baixo
	bobPeriod: number, -- segundos por sobe-e-desce
	spinPeriod: number, -- segundos por volta completa
	tilt: number, -- graus de balanço
	tiltPeriod: number,
}

export type OreDef = {
	hardness: number, -- dano de mineração pra quebrar
	dropMin: number,
	dropMax: number,
	respawn: number, -- segundos
	glow: Color3, -- lascas, estilhaço e fragmentos coletados
	motion: Motion?,
}

local DEFAULT_MOTION: Motion = {
	bob = 1.4,
	bobPeriod = 10,
	spinPeriod = 140,
	tilt = 5,
	tiltPeriod = 16,
}

OreConfig.Ores = {
	-- Rara: dura mais, rende pouco e demora a voltar. Dispatcher (35) leva
	-- ~6 s de fogo acertando; Deimos (45) ~4,5 s
	gravitita = {
		hardness = 200,
		dropMin = 1,
		dropMax = 3,
		respawn = 240,
		glow = Color3.fromRGB(175, 120, 255),
		-- Gravidade própria: sobe e desce mais e gira devagar
		motion = { bob = 2.2, bobPeriod = 12, spinPeriod = 160, tilt = 7, tiltPeriod = 19 },
	},
	iron_ore = {
		hardness = 90,
		dropMin = 4,
		dropMax = 7,
		respawn = 60,
		glow = Color3.fromRGB(230, 170, 110),
	},
	crystal_shard = {
		hardness = 140,
		dropMin = 2,
		dropMax = 4,
		respawn = 120,
		glow = Color3.fromRGB(120, 220, 255),
	},
} :: { [string]: OreDef }

function OreConfig.Get(oreId: string?): OreDef?
	return if oreId then OreConfig.Ores[oreId] else nil
end

function OreConfig.GetMotion(oreId: string?): Motion
	local def = OreConfig.Get(oreId)
	return def and def.motion or DEFAULT_MOTION
end

-- ═══════════════════════════════════════════════════════════
-- Regras de mineração
-- ═══════════════════════════════════════════════════════════

-- Parado de levar tiro por isto, a rocha volta inteira e esquece quem minerou
OreConfig.REGEN_DELAY = 20

-- Quem causou pelo menos esta fração do dano leva a própria recompensa (com
-- a própria nave). Minerar junto rende pra todo mundo; roubar o último tiro
-- de quem minerou quase tudo não rende nada
OreConfig.MIN_SHARE = 0.2

-- Nave sem broca nenhuma ainda arranha a rocha
OreConfig.MIN_MINING_POWER = 5

--- Dano de mineração por segundo de fogo contínuo, acertando tudo.
function OreConfig.MiningPower(miningQuality: number): number
	return math.max(miningQuality, OreConfig.MIN_MINING_POWER)
end

--- Dano de mineração de UM projétil (um cano, uma rajada). Mesmo formato do
--- CombatConfig.ShotDamage: cadência e número de canos não mudam o total.
function OreConfig.ShotMiningDamage(miningQuality: number, fireRate: number, muzzleCount: number): number
	if muzzleCount <= 0 then
		return 0
	end
	return OreConfig.MiningPower(miningQuality) * fireRate / muzzleCount
end

--- Rendimento: MiningQuality 0 → ×1, 100 → ×2.
function OreConfig.YieldMultiplier(miningQuality: number): number
	return 1 + math.clamp(miningQuality, 0, 100) / 100
end

--- Unidades que o jogador recebe ao quebrar a rocha. A parte fracionária
--- vira chance de uma unidade a mais.
function OreConfig.RollYield(oreId: string, miningQuality: number): number
	local def = OreConfig.Ores[oreId]
	if not def then
		return 0
	end
	local value = math.random(def.dropMin, def.dropMax) * OreConfig.YieldMultiplier(miningQuality)
	local whole = math.floor(value)
	if math.random() < value - whole then
		whole += 1
	end
	return math.max(whole, 1)
end

-- ═══════════════════════════════════════════════════════════
-- Identificação
-- ═══════════════════════════════════════════════════════════

local function normalize(value: any): string?
	if typeof(value) ~= "string" then
		return nil
	end
	local id = string.lower((string.gsub(value, "^%s*(.-)%s*$", "%1")))
	return if OreConfig.Ores[id] then id else nil
end

--- Minério de uma rocha, pelo atributo (ou pelo nome). nil = não reconhecido.
function OreConfig.ResolveOreId(root: Instance): string?
	local attributes = root:GetAttributes()

	local byLowerName = {}
	for name, value in attributes do
		byLowerName[string.lower(name)] = value
	end
	for _, name in OreConfig.ID_ATTRIBUTES do
		local id = normalize(byLowerName[string.lower(name)])
		if id then
			return id
		end
	end

	-- Qualquer atributo de texto com o nome de um minério
	for _, value in attributes do
		local id = normalize(value)
		if id then
			return id
		end
	end

	-- Atributo com o próprio nome do minério (ex.: gravitita = true)
	for name, value in attributes do
		local id = normalize(name)
		if id and value then
			return id
		end
	end

	return normalize(root.Name)
end

-- ═══════════════════════════════════════════════════════════
-- Flutuação
-- ═══════════════════════════════════════════════════════════

local TAU = math.pi * 2

-- Fase em [0, 1): dividir antes de multiplicar por 2π mantém a precisão com o
-- relógio do servidor (segundos desde 1970)
local function wave(t: number, period: number, phase: number): number
	return math.sin(TAU * ((t / period + phase) % 1))
end

--[[
	Transformação da rocha no instante t, em coordenadas do mundo: a pose
	animada de qualquer Part é GetMotionCFrame(...) * cframeEmRepouso.

	Sobe e desce no Y do mundo, balança um pouco em X/Z e gira devagar em Y,
	tudo em volta de center. O sentido do giro sai da semente.
]]
function OreConfig.GetMotionCFrame(center: Vector3, seed: number, motion: Motion, t: number): CFrame
	local bob = motion.bob * wave(t, motion.bobPeriod, seed)
	local spinDirection = if seed < 0.5 then 1 else -1
	local yaw = TAU * ((t / motion.spinPeriod + seed) % 1) * spinDirection
	local tilt = math.rad(motion.tilt)
	local tiltX = tilt * wave(t, motion.tiltPeriod, seed * 1.7)
	local tiltZ = tilt * wave(t, motion.tiltPeriod * 1.35, seed * 2.3)

	return CFrame.new(center + Vector3.new(0, bob, 0))
		* CFrame.Angles(tiltX, 0, tiltZ)
		* CFrame.Angles(0, yaw, 0)
		* CFrame.new(-center)
end

return OreConfig
