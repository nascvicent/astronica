--[[
	CombatConfig
	Números e regras do combate entre naves (PvP). Server (CombatService) e
	client (CombatController) leem daqui, pra que o tiro que o piloto vê e o
	que o servidor conta andem pelo mesmo caminho.

	Quem decide acerto e dano é SEMPRE o servidor. O client só desenha o
	traçado e o impacto.

	  Dano, cadência e superaquecimento → Configurations da nave (ShipData)
	  Velocidade, alcance, raio de acerto e zonas seguras → aqui

	Local: src/shared/CombatConfig.luau
]]

local CollectionService = game:GetService("CollectionService")
local Players = game:GetService("Players")

local ShipData = require(script.Parent.ShipData)
local PlaceConfig = require(script.Parent.PlaceConfig)
local MapConfig = require(script.Parent.MapConfig)

local CombatConfig = {}

-- ═══════════════════════════════════════════════════════════
-- Projétil
-- ═══════════════════════════════════════════════════════════

CombatConfig.PROJECTILE_SPEED = 2000 -- studs/s
CombatConfig.PROJECTILE_RANGE = 2000 -- studs até sumir
-- Raio do Spherecast do tiro. Folga pra latência: o servidor vê o alvo onde
-- ele estava há um ping, então um raio de 0 quase nunca acertaria em voo
CombatConfig.HIT_RADIUS = 4

-- Ângulo máximo (graus) entre a frente da nave e a mira mandada pelo client.
-- Além disso a mira é ignorada e o tiro sai reto: não dá pra atirar pra trás
CombatConfig.MAX_AIM_ANGLE = 40

-- Resfriamento sem superaquecer: depois de COOL_DELAY sem atirar, a arma
-- esfria por inteiro em CooldownTime segundos
CombatConfig.COOL_DELAY = 0.6

-- ═══════════════════════════════════════════════════════════
-- Dano e destruição
-- ═══════════════════════════════════════════════════════════

--[[
	O stat Damage da nave é DANO POR SEGUNDO de fogo contínuo (× DAMAGE_SCALE),
	não dano por projétil. Cada rajada leva Damage × FireRate × escala,
	dividido entre os canos: nave com 4 canos não bate o dobro da de 2, e
	cadência maior não multiplica o dano.

	Com 0.25, acertando TUDO (na prática, bem mais):
	  Dispatcher × Dispatcher   10 dps · casco 70  → ~7 s de acerto, 4 cargas
	  Deimos     × Dispatcher   6 dps  · casco 70  → ~11 s
	  Scout Combate × Dispatcher 25 dps · casco 70 → ~3 s, 2 cargas
	  Scout Combate × Scout Combate 25 dps · casco 100 → ~4 s
	Uma carga = MaxShots × FireRate segundos antes de superaquecer.
]]
CombatConfig.DAMAGE_SCALE = 0.25

--- Dano de UM projétil (um cano, uma rajada).
function CombatConfig.ShotDamage(damageStat: number, fireRate: number, muzzleCount: number): number
	if muzzleCount <= 0 then
		return 0
	end
	return math.max(damageStat, 0) * fireRate * CombatConfig.DAMAGE_SCALE / muzzleCount
end

-- Nave sem piloto não toma dano (não dá pra destruir nave estacionada), a
-- menos que tenha levado tiro há menos que isto: sair do assento no meio da
-- briga não salva a nave
CombatConfig.COMBAT_TAG_TIME = 10

-- Crédito do abate: quem acertou por último, se foi há menos que isto
CombatConfig.KILL_CREDIT_TIME = 15

-- Do casco zerado até o piloto reaparecer
CombatConfig.RESPAWN_DELAY = 2.5

-- ═══════════════════════════════════════════════════════════
-- Zonas seguras
-- ═══════════════════════════════════════════════════════════

