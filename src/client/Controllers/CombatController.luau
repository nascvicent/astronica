--[[
	CombatController
	Lado visual do combate entre naves. Nada aqui decide acerto nem dano: o
	CombatService manda, este controller desenha.

	  - Traçado dos tiros (ShotFired): cada client anda o projétil com o mesmo
	    CastShot do servidor, a partir da posição LOCAL do Muzzle — o piloto
	    não vê o tiro nascer atrás da própria nave por causa do ping
	  - Som de disparo, brilho e som de superaquecimento (atributos da nave)
	  - Painel do piloto: casco e calor (CombatHUD)
	  - Marcador de acerto, flash de dano e mensagem de abate
	  - Etiqueta de casco sobre as naves pilotadas por outros jogadores
	  - Rede de segurança pós-destruição: se algo do voo sobrou (câmera,
	    mouse preso, mira, HUD de velocidade), limpa ao reaparecer

	Local: src/client/Controllers/CombatController.luau
]]

local Knit = require(game:GetService("ReplicatedStorage").Packages.Knit)
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local CollectionService = game:GetService("CollectionService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")
local UserInputService = game:GetService("UserInputService")

local ShipData = require(ReplicatedStorage.Shared.ShipData)
local PlaceConfig = require(ReplicatedStorage.Shared.PlaceConfig)
local CombatConfig = require(ReplicatedStorage.Shared.CombatConfig)

local UI = script.Parent.Parent.UI
local CombatHUD = require(UI.CombatHUD)
local UIStyle = require(UI.UIStyle)

local player = Players.LocalPlayer

local SHOT_SOUND_ID = "rbxassetid://110409606986302"
local OVERHEAT_SOUND_ID = "rbxassetid://139083821951880"

local TRACER_COLOR = Color3.fromRGB(4, 175, 236) -- BrickColor "Cyan" do tiro antigo
local TRACER_SIZE = Vector3.new(10, 0.4, 0.4) -- cilindro: comprimento no eixo X
local MAX_TRACERS = 200
local SPARK_SIZE = 3
local SPARK_FADE = TweenInfo.new(0.18, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)

local OVERHEAT_GLOW = Color3.fromRGB(255, 80, 0)

-- Etiquetas de casco sobre naves inimigas. Tela pequena (celular, altura <=
-- UIStyle.COMPACT_MAX_HEIGHT) usa a versão estreita
local TAG_REFRESH = 0.2
local TAG_MAX_DISTANCE = 1500
local TAG_WIDTH = 120
local TAG_WIDTH_COMPACT = 70
local TAG_NAME_SIZE = 11
local TAG_NAME_SIZE_COMPACT = 9

-- Alerta de casco baixo: cada faixa pulsa uma vez ao ser cruzada pra baixo.
-- Voltar acima da primeira (nave nova, upgrade) rearma tudo
local LOW_HULL_BANDS = {
	{ threshold = 0.3, pulses = 3, text = "CASCO CRÍTICO" },
	{ threshold = 0.15, pulses = 4, text = "CASCO EM COLAPSO" },
}

-- Zona segura do próprio piloto: a checagem varre a HangarZone, não precisa
-- ser por frame
local SAFE_REFRESH = 0.25

type Tracer = {
	part: BasePart,
	position: Vector3,
	direction: Vector3,
	travelled: number,
	params: RaycastParams,
}

local CombatController = Knit.CreateController({
	Name = "CombatController",
})

function CombatController:KnitInit()
	self._hud = CombatHUD.new()
	self._tracers = {} :: { Tracer }
	self._fx = {} :: { [Model]: { conns: { RBXScriptConnection }, glows: { Instance }, sound: Sound? } }
	self._tags = {} :: { [Model]: any }
	self._tagTimer = 0
	self._safeTimer = 0
	self._inSafeZone = false
	self._inHangar = false
	self._flightCleanupPending = false
	self._lowHullShip = nil :: Model?
	self._lowHullBand = 0
end

