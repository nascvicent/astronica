--[[
	WarpTunnel
	O túnel do salto, em geometria 3D de verdade: a nave voa DENTRO dele.

	Nada aqui é overlay de tela. São Parts Neon num eixo, com perspectiva,
	paralaxe e oclusão reais — a nave passa na frente dos riscos, e girar a
	câmera mostra o túnel por outro ângulo. Tudo criado em runtime: nenhum
	asset novo, nada pra montar no Studio.

	  · Riscos    — pool de Parts finas e compridas deitadas no eixo do salto,
	                distribuídas num cilindro em volta da nave e recicladas
	                quando passam por trás. São eles que FORMAM a parede: o
	                sorteio do raio puxa pra fora, então o miolo fica limpo e
	                a casca, densa
	  · Poeira    — ParticleEmitter preso ao eixo, pra densidade fina
	  · Tela      — só o flash da entrada/chegada, o FOV e o Lighting
	  · Áudio     — uma trilha só (17s) com o estouro no segundo 12. Ela
	                entra no meio, calculado pra que o segundo 12 caia
	                exatamente no teleporte, seja qual for a carga da nave

	O eixo é travado no Play(): a posição acompanha a nave (inclusive no
	PivotTo do teleporte, que por isso não dá solavanco), mas a direção fica
	parada no mundo — é o que deixa olhar em volta dentro do túnel.

	Local: src/client/UI/WarpTunnel.luau
]]

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")
local Lighting = game:GetService("Lighting")
local SoundService = game:GetService("SoundService")

local ShipData = require(game:GetService("ReplicatedStorage").Shared.ShipData)

local player = Players.LocalPlayer
local playerGui = player:WaitForChild("PlayerGui")

-- Família do azul da carga do warp (ShipController.WARP_FX_COLOR)
local CORE_COLOR = Color3.fromHex("#DDF5FF")
local EDGE_COLOR = Color3.fromHex("#2F7BFF")

-- Geometria do túnel, em studs
local STREAK_COUNT = 170
local RADIUS_MIN = 14
local RADIUS_MAX = 160
-- < 1 empurra os riscos pro raio grande: parede densa, miolo livre pra nave
local RADIUS_BIAS = 0.55
local AHEAD = 900 -- até onde o túnel vai à frente da nave
local BEHIND = 500 -- e atrás: a câmera de perseguição tem que caber aqui

local STREAK_SPEED_MIN = 900
local STREAK_SPEED_MAX = 2400
local STREAK_LENGTH_MIN = 45
local STREAK_LENGTH_MAX = 190
local STREAK_THICK_MIN = 0.3
local STREAK_THICK_MAX = 1.1

local SPIN_RATE = 0.35 -- rad/s de giro do túnel em torno do próprio eixo

-- Fases de Play(). O marco é o TELEPORTE: entrada, cruzeiro, teleporte (com
-- flash e estouro juntos) e a dissolução do que sobrar. O cruzeiro é a folga.
local ENTRY_TIME = 0.45
local MIN_CRUISE = 0.4
local MIN_EXIT = 0.35 -- dissolução mínima depois do teleporte
local FLASH_DECAY = 0.4 -- quanto o flash leva pra apagar

local FOV_PUNCH = 30
local FOV_RETURN = TweenInfo.new(0.5, Enum.EasingStyle.Quart, Enum.EasingDirection.Out)

local CHARGE_CEILING = 0.2 -- intensidade máxima durante a carga

-- Áudio: uma trilha de 17s cujo estouro está no segundo 12. 2D (filha do
-- SoundService), só o piloto ouve.
local SOUND_WARP = "rbxassetid://126087950396291"
local SOUND_TELEPORT_AT = 12 -- segundo da trilha em que o teleporte acontece
local SOUND_LENGTH = 17 -- duração da trilha (usado se o TimeLength ainda não carregou)