-- Zona segura tira o DANO ENTRE NAVES, não o tiro: dentro dela as armas
-- continuam funcionando (mineração). Só o hangar (HangarZone, sem margem)
-- trava as armas.
--
-- Três fontes, qualquer uma vale:
--   1. SAFE_BODIES: esfera em volta de um corpo do mapa (MapConfig.BODIES).
--      É a que aparece no mapa do sistema
--   2. HangarZone + HANGAR_SAFE_MARGIN
--   3. Parts em Workspace.SafeZones (volume exato da Part)

-- Corpo do mapa → raio da zona segura em studs, a partir da posição do corpo
-- no mapa (o marcador de warp). A chegada de warp cai ARRIVAL_OFFSET (1500)
-- antes do marcador, então o raio passa disso com folga: ninguém chega de
-- warp já na mira de quem está esperando do lado de fora
CombatConfig.SAFE_BODIES = {
	cidadel = 2500,
}

-- Em volta da HangarZone ninguém atira nem toma dano (studs além da caixa)
CombatConfig.HANGAR_SAFE_MARGIN = 200

-- Pasta opcional no Workspace com Parts extras de zona segura (estações,
-- pontos de encontro). O volume de cada Part é a zona, sem margem.
CombatConfig.SAFE_ZONES = "SafeZones"

-- ═══════════════════════════════════════════════════════════
-- Atributos (no modelo da nave, escritos pelo servidor)
-- ═══════════════════════════════════════════════════════════

CombatConfig.HEAT_ATTRIBUTE = "WeaponHeat" -- 0..1
CombatConfig.OVERHEATED_ATTRIBUTE = "WeaponOverheated" -- true durante o CooldownTime

-- ═══════════════════════════════════════════════════════════
-- Regras
-- ═══════════════════════════════════════════════════════════

--- Combate só existe no espaço: em planeta a nave nem voa.
function CombatConfig.IsCombatPlace(): boolean
	return not PlaceConfig.IsPlanet()
end

local function insideBox(part: BasePart, position: Vector3, margin: number): boolean
	local localPos = part.CFrame:PointToObjectSpace(position)
	local half = part.Size / 2 + Vector3.new(margin, margin, margin)
	return math.abs(localPos.X) <= half.X and math.abs(localPos.Y) <= half.Y and math.abs(localPos.Z) <= half.Z
end

local function partsOf(instance: Instance?): { BasePart }
	if not instance then
		return {}
	end
	if instance:IsA("BasePart") then
		return { instance }
	end
	local parts = {}
	for _, child in instance:GetDescendants() do
		if child:IsA("BasePart") then
			table.insert(parts, child)
		end
	end
	return parts
end

export type SafeSphere = { id: string, position: Vector3, radius: number }

-- Corpos não se movem: relê a cada tanto (o marcador pode chegar tarde por
-- streaming no client)
local SPHERE_REFRESH = 2
local sphereCache: { SafeSphere }? = nil
local sphereCacheAt = 0

--- Esferas seguras dos SAFE_BODIES com posição resolvida.
function CombatConfig.GetSafeSpheres(): { SafeSphere }
	local now = os.clock()
	if sphereCache and now - sphereCacheAt < SPHERE_REFRESH then
		return sphereCache
	end

	local spheres = {}
	for _, body in MapConfig.GetBodies() do
		local key = string.lower(body.entry or body.id)
		for id, radius in CombatConfig.SAFE_BODIES do
			if string.lower(id) == key or string.lower(body.id) == string.lower(id) then
				table.insert(spheres, { id = body.id, position = body.position, radius = radius })
				break
			end
		end
	end

	sphereCache = spheres
	sphereCacheAt = now
	return spheres
end

function CombatConfig.IsInSafeZone(position: Vector3): boolean
	for _, sphere in CombatConfig.GetSafeSpheres() do
		if (position - sphere.position).Magnitude <= sphere.radius then
			return true
		end
	end
	for _, part in partsOf(workspace:FindFirstChild(PlaceConfig.HANGAR_ZONE)) do
		if insideBox(part, position, CombatConfig.HANGAR_SAFE_MARGIN) then
			return true
		end
	end
	for _, part in partsOf(workspace:FindFirstChild(CombatConfig.SAFE_ZONES)) do
		if insideBox(part, position, 0) then
			return true
		end
	end
	return false
