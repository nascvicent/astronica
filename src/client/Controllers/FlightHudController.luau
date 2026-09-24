--[[
	FlightHudController
	Modo cruzeiro da HUD de voo: em velocidade de cruzeiro estável, as placas
	que são SÓ informação (velocidade e casco/armas) deslizam pra fora da tela
	pela esquerda e a tela fica limpa. Voltam quando algo muda de verdade.

	O que é interação (botão MAPA) e o que é evento (carga do warp, mensagens,
	flashes) não entra aqui: continua como está.

	ESCONDE quando, tudo junto:
	  - velocidade >= CRUISE_FRACTION do máximo da nave
	  - velocidade estável (dentro de STABLE_BAND) por CRUISE_HOLD segundos
	  - sem dano nem tiro há EVENT_QUIET segundos
	  - a HUD está na tela há pelo menos MIN_SHOWN (não fica piscando)

	VOLTA quando qualquer um:
	  - levou dano (o Hull caiu) ou atirou (o calor subiu)
	  - a velocidade mudou mais que DRASTIC_CHANGE do máximo desde que escondeu
	  - casco baixo ou armas superaquecidas (aí nem chega a esconder)

	Durante o warp (carga e túnel) fica escondida, a não ser por dano ou
	estado crítico: a arrancada e a chegada mudariam a velocidade à toa.

	A posição é aplicada pelo ShipHudModule (SpeedHUD.SetSlide), que as duas
	placas usam pra se posicionar.

	Local: src/client/Controllers/FlightHudController.luau
]]

local Knit = require(game:GetService("ReplicatedStorage").Packages.Knit)
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local ShipData = require(ReplicatedStorage.Shared.ShipData)
local CombatConfig = require(ReplicatedStorage.Shared.CombatConfig)
local SpeedHUD = require(ReplicatedStorage.Shared.ShipHudModule)

local player = Players.LocalPlayer

-- Frações da velocidade máxima da nave (Configurations.Speed)
local CRUISE_FRACTION = 0.8
local STABLE_BAND = 0.05
local DRASTIC_CHANGE = 0.15

-- Segundos
local CRUISE_HOLD = 2.5
local EVENT_QUIET = 4
local MIN_SHOWN = 3
local HIDE_TIME = 0.6 -- sai devagar: é a tela "respirando"
local SHOW_TIME = 0.25 -- volta rápido: se voltou, é porque importa

-- Casco abaixo disso nunca esconde (mesmo limite do alerta de casco baixo)
local HULL_CRITICAL = 0.3

local FlightHudController = Knit.CreateController({
	Name = "FlightHudController",
})

function FlightHudController:KnitInit()
	self._ship = nil :: Model?
	self._hidden = false
	self._progress = 0 -- 0..1 linear; a tela recebe com easing
end

function FlightHudController:KnitStart()
	self._shipController = Knit.GetController("ShipController")

	RunService.RenderStepped:Connect(function(dt)
		self:_step(dt)
	end)
end

-- ═══════════════════════════════════════════════════════════
-- Leitura
-- ═══════════════════════════════════════════════════════════

local function readNumber(model: Model, name: string): number?
	local config = model:FindFirstChild(ShipData.PARTS.configurations)
	local value = config and config:FindFirstChild(name)
	return if value and value:IsA("NumberValue") then value.Value else nil
end

--- Nave que o jogador local está pilotando agora, ou nil.
function FlightHudController:_getPilotedShip(): Model?
	local ship = self._shipController:GetOwnShip()
	local character = player.Character
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	local seat = humanoid and humanoid.SeatPart
	if ship and seat and seat:IsDescendantOf(ship) then
		return ship
	end
	return nil
end

-- ═══════════════════════════════════════════════════════════
-- Decisão
-- ═══════════════════════════════════════════════════════════

function FlightHudController:_reveal(now: number)
	self._hidden = false
	self._shownAt = now
end

function FlightHudController:_step(dt: number)
	local ship = self:_getPilotedShip()
	if not ship then
		-- Fora da nave: zera, pra próxima pilotagem começar com a HUD na tela
		self._ship = nil
		self._hidden = false
		self._progress = 0
		SpeedHUD.SetSlide(0)
		return
	end

	local now = os.clock()
	local body = CombatConfig.GetBody(ship)
	local speed = if body then body.AssemblyLinearVelocity.Magnitude else 0
	local maxSpeed = readNumber(ship, "Speed") or 0
	local maxHull = readNumber(ship, "MaxHull") or 0
	local hull = readNumber(ship, "Hull") or maxHull
	local heat = ship:GetAttribute(CombatConfig.HEAT_ATTRIBUTE)
	heat = if typeof(heat) == "number" then heat else 0

	-- Nave nova (ou acabou de sentar): começa na tela, contagem do zero
	if ship ~= self._ship then
		self._ship = ship
		self._hidden = false
		self._shownAt = now
		self._lastEvent = now
		self._lastHull = hull
		self._lastHeat = heat
		self._anchor = speed
		self._stableSince = now
	end

	-- Eventos: dano e tiro
	local damaged = hull < self._lastHull - 1e-3
	local fired = heat > self._lastHeat + 1e-4
	if damaged or fired then
		self._lastEvent = now
	end
	self._lastHull = hull
	self._lastHeat = heat

	local critical = ship:GetAttribute(CombatConfig.OVERHEATED_ATTRIBUTE) == true
		or (maxHull > 0 and hull / maxHull <= HULL_CRITICAL)
	local warping = self._shipController:IsWarpBusy()

	-- Estabilidade: a âncora anda quando a velocidade sai da faixa
	if maxSpeed > 0 and math.abs(speed - self._anchor) > STABLE_BAND * maxSpeed then
		self._anchor = speed
		self._stableSince = now
	end

	if self._hidden then
		local changed = maxSpeed > 0 and math.abs(speed - self._cruiseSpeed) > DRASTIC_CHANGE * maxSpeed
		-- No warp só dano/estado crítico trazem de volta (atirar no túnel não)
		if critical or damaged or (fired and not warping) or (changed and not warping) then
			self:_reveal(now)
		end
	elseif not critical and maxSpeed > 0 then
		local quiet = now - self._lastEvent >= EVENT_QUIET
		local settled = now - self._shownAt >= MIN_SHOWN
		local cruising = speed >= CRUISE_FRACTION * maxSpeed and now - self._stableSince >= CRUISE_HOLD
		-- No warp esconde sem esperar o cruzeiro: é cena, não pilotagem
		if quiet and settled and (cruising or warping) then
			self._hidden = true
			self._cruiseSpeed = speed
		end
	end

	-- Durante o warp a referência acompanha a velocidade: na saída do túnel a
	-- comparação parte de onde a nave chegou, não de antes da arrancada
	if self._hidden and warping then
		self._cruiseSpeed = speed
	end

	self:_animate(dt)
end

-- ═══════════════════════════════════════════════════════════
-- Animação
-- ═══════════════════════════════════════════════════════════

local function easeInOutCubic(t: number): number
	if t < 0.5 then
		return 4 * t * t * t
	end
	return 1 - (-2 * t + 2) ^ 3 / 2
end

function FlightHudController:_animate(dt: number)
	if self._hidden then
		self._progress = math.min(self._progress + dt / HIDE_TIME, 1)
	else
		self._progress = math.max(self._progress - dt / SHOW_TIME, 0)
	end
	SpeedHUD.SetSlide(easeInOutCubic(self._progress))
end

return FlightHudController