-- Envelope de volume, em três trechos até o teleporte e a cauda depois:
--
--   volume
--    PEAK ┤                     ╭╮
--         │                ╭────╯ ╲__
--   ENTRY ┤            ╭───╯         ╲___
--         │            │ ← degrau: entrada no túnel
--    PREP ┤      ╭─────╯                 ╲___
--   START ┤ ─────╯                           ╲
--         └── carga ───┴─ viagem ──┴─ cauda (5s) ─▶
--                   túnel abre   teleporte
--
-- A carga sobe pouco (START → PREP), de propósito: é ela que abre espaço pro
-- degrau da entrada ser ouvido.
local SOUND_START_VOLUME = 0.03 -- quase inaudível: a carga nasce do silêncio
local SOUND_PREP_VOLUME = 0.28 -- fim da carga
local SOUND_ENTRY_VOLUME = 0.75 -- logo depois do túnel abrir
local SOUND_PEAK_VOLUME = 1 -- no estouro
-- Degrau da entrada: rápido e com Out, pra bater junto com o flash e o FOV
local SOUND_ENTRY_BOOST = TweenInfo.new(0.45, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
-- Quad In: fica baixo boa parte do tempo e acelera no fim de cada rampa
local SOUND_RAMP_STYLE = Enum.EasingStyle.Quad
-- Quad In também na descida: segura o estouro alto e só depois vai sumindo
local SOUND_TAIL_STYLE = Enum.EasingStyle.Quad
local SOUND_FADE_OUT = TweenInfo.new(0.35, Enum.EasingStyle.Sine, Enum.EasingDirection.In)
-- Se a trilha estiver mais longe que isso de onde deveria no início da
-- viagem (latência, carga que chegou atrasada), reposiciona
local SOUND_RESYNC_TOLERANCE = 0.15

local RENDER_NAME = "WarpTunnel"
-- Depois da câmera: se o script da nave mexer no FOV, quem escreve por último
-- é a gente
local RENDER_PRIORITY = Enum.RenderPriority.Camera.Value + 10

local WarpTunnel = {}
WarpTunnel.__index = WarpTunnel

local function easeOut(alpha: number): number
	return 1 - (1 - alpha) ^ 3
end

local function easeIn(alpha: number): number
	return alpha * alpha * alpha
end

local function randomBetween(min: number, max: number): number
	return min + math.random() * (max - min)
end

function WarpTunnel.new()
	local self = setmetatable({}, WarpTunnel)

	self._intensity = 0
	self._charge = 0
	self._spin = 0
	self._playing = nil :: { started: number, duration: number, entry: number, exit: number, jumpAt: number }?
	self._baseFov = nil :: number?
	self._lockedRotation = nil :: CFrame?
	self._ship = nil :: Model?
	self._rendering = false
	self._streaks = {}

	self:_buildFlash()
	self:_buildSounds()
	return self
end

-- ═══════════════════════════════════════════════════════════
-- Tela: só o flash. O resto é mundo.
-- ═══════════════════════════════════════════════════════════

function WarpTunnel:_buildFlash()
	local gui = Instance.new("ScreenGui")
	gui.Name = "WarpTunnelFlash"
	gui.ResetOnSpawn = false
	gui.IgnoreGuiInset = true
	gui.DisplayOrder = 4 -- abaixo das HUDs: o piloto continua lendo a barra
	gui.Enabled = false
	gui.Parent = playerGui
	self._gui = gui

	local flash = Instance.new("Frame")
	flash.Name = "Flash"
	flash.Size = UDim2.fromScale(1, 1)
	flash.BackgroundColor3 = Color3.new(1, 1, 1)
	flash.BackgroundTransparency = 1
	flash.BorderSizePixel = 0
	flash.Parent = gui
	self._flash = flash
end

--- A trilha vive a sessão inteira: criar no warp atrasaria o primeiro toque,
--- e destruir quando o túnel some cortaria a cauda (os 5s depois do estouro).
function WarpTunnel:_buildSounds()
	local sound = Instance.new("Sound")
	sound.Name = "WarpTrack"
	sound.SoundId = SOUND_WARP
	sound.Volume = SOUND_START_VOLUME
	sound.Parent = SoundService
	self._sound = sound
end

-- ═══════════════════════════════════════════════════════════
-- Mundo (filho da Camera: renderiza, não replica e não colide)
-- ═══════════════════════════════════════════════════════════

local function decorate(part: BasePart)
	part.Anchored = true
	part.CanCollide = false
	part.CanQuery = false
	part.CanTouch = false
	part.CastShadow = false
	part.Locked = true
	part.Massless = true
	part.Material = Enum.Material.Neon
end

--- Sorteia de novo onde o risco entra no túnel. Chamado no nascimento e toda
--- vez que ele passa por trás da câmera.
local function recycle(streak, z: number?)
	streak.angle = math.random() * math.pi * 2
	streak.radius = RADIUS_MIN + (RADIUS_MAX - RADIUS_MIN) * math.random() ^ RADIUS_BIAS
	streak.speed = randomBetween(STREAK_SPEED_MIN, STREAK_SPEED_MAX)
	streak.length = randomBetween(STREAK_LENGTH_MIN, STREAK_LENGTH_MAX)
	streak.thickness = randomBetween(STREAK_THICK_MIN, STREAK_THICK_MAX)
	streak.alpha = randomBetween(0.45, 1)
	streak.z = z or AHEAD
end

function WarpTunnel:_world(): Folder?
	local camera = workspace.CurrentCamera
	if not camera then
		return nil
	end

	local folder = self._folder
	if folder and folder.Parent ~= camera then
		folder:Destroy()
		folder = nil
		self._folder = nil
	end
	if folder then
		return folder
	end

	folder = Instance.new("Folder")
	folder.Name = "WarpTunnel"

	-- Riscos
	self._streaks = {}
	for i = 1, STREAK_COUNT do
		local part = Instance.new("Part")
		part.Name = "Streak" .. i
		part.Size = Vector3.new(0.4, 0.4, 60)
		part.Color = CORE_COLOR:Lerp(EDGE_COLOR, math.random())
		part.Transparency = 1
		decorate(part)
		part.Parent = folder

		local streak = { part = part }
		-- Espalhados no comprimento todo desde o começo: o túnel já nasce cheio
		recycle(streak, randomBetween(-BEHIND, AHEAD))
		table.insert(self._streaks, streak)
	end

	-- Poeira: densidade fina que os riscos sozinhos não dão
	local dust = Instance.new("Part")
	dust.Name = "Dust"
	dust.Size = Vector3.new(RADIUS_MAX * 2, RADIUS_MAX * 2, 40)
	dust.Transparency = 1
	decorate(dust)
	dust.Parent = folder
	self._dust = dust

	local emitter = Instance.new("ParticleEmitter")
	emitter.Name = "Motes"
	emitter.Orientation = Enum.ParticleOrientation.VelocityParallel
	emitter.Squash = NumberSequence.new(9)
	emitter.Size = NumberSequence.new(1.2)
	emitter.Color = ColorSequence.new(CORE_COLOR, EDGE_COLOR)
	emitter.Transparency = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 1),
		NumberSequenceKeypoint.new(0.2, 0.15),
		NumberSequenceKeypoint.new(0.8, 0.3),
		NumberSequenceKeypoint.new(1, 1),
	})
	emitter.LightEmission = 1
	emitter.LightInfluence = 0
	emitter.Lifetime = NumberRange.new(0.5, 0.9)
	emitter.Speed = NumberRange.new(900, 1600)
	emitter.SpreadAngle = Vector2.new(4, 4)
	-- Back = +Z do Part; o eixo aponta pra frente em -Z, então os motes voltam
	emitter.EmissionDirection = Enum.NormalId.Back
	emitter.Drag = 0
	-- Acompanha o eixo: sem isso o PivotTo do teleporte abre um buraco
	emitter.LockedToPart = true
	emitter.Rate = 0
	emitter.Parent = dust
	self._emitter = emitter

	folder.Parent = camera
	self._folder = folder
	return folder
