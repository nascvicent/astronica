--[[
	CombatService
	Combate entre naves de jogadores (PvP). Autoridade total do servidor:
	cadência, superaquecimento, trajetória, acerto, dano e destruição.

	O client só diz "estou atirando" e pra onde mira, pelo mesmo RemoteEvent
	Shoot que o LocalPlaneScript já usa (plane.Shoot:FireServer(atirando, mira)).
	O PlaneScript do modelo NÃO atira mais: ele cuida só de voo e motor.

	TIRO
	  A cada FireRate, com o piloto segurando o gatilho, cada Muzzle solta um
	  projétil. O projétil é só um ponto andando PROJECTILE_SPEED por frame com
	  Spherecast (sem Part física: nada de Touched perdido a 2000 studs/s).
	  Os clients recebem ShotFired e desenham o traçado por conta própria.

	SUPERAQUECIMENTO
	  MaxShots rajadas seguidas travam as armas por CooldownTime. Parado de
	  atirar por COOL_DELAY, a arma esfria sozinha. O estado vai nos atributos
	  WeaponHeat / WeaponOverheated do modelo (HUD e brilho leem de lá).

	ONDE ATIRA
	  Em qualquer lugar do espaço, INCLUSIVE zona segura: as armas da nave
	  também vão minerar, e minerar perto da estação não pode ser proibido.
	  Só travam dentro da HangarZone (o hangar em si), ancoradas e no túnel.

	DANO EM NAVE — só vale quando
	  - o Place é de espaço
	  - atirador e alvo estão fora de zona segura (o tiro de dentro dela
	    atinge a nave e para, mas não fere)
	  - o alvo não é a nave do atirador, não está ancorada nem no túnel de warp
	  - o alvo tem piloto, ou levou tiro há menos de COMBAT_TAG_TIME

	DESTRUIÇÃO
	  Casco em 0 (de qualquer fonte) → ShipService:DestroyShip: explode, some,
	  e o piloto reaparece no spawn do Place. Quem acertou por último leva o
	  crédito.

	Local: src/server/Services/CombatService.luau
]]

local Knit = require(game:GetService("ReplicatedStorage").Packages.Knit)
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local CollectionService = game:GetService("CollectionService")
local RunService = game:GetService("RunService")

local ShipData = require(ReplicatedStorage.Shared.ShipData)
local PlaceConfig = require(ReplicatedStorage.Shared.PlaceConfig)
local CombatConfig = require(ReplicatedStorage.Shared.CombatConfig)

-- Fallbacks iguais aos do PlaneScript antigo, pra nave sem o Value
local DEFAULT_MAX_SHOTS = 20
local DEFAULT_COOLDOWN_TIME = 3
local DEFAULT_FIRE_RATE = 0.1
local MIN_FIRE_RATE = 0.03

-- Passo mínimo pra republicar o calor (evita um atributo por frame)
local HEAT_STEP = 0.02

type ShipState = {
	model: Model,
	shoot: RemoteEvent?,
	shooting: boolean,
	aim: Vector3?,
	shots: number, -- rajadas acumuladas (calor = shots / MaxShots)
	overheatedUntil: number?,
	nextShot: number,
	lastShot: number,
	publishedHeat: number,
	lastHitAt: number?, -- última vez que ESTA nave levou dano
	lastAttacker: Player?,
	destroyed: boolean,
	conns: { RBXScriptConnection },
}

type Projectile = {
	shooter: Player,
	shooterModel: Model,
	damage: number,
	position: Vector3,
	direction: Vector3,
	travelled: number,
	params: RaycastParams,
}

local CombatService = Knit.CreateService({
	Name = "CombatService",

	Client = {
		-- (model, shots: { { muzzle: Instance, direction: Vector3 } }) — todos
		ShotFired = Knit.CreateSignal(),
		-- (damage, destroyed: boolean) — só pro atirador
		HitConfirmed = Knit.CreateSignal(),
		-- (damage, fromPosition: Vector3) — só pro piloto atingido
		DamageTaken = Knit.CreateSignal(),
		-- (isVictim: boolean, otherName: string?) — pra vítima (otherName = quem
		-- destruiu, se houver) e pro autor do abate (otherName = a vítima)
		ShipDestroyed = Knit.CreateSignal(),
	},

	_ships = {} :: { [Model]: ShipState },
	_projectiles = {} :: { Projectile },
})

-- ═══════════════════════════════════════════════════════════
-- Helpers
-- ═══════════════════════════════════════════════════════════

local warnedLegacy: { [string]: boolean } = {}

local function readConfig(model: Model, name: string, default: any): any
	local config = model:FindFirstChild(ShipData.PARTS.configurations)
	local value = config and config:FindFirstChild(name)
	if value and value:IsA("ValueBase") then
		return (value :: any).Value
	end
	return default
