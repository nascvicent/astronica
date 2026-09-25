--[[
	ShipMiningController
	Lado visual da mineração pela nave. Nada aqui decide acerto nem recompensa:
	o ShipMiningService manda, este controller desenha.

	  - Flutuação das rochas (Workspace/Ores): sobe e desce devagar, balança e
	    gira, pela mesma função do servidor (OreConfig.GetMotionCFrame). O
	    servidor nunca move as Parts; só o client, localmente
	  - Acerto: a rocha treme e solta lascas no ponto do tiro
	  - Barra de integridade sobre a rocha que o jogador está minerando
	  - Quebra: a rocha estilhaça e os pedaços derivam no vácuo
	  - Coleta: fragmentos brilhantes voam até a nave e o cartão de coleta
	    (OreCollectHUD) aparece com a descrição do item
	  - Renascimento: a rocha volta aparecendo aos poucos

	Local: src/client/Controllers/ShipMiningController.luau
]]

local Knit = require(game:GetService("ReplicatedStorage").Packages.Knit)
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local CollectionService = game:GetService("CollectionService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")

local OreConfig = require(ReplicatedStorage.Shared.OreConfig)
local CombatConfig = require(ReplicatedStorage.Shared.CombatConfig)
local InventoryModule = require(ReplicatedStorage.Shared.InventoryModule)

local UI = script.Parent.Parent.UI
local OreCollectHUD = require(UI.OreCollectHUD)
local ShipToast = require(UI.ShipToast)
local UIStyle = require(UI.UIStyle)

local player = Players.LocalPlayer

-- Além disto da câmera a rocha não é animada (fica na última pose)
local ANIMATE_DISTANCE = 2500

-- Tremor ao levar tiro
local SHAKE_TIME = 0.3
local SHAKE_AMPLITUDE = 0.35

-- Lascas no ponto do tiro
local CHIPS_PER_HIT = 3
local CHIP_LIFETIME = 1.4
local CHIP_SPEED = { 6, 16 }
local CHIP_SIZE = { 0.5, 1.3 }

-- Estilhaço: cada Part vira um pedaço derivando pra fora
local SHATTER_LIFETIME = 3.2
local SHATTER_SPEED = { 6, 18 }
local SHATTER_SPIN = 1.6 -- rad/s máximo por eixo
local SHATTER_FADE_START = 0.45 -- fração da vida em que começa a sumir

-- Fragmentos que voam pra nave de quem coletou
local SHARD_MAX = 8
local SHARD_SIZE = 0.9
local SHARD_BURST_TIME = 0.45
local SHARD_TIMEOUT = 2.2
local SHARD_ACCEL = 260 -- studs/s² de puxão até a nave

local MAX_DEBRIS = 250

-- Renascimento
local FADE_IN_TIME = 1.6

-- Barra de integridade
local BAR_SHOW_TIME = 3
local BAR_WIDTH = 170

local FAIL_COLOR = UIStyle.C.negative

type OreRig = {
	root: Instance,
	oreId: string?,
	def: OreConfig.OreDef?,
	motion: OreConfig.Motion,
	parts: { BasePart },
	rest: { CFrame },
	transparency: { number },
	center: Vector3,
	radius: number,
	seed: number,
	shakeUntil: number,
	fadeStart: number?,
	hidden: boolean,
	lastPose: CFrame,
	conns: { RBXScriptConnection },
}

type Debris = {
	part: BasePart,
	velocity: Vector3,
	spin: Vector3,
	age: number,
	lifetime: number,
	baseTransparency: number,
	baseSize: Vector3,
	shrink: boolean,
}

type Shard = {
	part: BasePart,
	velocity: Vector3,
	age: number,
	target: BasePart,
	onArrive: (() -> ())?,
}

local ShipMiningController = Knit.CreateController({
	Name = "ShipMiningController",
})

local function randomRange(range: { number }): number
	return range[1] + math.random() * (range[2] - range[1])
end

local function randomUnit(): Vector3
	local v = Vector3.new(math.random() - 0.5, math.random() - 0.5, math.random() - 0.5)
	return if v.Magnitude > 1e-3 then v.Unit else Vector3.yAxis
end