end

function WarpTunnel:_effects()
	if self._bloom then
		return
	end

	local bloom = Instance.new("BloomEffect")
	bloom.Name = "WarpTunnelBloom"
	bloom.Intensity = 0
	bloom.Size = 40
	bloom.Threshold = 0.9
	bloom.Parent = Lighting
	self._bloom = bloom

	local correction = Instance.new("ColorCorrectionEffect")
	correction.Name = "WarpTunnelColor"
	correction.Brightness = 0
	correction.Contrast = 0
	correction.Saturation = 0
	correction.TintColor = Color3.new(1, 1, 1)
	correction.Parent = Lighting
	self._correction = correction
end

function WarpTunnel:_teardown()
	if self._folder then
		self._folder:Destroy()
		self._folder = nil
		self._dust = nil
		self._emitter = nil
		self._streaks = {}
	end
	for _, key in { "_bloom", "_correction" } do
		local effect = self[key]
		if effect then
			effect:Destroy()
			self[key] = nil
		end
	end
	self._gui.Enabled = false
end

-- ═══════════════════════════════════════════════════════════
-- Controle
-- ═══════════════════════════════════════════════════════════

--- A nave que faz o salto: é nela que o túnel fica centrado.
function WarpTunnel:SetShip(ship: Model?)
	self._ship = ship