end

-- ═══════════════════════════════════════════════════════════
-- Nave
-- ═══════════════════════════════════════════════════════════

function CombatConfig.GetBody(model: Model): BasePart?
	local body = model:FindFirstChild(ShipData.PARTS.body)
	return if body and body:IsA("BasePart") then body else nil
end

function CombatConfig.GetShipPosition(model: Model): Vector3
	local body = CombatConfig.GetBody(model)
	return if body then body.Position else model:GetPivot().Position
end

--- Muzzles das armas (Guns/<arma>/Muzzle), na ordem das armas.
function CombatConfig.GetMuzzles(model: Model): { Instance }
	local muzzles = {}
	local guns = model:FindFirstChild("Guns")
	if not guns then
		return muzzles
	end
	for _, gun in guns:GetChildren() do
		local muzzle = gun:FindFirstChild("Muzzle")
		if muzzle and (muzzle:IsA("BasePart") or muzzle:IsA("Attachment")) then
			table.insert(muzzles, muzzle)
		end
	end
	return muzzles
end

--- Muzzle pode ser Part ou Attachment (Position de Attachment é local).
function CombatConfig.GetMuzzlePosition(muzzle: Instance): Vector3
	if muzzle:IsA("Attachment") then
		return muzzle.WorldPosition
	end
	return (muzzle :: BasePart).Position
end

--- Nave dona da parte atingida. Acertar o piloto sentado conta como acertar
--- a nave dele.
function CombatConfig.FindShip(instance: Instance?): Model?
	local node = instance
	while node and node ~= workspace do
		if node:IsA("Model") then
			if CollectionService:HasTag(node, ShipData.SHIP_TAG) then
				return node
			end
			local humanoid = node:FindFirstChildOfClass("Humanoid")
			if humanoid then
				return if humanoid.SeatPart then CombatConfig.FindShip(humanoid.SeatPart) else nil
			end
		end
		node = node.Parent
	end
	return nil
end

--- Jogador sentado no assento da nave, ou nil.
function CombatConfig.GetPilot(model: Model): Player?
	local seat = model:FindFirstChild(ShipData.PARTS.seat, true)
	if not seat or not (seat:IsA("Seat") or seat:IsA("VehicleSeat")) then
		return nil
	end
	local occupant = seat.Occupant
	return occupant and Players:GetPlayerFromCharacter(occupant.Parent)
end

-- ═══════════════════════════════════════════════════════════
-- Traçado do tiro (mesmo no server e no client)
-- ═══════════════════════════════════════════════════════════

--- Parte que o tiro atravessa: volume invisível sem colisão (zonas,
--- marcadores de warp) e personagem que não está pilotando.
local function isPassThrough(part: BasePart): boolean
	if part.Transparency >= 0.99 and not part.CanCollide then
		return true
	end
	local character = part:FindFirstAncestorOfClass("Model")
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	return humanoid ~= nil and humanoid.SeatPart == nil
end

local MAX_PASS_THROUGH = 4
local SPHERECAST_LIMIT = 1000 -- o Spherecast recusa deslocamento acima de 1024

--- Anda o tiro de origin por displacement. Pula o que não bloqueia tiro
--- (acrescentando ao filtro de params) e devolve o primeiro acerto de verdade.
function CombatConfig.CastShot(origin: Vector3, displacement: Vector3, params: RaycastParams): RaycastResult?
	local distance = displacement.Magnitude
	if distance <= 0 then
		return nil
	end
	if distance > SPHERECAST_LIMIT then
		displacement = displacement.Unit * SPHERECAST_LIMIT
	end

	for _ = 1, MAX_PASS_THROUGH do
		local result = workspace:Spherecast(origin, CombatConfig.HIT_RADIUS, displacement, params)
		if not result then
			return nil
		end
		local part = result.Instance
		if part:IsA("BasePart") and isPassThrough(part) then
			params:AddToFilter(part)
			continue
		end
		return result
	end
	return nil
end

return CombatConfig