local function fxPart(name: string): Part
	local part = Instance.new("Part")
	part.Name = name
	part.Anchored = true
	part.CanCollide = false
	part.CanQuery = false
	part.CanTouch = false
	part.CastShadow = false
	part.TopSurface = Enum.SurfaceType.Smooth
	part.BottomSurface = Enum.SurfaceType.Smooth
	return part
end

function ShipMiningController:KnitInit()
	self._rigs = {} :: { [Instance]: OreRig }
	self._debris = {} :: { Debris }
	self._shards = {} :: { Shard }
	self._hud = OreCollectHUD.new()
	self._toast = ShipToast.new()
	self._bar = nil :: any
end

function ShipMiningController:KnitStart()
	local service = Knit.GetService("ShipMiningService")

	local folder = Instance.new("Folder")
	folder.Name = "OreFx"
	folder.Parent = workspace
	self._folder = folder

	self:_buildBar()

	CollectionService:GetInstanceAddedSignal(OreConfig.TAG):Connect(function(root)
		self:_bind(root)
	end)
	CollectionService:GetInstanceRemovedSignal(OreConfig.TAG):Connect(function(root)
		self:_unbind(root)
	end)
	for _, root in CollectionService:GetTagged(OreConfig.TAG) do
		self:_bind(root)
	end

	service.OreHit:Connect(function(root, position, shooter)
		self:_onHit(root, position, shooter)
	end)
	service.OreDepleted:Connect(function(root)
		self:_onDepleted(root)
	end)
	service.OreCollected:Connect(function(root, itemId, amount)
		self:_onCollected(root, itemId, amount)
	end)
	service.OreFailed:Connect(function(message)
		if typeof(message) == "string" then
			self._toast:Flash(message, 3, FAIL_COLOR)
		end
	end)

	RunService.RenderStepped:Connect(function(dt)
		self:_animate()
		self:_stepDebris(dt)
		self:_stepShards(dt)
		self:_updateBar()
	end)
end

-- ═══════════════════════════════════════════════════════════
-- Rochas
-- ═══════════════════════════════════════════════════════════

function ShipMiningController:_addPart(rig: OreRig, part: BasePart)
	if table.find(rig.parts, part) then
		return
	end
	table.insert(rig.parts, part)
	-- O servidor nunca move a rocha: o CFrame que chega é o de repouso
	table.insert(rig.rest, part.CFrame)
	table.insert(rig.transparency, part.Transparency)
	part.LocalTransparencyModifier = if rig.hidden then 1 else 0
end

function ShipMiningController:_bind(root: Instance)
	if self._rigs[root] or not (root:IsA("Model") or root:IsA("BasePart")) then
		return
	end

	local oreId = root:GetAttribute(OreConfig.ID_ATTRIBUTE)
	local center = root:GetAttribute(OreConfig.CENTER_ATTRIBUTE)
	if typeof(center) ~= "Vector3" then
		center = if root:IsA("Model") then root:GetBoundingBox().Position else (root :: BasePart).Position
	end

	local rig: OreRig = {
		root = root,
		oreId = oreId,
		def = OreConfig.Get(oreId),
		motion = OreConfig.GetMotion(oreId),
		parts = {},
		rest = {},
		transparency = {},
		center = center,
		radius = root:GetAttribute(OreConfig.RADIUS_ATTRIBUTE) or 10,
		seed = root:GetAttribute(OreConfig.SEED_ATTRIBUTE) or 0,
		shakeUntil = 0,
		fadeStart = nil,
		hidden = root:GetAttribute(OreConfig.ACTIVE_ATTRIBUTE) == false,
		lastPose = CFrame.identity,
		conns = {},
	}
	self._rigs[root] = rig

	if root:IsA("BasePart") then
		self:_addPart(rig, root)
	else
		for _, inst in root:GetDescendants() do
			if inst:IsA("BasePart") then
				self:_addPart(rig, inst)
			end
		end
		-- Streaming fora do modo atômico: Parts chegam depois
		table.insert(rig.conns, root.DescendantAdded:Connect(function(inst)
			if inst:IsA("BasePart") then
				self:_addPart(rig, inst)
			end
		end))
	end

	table.insert(rig.conns, root:GetAttributeChangedSignal(OreConfig.ACTIVE_ATTRIBUTE):Connect(function()
		if root:GetAttribute(OreConfig.ACTIVE_ATTRIBUTE) == false then
			self:_setHidden(rig, true)
		else
			-- Volta invisível e aparece aos poucos (ver _animate)
			rig.hidden = false
			for _, part in rig.parts do
				part.LocalTransparencyModifier = 1
			end
			rig.fadeStart = os.clock()
		end
	end))
	-- A semente chega junto com a tag, mas só por garantia
	table.insert(rig.conns, root:GetAttributeChangedSignal(OreConfig.SEED_ATTRIBUTE):Connect(function()
		rig.seed = root:GetAttribute(OreConfig.SEED_ATTRIBUTE) or rig.seed
	end))