end

--- Build-up visual durante a carga. alpha 0..1; 0 desliga.
function WarpTunnel:SetCharge(alpha: number)
	self._charge = math.clamp(alpha, 0, 1)
	if self._charge > 0 then
		self:_startRender()
	end
end

--[[
	Começo da carga: solta a trilha, baixinha, e começa a subir o volume.

	Ela não começa do zero — começa no ponto em que, somando a carga desta nave
	e a viagem até o teleporte, o segundo 12 cai no teleporte:

	    início = 12 - (carga + jumpAt)

	    carga 2s → começa em 7.4s     carga 3s → 6.4s     carga 6s → 3.4s

	Na carga o volume sobe pouco (START → PREP); o grosso da subida fica pro
	Play(), que dá o degrau da entrada no túnel.
]]
function WarpTunnel:BeginCharge(chargeTime: number, jumpAt: number)
	self._tailToken = nil -- um warp novo anula a cauda de um anterior
	self:_setVolume(SOUND_START_VOLUME, nil)
	self:_playTrackAt(SOUND_TELEPORT_AT - (chargeTime + jumpAt))
	self:_rampTo(SOUND_PREP_VOLUME, chargeTime)
end

--[[
	Entrada no túnel: degrau rápido até ENTRY e, emendado nele, a rampa final
	até o PEAK, que termina no teleporte.

	A emenda é pelo Completed do degrau: se qualquer coisa cancelar o degrau
	no meio (warp cancelado, outro warp), a rampa final nem começa.
]]
function WarpTunnel:_boostEntry(untilTeleport: number)
	self:_setVolume(SOUND_ENTRY_VOLUME, SOUND_ENTRY_BOOST)
	local boost = self._volumeTween
	if not boost then
		return
	end

	local remaining = untilTeleport - SOUND_ENTRY_BOOST.Time
	boost.Completed:Connect(function(state)
		if state == Enum.PlaybackState.Completed and self._volumeTween == boost then
			self:_rampTo(SOUND_PEAK_VOLUME, remaining)
		end
	end)
end

--- Sobe o volume até o pico, devagar no começo, em `seconds`.
function WarpTunnel:_rampTo(volume: number, seconds: number)
	self:_setVolume(volume, TweenInfo.new(math.max(seconds, 0.05), SOUND_RAMP_STYLE, Enum.EasingDirection.In))
end

--- Toca a trilha a partir de um ponto. Negativo não existe: a carga seria mais
--- longa que os 12s de trilha antes do estouro, e aí ela só começa do zero.
function WarpTunnel:_playTrackAt(position: number)
	local sound = self._sound
	if self._fadeTween then
		self._fadeTween:Cancel()
		self._fadeTween = nil
	end
	sound.TimePosition = math.max(position, 0)
	if not sound.IsPlaying then
		sound:Play()
	end
end

function WarpTunnel:_setVolume(volume: number, info: TweenInfo?)
	if self._volumeTween then
		self._volumeTween:Cancel()
		self._volumeTween = nil
	end
	if info then
		self._volumeTween = TweenService:Create(self._sound, info, { Volume = volume })
		self._volumeTween:Play()
	else
		self._sound.Volume = volume
	end
end

