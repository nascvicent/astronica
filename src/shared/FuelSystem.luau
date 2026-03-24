--[[
	FuelSystem (ModuleScript)
	Sistema de gasolina para naves — controla consumo, recarga e estado.

	USO (no PlaneScript server):
		local FuelSystem = require(path.to.FuelSystem)
		local fuel = FuelSystem.new(plane, {
			MaxFuel      = 100,    -- tanque cheio
			IdleRate     = 0.3,    -- consumo parado (motor ligado) por segundo
			MoveRate     = 2.0,    -- consumo em velocidade máxima por segundo
			RegenRate    = 15,     -- recarga por segundo (quando abastecendo)
		})

		-- No loop principal:
		fuel:Update(deltaTime, power)   -- power = speed / maxSpeed (0‑1)
		if fuel:IsEmpty() then ... end

		-- Para reabastecer (ex: pousou num posto):
		fuel:Refuel(deltaTime)

		-- Leitura:
		fuel:GetFuel()        --> número atual
		fuel:GetMaxFuel()     --> tanque máximo
		fuel:GetPercent()     --> 0‑1

		-- Cleanup:
		fuel:Destroy()
]]

local FuelSystem = {}
FuelSystem.__index = FuelSystem

export type FuelConfig = {
	MaxFuel:  number?,
	IdleRate: number?,
	MoveRate: number?,
	RegenRate: number?,
}

local DEFAULTS: FuelConfig = {
	MaxFuel   = 100,
	IdleRate  = 0.3,
	MoveRate  = 2.0,
	RegenRate = 15,
}

function FuelSystem.new(plane: Model, config: FuelConfig?)
	local cfg = config or {}
	local self = setmetatable({}, FuelSystem)

	self._plane    = plane
	self._maxFuel  = cfg.MaxFuel  or DEFAULTS.MaxFuel
	self._fuel     = self._maxFuel
	self._idleRate = cfg.IdleRate or DEFAULTS.IdleRate
	self._moveRate = cfg.MoveRate or DEFAULTS.MoveRate
	self._regenRate = cfg.RegenRate or DEFAULTS.RegenRate
	self._empty    = false

	-- Atributo replicado para o client ler (FuelHUD usa isso)
	plane:SetAttribute("Fuel", self._fuel)
	plane:SetAttribute("MaxFuel", self._maxFuel)

	return self
end

--- Chame todo frame no loop do servidor.
--- @param dt      deltaTime em segundos
--- @param power   0‑1 (speed / maxSpeed)
function FuelSystem:Update(dt: number, power: number)
	if self._empty then return end

	-- Consumo: lerp entre idle e move baseado no power
	local rate = self._idleRate + (self._moveRate - self._idleRate) * power
	self._fuel = math.max(self._fuel - rate * dt, 0)

	self._empty = (self._fuel <= 0)

	-- Replica pro client
	self._plane:SetAttribute("Fuel", self._fuel)
end

--- Reabastece (chamar em loop enquanto estiver no posto).
function FuelSystem:Refuel(dt: number)
	self._fuel  = math.min(self._fuel + self._regenRate * dt, self._maxFuel)
	self._empty = false
	self._plane:SetAttribute("Fuel", self._fuel)
end

--- Seta fuel direto (útil pra reset ou cheat).
function FuelSystem:SetFuel(amount: number)
	self._fuel  = math.clamp(amount, 0, self._maxFuel)
	self._empty = (self._fuel <= 0)
	self._plane:SetAttribute("Fuel", self._fuel)
end

function FuelSystem:GetFuel(): number
	return self._fuel
end

function FuelSystem:GetMaxFuel(): number
	return self._maxFuel
end

function FuelSystem:GetPercent(): number
	return self._fuel / self._maxFuel
end

function FuelSystem:IsEmpty(): boolean
	return self._empty
end

function FuelSystem:Destroy()
	-- limpa atributos
	if self._plane then
		self._plane:SetAttribute("Fuel", nil)
		self._plane:SetAttribute("MaxFuel", nil)
	end
	self._plane = nil
end

return FuelSystem