end

local function getHull(model: Model): NumberValue?
	local config = model:FindFirstChild(ShipData.PARTS.configurations)
	local hull = config and config:FindFirstChild("Hull")
	return if hull and hull:IsA("NumberValue") then hull else nil
end

local function isFiniteVector(v: any): boolean
	return typeof(v) == "Vector3" and v == v and v.Magnitude < math.huge
end

-- ═══════════════════════════════════════════════════════════
-- Registro das naves
-- ═══════════════════════════════════════════════════════════

function CombatService:_bindShip(model: Instance)
	if not model:IsA("Model") or self._ships[model] then
		return
	end

	local state: ShipState = {
		model = model,
		shoot = nil,
		shooting = false,
		aim = nil,
		shots = 0,
		overheatedUntil = nil,
		nextShot = 0,
		lastShot = 0,
		publishedHeat = 0,
		lastHitAt = nil,
		lastAttacker = nil,
		destroyed = false,
		conns = {},
	}
	self._ships[model] = state

	model:SetAttribute(CombatConfig.HEAT_ATTRIBUTE, 0)
	model:SetAttribute(CombatConfig.OVERHEATED_ATTRIBUTE, false)

	local shoot = model:FindFirstChild("Shoot")
	if shoot and shoot:IsA("RemoteEvent") then
		state.shoot = shoot
		table.insert(state.conns, shoot.OnServerEvent:Connect(function(player, shooting, aim)
			self:_onShoot(state, player, shooting, aim)
		end))
	end

	local seat = model:FindFirstChild(ShipData.PARTS.seat, true)
	if seat and (seat:IsA("Seat") or seat:IsA("VehicleSeat")) then
		-- Saiu do assento (ou morreu): larga o gatilho
		table.insert(state.conns, seat:GetPropertyChangedSignal("Occupant"):Connect(function()
			state.shooting = false
			state.aim = nil
		end))
	end

	-- PlaneScript antigo ainda atirando por conta própria (Parts "Bullet" com
	-- dano no Touched): o dano contaria em dobro. Some com as balas e avisa.
	local guns = model:FindFirstChild("Guns")
	if guns then
		table.insert(state.conns, guns.DescendantAdded:Connect(function(inst)
			if inst.Name ~= "Bullet" or not inst:IsA("BasePart") then
				return
			end
			if not warnedLegacy[model.Name] then
				warnedLegacy[model.Name] = true
				warn(string.format(
					"[CombatService] %s ainda usa o PlaneScript antigo (cria Bullet) — cole o de studio/PlaneScript.server.luau no modelo",
					model.Name
				))
			end
			task.defer(inst.Destroy, inst)
		end))
	end

	-- Casco zerado por qualquer caminho destrói a nave
	local hull = getHull(model)
	if hull then
		table.insert(state.conns, hull.Changed:Connect(function(value)
			if value <= 0 then
				self:_destroy(state)
			end
		end))
	end
end

function CombatService:_unbindShip(model: Instance)
	local state = self._ships[model :: Model]
	if not state then
		return
	end
	self._ships[model :: Model] = nil
	for _, conn in state.conns do
		conn:Disconnect()
	end
end

function CombatService:_onShoot(state: ShipState, player: Player, shooting: any, aim: any)
	if CombatConfig.GetPilot(state.model) ~= player then
		return
	end
	state.shooting = shooting == true
	if isFiniteVector(aim) then
		state.aim = aim
	end
end

-- ═══════════════════════════════════════════════════════════
-- Regras
-- ═══════════════════════════════════════════════════════════

--- A nave pode levar dano agora?
function CombatService:_isVulnerable(state: ShipState): boolean
	local model = state.model
	if state.destroyed or not model.Parent then
		return false
	end
	if model:GetAttribute(ShipData.DOCKED_ATTRIBUTE) == true then
		return false
	end
	if CombatConfig.IsInSafeZone(CombatConfig.GetShipPosition(model)) then
		return false
	end

	local owner = Players:GetPlayerByUserId(model:GetAttribute(ShipData.OWNER_ATTRIBUTE) or 0)
	if owner and self._shipService:IsWarpTravelling(owner) then
		return false
	end

	if CombatConfig.GetPilot(model) then
		return true
	end
	return state.lastHitAt ~= nil and os.clock() - state.lastHitAt < CombatConfig.COMBAT_TAG_TIME
end

--- O piloto pode atirar agora? (sem contar calor e cadência). Zona segura
--- NÃO trava a arma: ela só tira o dano entre naves (ver _onHit).
function CombatService:_canFire(state: ShipState, pilot: Player): boolean
	local model = state.model
	if not readConfig(model, "GunsEnabled", false) then
		return false
	end
	if model:GetAttribute(ShipData.DOCKED_ATTRIBUTE) == true then
		return false
	end
	if PlaceConfig.IsInHangarZone(CombatConfig.GetShipPosition(model)) then
		return false
	end
	return not self._shipService:IsWarpTravelling(pilot)