--[[
	O salto inteiro. duration e jumpAt vêm do servidor: jumpAt é o instante,
	dentro da viagem, em que a nave troca de lugar de verdade.

	É nele que o flash cai (junto com o estouro da trilha), e é dele que a
	dissolução começa — o túnel não fica sobrando depois do teleporte.
]]
function WarpTunnel:Play(duration: number, jumpAt: number?)
	local total = math.max(duration, ENTRY_TIME + MIN_CRUISE + MIN_EXIT)
	local jump = math.clamp(jumpAt or (total - MIN_EXIT), ENTRY_TIME, total - MIN_EXIT)

	self._playing = {
		started = os.clock(),
		duration = total,
		entry = ENTRY_TIME,
		exit = total - jump,
		jumpAt = jump,
	}
	self._charge = 0

	-- Aqui a gente sabe EXATAMENTE quanto falta pro teleporte. Se a trilha
	-- escorregou na carga (ou nem tocou), acerta a posição; senão não mexe,
	-- pra não dar clique no som.
	local expected = SOUND_TELEPORT_AT - jump
	local sound = self._sound
	if not sound.IsPlaying or math.abs(sound.TimePosition - expected) > SOUND_RESYNC_TOLERANCE then
		self:_playTrackAt(expected)
	end
	self:_boostEntry(jump)

	-- No teleporte, começa a descida até o fim da trilha
	local token = {}
	self._tailToken = token
	task.delay(jump, function()
		if self._tailToken ~= token then
			return -- cancelado ou substituído por outro warp
		end
		self._tailToken = nil
		local length = if sound.TimeLength > 0 then sound.TimeLength else SOUND_LENGTH
		local remaining = math.max(length - sound.TimePosition, 0.3)
		self:_fadeOutTrack(TweenInfo.new(remaining, SOUND_TAIL_STYLE, Enum.EasingDirection.In))
	end)

	-- Trava a direção agora: daqui pra frente o túnel só acompanha a POSIÇÃO
	-- da nave. Assim o PivotTo do teleporte passa despercebido e dá pra olhar
	-- em volta sem o túnel girar junto com a câmera.
	self._lockedRotation = self:_rotation()

	local camera = workspace.CurrentCamera
	if camera and not self._baseFov then
		self._baseFov = camera.FieldOfView
	end

	self:_startRender()
end

--- Aborta (warp cancelado/interrompido) e devolve tudo ao normal.
function WarpTunnel:Stop()
	self._playing = nil
	self._charge = 0
	self._intensity = 0
	self._lockedRotation = nil
	self._tailToken = nil
	self:_fadeOutTrack(SOUND_FADE_OUT)
	self:_restoreFov()
	self:_stopRender()
	self:_teardown()
end

--- Leva o volume a zero e para a trilha no fim. Serve pro cancelamento
--- (rápido) e pra cauda depois do teleporte (lenta, até o fim do arquivo).
function WarpTunnel:_fadeOutTrack(info: TweenInfo)
	local sound = self._sound
	if not sound.IsPlaying then
		return
	end
	if self._volumeTween then
		self._volumeTween:Cancel()
		self._volumeTween = nil
	end
	if self._fadeTween then
		self._fadeTween:Cancel()
		self._fadeTween = nil
	end
	local tween = TweenService:Create(sound, info, { Volume = 0 })
	self._fadeTween = tween
	tween.Completed:Connect(function(state)
		if state == Enum.PlaybackState.Completed and self._fadeTween == tween then
			self._fadeTween = nil
			sound:Stop()
		end
	end)
	tween:Play()
end

function WarpTunnel:IsPlaying(): boolean
	return self._playing ~= nil
end

function WarpTunnel:_restoreFov()
	local camera = workspace.CurrentCamera
	if camera and self._baseFov then
		TweenService:Create(camera, FOV_RETURN, { FieldOfView = self._baseFov }):Play()
	end
	self._baseFov = nil
end

function WarpTunnel:_startRender()
	if self._rendering then
		return
	end
	self._rendering = true
	self:_effects()
	RunService:BindToRenderStep(RENDER_NAME, RENDER_PRIORITY, function(dt)
		self:_step(dt)
	end)
end

function WarpTunnel:_stopRender()
	if not self._rendering then
		return
	end
	self._rendering = false
	RunService:UnbindFromRenderStep(RENDER_NAME)
end

-- ═══════════════════════════════════════════════════════════
-- Eixo do túnel
-- ═══════════════════════════════════════════════════════════

function WarpTunnel:_body(): BasePart?
	local ship = self._ship
	if not ship or not ship.Parent then
		return nil
	end
	local body = ship:FindFirstChild(ShipData.PARTS.body)
	return if body and body:IsA("BasePart") then body else nil
end

--- Pra onde o túnel aponta. Durante a carga segue o nariz da nave (que está
--- girando pro destino); no salto já está travada.
function WarpTunnel:_rotation(): CFrame
	if self._lockedRotation then
		return self._lockedRotation
	end

	local body = self:_body()
	if body then
		return body.CFrame.Rotation
	end

	local camera = workspace.CurrentCamera
	return if camera then camera.CFrame.Rotation else CFrame.identity
end

