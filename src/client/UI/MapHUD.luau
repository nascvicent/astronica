--[[
	MapHUD
	Mapa 3D do sistema, em tela cheia. Abre com [M] ou pelo botão MAPA.

	Duas camadas:
	  ViewportFrame   — maquete: esferas (ou o visual copiado da cena), anéis de
	                    órbita e o disco do plano. Câmera própria, orbital.
	  Marcadores 2D   — ícones, nomes e as linhas verticais até o plano, por
	                    cima do viewport. Cada frame a posição 3D de cada corpo
	                    é projetada pela câmera do mapa (_project), então os
	                    ícones andam junto com a maquete.

	A maquete é remontada a cada abertura a partir de MapConfig.GetBodies():
	o que estiver na cena naquele momento é o que aparece.

	Não decide nada: quem abre, fecha, diz distância/alcance e pede o warp é o
	MapController (SetInfoProvider / SetPlayerPositionProvider / SetWarpHandler).

	Local: src/client/UI/MapHUD.luau
]]

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local ContextActionService = game:GetService("ContextActionService")
local GuiService = game:GetService("GuiService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local MapConfig = require(ReplicatedStorage.Shared.MapConfig)
local UIStyle = require(script.Parent.UIStyle)

local player = Players.LocalPlayer
local playerGui = player:WaitForChild("PlayerGui")

local C, T = UIStyle.C, UIStyle.T
local spaced, upper = UIStyle.spaced, UIStyle.upper

-- Maquete, em unidades do viewport
local MAP_RADIUS = 100
local MIN_RADIUS = 14 -- nada fora do centro fica colado nele
local PLANE_MARGIN = 1.12 -- disco do plano um pouco maior que a órbita mais longe
local RING_SEGMENTS = 72
local RING_THICKNESS = 0.35
local RING_COLOR = Color3.fromRGB(255, 255, 255)
local RING_TRANSPARENCY = 0.72
local RING_SELECTED_TRANSPARENCY = 0.25

-- Câmera
local FOV = 40
local PITCH_DEFAULT = math.rad(38)
local PITCH_MIN = math.rad(10)
local PITCH_MAX = math.rad(85)
local YAW_DEFAULT = math.rad(25)
local DISTANCE_DEFAULT = MAP_RADIUS * 3.4
local DISTANCE_MIN = 30
local DISTANCE_MAX = MAP_RADIUS * 5
local FOCUS_DISTANCE = 130 -- selecionar aproxima até aqui (se estiver mais longe)
local ROTATE_SPEED = 0.006 -- rad por pixel arrastado
local ZOOM_STEP = 0.88 -- por "clique" da roda
local CAMERA_SMOOTH = 10
local CLICK_SLOP = 6 -- arrastar menos que isso ainda é clique

-- Tela
local DISPLAY_ORDER = 9 -- acima do WarpHUD (6) e do toast (7)
local MARGIN = 24
local MARGIN_COMPACT = 12
local PANEL_WIDTH = 320
local MARKER_HIT = 30
local MARKER_GAP = 12 -- entre o topo da esfera e o ícone
local STAR_COUNT = 120
local INFO_REFRESH = 0.25
local ZOOM_ACTION = "SystemMapZoom"

local MapHUD = {}
MapHUD.__index = MapHUD

local function formatDistance(studs: number): string
	if studs >= 1000 then
		return string.format("%.1fk studs", studs / 1000)
	end
	return string.format("%d studs", math.floor(studs))
end

local function inertPart(): Part
	local part = Instance.new("Part")
	part.Anchored = true
	part.CanCollide = false
	part.CanQuery = false
	part.CanTouch = false
	part.CastShadow = false
	part.Material = Enum.Material.SmoothPlastic
	part.TopSurface = Enum.SurfaceType.Smooth
	part.BottomSurface = Enum.SurfaceType.Smooth
	return part
end

--- Cópia só visual de um modelo da cena, ou nil se pesado demais.
local function copyVisual(source: Instance): Model?
	local count = if source:IsA("BasePart") then 1 else 0
	for _, inst in source:GetDescendants() do
		if inst:IsA("BasePart") then
			count += 1
		end
	end
	if count == 0 or count > MapConfig.MAX_VISUAL_PARTS then
		return nil
	end

	local clone = source:Clone()
	local model: Model
	if clone:IsA("Model") then
		model = clone
	else
		model = Instance.new("Model")
		clone.Parent = model
	end

	for _, inst in model:GetDescendants() do
		if inst:IsA("BasePart") then
			inst.Anchored = true
			inst.CanCollide = false
			inst.CanQuery = false
			inst.CanTouch = false
			inst.CastShadow = false
		elseif inst:IsA("LuaSourceContainer") or inst:IsA("ProximityPrompt") or inst:IsA("Sound")
			or inst:IsA("ParticleEmitter") or inst:IsA("BillboardGui") or inst:IsA("SurfaceGui")
			or inst:IsA("Constraint") or inst:IsA("JointInstance") or inst:IsA("BodyMover")
			or inst:IsA("Light") or inst:IsA("Beam") or inst:IsA("Trail")
		then
			inst:Destroy()
		end
	end
	model.PrimaryPart = nil
	return model
end

function MapHUD.new()
	local self = setmetatable({}, MapHUD)

	self._open = false
	self._available = false
	self._entries = {} :: { [string]: any }
	self._order = {} :: { string }
	self._selected = nil :: string?
	self._touches = {} :: { [InputObject]: boolean }
	self._conns = {} :: { RBXScriptConnection }
	self._infoTimer = 0

	self._yaw, self._yawTarget = YAW_DEFAULT, YAW_DEFAULT
	self._pitch, self._pitchTarget = PITCH_DEFAULT, PITCH_DEFAULT
	self._distance, self._distanceTarget = DISTANCE_DEFAULT, DISTANCE_DEFAULT
	self._focus, self._focusTarget = Vector3.zero, Vector3.zero
	self._camCFrame = CFrame.new()

	self:_build()
	self:_buildToggle()
	return self
end

-- ═══════════════════════════════════════════════════════════
-- Construção
-- ═══════════════════════════════════════════════════════════

function MapHUD:_build()
	local gui = Instance.new("ScreenGui")
	gui.Name = "SystemMap"
	gui.ResetOnSpawn = false
	gui.IgnoreGuiInset = true
	gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
	gui.DisplayOrder = DISPLAY_ORDER
	gui.Enabled = false
	gui.Parent = playerGui
	self._gui = gui

	-- Fundo: espaço escuro com leve tom azul e estrelas fixas
	local background = Instance.new("Frame")
	background.Name = "Background"
	background.Size = UDim2.fromScale(1, 1)
	background.BackgroundColor3 = Color3.new(1, 1, 1)
	background.BackgroundTransparency = 0.04
	background.BorderSizePixel = 0
	background.Active = true -- clique não vaza pro mundo
	background.Parent = gui
	local gradient = Instance.new("UIGradient")
	gradient.Rotation = 90
	gradient.Color = ColorSequence.new({
		ColorSequenceKeypoint.new(0, Color3.fromRGB(4, 5, 9)),
		ColorSequenceKeypoint.new(0.5, Color3.fromRGB(10, 13, 24)),
		ColorSequenceKeypoint.new(1, Color3.fromRGB(4, 5, 9)),
	})
	gradient.Parent = background

	local stars = Instance.new("Frame")
	stars.Name = "Stars"
	stars.Size = UDim2.fromScale(1, 1)
	stars.BackgroundTransparency = 1
	stars.Parent = background
	local rng = Random.new(7)
	for i = 1, STAR_COUNT do
		local star = Instance.new("Frame")
		star.Name = "Star" .. i
		local size = if rng:NextNumber() < 0.15 then 2 else 1
		star.Size = UDim2.fromOffset(size, size)
		star.Position = UDim2.fromScale(rng:NextNumber(), rng:NextNumber())
		star.BackgroundColor3 = C.text
		star.BackgroundTransparency = rng:NextNumber(0.25, 0.8)
		star.BorderSizePixel = 0
		star.Parent = stars
	end

	-- Maquete
	local viewport = Instance.new("ViewportFrame")
	viewport.Name = "Viewport"
	viewport.Size = UDim2.fromScale(1, 1)
	viewport.BackgroundTransparency = 1
	viewport.Ambient = Color3.fromRGB(125, 128, 140)
	viewport.LightColor = Color3.fromRGB(255, 246, 232)
	viewport.LightDirection = Vector3.new(-0.5, -1, -0.35)
	viewport.Parent = gui
	self._viewport = viewport

	local camera = Instance.new("Camera")
	camera.FieldOfView = FOV
	camera.Parent = viewport
	viewport.CurrentCamera = camera
	self._camera = camera
	self._focal = 1 / math.tan(math.rad(FOV) / 2)

	-- Arrastar gira, clique no vazio desseleciona
	local input = Instance.new("TextButton")
	input.Name = "Input"
	input.Size = UDim2.fromScale(1, 1)
	input.BackgroundTransparency = 1
	input.Text = ""
	input.AutoButtonColor = false
	input.Parent = gui
	input.InputBegan:Connect(function(inputObject)
		self:_onPointerBegan(inputObject)
	end)

	local markers = Instance.new("Frame")
	markers.Name = "Markers"
	markers.Size = UDim2.fromScale(1, 1)
	markers.BackgroundTransparency = 1
	markers.Parent = gui
	self._markers = markers

	self:_buildYouMarker()

	-- Cabeçalho
	local header = Instance.new("Frame")
	header.Name = "Header"
	header.AnchorPoint = Vector2.new(0.5, 0)
	header.Size = UDim2.fromOffset(520, 52)
	header.BackgroundTransparency = 1
	header.Parent = gui
	self._header = header

	local caption = UIStyle.label(header, "Caption", 11, UIStyle.FONT_MEDIUM, T.textMuted)
	caption.Size = UDim2.new(1, 0, 0, 16)
	caption.TextXAlignment = Enum.TextXAlignment.Center
	caption.Text = spaced("MAPA DO SISTEMA")

	local title = UIStyle.label(header, "Title", 24, UIStyle.FONT_BOLD, T.textPrimary)
	title.Position = UDim2.fromOffset(0, 18)
	title.Size = UDim2.new(1, 0, 0, 30)
	title.TextXAlignment = Enum.TextXAlignment.Center
	title.TextTruncate = Enum.TextTruncate.AtEnd
	self._title = title

	-- Fechar
	local close, _ = UIStyle.keyHint(gui, "M", "FECHAR")
	close.Name = "Close"
	close.Activated:Connect(function()
		if self._onClose then
			self._onClose()
		end
	end)
	self._close = close

	-- Dica de controles
	local hint = UIStyle.label(gui, "Hint", 11, UIStyle.FONT_MEDIUM, T.textMuted)
	hint.AnchorPoint = Vector2.new(0, 1)
	hint.Size = UDim2.fromOffset(460, 16)
	hint.Text = if UIStyle.IS_MOBILE
		then "ARRASTE  girar    ·    PINÇA  zoom    ·    TOQUE  selecionar"
		else "ARRASTE  girar    ·    RODA  zoom    ·    CLIQUE  selecionar"
	self._hint = hint

	self:_buildInfo()

	gui:GetPropertyChangedSignal("AbsoluteSize"):Connect(function()
		self:_layout()
	end)
	self:_layout()
end

function MapHUD:_buildYouMarker()
	local you = Instance.new("Frame")
	you.Name = "You"
	you.AnchorPoint = Vector2.new(0.5, 0.5)
	you.Size = UDim2.fromOffset(12, 12)
	you.BackgroundColor3 = C.prompt
	you.BorderSizePixel = 0
	you.Visible = false
	you.ZIndex = 4
	you.Parent = self._markers
	UIStyle.corner(you, 6)
	local stroke = UIStyle.stroke(you, 0, 2)
	stroke.Color = C.plate

	local halo = Instance.new("Frame")
	halo.Name = "Halo"
	halo.AnchorPoint = Vector2.new(0.5, 0.5)
	halo.Position = UDim2.fromScale(0.5, 0.5)
	halo.Size = UDim2.fromOffset(24, 24)
	halo.BackgroundTransparency = 1
	halo.Parent = you
	UIStyle.corner(halo, 12)
	local haloStroke = UIStyle.stroke(halo, 0.4, 1)
	haloStroke.Color = C.prompt

	local label = UIStyle.label(you, "Label", 11, UIStyle.FONT_BOLD, T.textPrimary)
	label.AnchorPoint = Vector2.new(0.5, 1)
	label.Position = UDim2.new(0.5, 0, 0, -8)
	label.Size = UDim2.fromOffset(80, 14)
	label.TextXAlignment = Enum.TextXAlignment.Center
	label.TextColor3 = C.prompt
	label.Text = spaced("VOCÊ")

	local stem, foot = self:_makeStem("YouStem")
	self._you = { frame = you, stem = stem, foot = foot }
end

function MapHUD:_buildInfo()
	local info = Instance.new("Frame")
	info.Name = "Info"
	info.AnchorPoint = Vector2.new(1, 1)
	info.AutomaticSize = Enum.AutomaticSize.Y
	info.BackgroundColor3 = C.plate
	info.BackgroundTransparency = 0.12
	info.BorderSizePixel = 0
	info.Visible = false
	info.Active = true -- clique no painel não desseleciona
	info.Parent = self._gui
	UIStyle.corner(info, 12)
	UIStyle.stroke(info, T.panelLine, 1)
	UIStyle.padding(info, 14, 16, 14, 16)
	UIStyle.list(info, 8)
	self._info = info

	-- Nome + tipo, com o losango na cor do corpo
	local head = Instance.new("Frame")
	head.Name = "Head"
	head.Size = UDim2.new(1, 0, 0, 40)
	head.BackgroundTransparency = 1
	head.LayoutOrder = 1
	head.Parent = info

	local swatch = Instance.new("Frame")
	swatch.Name = "Swatch"
	swatch.AnchorPoint = Vector2.new(0.5, 0.5)
	swatch.Position = UDim2.fromOffset(9, 20)
	swatch.Size = UDim2.fromOffset(12, 12)
	swatch.Rotation = 45
	swatch.BorderSizePixel = 0
	swatch.Parent = head
	self._infoSwatch = swatch

	local name = UIStyle.label(head, "Name", 18, UIStyle.FONT_BOLD, T.textPrimary)
	name.Position = UDim2.fromOffset(28, 0)
	name.Size = UDim2.new(1, -28, 0, 22)
	name.TextTruncate = Enum.TextTruncate.AtEnd
	self._infoName = name

	local kind = UIStyle.label(head, "Kind", 11, UIStyle.FONT_MEDIUM, T.textMuted)
	kind.Position = UDim2.fromOffset(28, 23)
	kind.Size = UDim2.new(1, -28, 0, 14)
	self._infoKind = kind

	local divider = UIStyle.divider(info, true)
	divider.LayoutOrder = 2

	local description = UIStyle.label(info, "Description", 13, UIStyle.FONT_REGULAR, T.textSecondary)
	description.Size = UDim2.new(1, 0, 0, 0)
	description.AutomaticSize = Enum.AutomaticSize.Y
	description.TextWrapped = true
	description.LayoutOrder = 3
	self._infoDescription = description

	local function row(order: number, key: string)
		local frame = Instance.new("Frame")
		frame.Name = "Row_" .. key
		frame.Size = UDim2.new(1, 0, 0, 16)
		frame.BackgroundTransparency = 1
		frame.LayoutOrder = order
		frame.Parent = info

		local keyLabel = UIStyle.label(frame, "Key", 11, UIStyle.FONT_MEDIUM, T.textMuted)
		keyLabel.Size = UDim2.new(0.4, 0, 1, 0)
		keyLabel.Text = spaced(key)

		local value = UIStyle.label(frame, "Value", 13, UIStyle.FONT_BOLD, T.textPrimary)
		value.Position = UDim2.fromScale(0.4, 0)
		value.Size = UDim2.new(0.6, 0, 1, 0)
		value.TextXAlignment = Enum.TextXAlignment.Right
		return frame, value
	end

	self._infoDistanceRow, self._infoDistance = row(4, "DISTÂNCIA")
	self._infoWarpRow, self._infoWarp = row(5, "WARP")

	-- Warp direto do mapa: só pilotando e com o destino no alcance
	local warp, setWarp = UIStyle.button(info, "WARP", true)
	warp.Name = "Warp"
	warp.Size = UDim2.new(1, 0, 0, 34)
	warp.LayoutOrder = 6
	warp.Visible = false
	warp.Activated:Connect(function()
		self:ActivateWarp()
	end)
	self._warpButton = warp
	self._setWarpButton = setWarp
end

--- Botão MAPA na HUD normal (fora do mapa). Vive numa ScreenGui própria pra
--- continuar na tela com o mapa fechado.
function MapHUD:_buildToggle()
	local gui = Instance.new("ScreenGui")
	gui.Name = "SystemMapButton"
	gui.ResetOnSpawn = false
	gui.IgnoreGuiInset = true
	gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
	gui.DisplayOrder = 5
	gui.Enabled = false
	gui.Parent = playerGui
	self._toggleGui = gui

	local toggle, _ = UIStyle.keyHint(gui, "M", "MAPA")
	toggle.Name = "Toggle"
	toggle.Activated:Connect(function()
		if self._onToggle then
			self._onToggle()
		end
	end)
	self._toggle = toggle

	gui:GetPropertyChangedSignal("AbsoluteSize"):Connect(function()
		self:_layout()
	end)
end

function MapHUD:_layout()
	local size = self._gui.AbsoluteSize
	if size.X <= 0 or size.Y <= 0 then
		return
	end

	local compact = size.Y <= UIStyle.COMPACT_MAX_HEIGHT
	local margin = if compact then MARGIN_COMPACT else MARGIN
	local top = GuiService:GetGuiInset().Y + margin

	self._header.Position = UDim2.new(0.5, 0, 0, top)
	self._header.Size = UDim2.fromOffset(math.clamp(size.X - 2 * (margin + 150), 200, 520), 52)

	-- Dicas de tecla: pilha no canto superior direito (slot 1 = mapa; o
	-- WarpHUD usa o slot 2)
	self._close.Position = UDim2.new(1, -margin, 0, UIStyle.hintSlotY(top, 1))
	if self._toggle then -- o _build roda antes do _buildToggle
		self._toggle.Position = UDim2.new(1, -margin, 0, UIStyle.hintSlotY(top, 1))
	end

	self._hint.Position = UDim2.new(0, margin, 1, -margin)
	self._hint.Visible = size.X >= 700 or not compact

	self._info.Position = UDim2.new(1, -margin, 1, -margin)
	self._info.Size = UDim2.fromOffset(math.min(PANEL_WIDTH, size.X - margin * 2), 0)
end

--- Linha vertical do corpo até o plano, com um ponto no pé.
function MapHUD:_makeStem(name: string): (Frame, Frame)
	local stem = Instance.new("Frame")
	stem.Name = name
	stem.AnchorPoint = Vector2.new(0.5, 0.5)
	stem.BackgroundColor3 = C.line
	stem.BackgroundTransparency = 0.6
	stem.BorderSizePixel = 0
	stem.Visible = false
	stem.ZIndex = 1
	stem.Parent = self._markers

	local foot = Instance.new("Frame")
	foot.Name = name .. "Foot"
	foot.AnchorPoint = Vector2.new(0.5, 0.5)
	foot.Size = UDim2.fromOffset(4, 4)
	foot.BackgroundColor3 = C.line
	foot.BackgroundTransparency = 0.4
	foot.BorderSizePixel = 0
	foot.Visible = false
	foot.ZIndex = 1
	foot.Parent = self._markers
	UIStyle.corner(foot, 2)

	return stem, foot
end

-- ═══════════════════════════════════════════════════════════
-- Maquete
-- ═══════════════════════════════════════════════════════════

--- Posição real → posição na maquete (ver MapConfig.SCALE_EXPONENT).
function MapHUD:_toMap(world: Vector3): Vector3
	local offset = world - self._center
	local horizontal = Vector3.new(offset.X, 0, offset.Z)
	local exponent = MapConfig.SCALE_EXPONENT
	local span = MAP_RADIUS - MIN_RADIUS

	local flat = Vector3.zero
	local d = horizontal.Magnitude
	if d > 0.01 then
		-- Quem está além do corpo mais longe (o jogador, voando pra fora) passa
		-- um pouco da borda, sem sumir no infinito
		local r = MIN_RADIUS + span * math.min(d / self._span, 1.15) ^ exponent
		flat = horizontal / d * r
	end

	local h = offset.Y
	local y = math.sign(h) * span * math.min(math.abs(h) / self._span, 1) ^ exponent * MapConfig.HEIGHT_SCALE
	return flat + Vector3.new(0, y, 0)
end

function MapHUD:_makeBodyVisual(body): Model
	local model = if body.visual then copyVisual(body.visual) else nil
	if model then
		local boxCf, boxSize = model:GetBoundingBox()
		model.WorldPivot = CFrame.new(boxCf.Position)
		local largest = math.max(boxSize.X, boxSize.Y, boxSize.Z)
		if largest > 0 then
			model:ScaleTo(model:GetScale() * body.size / largest)
		end
	else
		model = Instance.new("Model")
		local sphere = inertPart()
		sphere.Name = "Sphere"
		sphere.Shape = Enum.PartType.Ball
		sphere.Size = Vector3.one * body.size
		sphere.Color = body.color
		sphere.Parent = model

		-- Estrela: halo translúcido, já que o viewport não tem brilho
		if body.kind == "star" then
			local halo = inertPart()
			halo.Name = "Halo"
			halo.Shape = Enum.PartType.Ball
			halo.Size = Vector3.one * body.size * 1.6
			halo.Color = body.color
			halo.Transparency = 0.82
			halo.Parent = model
		end
		model.WorldPivot = CFrame.new()
	end

	model.Name = "Body_" .. body.id
	return model
end

function MapHUD:_makeRing(center: Vector3, radius: number, thickness: number, transparency: number, color: Color3?): Model
	local ring = Instance.new("Model")
	ring.Name = "Ring"
	local length = 2 * math.pi * radius / RING_SEGMENTS * 1.04
	for i = 1, RING_SEGMENTS do
		local angle = (i / RING_SEGMENTS) * 2 * math.pi
		local segment = inertPart()
		segment.Name = "Segment"
		segment.Size = Vector3.new(length, thickness, thickness)
		segment.CFrame = CFrame.new(center) * CFrame.Angles(0, angle, 0) * CFrame.new(0, 0, -radius)
		segment.Color = color or RING_COLOR
		segment.Transparency = transparency
		segment.Material = Enum.Material.Neon
		segment.Parent = ring
	end
	ring.Parent = self._world
	return ring
end

local function paintRing(ring: Model?, transparency: number, color: Color3)
	if not ring then
		return
	end
	for _, part in ring:GetChildren() do
		if part:IsA("BasePart") then
			part.Transparency = transparency
			part.Color = color
		end
	end
end

function MapHUD:_clearWorld()
	if self._world then
		self._world:Destroy()
		self._world = nil
	end
	for _, entry in self._entries do
		entry.marker:Destroy()
		entry.stem:Destroy()
		entry.foot:Destroy()
	end
	table.clear(self._entries)
	table.clear(self._order)
end

function MapHUD:_buildWorld(bodies)
	self:_clearWorld()

	local world = Instance.new("Model")
	world.Name = "World"
	world.Parent = self._viewport
	self._world = world

	self._center = MapConfig.GetCenter(bodies)
	local span = 1
	for _, body in bodies do
		span = math.max(span, (body.position - self._center).Magnitude)
	end
	self._span = span

	-- Disco do plano e borda
	local planeRadius = MAP_RADIUS * PLANE_MARGIN
	local plane = inertPart()
	plane.Name = "Plane"
	plane.Shape = Enum.PartType.Cylinder
	plane.Size = Vector3.new(0.05, planeRadius * 2, planeRadius * 2)
	plane.CFrame = CFrame.Angles(0, 0, math.pi / 2)
	plane.Color = C.prompt
	plane.Transparency = 0.94
	plane.Parent = world
	self:_makeRing(Vector3.zero, planeRadius, 0.6, 0.6, C.prompt)

	for _, body in bodies do
		local mapPos = self:_toMap(body.position)
		local model = self:_makeBodyVisual(body)
		model:PivotTo(CFrame.new(mapPos))
		model.Parent = world

		local entry = {
			body = body,
			mapPos = mapPos,
			model = model,
		}
		self._entries[body.id] = entry
		table.insert(self._order, body.id)
		self:_makeMarker(entry)
	end

	-- Anéis: em volta do centro, ou do corpo indicado em `orbit`. O corpo do
	-- centro e estrelas não têm anel: elas não orbitam nada.
	for _, id in self._order do
		local entry = self._entries[id]
		local body = entry.body
		local noRing = MapConfig.IsCenter(body) or body.kind == "star"
		if body.orbit ~= false and not noRing then
			local parent = if typeof(body.orbit) == "string" then self:_findEntry(body.orbit) else nil
			local pivot = if parent then parent.mapPos else Vector3.zero
			local offset = entry.mapPos - pivot
			local radius = Vector3.new(offset.X, 0, offset.Z).Magnitude
			if radius > 2 then
				entry.ring = self:_makeRing(Vector3.new(pivot.X, pivot.Y, pivot.Z), radius, RING_THICKNESS, RING_TRANSPARENCY)
				entry.ringPivotY = pivot.Y
			end
		end
	end
end

--- Entrada da maquete pela chave de BODIES ou pelo nome do marcador, sem
--- diferenciar maiúsculas (pro `orbit = "verdana"` achar o marcador "Verdana").
function MapHUD:_findEntry(name: string)
	local lower = string.lower(name)
	for id, entry in self._entries do
		local key = entry.body.entry
		if string.lower(id) == lower or (key and string.lower(key) == lower) then
			return entry
		end
	end
	return nil
end

-- ═══════════════════════════════════════════════════════════
-- Marcadores
-- ═══════════════════════════════════════════════════════════

function MapHUD:_makeMarker(entry)
	local body = entry.body

	local marker = Instance.new("TextButton")
	marker.Name = "Marker_" .. body.id
	marker.AnchorPoint = Vector2.new(0.5, 0.5)
	marker.Size = UDim2.fromOffset(MARKER_HIT, MARKER_HIT)
	marker.BackgroundTransparency = 1
	marker.Text = ""
	marker.AutoButtonColor = false
	marker.ZIndex = 3
	marker.Visible = false
	marker.Parent = self._markers

	local diamond = Instance.new("Frame")
	diamond.Name = "Diamond"
	diamond.AnchorPoint = Vector2.new(0.5, 0.5)
	diamond.Position = UDim2.fromScale(0.5, 0.5)
	diamond.Size = UDim2.fromOffset(13, 13)
	diamond.Rotation = 45
	diamond.BackgroundColor3 = C.plate
	diamond.BackgroundTransparency = 0.15
	diamond.BorderSizePixel = 0
	diamond.ZIndex = 3
	diamond.Parent = marker
	local diamondStroke = UIStyle.stroke(diamond, 0, 1.5)
	diamondStroke.Color = body.color

	local core = Instance.new("Frame")
	core.Name = "Core"
	core.AnchorPoint = Vector2.new(0.5, 0.5)
	core.Position = UDim2.fromScale(0.5, 0.5)
	core.Size = UDim2.fromOffset(5, 5)
	core.BackgroundColor3 = body.color
	core.BorderSizePixel = 0
	core.ZIndex = 3
	core.Parent = diamond

	-- Anel de seleção
	local ring = Instance.new("Frame")
	ring.Name = "Selection"
	ring.AnchorPoint = Vector2.new(0.5, 0.5)
	ring.Position = UDim2.fromScale(0.5, 0.5)
	ring.Size = UDim2.fromOffset(30, 30)
	ring.BackgroundTransparency = 1
	ring.Visible = false
	ring.ZIndex = 3
	ring.Parent = marker
	UIStyle.corner(ring, 15)
	UIStyle.stroke(ring, 0.1, 1.5)

	local name = UIStyle.label(marker, "Name", 11, UIStyle.FONT_BOLD, T.textSecondary)
	name.AnchorPoint = Vector2.new(0.5, 1)
	name.Position = UDim2.new(0.5, 0, 0, 0)
	name.Size = UDim2.fromOffset(180, 14)
	name.TextXAlignment = Enum.TextXAlignment.Center
	name.Text = spaced(upper(body.displayName))
	name.ZIndex = 3
	local nameStroke = Instance.new("UIStroke")
	nameStroke.Color = C.plate
	nameStroke.Thickness = 1.5
	nameStroke.Transparency = 0.3
	nameStroke.Parent = name

	marker.MouseEnter:Connect(function()
		if self._selected ~= body.id then
			name.TextTransparency = T.textPrimary
		end
	end)
	marker.MouseLeave:Connect(function()
		if self._selected ~= body.id then
			name.TextTransparency = T.textSecondary
		end
	end)
	marker.Activated:Connect(function()
		self:Select(body.id)
	end)

	entry.marker = marker
	entry.diamond = diamond
	entry.selectionRing = ring
	entry.name = name
	entry.stem, entry.foot = self:_makeStem("Stem_" .. body.id)
end

--- Ponto da maquete → pixel na tela. Feito à mão em vez de
--- Camera:WorldToViewportPoint porque a câmera do viewport não sabe o tamanho
--- do ViewportFrame.
function MapHUD:_project(point: Vector3): (Vector2, number)
	local rel = self._camCFrame:PointToObjectSpace(point)
	local depth = -rel.Z
	if depth <= 0.1 then
		return Vector2.zero, depth
	end
	local size = self._viewport.AbsoluteSize
	local aspect = size.X / math.max(size.Y, 1)
	local x = rel.X / depth * self._focal / aspect
	local y = rel.Y / depth * self._focal
	return Vector2.new((x + 1) * 0.5 * size.X, (1 - y) * 0.5 * size.Y), depth
end

--- Linha entre dois pixels (a haste até o plano).
local function placeStem(stem: Frame, foot: Frame, from: Vector2, to: Vector2)
	local delta = to - from
	local length = delta.Magnitude
	if length < 3 then
		stem.Visible = false
		foot.Visible = false
		return
	end
	local mid = (from + to) / 2
	stem.Position = UDim2.fromOffset(mid.X, mid.Y)
	stem.Size = UDim2.fromOffset(1, length)
	stem.Rotation = math.deg(math.atan2(delta.Y, delta.X)) - 90
	stem.Visible = true
	foot.Position = UDim2.fromOffset(to.X, to.Y)
	foot.Visible = true
end

--- Haste de um ponto da maquete até o plano logo abaixo (ou acima) dele.
function MapHUD:_placeStemFor(stem: Frame, foot: Frame, mapPos: Vector3, planeY: number, screen: Vector2)
	if math.abs(mapPos.Y - planeY) < 0.5 then
		stem.Visible = false
		foot.Visible = false
		return
	end
	local footScreen, footDepth = self:_project(Vector3.new(mapPos.X, planeY, mapPos.Z))
	if footDepth <= 0.1 then
		stem.Visible = false
		foot.Visible = false
		return
	end
	placeStem(stem, foot, screen, footScreen)
end

function MapHUD:_updateMarkers()
	local halfHeight = self._viewport.AbsoluteSize.Y / 2

	for _, entry in self._entries do
		local screen, depth = self:_project(entry.mapPos)
		if depth <= 0.1 then
			entry.marker.Visible = false
			entry.stem.Visible = false
			entry.foot.Visible = false
			continue
		end

		-- O ícone fica logo acima da esfera, qualquer que seja o zoom
		local radiusPx = entry.body.size / 2 * halfHeight * self._focal / depth
		entry.marker.Position = UDim2.fromOffset(screen.X, screen.Y - radiusPx - MARKER_GAP)
		entry.marker.Visible = true

		self:_placeStemFor(entry.stem, entry.foot, entry.mapPos, entry.ringPivotY or 0, screen)
	end

	-- Jogador
	local you = self._you
	local world = self._playerPositionProvider and self._playerPositionProvider()
	if world then
		local mapPos = self:_toMap(world)
		local screen, depth = self:_project(mapPos)
		if depth > 0.1 then
			you.frame.Position = UDim2.fromOffset(screen.X, screen.Y)
			you.frame.Visible = true
			self:_placeStemFor(you.stem, you.foot, mapPos, 0, screen)
			return
		end
	end
	you.frame.Visible = false
	you.stem.Visible = false
	you.foot.Visible = false
end

-- ═══════════════════════════════════════════════════════════
-- Seleção e painel
-- ═══════════════════════════════════════════════════════════

function MapHUD:Select(id: string?)
	local entry = if id then self._entries[id] else nil
	if id and not entry then
		return
	end

	local previous = self._selected and self._entries[self._selected]
	if previous then
		previous.selectionRing.Visible = false
		previous.diamond.Size = UDim2.fromOffset(13, 13)
		previous.name.TextTransparency = T.textSecondary
		paintRing(previous.ring, RING_TRANSPARENCY, RING_COLOR)
	end

	self._selected = id

	if not entry then
		self._focusTarget = Vector3.zero
		self._distanceTarget = DISTANCE_DEFAULT
		self._info.Visible = false
		self._warpReady = false
		return
	end

	entry.selectionRing.Visible = true
	entry.diamond.Size = UDim2.fromOffset(16, 16)
	entry.name.TextTransparency = T.textPrimary
	paintRing(entry.ring, RING_SELECTED_TRANSPARENCY, entry.body.color)

	self._focusTarget = entry.mapPos
	self._distanceTarget = math.min(self._distanceTarget, FOCUS_DISTANCE)

	local body = entry.body
	self._infoSwatch.BackgroundColor3 = body.color
	self._infoName.Text = spaced(upper(body.displayName))
	self._infoKind.Text = spaced(upper(body.kindLabel))
	self._infoDescription.Text = body.description or ""
	self._infoDescription.Visible = body.description ~= nil and body.description ~= ""
	self._info.Visible = true
	self:_refreshInfo()
end

function MapHUD:_refreshInfo()
	local entry = self._selected and self._entries[self._selected]
	if not entry then
		return
	end

	local info = self._infoProvider and self._infoProvider(entry.body) or {}

	self._infoDistanceRow.Visible = info.distance ~= nil
	if info.distance then
		self._infoDistance.Text = formatDistance(info.distance)
	end

	-- WARP só aparece pilotando e em destino de warp (o provider manda nil fora disso)
	local warp = info.warp
	self._infoWarpRow.Visible = warp ~= nil
	self._warpReady = warp == "inRange" or warp == "unlimited"
	self._warpButton.Visible = warp ~= nil
	local key = if UIStyle.IS_MOBILE then "" else "   [F]"
	self._setWarpButton(self._warpReady, "WARP PARA " .. upper(entry.body.displayName) .. key)
	if warp == "inRange" then
		self._infoWarp.Text = "no alcance"
		self._infoWarp.TextColor3 = C.positive
	elseif warp == "unlimited" then
		self._infoWarp.Text = "alcance ilimitado"
		self._infoWarp.TextColor3 = C.positive
	elseif warp == "outOfRange" then
		self._infoWarp.Text = "fora do alcance"
		self._infoWarp.TextColor3 = C.negative
	elseif warp == "tooClose" then
		self._infoWarp.Text = "perto demais"
		self._infoWarp.TextColor3 = C.text
	end
end

-- ═══════════════════════════════════════════════════════════
-- Câmera e input
-- ═══════════════════════════════════════════════════════════

function MapHUD:_touchCount(): number
	local count = 0
	for _ in self._touches do
		count += 1
	end
	return count
end

function MapHUD:_onPointerBegan(input: InputObject)
	local kind = input.UserInputType
	if kind == Enum.UserInputType.Touch then
		self._touches[input] = true
	elseif kind ~= Enum.UserInputType.MouseButton1 then
		return
	end
	-- Segundo dedo vira pinça: não gira nem conta como toque
	if self:_touchCount() > 1 then
		self._drag = nil
		return
	end
	self._drag = { input = input, last = input.Position, moved = 0 }
end

function MapHUD:_onInputChanged(input: InputObject)
	local drag = self._drag
	if not drag then
		return
	end
	local isMouse = drag.input.UserInputType == Enum.UserInputType.MouseButton1
	if isMouse then
		if input.UserInputType ~= Enum.UserInputType.MouseMovement then
			return
		end
	elseif input ~= drag.input then
		return
	end

	local delta = input.Position - drag.last
	drag.last = input.Position
	drag.moved += Vector2.new(delta.X, delta.Y).Magnitude

	self._yawTarget -= delta.X * ROTATE_SPEED
	self._pitchTarget = math.clamp(self._pitchTarget + delta.Y * ROTATE_SPEED, PITCH_MIN, PITCH_MAX)
end

function MapHUD:_onInputEnded(input: InputObject)
	if input.UserInputType == Enum.UserInputType.Touch then
		self._touches[input] = nil
	end

	local drag = self._drag
	if not drag then
		return
	end
	local ended = if drag.input.UserInputType == Enum.UserInputType.MouseButton1
		then input.UserInputType == Enum.UserInputType.MouseButton1
		else input == drag.input
	if not ended then
		return
	end

	self._drag = nil
	-- Clique no vazio (sem arrastar): desseleciona e volta pra visão geral
	if drag.moved < CLICK_SLOP then
		self:Select(nil)
	end
end

function MapHUD:_zoom(factor: number)
	self._distanceTarget = math.clamp(self._distanceTarget * factor, DISTANCE_MIN, DISTANCE_MAX)
end

function MapHUD:_step(dt: number)
	local t = 1 - math.exp(-dt * CAMERA_SMOOTH)
	self._yaw += (self._yawTarget - self._yaw) * t
	self._pitch += (self._pitchTarget - self._pitch) * t
	self._distance += (self._distanceTarget - self._distance) * t
	self._focus = self._focus:Lerp(self._focusTarget, t)

	local yaw, pitch = self._yaw, self._pitch
	local direction = Vector3.new(math.sin(yaw) * math.cos(pitch), math.sin(pitch), math.cos(yaw) * math.cos(pitch))
	self._camCFrame = CFrame.lookAt(self._focus + direction * self._distance, self._focus)
	self._camera.CFrame = self._camCFrame

	self:_updateMarkers()

	self._infoTimer -= dt
	if self._infoTimer <= 0 then
		self._infoTimer = INFO_REFRESH
		self:_refreshInfo()
	end
end

function MapHUD:_connectInput()
	table.insert(self._conns, UserInputService.InputChanged:Connect(function(input)
		self:_onInputChanged(input)
	end))
	table.insert(self._conns, UserInputService.InputEnded:Connect(function(input)
		self:_onInputEnded(input)
	end))
	table.insert(self._conns, UserInputService.TouchPinch:Connect(function(_, scale, _, state)
		if state == Enum.UserInputState.Begin then
			self._pinchStart = self._distanceTarget
		elseif state == Enum.UserInputState.Change and self._pinchStart and scale > 0 then
			self._distanceTarget = math.clamp(self._pinchStart / scale, DISTANCE_MIN, DISTANCE_MAX)
		end
	end))
	table.insert(self._conns, RunService.RenderStepped:Connect(function(dt)
		self:_step(dt)
	end))

	-- A roda é do mapa enquanto ele está aberto (senão a câmera do jogo dá
	-- zoom junto, por baixo)
	ContextActionService:BindActionAtPriority(ZOOM_ACTION, function(_, state, input)
		if state == Enum.UserInputState.Change then
			self:_zoom(ZOOM_STEP ^ input.Position.Z)
		end
		return Enum.ContextActionResult.Sink
	end, false, Enum.ContextActionPriority.High.Value, Enum.UserInputType.MouseWheel)
end

function MapHUD:_disconnectInput()
	for _, conn in self._conns do
		conn:Disconnect()
	end
	table.clear(self._conns)
	table.clear(self._touches)
	self._drag = nil
	self._pinchStart = nil
	ContextActionService:UnbindAction(ZOOM_ACTION)
end

-- ═══════════════════════════════════════════════════════════
-- API
-- ═══════════════════════════════════════════════════════════

function MapHUD:Open(bodies, systemName: string)
	if self._open then
		return
	end
	self._open = true

	self._title.Text = spaced(upper(systemName))
	self:_buildWorld(bodies)
	self._info.Visible = false
	self._selected = nil
	self._warpReady = false

	-- Sempre abre na visão geral, já no lugar (sem voar da última posição)
	self._yaw, self._yawTarget = YAW_DEFAULT, YAW_DEFAULT
	self._pitch, self._pitchTarget = PITCH_DEFAULT, PITCH_DEFAULT
	self._distance, self._distanceTarget = DISTANCE_DEFAULT, DISTANCE_DEFAULT
	self._focus, self._focusTarget = Vector3.zero, Vector3.zero

	self._gui.Enabled = true
	self._toggleGui.Enabled = false
	self:_layout()
	self:_connectInput()
	self:_step(0)
end

function MapHUD:Close()
	if not self._open then
		return
	end
	self._open = false
	self:_disconnectInput()
	self._gui.Enabled = false
	self:_clearWorld()
	self._toggleGui.Enabled = self._available
end

--- Warp pro corpo selecionado, se estiver no alcance (botão ou [F]).
function MapHUD:ActivateWarp(): boolean
	local entry = self._selected and self._entries[self._selected]
	if not entry or not self._warpReady or not self._onWarp then
		return false
	end
	self._onWarp(entry.body.id)
	return true
end

function MapHUD:SetWarpHandler(handler: (string) -> ())
	self._onWarp = handler
end

function MapHUD:IsOpen(): boolean
	return self._open
end

--- Mostra ou esconde o botão MAPA (quando o mapa está fechado).
function MapHUD:SetAvailable(available: boolean)
	if self._available == available then
		return
	end
	self._available = available
	self._toggleGui.Enabled = available and not self._open
	if available then
		self:_layout()
	end
end

function MapHUD:SetToggleHandler(handler: () -> ())
	self._onToggle = handler
end

function MapHUD:SetCloseHandler(handler: () -> ())
	self._onClose = handler
end

--- provider(body) -> { distance: number?, warp: ("inRange" | "outOfRange" | "unlimited" | "tooClose")? }
function MapHUD:SetInfoProvider(provider: (any) -> any)
	self._infoProvider = provider
end

--- provider() -> Vector3? (posição real do jogador ou da nave dele)
function MapHUD:SetPlayerPositionProvider(provider: () -> Vector3?)
	self._playerPositionProvider = provider
end

return MapHUD