end

-- ═══════════════════════════════════════════════════════════
-- Tiro
-- ═══════════════════════════════════════════════════════════

--- Direção do tiro: pra mira do client, se ela está à frente da nave; senão
--- reto pra frente (mobile não manda mira).
local function shotDirection(model: Model, origin: Vector3, aim: Vector3?): Vector3
	local body = CombatConfig.GetBody(model)
	local forward = if body then body.CFrame.LookVector else model:GetPivot().LookVector

	if aim then
		local toAim = aim - origin
		if toAim.Magnitude > 1 then
			local direction = toAim.Unit
			local angle = math.deg(math.acos(math.clamp(direction:Dot(forward), -1, 1)))
			if angle <= CombatConfig.MAX_AIM_ANGLE then
				return direction
			end
		end
	end
	return forward
end

function CombatService:_fire(state: ShipState, pilot: Player, fireRate: number)
	local model = state.model
	local muzzles = CombatConfig.GetMuzzles(model)
	if #muzzles == 0 then
		return
	end

	local damage = CombatConfig.ShotDamage(readConfig(model, "Damage", 0), fireRate, #muzzles)

	-- Um filtro por rajada: os projéteis dela ignoram a própria nave e o piloto
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	params.FilterDescendantsInstances = { model, pilot.Character :: Instance }

	local shots = {}
	for _, muzzle in muzzles do
		local origin = CombatConfig.GetMuzzlePosition(muzzle)
		local direction = shotDirection(model, origin, state.aim)
		table.insert(shots, { muzzle = muzzle, direction = direction })
		table.insert(self._projectiles, {
			shooter = pilot,
			shooterModel = model,
			damage = damage,
			position = origin,
			direction = direction,
			travelled = 0,
			params = params,
		})
	end

	self.Client.ShotFired:FireAll(model, shots)
end

function CombatService:_setHeat(state: ShipState, heat: number, overheated: boolean)
	local model = state.model
	if math.abs(heat - state.publishedHeat) >= HEAT_STEP or ((heat == 0 or heat == 1) and state.publishedHeat ~= heat) then
		state.publishedHeat = heat
		model:SetAttribute(CombatConfig.HEAT_ATTRIBUTE, heat)
	end
	if model:GetAttribute(CombatConfig.OVERHEATED_ATTRIBUTE) ~= overheated then
		model:SetAttribute(CombatConfig.OVERHEATED_ATTRIBUTE, overheated)
	end
end

function CombatService:_stepWeapons(state: ShipState, now: number, dt: number)
	local model = state.model
	local maxShots = math.max(readConfig(model, "MaxShots", DEFAULT_MAX_SHOTS), 1)
	local cooldownTime = math.max(readConfig(model, "CooldownTime", DEFAULT_COOLDOWN_TIME), 0.1)

	-- Superaquecida: trava até o fim do CooldownTime e volta fria
	if state.overheatedUntil then
		if now < state.overheatedUntil then
			self:_setHeat(state, 1, true)
			return
		end
		state.overheatedUntil = nil
		state.shots = 0
	end

	local pilot = CombatConfig.GetPilot(model)
	local firing = state.shooting and pilot ~= nil and self:_canFire(state, pilot :: Player)

	if firing and now >= state.nextShot then
		local fireRate = math.max(readConfig(model, "FireRate", DEFAULT_FIRE_RATE), MIN_FIRE_RATE)
		-- Atraso de um frame não se perde (a cadência fica certa segurando o
		-- gatilho), mas uma pausa longa não vira rajada acumulada
		if state.nextShot < now - fireRate then
			state.nextShot = now
		end
		state.nextShot += fireRate
		state.lastShot = now
		self:_fire(state, pilot :: Player, fireRate)

		state.shots += 1
		if state.shots >= maxShots then
			-- Gatilho continua segurado: volta a atirar sozinha ao esfriar
			state.overheatedUntil = now + cooldownTime
			self:_setHeat(state, 1, true)
			return
		end
	elseif not firing then
		if state.shots > 0 and now - state.lastShot >= CombatConfig.COOL_DELAY then
			state.shots = math.max(state.shots - maxShots / cooldownTime * dt, 0)
		end
	end

	self:_setHeat(state, math.clamp(state.shots / maxShots, 0, 1), false)
end

-- ═══════════════════════════════════════════════════════════
-- Projéteis
-- ═══════════════════════════════════════════════════════════

--- Anda o projétil um frame. true = acabou (acertou algo ou saiu do alcance).
function CombatService:_stepProjectile(projectile: Projectile, dt: number): boolean
	local remaining = math.min(CombatConfig.PROJECTILE_SPEED * dt, CombatConfig.PROJECTILE_RANGE - projectile.travelled)

	while remaining > 0 do
		local step = math.min(remaining, 1000)
		local result = CombatConfig.CastShot(projectile.position, projectile.direction * step, projectile.params)
		if result then
			self:_onHit(projectile, result.Instance)
			return true
		end
		projectile.position += projectile.direction * step
		projectile.travelled += step
		remaining -= step
	end

	return projectile.travelled >= CombatConfig.PROJECTILE_RANGE
end

function CombatService:_onHit(projectile: Projectile, instance: Instance)
	local target = CombatConfig.FindShip(instance)
	if not target or target == projectile.shooterModel then
		return
	end
	local state = self._ships[target]
	if not state or projectile.damage <= 0 then
		return
	end

	-- Atirador dentro de zona segura não fere nave nenhuma (atirar lá é pra
	-- minerar). Checado no acerto: vale também pra quem entrou depois do disparo
	if CombatConfig.IsInSafeZone(CombatConfig.GetShipPosition(projectile.shooterModel)) then
		return
	end
	if not self:_isVulnerable(state) then
		return
	end

	local hull = getHull(target)
	if not hull then
		return
	end

	state.lastHitAt = os.clock()
	if projectile.shooter.Parent then
		state.lastAttacker = projectile.shooter
	end

	local newValue = math.max(hull.Value - projectile.damage, 0)
	local destroyed = newValue <= 0

	if projectile.shooter.Parent then
		self.Client.HitConfirmed:Fire(projectile.shooter, projectile.damage, destroyed)
	end
	local victim = CombatConfig.GetPilot(target)
	if victim then
		self.Client.DamageTaken:Fire(victim, projectile.damage, CombatConfig.GetShipPosition(projectile.shooterModel))
	end

	-- Por último: zerar o casco dispara a destruição pelo Hull.Changed
	hull.Value = newValue
end

-- ═══════════════════════════════════════════════════════════
-- Destruição
-- ═══════════════════════════════════════════════════════════

function CombatService:_destroy(state: ShipState)
	if state.destroyed then
		return
	end
	state.destroyed = true
	state.shooting = false

	local model = state.model
	local owner = Players:GetPlayerByUserId(model:GetAttribute(ShipData.OWNER_ATTRIBUTE) or 0)

	local killer = state.lastAttacker
	if
		killer
		and (not killer.Parent or not state.lastHitAt or os.clock() - state.lastHitAt > CombatConfig.KILL_CREDIT_TIME)
	then
		killer = nil
	end

	if owner then
		self.Client.ShipDestroyed:Fire(owner, true, if killer then killer.DisplayName else nil)
	end
	if killer and killer ~= owner then
		self.Client.ShipDestroyed:Fire(killer, false, if owner then owner.DisplayName else nil)
	end

	-- Fora do Hull.Changed: o despawn destrói a instância que disparou o evento
	task.defer(function()
		if owner and self._shipService:DestroyShip(owner, model) then
			return
		end
		-- Nave sem dono registrado (ou recusada): some do mesmo jeito
		if model.Parent then
			model:Destroy()
		end
	end)
end

-- ═══════════════════════════════════════════════════════════
-- Loop
-- ═══════════════════════════════════════════════════════════

function CombatService:_step(dt: number)
	local now = os.clock()

	for _, state in self._ships do
		if not state.destroyed and state.model.Parent then
			self:_stepWeapons(state, now, dt)
		end
	end

	local projectiles = self._projectiles
	local i = 1
	while i <= #projectiles do
		if self:_stepProjectile(projectiles[i], dt) then
			-- Troca com o último: ordem não importa
			projectiles[i] = projectiles[#projectiles]
			projectiles[#projectiles] = nil
		else
			i += 1
		end
	end
end

-- ═══════════════════════════════════════════════════════════
-- Knit Lifecycle
-- ═══════════════════════════════════════════════════════════

function CombatService:KnitStart()
	self._shipService = Knit.GetService("ShipService")

	if not CombatConfig.IsCombatPlace() then
		print("[CombatService] Place de planeta — combate desligado")
		return
	end

	CollectionService:GetInstanceAddedSignal(ShipData.SHIP_TAG):Connect(function(model)
		self:_bindShip(model)
	end)
	CollectionService:GetInstanceRemovedSignal(ShipData.SHIP_TAG):Connect(function(model)
		self:_unbindShip(model)
	end)
	for _, model in CollectionService:GetTagged(ShipData.SHIP_TAG) do
		self:_bindShip(model)
	end

	RunService.Heartbeat:Connect(function(dt)
		self:_step(dt)
	end)

	print("[CombatService] Started")
end

return CombatService