function CombatController:KnitStart()
	if not CombatConfig.IsCombatPlace() then
		return
	end

	self._shipController = Knit.GetController("ShipController")
	local service = Knit.GetService("CombatService")

	local folder = Instance.new("Folder")
	folder.Name = "ShotTracers"
	folder.Parent = workspace
	self._folder = folder

	service.ShotFired:Connect(function(model, shots)
		self:_onShotFired(model, shots)
	end)
	service.HitConfirmed:Connect(function(_damage, destroyed)
		self._hud:ShowHit(destroyed == true)
	end)
	service.DamageTaken:Connect(function(damage)
		self:_onDamageTaken(damage)
	end)
	service.ShipDestroyed:Connect(function(isVictim, otherName)
		self:_onShipDestroyed(isVictim, otherName)
	end)

	CollectionService:GetInstanceAddedSignal(ShipData.SHIP_TAG):Connect(function(model)
		self:_bindShipFx(model)
	end)
	CollectionService:GetInstanceRemovedSignal(ShipData.SHIP_TAG):Connect(function(model)
		self:_unbindShipFx(model)
	end)
	for _, model in CollectionService:GetTagged(ShipData.SHIP_TAG) do
		self:_bindShipFx(model)
	end

	player.CharacterAdded:Connect(function(character)
		if self._flightCleanupPending then
			self._flightCleanupPending = false
			self:_cleanupFlight(character)
		end
	end)

	RunService.RenderStepped:Connect(function(dt)
		self:_stepTracers(dt)
		self:_updateHud(dt)
		self:_updateTags(dt)
	end)
end

-- ═══════════════════════════════════════════════════════════
-- Tiros
-- ═══════════════════════════════════════════════════════════

local function playShotSound(muzzle: Instance)
	local sound = muzzle:FindFirstChild("CombatShotSound")
	if not sound then
		sound = Instance.new("Sound")
		sound.Name = "CombatShotSound"
		sound.SoundId = SHOT_SOUND_ID
		sound.Volume = 1
		sound.RollOffMaxDistance = 500
		sound.Parent = muzzle
	end
	;(sound :: Sound):Play()
end

function CombatController:_onShotFired(model: Model?, shots: any)
	if typeof(model) ~= "Instance" or not model:IsA("Model") or typeof(shots) ~= "table" then
		return -- nave fora do streaming deste client
	end

	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	-- Igual ao servidor: a própria nave e o piloto dela não bloqueiam o tiro
	local pilot = CombatConfig.GetPilot(model)
	params.FilterDescendantsInstances = { model, self._folder, pilot and pilot.Character :: Instance }

	for _, shot in shots do
		local muzzle = shot.muzzle
		local direction = shot.direction
		if typeof(muzzle) ~= "Instance" or typeof(direction) ~= "Vector3" or not muzzle:IsDescendantOf(model) then
			continue
		end

		playShotSound(muzzle)

		if #self._tracers >= MAX_TRACERS then
			continue
		end

		local position = CombatConfig.GetMuzzlePosition(muzzle)
		local part = Instance.new("Part")
		part.Name = "Tracer"
		part.Shape = Enum.PartType.Cylinder
		part.Size = TRACER_SIZE
		part.Color = TRACER_COLOR
		part.Material = Enum.Material.Neon
		part.Anchored = true
		part.CanCollide = false
		part.CanQuery = false
		part.CanTouch = false
		part.CastShadow = false
		part.CFrame = CFrame.lookAt(position, position + direction) * CFrame.Angles(0, math.pi / 2, 0)
		part.Parent = self._folder

		table.insert(self._tracers, {
			part = part,
			position = position,
			direction = direction,
			travelled = 0,
			params = params,
		})
	end
end

function CombatController:_spark(position: Vector3)
	local spark = Instance.new("Part")
	spark.Name = "Spark"
	spark.Shape = Enum.PartType.Ball
	spark.Size = Vector3.one * SPARK_SIZE
	spark.Color = TRACER_COLOR
	spark.Material = Enum.Material.Neon
	spark.Anchored = true
	spark.CanCollide = false
	spark.CanQuery = false
	spark.CanTouch = false
	spark.CastShadow = false
	spark.Position = position
	spark.Parent = self._folder

	local tween = TweenService:Create(spark, SPARK_FADE, { Size = Vector3.one * SPARK_SIZE * 2.5, Transparency = 1 })
	tween.Completed:Connect(function()
		spark:Destroy()
	end)
	tween:Play()
end