end

function ShipMiningController:_unbind(root: Instance)
	local rig = self._rigs[root]
	if not rig then
		return
	end
	self._rigs[root] = nil
	for _, conn in rig.conns do
		conn:Disconnect()
	end
	if self._bar and self._bar.rig == rig then
		self._bar.until_ = 0
	end
end

function ShipMiningController:_setHidden(rig: OreRig, hidden: boolean)
	rig.hidden = hidden
	for _, part in rig.parts do
		part.LocalTransparencyModifier = if hidden then 1 else 0
	end
end

function ShipMiningController:_animate()
	local camera = workspace.CurrentCamera
	if not camera then
		return
	end
	local cameraPosition = camera.CFrame.Position
	local t = workspace:GetServerTimeNow()
	local now = os.clock()

	local parts: { BasePart } = {}
	local cframes: { CFrame } = {}

	for _, rig in self._rigs do
		-- Renascendo: aparece aos poucos (longe também, pra não ficar invisível)
		if rig.fadeStart then
			local alpha = math.clamp((now - rig.fadeStart) / FADE_IN_TIME, 0, 1)
			local modifier = 1 - TweenService:GetValue(alpha, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
			for _, part in rig.parts do
				part.LocalTransparencyModifier = modifier
			end
			if alpha >= 1 then
				rig.fadeStart = nil
			end
		end

		if (rig.center - cameraPosition).Magnitude > ANIMATE_DISTANCE + rig.radius then
			continue
		end

		local pose = OreConfig.GetMotionCFrame(rig.center, rig.seed, rig.motion, t)
		if now < rig.shakeUntil then
			local strength = (rig.shakeUntil - now) / SHAKE_TIME
			pose = CFrame.new(randomUnit() * SHAKE_AMPLITUDE * strength) * pose
		end
		rig.lastPose = pose

		for i, part in rig.parts do
			if part.Parent then
				table.insert(parts, part)
				table.insert(cframes, pose * rig.rest[i])
			end
		end
	end

	if #parts > 0 then
		workspace:BulkMoveTo(parts, cframes, Enum.BulkMoveMode.FireCFrameChanged)
	end
end

-- ═══════════════════════════════════════════════════════════
-- Acerto
-- ═══════════════════════════════════════════════════════════

--- Part da rocha mais perto do ponto (pra lasca sair com a cor certa).
local function nearestPart(rig: OreRig, position: Vector3): BasePart?
	local best, bestDistance = nil, math.huge
	for i, part in rig.parts do
		if rig.transparency[i] < 1 then
			local distance = (part.Position - position).Magnitude
			if distance < bestDistance then
				best, bestDistance = part, distance
			end
		end
	end
	return best
end

function ShipMiningController:_onHit(root: Instance?, position: any, shooter: any)
	local rig = root and self._rigs[root]
	if not rig or typeof(position) ~= "Vector3" then
		return
	end

	rig.shakeUntil = os.clock() + SHAKE_TIME

	local source = nearestPart(rig, position)
	local color = if source then source.Color else Color3.fromRGB(120, 110, 130)
	local material = if source then source.Material else Enum.Material.Slate
	local glow = if rig.def then rig.def.glow else color

	local outward = position - rig.lastPose * rig.center
	outward = if outward.Magnitude > 1e-3 then outward.Unit else randomUnit()

	for i = 1, CHIPS_PER_HIT do
		local chip = fxPart("OreChip")
		chip.Size = Vector3.one * randomRange(CHIP_SIZE)
		-- Uma das lascas sai brilhando na cor do minério
		if i == 1 then
			chip.Color = glow
			chip.Material = Enum.Material.Neon
		else
			chip.Color = color
			chip.Material = material
		end
		chip.CFrame = CFrame.new(position) * CFrame.Angles(math.random() * 6, math.random() * 6, math.random() * 6)
		chip.Parent = self._folder
		self:_addDebris(chip, (outward + randomUnit() * 0.8).Unit * randomRange(CHIP_SPEED), CHIP_LIFETIME, true)
	end

	if shooter == player then
		self:_showBar(rig)
	end
end

-- ═══════════════════════════════════════════════════════════
-- Destroços
-- ═══════════════════════════════════════════════════════════

function ShipMiningController:_addDebris(part: BasePart, velocity: Vector3, lifetime: number, shrink: boolean)
	if #self._debris >= MAX_DEBRIS then
		part:Destroy()
		return
	end
	table.insert(self._debris, {
		part = part,
		velocity = velocity,
		spin = randomUnit() * math.random() * SHATTER_SPIN * 2,
		age = 0,
		lifetime = lifetime,
		baseTransparency = part.Transparency,
		baseSize = part.Size,
		shrink = shrink,
	})
end

function ShipMiningController:_stepDebris(dt: number)
	local debris = self._debris
	local i = 1
	while i <= #debris do
		local d = debris[i]
		d.age += dt
		local life = d.age / d.lifetime
		if life >= 1 or not d.part.Parent then
			d.part:Destroy()
			debris[i] = debris[#debris]
			debris[#debris] = nil
			continue
		end

		-- Vácuo: sem gravidade, só um arrasto leve pra não sumir de vista
		d.velocity *= math.max(1 - 0.6 * dt, 0)
		local spin = d.spin * dt
		d.part.CFrame = (d.part.CFrame + d.velocity * dt) * CFrame.Angles(spin.X, spin.Y, spin.Z)

		if life > SHATTER_FADE_START then
			local fade = (life - SHATTER_FADE_START) / (1 - SHATTER_FADE_START)
			d.part.Transparency = d.baseTransparency + (1 - d.baseTransparency) * fade
			if d.shrink then
				d.part.Size = d.baseSize * (1 - 0.7 * fade)
			end
		end
		i += 1
	end
end

--- Cópia só visual de uma Part da rocha: sem scripts, prompts, sons nem
--- colisão. Mesh, textura e SurfaceAppearance ficam.
local function visualClone(part: BasePart, transparency: number): BasePart?
	local ok, clone = pcall(function()
		return part:Clone()
	end)
	if not ok or not clone then
		return nil
	end
	for _, inst in clone:GetDescendants() do
		if
			not (inst:IsA("DataModelMesh") or inst:IsA("Decal") or inst:IsA("SurfaceAppearance"))
		then
			inst:Destroy()
		end
	end
	clone.Anchored = true
	clone.CanCollide = false
	clone.CanQuery = false
	clone.CanTouch = false
	clone.Transparency = transparency
	clone.LocalTransparencyModifier = 0
	return clone
end

function ShipMiningController:_onDepleted(root: Instance?)
	local rig = root and self._rigs[root]
	if not rig then
		return
	end

	local center = rig.lastPose * rig.center
	local glow = if rig.def then rig.def.glow else Color3.new(1, 1, 1)

	-- Pedaços: cada Part sai voando do centro pra fora
	for i, part in rig.parts do
		if rig.transparency[i] >= 1 or not part.Parent then
			continue
		end
		local clone = visualClone(part, rig.transparency[i])
		if clone then
			clone.CFrame = part.CFrame
			clone.Parent = self._folder
			local away = part.Position - center
			away = if away.Magnitude > 1e-3 then away.Unit else randomUnit()
			local velocity = (away + randomUnit() * 0.35).Unit * randomRange(SHATTER_SPEED)
			self:_addDebris(clone, velocity, SHATTER_LIFETIME * (0.8 + math.random() * 0.4), false)
		end
	end

	self:_setHidden(rig, true)
	rig.fadeStart = nil

	-- Clarão
	local flash = fxPart("OreFlash")
	flash.Shape = Enum.PartType.Ball
	flash.Material = Enum.Material.Neon
	flash.Color = glow
	flash.Transparency = 0.2
	flash.Size = Vector3.one * math.max(rig.radius * 0.6, 4)
	flash.Position = center
	flash.Parent = self._folder

	local light = Instance.new("PointLight")
	light.Color = glow
	light.Brightness = 6
	light.Range = math.clamp(rig.radius * 3, 20, 60)
	light.Parent = flash

	local info = TweenInfo.new(0.6, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
	TweenService:Create(flash, info, { Size = Vector3.one * math.max(rig.radius * 2.2, 12), Transparency = 1 }):Play()
	TweenService:Create(light, info, { Brightness = 0 }):Play()
	task.delay(info.Time, function()
		flash:Destroy()
	end)

	if self._bar and self._bar.rig == rig then
		self._bar.until_ = 0
	end
end

-- ═══════════════════════════════════════════════════════════
-- Coleta
-- ═══════════════════════════════════════════════════════════

--- Parte da nave pra onde os fragmentos voam (a nave que o jogador pilota).
local function myShipTarget(): BasePart?
	local character = player.Character
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	local ship = humanoid and humanoid.SeatPart and CombatConfig.FindShip(humanoid.SeatPart)
	if ship then
		return CombatConfig.GetBody(ship) or humanoid.SeatPart
	end
	return humanoid and humanoid.SeatPart or nil
end

function ShipMiningController:_onCollected(root: Instance?, itemId: any, amount: any)
	if typeof(itemId) ~= "string" or typeof(amount) ~= "number" then
		return
	end

	local shown = false
	local function show()
		if shown then
			return
		end
		shown = true
		self._hud:Show(itemId, amount)
	end

	local rig = root and self._rigs[root]
	local target = myShipTarget()
	if not rig or not target then
		show()
		return
	end

	local center = rig.lastPose * rig.center
	local glow = if rig.def then rig.def.glow else InventoryModule.GetRarity(itemId).color
	local count = math.clamp(amount + 2, 3, SHARD_MAX)

	for _ = 1, count do
		if #self._shards >= SHARD_MAX * 4 then
			break
		end
		local shard = fxPart("OreShard")
		shard.Shape = Enum.PartType.Ball
		shard.Material = Enum.Material.Neon
		shard.Color = glow
		shard.Size = Vector3.one * SHARD_SIZE
		shard.Position = center + randomUnit() * rig.radius * 0.3
		shard.Parent = self._folder

		local trail = Instance.new("Trail")
		local a0 = Instance.new("Attachment")
		a0.Position = Vector3.new(0, SHARD_SIZE * 0.3, 0)
		a0.Parent = shard
		local a1 = Instance.new("Attachment")
		a1.Position = Vector3.new(0, -SHARD_SIZE * 0.3, 0)
		a1.Parent = shard
		trail.Attachment0 = a0
		trail.Attachment1 = a1
		trail.Color = ColorSequence.new(glow)
		trail.LightEmission = 1
		trail.Lifetime = 0.25
		trail.Transparency = NumberSequence.new(0.2, 1)
		trail.FaceCamera = true
		trail.Parent = shard

		table.insert(self._shards, {
			part = shard,
			velocity = randomUnit() * randomRange({ 14, 26 }),
			age = 0,
			target = target,
			onArrive = show,
		})
	end

	-- Rede de segurança: o cartão aparece mesmo que nenhum fragmento chegue
	task.delay(SHARD_TIMEOUT, show)
end

function ShipMiningController:_stepShards(dt: number)
	local shards = self._shards
	local i = 1
	while i <= #shards do
		local s = shards[i]
		s.age += dt
		local target = s.target
		local done = s.age >= SHARD_TIMEOUT or not target.Parent

		if not done then
			local position = s.part.Position
			if s.age < SHARD_BURST_TIME then
				-- Estouro: espalha e desacelera
				s.velocity *= math.max(1 - 4 * dt, 0)
			else
				-- Puxão cada vez mais forte até a nave
				local toTarget = target.Position - position
				local distance = toTarget.Magnitude
				if distance < 4 then
					done = true
					if s.onArrive then
						s.onArrive()
					end
				else
					local pull = SHARD_ACCEL * (1 + (s.age - SHARD_BURST_TIME) * 3)
					s.velocity += toTarget.Unit * pull * dt
					-- Amortece o que não aponta pra nave: sem isso ele orbita
					local along = toTarget.Unit * s.velocity:Dot(toTarget.Unit)
					s.velocity = along + (s.velocity - along) * math.max(1 - 6 * dt, 0)
				end
			end
			if not done then
				s.part.Position = position + s.velocity * dt
			end
		end

		if done then
			s.part:Destroy()
			shards[i] = shards[#shards]
			shards[#shards] = nil
		else
			i += 1
		end
	end
end

-- ═══════════════════════════════════════════════════════════
-- Barra de integridade
-- ═══════════════════════════════════════════════════════════

function ShipMiningController:_buildBar()
	local gui = Instance.new("BillboardGui")
	gui.Name = "OreIntegrity"
	gui.AlwaysOnTop = true
	gui.LightInfluence = 0
	gui.Size = UDim2.fromOffset(BAR_WIDTH, 38)
	gui.ResetOnSpawn = false
	gui.Enabled = false
	gui.Parent = player:WaitForChild("PlayerGui")

	local name = UIStyle.label(gui, "Name", 13, UIStyle.FONT_BOLD, 0)
	name.Size = UDim2.new(1, 0, 0, 18)
	name.TextXAlignment = Enum.TextXAlignment.Center
	name.TextStrokeTransparency = 0.5

	local track = Instance.new("Frame")
	track.Name = "Track"
	track.AnchorPoint = Vector2.new(0.5, 0)
	track.Position = UDim2.new(0.5, 0, 0, 24)
	track.Size = UDim2.new(1, -20, 0, 6)
	track.BackgroundColor3 = UIStyle.C.plate
	track.BackgroundTransparency = 0.25
	track.BorderSizePixel = 0
	track.Parent = gui
	UIStyle.corner(track, 3)
	UIStyle.stroke(track, 0.6, 1)

	local fill = Instance.new("Frame")
	fill.Name = "Fill"
	fill.Size = UDim2.fromScale(1, 1)
	fill.BorderSizePixel = 0
	fill.Parent = track
	UIStyle.corner(fill, 3)

	self._bar = { gui = gui, name = name, fill = fill, rig = nil, until_ = 0 }
end

function ShipMiningController:_showBar(rig: OreRig)
	local bar = self._bar
	if not bar then
		return
	end
	if bar.rig ~= rig then
		bar.rig = rig
		local def = rig.oreId and InventoryModule.GetItemDef(rig.oreId)
		local color = if rig.oreId then InventoryModule.GetRarity(rig.oreId).color else Color3.new(1, 1, 1)
		bar.name.Text = UIStyle.spaced(UIStyle.upper(if def then def.name else "Minério"))
		bar.name.TextColor3 = color
		bar.fill.BackgroundColor3 = color

		-- A âncora é a maior Part: ela acompanha a flutuação
		local anchor, biggest = nil, -1
		for i, part in rig.parts do
			local volume = part.Size.X * part.Size.Y * part.Size.Z
			if rig.transparency[i] < 1 and volume > biggest then
				anchor, biggest = part, volume
			end
		end
		bar.gui.Adornee = anchor
	end
	bar.until_ = os.clock() + BAR_SHOW_TIME
end

function ShipMiningController:_updateBar()
	local bar = self._bar
	if not bar then
		return
	end
	local rig = bar.rig
	local visible = rig ~= nil and os.clock() < bar.until_ and not rig.hidden and bar.gui.Adornee ~= nil
	bar.gui.Enabled = visible
	if visible then
		local integrity = rig.root:GetAttribute(OreConfig.INTEGRITY_ATTRIBUTE) or 1
		bar.fill.Size = UDim2.fromScale(math.clamp(integrity, 0, 1), 1)
		-- Acima do centro da rocha, não da Part âncora (que gira em volta dele)
		local anchor = bar.gui.Adornee :: BasePart
		bar.gui.StudsOffsetWorldSpace = rig.lastPose * rig.center - anchor.Position + Vector3.new(0, rig.radius * 0.8 + 3, 0)
	end
end

return ShipMiningController