--- Centro do túnel: a nave. Sem ela (destruída no meio), a câmera segura.
function WarpTunnel:_origin(): CFrame?
	local body = self:_body()
	if body then
		return CFrame.new(body.Position) * self:_rotation()
	end

	local camera = workspace.CurrentCamera
	if camera then
		return CFrame.new(camera.CFrame.Position) * self:_rotation()
	end
	return nil
end

-- ═══════════════════════════════════════════════════════════
-- Frame
-- ═══════════════════════════════════════════════════════════

--- Intensidade alvo: a fase do salto manda; sem salto, sobra o build-up.
function WarpTunnel:_target(): number
	local play = self._playing
	if not play then
		return CHARGE_CEILING * self._charge * self._charge
	end

	local elapsed = os.clock() - play.started
	if elapsed >= play.duration then
		self._playing = nil
		self._lockedRotation = nil
		self:_restoreFov()
		return 0
	end

	if elapsed < play.entry then
		return easeOut(elapsed / play.entry)
	end

	local exitStart = play.duration - play.exit
	if elapsed > exitStart then
		return 1 - easeIn((elapsed - exitStart) / play.exit)
	end

	-- Cruzeiro: pulsa de leve pra não ficar um quadro parado
	return 0.94 + 0.06 * math.sin(elapsed * 9)
end

function WarpTunnel:_flashAmount(): number
	local play = self._playing
	if not play then
		return 0
	end
	local elapsed = os.clock() - play.started

	if elapsed < 0.22 then
		return (1 - elapsed / 0.22) * 0.8
	end

	-- Teleporte: o clarão que cobre a troca de lugar
	if elapsed >= play.jumpAt then
		local alpha = math.clamp((elapsed - play.jumpAt) / FLASH_DECAY, 0, 1)
		return (1 - alpha) * 0.85
	end

	return 0
end

function WarpTunnel:_step(dt: number)
	local target = self:_target()

	-- Sobe rápido, desce liso: o salto tem que bater e a chegada, assentar
	local rate = if target > self._intensity then 14 else 5
	self._intensity += (target - self._intensity) * math.min(dt * rate, 1)

	local intensity = self._intensity
	if intensity <= 0.002 and not self._playing and self._charge <= 0 then
		self._intensity = 0
		self:_stopRender()
		self:_teardown()
		return
	end

	self._spin = (self._spin + dt * SPIN_RATE * intensity) % (math.pi * 2)

	self:_stepTunnel(dt, intensity)
	self:_stepScreen(intensity)
end

function WarpTunnel:_stepTunnel(dt: number, intensity: number)
	local folder = self:_world()
	local origin = self:_origin()
	if not folder or not origin then
		return
	end

	local frame = origin * CFrame.Angles(0, 0, self._spin)
	-- Parado em 15% da velocidade durante a carga; a 100% no salto
	local flow = dt * (0.15 + 0.85 * intensity)

	for _, streak in self._streaks do
		streak.z -= streak.speed * flow
		if streak.z < -BEHIND then
			recycle(streak)
		end

		local thickness = streak.thickness * (0.6 + 0.4 * intensity)
		local part = streak.part
		part.Size = Vector3.new(thickness, thickness, streak.length * (0.2 + 0.8 * intensity))
		part.CFrame = frame
			* CFrame.new(math.cos(streak.angle) * streak.radius, math.sin(streak.angle) * streak.radius, -streak.z)
		part.Transparency = 1 - math.clamp(intensity * streak.alpha, 0, 1)
	end

	if self._dust then
		self._dust.CFrame = frame * CFrame.new(0, 0, -AHEAD * 0.5)
	end
	if self._emitter then
		self._emitter.Rate = 450 * intensity
	end
end

function WarpTunnel:_stepScreen(intensity: number)
	local flash = self:_flashAmount()
	self._gui.Enabled = flash > 0.001
	self._flash.BackgroundTransparency = 1 - flash

	if self._bloom then
		self._bloom.Intensity = 1.6 * intensity
	end
	if self._correction then
		self._correction.TintColor = Color3.new(1, 1, 1):Lerp(EDGE_COLOR, 0.22 * intensity)
		self._correction.Saturation = -0.12 * intensity
		self._correction.Contrast = 0.14 * intensity
	end

	-- FOV só no salto: durante a carga a câmera fica quieta
	local camera = workspace.CurrentCamera
	if camera and self._baseFov and self._playing then
		camera.FieldOfView = self._baseFov + FOV_PUNCH * intensity
	end
end

return WarpTunnel
