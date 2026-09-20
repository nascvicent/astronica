--[[
	WarpModule
	Regras do warp: destinos, raio por tipo e a carga interrompível.

	O warp leva até o MARCADOR ORBITAL (Part em workspace/WarpDestinations,
	nome = id do destino), ainda voando. Descer no planeta é outro evento
	(TeleportManager) e não passa por aqui.

	Funções puras são usadas pelo client (lista de destinos com "no alcance")
	e pelo server (validação). WarpModule.Charge só roda no server.

	Local: src/shared/WarpModule.luau
]]

local PlaceConfig = require(script.Parent.PlaceConfig)

local WarpModule = {}

-- Distância da chegada até o marcador, pra nave não nascer dentro dele
WarpModule.ARRIVAL_OFFSET = 60

export type Destination = {
	id: string,
	part: BasePart,
	position: Vector3,
}

function WarpModule.GetDestinations(): { Destination }
	local folder = workspace:FindFirstChild(PlaceConfig.WARP_DESTINATIONS)
	local list = {}
	if not folder then
		return list
	end

	for _, child in folder:GetChildren() do
		if child:IsA("BasePart") then
			table.insert(list, { id = child.Name, part = child, position = child.Position })
		end
	end

	table.sort(list, function(a, b)
		return a.id < b.id
	end)
	return list
end

function WarpModule.GetDestination(destinationId: string): Destination?
	local folder = workspace:FindFirstChild(PlaceConfig.WARP_DESTINATIONS)
	local part = folder and folder:FindFirstChild(destinationId)
	if part and part:IsA("BasePart") then
		return { id = part.Name, part = part, position = part.Position }
	end
	return nil
end

function WarpModule.IsUnlimited(range: number): boolean
	return range <= 0
end

function WarpModule.IsInRange(range: number, from: Vector3, to: Vector3): boolean
	return WarpModule.IsUnlimited(range) or (to - from).Magnitude <= range
end

--- CFrame de chegada: um pouco antes do marcador, olhando pra ele.
function WarpModule.GetArrivalCFrame(from: Vector3, marker: BasePart): CFrame
	local target = marker.Position
	local dir = target - from
	if dir.Magnitude < 1 then
		dir = marker.CFrame.LookVector
	end
	local arrival = target - dir.Unit * (WarpModule.ARRIVAL_OFFSET + marker.Size.Magnitude / 2)
	return CFrame.lookAt(arrival, target)
end

-- ═══════════════════════════════════════════════════════════
-- Carga (server)
-- ═══════════════════════════════════════════════════════════

--[[
	Carga do warp. Termina de três jeitos:
	  onComplete()          — carga cheia sem interrupção
	  onCancel(reason)      — "WARP_INTERRUPTED" (dano / saiu do assento)
	                          ou "CANCELLED" (pedido do piloto / nave sumiu)

	O progresso vai no atributo WarpCharge do modelo, que replica pra todo
	mundo: é o que deixa os outros jogadores verem a nave carregando.
]]

local Charge = {}
Charge.__index = Charge

export type ChargeOptions = {
	model: Model,
	chargeTime: number,
	progressAttribute: string,
	onProgress: ((alpha: number) -> ())?,
	onComplete: () -> (),
	onCancel: (reason: string) -> (),
}

function WarpModule.StartCharge(options: ChargeOptions)
	local self = setmetatable({}, Charge)
	self._options = options
	self._done = false
	self._started = os.clock()

	options.model:SetAttribute(options.progressAttribute, 0)

	self._thread = task.spawn(function()
		local duration = math.max(options.chargeTime, 0)
		while not self._done do
			local alpha = if duration > 0 then math.clamp((os.clock() - self._started) / duration, 0, 1) else 1

			if not options.model.Parent then
				self:Cancel("CANCELLED")
				return
			end

			options.model:SetAttribute(options.progressAttribute, alpha)
			if options.onProgress then
				options.onProgress(alpha)
			end

			if alpha >= 1 then
				self:_finish()
				options.onComplete()
				return
			end

			task.wait(0.1)
		end
	end)

	return self
end

function Charge:_finish()
	if self._done then
		return false
	end
	self._done = true
	local model = self._options.model
	if model.Parent then
		model:SetAttribute(self._options.progressAttribute, nil)
	end
	return true
end

function Charge:Cancel(reason: string)
	if self:_finish() then
		self._options.onCancel(reason)
	end
end

function Charge:IsActive(): boolean
	return not self._done
end

return WarpModule