--- Mesmo passo do servidor: true = acabou.
function CombatController:_stepTracer(tracer: Tracer, dt: number): boolean
	local remaining = math.min(CombatConfig.PROJECTILE_SPEED * dt, CombatConfig.PROJECTILE_RANGE - tracer.travelled)

	while remaining > 0 do
		local step = math.min(remaining, 1000)
		local result = CombatConfig.CastShot(tracer.position, tracer.direction * step, tracer.params)
		if result then
			self:_spark(result.Position)
			return true
		end
		tracer.position += tracer.direction * step
		tracer.travelled += step
		remaining -= step
	end

	tracer.part.CFrame = CFrame.lookAt(tracer.position, tracer.position + tracer.direction)
		* CFrame.Angles(0, math.pi / 2, 0)
	return tracer.travelled >= CombatConfig.PROJECTILE_RANGE
end

function CombatController:_stepTracers(dt: number)
	local tracers = self._tracers
	local i = 1
	while i <= #tracers do
		local tracer = tracers[i]
		if self:_stepTracer(tracer, dt) then
			tracer.part:Destroy()
			tracers[i] = tracers[#tracers]
			tracers[#tracers] = nil
		else
			i += 1
		end
	end
end

-- ═══════════════════════════════════════════════════════════
-- Superaquecimento (qualquer nave, visto por todos)
-- ═══════════════════════════════════════════════════════════

function CombatController:_setOverheatFx(model: Model, fx, active: boolean)
	for _, glow in fx.glows do
		glow:Destroy()
	end
	table.clear(fx.glows)

	if active then
		for _, muzzle in CombatConfig.GetMuzzles(model) do
			local glow = Instance.new("PointLight")
			glow.Name = "OverheatGlow"
			glow.Color = OVERHEAT_GLOW
			glow.Brightness = 3
			glow.Range = 12
			glow.Parent = muzzle
			table.insert(fx.glows, glow)
		end

		local body = CombatConfig.GetBody(model)
		if body then
			if not fx.sound then
				local sound = Instance.new("Sound")
				sound.Name = "CombatOverheatSound"
				sound.SoundId = OVERHEAT_SOUND_ID
				sound.Volume = 1.5
				sound.RollOffMaxDistance = 300
				sound.Parent = body
				fx.sound = sound
			end
			fx.sound:Play()
		end
	elseif fx.sound then
		fx.sound:Stop()
	end
end

function CombatController:_bindShipFx(model: Instance)
	if not model:IsA("Model") or self._fx[model] then
		return
	end

	local fx = { conns = {}, glows = {}, sound = nil }
	self._fx[model] = fx

	table.insert(fx.conns, model:GetAttributeChangedSignal(CombatConfig.OVERHEATED_ATTRIBUTE):Connect(function()
		self:_setOverheatFx(model, fx, model:GetAttribute(CombatConfig.OVERHEATED_ATTRIBUTE) == true)
	end))
	if model:GetAttribute(CombatConfig.OVERHEATED_ATTRIBUTE) == true then
		self:_setOverheatFx(model, fx, true)
	end
end

function CombatController:_unbindShipFx(model: Instance)
	local fx = self._fx[model :: Model]
	if not fx then
		return
	end
	self._fx[model :: Model] = nil
	for _, conn in fx.conns do
		conn:Disconnect()
	end
	for _, glow in fx.glows do
		glow:Destroy()
	end
	if fx.sound then
		fx.sound:Destroy()
	end
	self:_removeTag(model :: Model)
end

-- ═══════════════════════════════════════════════════════════
-- Painel do piloto
-- ═══════════════════════════════════════════════════════════

local function readNumber(model: Model, name: string): number?
	local config = model:FindFirstChild(ShipData.PARTS.configurations)
	local value = config and config:FindFirstChild(name)
	return if value and value:IsA("NumberValue") then value.Value else nil
end

local function gunsEnabled(model: Model): boolean
	local config = model:FindFirstChild(ShipData.PARTS.configurations)
	local value = config and config:FindFirstChild("GunsEnabled")
	return value ~= nil and value:IsA("BoolValue") and value.Value
end

--- Nave que o jogador local está pilotando agora, ou nil.
function CombatController:_getPilotedShip(): Model?
	local ship = self._shipController:GetOwnShip()
	local character = player.Character
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	local seat = humanoid and humanoid.SeatPart
	if ship and seat and seat:IsDescendantOf(ship) then
		return ship
	end
	return nil
end

function CombatController:_updateHud(dt: number)
	local ship = self:_getPilotedShip()
	self._hud:SetVisible(ship ~= nil)
	if not ship then
		return
	end

	local max = readNumber(ship, "MaxHull") or 0
	local hull = readNumber(ship, "Hull") or max
	self._hud:SetHull(hull, max)
	self:_updateLowHull(ship, if max > 0 then hull / max else 1)

	self._safeTimer -= dt
	if self._safeTimer <= 0 then
		self._safeTimer = SAFE_REFRESH
		local position = CombatConfig.GetShipPosition(ship)
		self._inSafeZone = CombatConfig.IsInSafeZone(position)
		self._inHangar = PlaceConfig.IsInHangarZone(position)
	end

	local heat = ship:GetAttribute(CombatConfig.HEAT_ATTRIBUTE)
	local status = nil
	if not gunsEnabled(ship) then
		status = "offline"
	elseif ship:GetAttribute(CombatConfig.OVERHEATED_ATTRIBUTE) == true then
		status = "overheated"
	elseif self._inHangar or ship:GetAttribute(ShipData.DOCKED_ATTRIBUTE) == true then
		status = "hangar"
	elseif self._inSafeZone then
		status = "safe"
	end
	self._hud:SetWeapons(if typeof(heat) == "number" then heat else 0, status)
end

function CombatController:_updateLowHull(ship: Model, fraction: number)
	if ship ~= self._lowHullShip then
		self._lowHullShip = ship
		self._lowHullBand = 0
	end

	-- Faixa mais funda em que o casco está agora
	local band = 0
	for i, def in LOW_HULL_BANDS do
		if fraction > 0 and fraction <= def.threshold then
			band = i
		end
	end

	if band > self._lowHullBand then
		local def = LOW_HULL_BANDS[band]
		self._hud:PulseWarning(def.pulses)
		self._hud:ShowMessage(def.text, UIStyle.C.negative, 2)
	end
	-- Só desce a marca quando o casco sobe de verdade: oscilar na borda não
	-- repete o alerta
	if band > self._lowHullBand or fraction > LOW_HULL_BANDS[1].threshold then
		self._lowHullBand = band
	end
end

function CombatController:_onDamageTaken(damage: any)
	local ship = self:_getPilotedShip()
	local max = ship and readNumber(ship, "MaxHull")
	local share = if typeof(damage) == "number" and max and max > 0 then damage / max else 0.1
	self._hud:ShowDamage(share * 2)
end

function CombatController:_onShipDestroyed(isVictim: any, otherName: any)
	local name = if typeof(otherName) == "string" then otherName else nil
	if isVictim == true then
		self._flightCleanupPending = true
		local text = if name then "DESTRUÍDA POR " .. name else "NAVE DESTRUÍDA"
		self._hud:ShowMessage(text, UIStyle.C.negative, 4)
	else
		local text = if name then "NAVE DE " .. name .. " DESTRUÍDA" else "NAVE DESTRUÍDA"
		self._hud:ShowMessage(text, UIStyle.C.text, 3)
	end
end

-- ═══════════════════════════════════════════════════════════
-- Pós-destruição
-- ═══════════════════════════════════════════════════════════

-- O que o LocalPlaneScript cria e só desfaz no fim do próprio loop de voo
local FLIGHT_LEFTOVERS = { "LocalPlaneScript", "CrosshairGui", "MobileGui", "SpeedHUD_SGui" }
local BASE_FOV = 70

--- Normalmente o LocalPlaneScript se limpa sozinho quando o servidor tira o
--- piloto do assento. Se ele não chegou a rodar o fim (nave sumiu no mesmo
--- frame, lag), a câmera ficaria presa onde a nave explodiu.
function CombatController:_cleanupFlight(character: Model)
	local playerGui = player:FindFirstChildOfClass("PlayerGui")
	if playerGui then
		for _, name in FLIGHT_LEFTOVERS do
			local leftover = playerGui:FindFirstChild(name)
			if leftover then
				leftover:Destroy()
			end
		end
	end
	local speedHud = workspace:FindFirstChild("SpeedHUD")
	if speedHud then
		speedHud:Destroy()
	end

	local camera = workspace.CurrentCamera
	camera.CameraType = Enum.CameraType.Custom
	camera.FieldOfView = BASE_FOV
	local humanoid = character:FindFirstChildOfClass("Humanoid") or character:WaitForChild("Humanoid", 5)
	if humanoid then
		camera.CameraSubject = humanoid
	end

	UserInputService.MouseBehavior = Enum.MouseBehavior.Default
	UserInputService.MouseIconEnabled = true
	UserInputService.ModalEnabled = false
end

-- ═══════════════════════════════════════════════════════════
-- Etiquetas de casco sobre naves inimigas
-- ═══════════════════════════════════════════════════════════

function CombatController:_createTag(model: Model, body: BasePart, pilot: Player)
	local camera = workspace.CurrentCamera
	local compact = UIStyle.IS_MOBILE or (camera ~= nil and camera.ViewportSize.Y <= UIStyle.COMPACT_MAX_HEIGHT)
	local width = if compact then TAG_WIDTH_COMPACT else TAG_WIDTH
	local nameSize = if compact then TAG_NAME_SIZE_COMPACT else TAG_NAME_SIZE

	local gui = Instance.new("BillboardGui")
	gui.Name = "ShipHullTag"
	gui.Adornee = body
	gui.AlwaysOnTop = true
	gui.LightInfluence = 0
	gui.MaxDistance = TAG_MAX_DISTANCE
	gui.Size = UDim2.fromOffset(width, nameSize + 15)
	gui.StudsOffsetWorldSpace = Vector3.new(0, body.Size.Y / 2 + 6, 0)
	gui.ResetOnSpawn = false
	gui.Parent = player:WaitForChild("PlayerGui")

	local name = UIStyle.label(gui, "Name", nameSize, UIStyle.FONT_BOLD, 0)
	name.Size = UDim2.new(1, 0, 0, nameSize + 3)
	name.TextXAlignment = Enum.TextXAlignment.Center
	name.TextTruncate = Enum.TextTruncate.AtEnd
	name.Text = pilot.DisplayName
	local stroke = Instance.new("UIStroke")
	stroke.Color = UIStyle.C.plate
	stroke.Thickness = 1.5
	stroke.Transparency = 0.3
	stroke.Parent = name

	local track = Instance.new("Frame")
	track.Name = "Track"
	track.Position = UDim2.fromOffset(0, nameSize + 7)
	track.Size = UDim2.new(1, 0, 0, if compact then 3 else 4)
	track.BackgroundColor3 = UIStyle.C.plate
	track.BackgroundTransparency = 0.3
	track.BorderSizePixel = 0
	track.Parent = gui
	UIStyle.corner(track, 2)

	local fill = Instance.new("Frame")
	fill.Name = "Fill"
	fill.Size = UDim2.fromScale(1, 1)
	fill.BackgroundColor3 = UIStyle.C.negative
	fill.BorderSizePixel = 0
	fill.Parent = track
	UIStyle.corner(fill, 2)

	self._tags[model] = { gui = gui, fill = fill, pilot = pilot }
end

function CombatController:_removeTag(model: Model)
	local tag = self._tags[model]
	if tag then
		self._tags[model] = nil
		tag.gui:Destroy()
	end
end

function CombatController:_updateTags(dt: number)
	self._tagTimer -= dt
	if self._tagTimer > 0 then
		return
	end
	self._tagTimer = TAG_REFRESH

	for _, model in CollectionService:GetTagged(ShipData.SHIP_TAG) do
		if not model:IsA("Model") or model:GetAttribute(ShipData.OWNER_ATTRIBUTE) == player.UserId then
			continue
		end

		local body = CombatConfig.GetBody(model)
		local pilot = CombatConfig.GetPilot(model)
		local show = body ~= nil
			and pilot ~= nil
			and not CombatConfig.IsInSafeZone(body.Position)

		local tag = self._tags[model]
		if tag and (not show or tag.pilot ~= pilot) then
			self:_removeTag(model)
			tag = nil
		end
		if show and not tag then
			self:_createTag(model, body :: BasePart, pilot :: Player)
			tag = self._tags[model]
		end

		if tag then
			local max = readNumber(model, "MaxHull") or 0
			local hull = readNumber(model, "Hull") or max
			tag.fill.Size = UDim2.fromScale(if max > 0 then math.clamp(hull / max, 0, 1) else 0, 1)
		end
	end
end

return CombatController
