--[[
	FlightLimits
	Até onde a nave pode voar no espaço. Passar do fundo do mapa mata o
	jogador e destrói a nave (FallenPartsDestroyHeight), e Solara é uma
	estrela: nenhum dos dois pode ser alcançado.

	Cada limite tem duas faixas:
	  aviso    WARN_DISTANCE antes do limite: "SINAL DA CENTRAL FRACO" e a nave
	           começa a frear no sentido do limite (continua livre pros lados
	           e pra voltar)
	  limite   a nave para ali: "CONTATO PERDIDO COM A CENTRAL". Se passou
	           (lag, arrancada), é empurrada de volta

	Quem aplica é o ShipController, no client do piloto (que tem a posse de
	rede da nave).

	Local: src/shared/FlightLimits.luau
]]

local MapConfig = require(script.Parent.MapConfig)

local FlightLimits = {}

-- Fundo: o limite fica essa distância acima do FallenPartsDestroyHeight
FlightLimits.FLOOR_MARGIN = 200

-- Solara: raio em volta do centro dela que a nave não atravessa
FlightLimits.SOLARA_ID = "solara"
FlightLimits.SOLARA_RADIUS = 1600

-- Faixa de aviso antes de cada limite
FlightLimits.WARN_DISTANCE = 250
-- Freio: velocidade máxima em direção ao limite = distância restante / isso
FlightLimits.BRAKE_TIME = 0.6
-- Já do lado de lá do limite: velocidade com que volta
FlightLimits.PUSH_SPEED = 60

export type Limit = {
	id: string,
	distance: number, -- quanto falta até o limite (negativo = passou)
	normal: Vector3, -- aponta pro lado permitido
}

function FlightLimits.GetFloorY(): number
	return workspace.FallenPartsDestroyHeight + FlightLimits.FLOOR_MARGIN
end

--- Posição de Solara, pela mesma regra do mapa (marcador → anchor → position).
function FlightLimits.GetSolaraPosition(): Vector3?
	for _, body in MapConfig.GetBodies() do
		if string.lower(body.entry or body.id) == FlightLimits.SOLARA_ID then
			return body.position
		end
	end
	return nil
end

--- O limite mais apertado pra essa posição. solara = posição de Solara (nil
--- ignora esse limite).
function FlightLimits.Nearest(position: Vector3, solara: Vector3?): Limit
	local best: Limit = {
		id = "floor",
		distance = position.Y - FlightLimits.GetFloorY(),
		normal = Vector3.yAxis,
	}

	if solara then
		local offset = position - solara
		local length = offset.Magnitude
		local distance = length - FlightLimits.SOLARA_RADIUS
		if distance < best.distance then
			best = {
				id = "solara",
				distance = distance,
				normal = if length > 1e-3 then offset / length else Vector3.yAxis,
			}
		end
	end

	return best
end

--- Velocidade com o componente em direção ao limite cortado pelo freio. Longe
--- do limite devolve a mesma.
function FlightLimits.Clamp(velocity: Vector3, limit: Limit): Vector3
	if limit.distance >= FlightLimits.WARN_DISTANCE then
		return velocity
	end

	-- Componente "pra fora" (positivo = se afastando do limite)
	local outward = velocity:Dot(limit.normal)
	local minOutward
	if limit.distance <= 0 then
		minOutward = FlightLimits.PUSH_SPEED * math.min(-limit.distance / 20, 1)
	else
		minOutward = -limit.distance / FlightLimits.BRAKE_TIME
	end

	if outward >= minOutward then
		return velocity
	end
	return velocity + limit.normal * (minOutward - outward)
end

return FlightLimits
