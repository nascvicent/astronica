--[[
	InventoryHUD
	Quick bar: 3D holográfica (SurfaceGui em Part que segue a câmera).
	Full inventory: 2D ScreenGui tela inteira (usa "InventoryGui" pré-existente).

	Estilo: minimalista monocromático — tudo branco, hierarquia feita por
	transparência (ver C / T abaixo) em vez de matiz.
	Para voltar às cores por categoria, basta MONOCHROME = false.
]]

local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")
local Players = game:GetService("Players")
local UserInputService = game:GetService("UserInputService")

local Shared = game:GetService("ReplicatedStorage").Shared
local InventoryModule = require(Shared.InventoryModule)
local ItemModels = require(Shared.ItemModels)

local player = Players.LocalPlayer
local playerGui = player:WaitForChild("PlayerGui")

-- ═══════════════════════════════════════════════════════════
-- Config
-- ═══════════════════════════════════════════════════════════

local PPS = 512

-- Quick bar (3 slots, bottom-right, ângulo holográfico)
local QB_PART_SIZE = Vector3.new(1.6, 0.45, 0.01)
local QB_DEPTH = 4          -- distância Z da câmera
local IS_MOBILE = UserInputService.TouchEnabled and not UserInputService.KeyboardEnabled
local QB_SCREEN_X = if IS_MOBILE then 0.35 else 0.62    -- mobile: mais perto do centro para não esbarrar nos botões de movimento
local QB_SCREEN_Y = 0.78    -- mesma altura do health
local QB_ROT_Y = -15
local QB_SLOT_COUNT = InventoryModule.HOTBAR_SLOTS

-- Toggle button (3D, à esquerda da quick bar)
local TB_PART_SIZE = Vector3.new(0.22, 0.22, 0.01)
local TB_OFFSET_X = 0.88    -- offset horizontal em relação à quick bar (positivo = direita)
local TB_OFFSET_Y = -0.17   -- offset vertical (negativo = para baixo); alinha a base com a dos slots

-- Full inventory (grid 2D)
local FULL_SLOT_COUNT = InventoryModule.DEFAULT_SLOTS
local FULL_COLS = 5
local FULL_CELL = 86        -- lado do slot em px (~16% maior que os 74 de antes)
local FULL_CELL_GAP = 10
local FULL_CELL_MIN = 56    -- abaixo disso o nome do item não cabe no slot

-- Layout compacto: telas baixas (celular deitado). O painel ocupa quase a tela
-- toda, o cabeçalho encolhe e o preview da direita passa a rolar.
local COMPACT_MAX_HEIGHT = 600
local COMPACT_MARGIN = 12
local COMPACT_PREVIEW_HEIGHT = 130
local SCROLLBAR = if IS_MOBILE then 6 else 2

-- Tabs
local TABS = { "Itens", "Traje", "Nave" }

-- Ícone 3D do item (ViewportFrame). Com false, volta pra abreviação em texto.
local ICON_3D = true
local ICON_SPIN_SPEED = 0.7   -- rad/s; 0 deixa o item parado no ângulo 3/4
-- TESTE: ícone com a cor original do modelo, para o item se destacar melhor
-- na quick bar. O resto do HUD segue monocromático. false volta pro cinza.
local ICON_COLOR = true

-- Preview 3D (painel da direita): personagem por padrão, item quando há um
-- sob o mouse ou selecionado
local PREVIEW_ITEM_SPIN = 0.6    -- rad/s
local PREVIEW_CHAR_SPIN = 0.35   -- rad/s
local PREVIEW_CHAR_FOV = 30
local PREVIEW_CHAR_PADDING = 1.12
local PREVIEW_CHAR_DIR = Vector3.new(0.3, 0.12, -1).Unit  -- de frente, levemente de cima
local PREVIEW_CHARACTER_KEY = "__character"

-- Brilho por raridade (tier vem de InventoryModule.Rarities)
local RARITY_STROKE_TIER = 2    -- a partir daqui a borda ganha a cor da raridade
local RARITY_GLOW_TIER = 3      -- + brilho subindo do fundo, pulsando
local RARITY_SHINE_TIER = 4     -- + reflexo percorrendo a borda
local RARITY_LINE = 0.3         -- transparência da borda colorida
local RARITY_PULSE_SPEED = 2.2  -- rad/s
local RARITY_SHINE_SPEED = 120  -- graus/s

-- ═══════════════════════════════════════════════════════════
-- Paleta — monocromática (teste "tudo branco")
-- ═══════════════════════════════════════════════════════════

local MONOCHROME = true

local WHITE = Color3.fromRGB(255, 255, 255)

local C = {
	overlay = Color3.fromRGB(0, 0, 0),
	panelBg = Color3.fromRGB(13, 14, 17),
	plate   = Color3.fromRGB(10, 11, 14),  -- placa escura dos HUDs 3D (contraste contra o céu)
	surface = WHITE,   -- sempre usado com transparência
	line    = WHITE,
	accent  = WHITE,
	text    = WHITE,
}

-- Escala de "cinzas": a hierarquia vem da transparência, não da cor
local T = {
	overlay       = 0.42,
	panel         = 0.08,
	panelLine     = 0.82,
	divider       = 0.9,
	-- slots dentro do painel (já apoiados em fundo escuro)
	slotEmptyBg   = 0.94,
	slotEmptyLine = 0.88,
	slotFillBg    = 0.87,
	slotFillLine  = 0.45,
	-- slots da quick bar / botão (soltos na tela, precisam de placa escura)
	plateEmptyBg   = 0.38,
	plateEmptyLine = 0.72,
	plateFillBg    = 0.16,
	plateFillLine  = 0.25,
	textPrimary   = 0,
	textSecondary = 0.35,
	textMuted     = 0.62,
	textFaint     = 0.8,
}

-- Cores por categoria (usadas apenas quando MONOCHROME = false)
local CATEGORY_COLOR = {
	resource   = Color3.fromRGB(60, 170, 255),
	consumable = Color3.fromRGB(70, 230, 130),
	tool       = Color3.fromRGB(255, 190, 50),
	quest      = Color3.fromRGB(190, 110, 255),
}

local function categoryColor(category: string?): Color3
	if MONOCHROME then
		return C.accent
	end
	return CATEGORY_COLOR[category or ""] or C.accent
end

-- ═══════════════════════════════════════════════════════════
-- Fontes
-- ═══════════════════════════════════════════════════════════

local JURA = "rbxasset://fonts/families/Jura.json"

local FONT_REGULAR = Font.new(JURA, Enum.FontWeight.Regular, Enum.FontStyle.Normal)
local FONT_MEDIUM = Font.new(JURA, Enum.FontWeight.Medium, Enum.FontStyle.Normal)
local FONT_BOLD = Font.new(JURA, Enum.FontWeight.Bold, Enum.FontStyle.Normal)

-- ═══════════════════════════════════════════════════════════
-- Helpers
-- ═══════════════════════════════════════════════════════════

-- "INVENTORY" -> "I N V E N T O R Y" (letter-spacing manual)
local function spaced(text: string): string
	local chars = {}
	for _, code in utf8.codes(text) do
		table.insert(chars, utf8.char(code))
	end
	return table.concat(chars, " ")
end

local function addCorner(parent: Instance, radius: number)
	local c = Instance.new("UICorner")
	c.CornerRadius = UDim.new(0, radius)
	c.Parent = parent
	return c
end

local function addStroke(parent: Instance, transparency: number, thickness: number?)
	local s = Instance.new("UIStroke")
	s.Color = C.line
	s.Thickness = thickness or 1
	s.Transparency = transparency
	s.Parent = parent
	return s
end

local function addLabel(parent: Instance, name: string, textSize: number, font: Font, transparency: number)
	local l = Instance.new("TextLabel")
	l.Name = name
	l.BackgroundTransparency = 1
	l.BorderSizePixel = 0
	l.Text = ""
	l.TextColor3 = C.text
	l.TextTransparency = transparency
	l.TextSize = textSize
	l.FontFace = font
	l.TextXAlignment = Enum.TextXAlignment.Left
	l.Parent = parent
	return l
end

local function addDivider(parent: Instance, horizontal: boolean)
	local d = Instance.new("Frame")
	d.Name = "Divider"
	d.BackgroundColor3 = C.line
	d.BackgroundTransparency = T.divider
	d.BorderSizePixel = 0
	d.Size = if horizontal then UDim2.new(1, 0, 0, 1) else UDim2.new(0, 1, 1, 0)
	d.Parent = parent
	return d
end

-- string.upper só mexe em ASCII: "Lendário" viraria "LENDáRIO"
local ACCENT_UPPER = {
	["á"] = "Á", ["à"] = "À", ["â"] = "Â", ["ã"] = "Ã",
	["é"] = "É", ["ê"] = "Ê", ["í"] = "Í",
	["ó"] = "Ó", ["ô"] = "Ô", ["õ"] = "Õ",
	["ú"] = "Ú", ["ç"] = "Ç",
}

local function upper(text: string): string
	for lower, up in ACCENT_UPPER do
		text = string.gsub(text, lower, up)
	end
	return string.upper(text)
end

--- Elementos do brilho de raridade dentro de um frame com borda:
--- glow = gradiente subindo do fundo; shine = UIGradient no UIStroke, que
--- pinta só a borda e gira para dar o reflexo.
local function addRarityFx(frame: GuiObject, stroke: UIStroke, radius: number)
	local glow = Instance.new("Frame")
	glow.Name = "RarityGlow"
	glow.Size = UDim2.fromScale(1, 1)
	glow.BackgroundColor3 = C.accent
	glow.BackgroundTransparency = 0.5
	glow.BorderSizePixel = 0
	glow.ZIndex = 0
	glow.Visible = false
	glow.Parent = frame
	addCorner(glow, radius)

	local glowGradient = Instance.new("UIGradient")
	glowGradient.Rotation = 90
	glowGradient.Transparency = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 1),
		NumberSequenceKeypoint.new(0.5, 0.88),
		NumberSequenceKeypoint.new(1, 0),
	})
	glowGradient.Parent = glow

	local shine = Instance.new("UIGradient")
	shine.Name = "Shine"
	shine.Enabled = false
	shine.Parent = stroke

	return glow, shine
end

--- Pinta borda/brilho/reflexo conforme a raridade. fx = { stroke, glow, shine }.
--- Abaixo de RARITY_STROKE_TIER a borda volta para baseColor/baseLine.
local function applyRarityFx(fx, rarity, baseColor: Color3, baseLine: number)
	local tier = if rarity then rarity.tier else 0
	local colored = tier >= RARITY_STROKE_TIER
	local shining = tier >= RARITY_SHINE_TIER

	fx.rarity = if colored then rarity else nil

	-- Com o reflexo ligado quem dá a cor é o gradiente (ele multiplica a cor da
	-- borda), então a borda fica branca por baixo
	fx.stroke.Color = if shining then WHITE elseif colored then rarity.color else baseColor
	fx.stroke.Transparency = if colored then RARITY_LINE else baseLine
	fx.stroke.Thickness = if tier >= RARITY_GLOW_TIER then 1.5 else 1

	fx.glow.Visible = tier >= RARITY_GLOW_TIER
	if colored then
		fx.glow.BackgroundColor3 = rarity.color
	end

	fx.shine.Enabled = shining
	if shining then
		local bright = rarity.color:Lerp(WHITE, 0.75)
		fx.shine.Color = ColorSequence.new({
			ColorSequenceKeypoint.new(0, rarity.color),
			ColorSequenceKeypoint.new(0.4, rarity.color),
			ColorSequenceKeypoint.new(0.5, bright),
			ColorSequenceKeypoint.new(0.6, rarity.color),
			ColorSequenceKeypoint.new(1, rarity.color),
		})
	end
end

local function animateRarityFx(fx, pulse: number, shineRotation: number)
	local rarity = fx.rarity
	if not rarity then return end

	if rarity.tier >= RARITY_GLOW_TIER then
		fx.glow.BackgroundTransparency = 0.6 - 0.35 * pulse
		fx.stroke.Transparency = RARITY_LINE - 0.25 * pulse
	end
	if rarity.tier >= RARITY_SHINE_TIER then
		fx.shine.Rotation = shineRotation
	end
end

-- ═══════════════════════════════════════════════════════════
-- Module
-- ═══════════════════════════════════════════════════════════

local InventoryHUD = {}
InventoryHUD.__index = InventoryHUD

function InventoryHUD.new()
	local self = setmetatable({}, InventoryHUD)

	self._folder = Instance.new("Folder")
	self._folder.Name = "InventoryHUD"
	self._folder.Parent = workspace

	-- Quick bar (3D)
	self._qbPart, self._qbGui = self:_createSurfacePart("QuickBar", QB_PART_SIZE)
	self._qbSlots = {}
	self:_buildQuickBar()

	-- Full inventory (2D ScreenGui)
	self._fullGui = playerGui:WaitForChild("InventoryGui")
	self._fullGui.Enabled = false
	-- Acima dos botões de toque (RUN, disparo), que cobririam o painel no mobile
	self._fullGui.DisplayOrder = math.max(self._fullGui.DisplayOrder, 10)
	self._fullSlots = {}
	self._activeTab = 1
	self._tabButtons = {}
	self:_buildFullInventory()

	-- Toggle button (3D, ao lado da quick bar)
	self._tbPart, self._tbGui = self:_createSurfacePart("ToggleBtn", TB_PART_SIZE)
	self:_buildToggleButton()

	-- State
	self._isOpen = false
	self._selectedSlot = nil
	self._hoveredSlot = nil
	self._onMove = nil

	-- Render loop (só quick bar 3D)
	self._iconSpin = 0
	self._previewSpin = 0
	self._previewSpinSpeed = 0
	self._fxTime = 0
	self._renderConn = RunService.RenderStepped:Connect(function(dt)
		self:_onRender(dt)
	end)

	return self
end

-- ═══════════════════════════════════════════════════════════
-- Part + SurfaceGui factory (só para quick bar)
-- ═══════════════════════════════════════════════════════════

function InventoryHUD:_createSurfacePart(name: string, size: Vector3)
	local part = Instance.new("Part")
	part.Name = "InvHUD_" .. name
	part.Size = size
	part.Anchored = true
	part.CanCollide = false
	part.CanQuery = false
	part.CanTouch = false
	part.CastShadow = false
	part.Transparency = 1
	part.Parent = self._folder

	local gui = Instance.new("SurfaceGui")
	gui.Name = name .. "_SGui"
	gui.Adornee = part
	gui.Face = Enum.NormalId.Back
	gui.AlwaysOnTop = true
	gui.PixelsPerStud = PPS
	gui.SizingMode = Enum.SurfaceGuiSizingMode.PixelsPerStud
	gui.LightInfluence = 0
	gui.ResetOnSpawn = false
	gui.Parent = playerGui

	return part, gui
end

-- ═══════════════════════════════════════════════════════════
-- Slot frame factory
-- ═══════════════════════════════════════════════════════════

-- dark = slot solto na tela (quick bar): placa escura para o branco ter contraste.
-- Sem dark = slot dentro do painel, que já tem fundo escuro próprio.
function InventoryHUD:_createSlotFrame(parent: Instance, showName: boolean, dark: boolean?)
	local slot = {}

	slot.bgEmpty = if dark then T.plateEmptyBg else T.slotEmptyBg
	slot.bgFill = if dark then T.plateFillBg else T.slotFillBg
	slot.lineEmpty = if dark then T.plateEmptyLine else T.slotEmptyLine
	slot.lineFill = if dark then T.plateFillLine else T.slotFillLine

	local frame = Instance.new("Frame")
	frame.Name = "Slot"
	frame.BackgroundColor3 = if dark then C.plate else C.surface
	frame.BackgroundTransparency = slot.bgEmpty
	frame.BorderSizePixel = 0
	addCorner(frame, 10)

	local slotStroke = addStroke(frame, slot.lineEmpty, 1)
	local glow, shine = addRarityFx(frame, slotStroke, 10)

	-- Ícone 3D do item (centro) — modelo num ViewportFrame
	local iconViewport = nil
	if ICON_3D then
		iconViewport = Instance.new("ViewportFrame")
		iconViewport.Name = "Icon3D"
		iconViewport.AnchorPoint = Vector2.new(0.5, 0.5)
		iconViewport.Size = UDim2.fromScale(if showName then 0.88 else 0.86, if showName then 0.64 else 0.86)
		iconViewport.Position = UDim2.fromScale(0.5, if showName then 0.34 else 0.5)
		iconViewport.BorderSizePixel = 0
		iconViewport.Visible = false
		ItemModels.StyleViewport(iconViewport)
		iconViewport.Parent = frame
	end

	-- Abreviação do item (centro) — fallback quando ICON_3D = false
	local abbrLabel = Instance.new("TextLabel")
	abbrLabel.Name = "Abbr"
	abbrLabel.Size = UDim2.new(1, 0, if showName then 0.62 else 1, 0)
	abbrLabel.Position = UDim2.new(0, 0, 0, 0)
	abbrLabel.BackgroundTransparency = 1
	abbrLabel.Text = ""
	abbrLabel.TextColor3 = C.text
	abbrLabel.TextTransparency = T.textSecondary
	abbrLabel.TextSize = if showName then 20 else 22
	abbrLabel.FontFace = FONT_MEDIUM
	abbrLabel.Parent = frame

	-- Quantidade (canto inferior direito)
	local qtyLabel = Instance.new("TextLabel")
	qtyLabel.Name = "Qty"
	qtyLabel.AnchorPoint = Vector2.new(1, 1)
	qtyLabel.Size = UDim2.new(0.6, 0, 0, if showName then 14 else 17)
	qtyLabel.Position = if showName then UDim2.new(1, -7, 0.66, 0) else UDim2.new(1, -7, 1, -6)
	qtyLabel.BackgroundTransparency = 1
	qtyLabel.Text = ""
	qtyLabel.TextColor3 = C.text
	qtyLabel.TextTransparency = T.textPrimary
	qtyLabel.TextSize = if showName then 13 else 16
	qtyLabel.FontFace = FONT_BOLD
	qtyLabel.TextXAlignment = Enum.TextXAlignment.Right
	qtyLabel.Parent = frame

	-- Nome do item (inferior, só no inventário completo)
	local nameLabel = nil
	if showName then
		nameLabel = Instance.new("TextLabel")
		nameLabel.Name = "ItemName"
		nameLabel.AnchorPoint = Vector2.new(0.5, 1)
		nameLabel.Size = UDim2.new(1, -10, 0, 12)
		nameLabel.Position = UDim2.new(0.5, 0, 1, -7)
		nameLabel.BackgroundTransparency = 1
		nameLabel.Text = ""
		nameLabel.TextColor3 = C.text
		nameLabel.TextTransparency = T.textMuted
		nameLabel.TextSize = 11
		nameLabel.FontFace = FONT_REGULAR
		nameLabel.TextXAlignment = Enum.TextXAlignment.Center
		nameLabel.TextTruncate = Enum.TextTruncate.AtEnd
		nameLabel.Parent = frame
	end

	slot.frame = frame
	slot.stroke = slotStroke
	slot.glow = glow
	slot.shine = shine
	slot.iconViewport = iconViewport
	slot.abbrLabel = abbrLabel
	slot.qtyLabel = qtyLabel
	slot.nameLabel = nameLabel
	frame.Parent = parent

	return slot
end

-- ═══════════════════════════════════════════════════════════
-- Seleção e movimentação de itens
-- ═══════════════════════════════════════════════════════════

--- Põe um botão invisível por cima do slot e um destaque de seleção.
--- O destaque é elemento separado de propósito: o _renderSlot reescreve
--- stroke e fundo a cada atualização e apagaria qualquer marca feita neles.
function InventoryHUD:_makeSlotInteractive(slot, index: number)
	local selectOverlay = Instance.new("Frame")
	selectOverlay.Name = "SelectOverlay"
	selectOverlay.Size = UDim2.new(1, 0, 1, 0)
	selectOverlay.BackgroundColor3 = C.accent
	selectOverlay.BackgroundTransparency = 0.78
	selectOverlay.BorderSizePixel = 0
	selectOverlay.ZIndex = 0
	selectOverlay.Visible = false
	selectOverlay.Parent = slot.frame
	addCorner(selectOverlay, 10)

	local button = Instance.new("TextButton")
	button.Name = "ClickArea"
	button.Size = UDim2.new(1, 0, 1, 0)
	button.BackgroundTransparency = 1
	button.Text = ""
	button.AutoButtonColor = false
	button.ZIndex = 10
	button.Parent = slot.frame

	button.Activated:Connect(function()
		self:_onSlotActivated(index)
	end)

	-- Hover mostra o item no preview (no mobile não existe: vale a seleção)
	button.MouseEnter:Connect(function()
		self:_setHovered(index)
	end)
	button.MouseLeave:Connect(function()
		if self._hoveredSlot == index then
			self:_setHovered(nil)
		end
	end)

	slot.selectOverlay = selectOverlay
	slot.button = button
end

function InventoryHUD:_setSelected(index: number?)
	self._selectedSlot = index

	for i, slot in self._fullSlots do
		if slot.selectOverlay then
			slot.selectOverlay.Visible = (i == index)
		end
	end

	self:_refreshPreview()
end

function InventoryHUD:_setHovered(index: number?)
	self._hoveredSlot = index
	self:_refreshPreview()
end

--- Primeiro clique escolhe o item, segundo clique diz para onde ele vai.
function InventoryHUD:_onSlotActivated(index: number)
	local selected = self._selectedSlot

	if selected == index then
		self:_setSelected(nil)
		return
	end

	if not selected then
		-- Clicar em slot vazio sem nada selecionado não faz nada
		local slot = self._fullSlots[index]
		if not slot or not slot.hasItem then
			return
		end
		self:_setSelected(index)
		return
	end

	self:_setSelected(nil)

	if self._onMove then
		self._onMove(selected, index)
	end
end

--- handler(fromSlot, toSlot) — quem fala com o servidor é o controller.
function InventoryHUD:SetMoveHandler(handler)
	self._onMove = handler
end

-- ═══════════════════════════════════════════════════════════
-- Toggle button (SurfaceGui lateral)
-- ═══════════════════════════════════════════════════════════

function InventoryHUD:_buildToggleButton()
	local container = Instance.new("Frame")
	container.Name = "Container"
	container.Size = UDim2.new(1, 0, 1, 0)
	container.BackgroundTransparency = 1
	container.Parent = self._tbGui

	local btn = Instance.new("TextButton")
	btn.Name = "ToggleBtn"
	btn.Size = UDim2.new(0.85, 0, 0.85, 0)
	btn.Position = UDim2.new(0.075, 0, 0.075, 0)
	btn.BackgroundColor3 = C.plate
	btn.BackgroundTransparency = T.plateEmptyBg
	btn.Text = ""
	btn.AutoButtonColor = false
	btn.BorderSizePixel = 0
	btn.Parent = container

	addCorner(btn, 10)
	self._btnStroke = addStroke(btn, T.plateEmptyLine, 1)

	local icon = Instance.new("ImageLabel")
	icon.Name = "Icon"
	icon.Size = UDim2.new(0.6, 0, 0.6, 0)
	icon.Position = UDim2.new(0.2, 0, 0.2, 0)
	icon.BackgroundTransparency = 1
	icon.Image = "rbxassetid://96507897375758"
	icon.ImageColor3 = C.accent
	icon.ImageTransparency = 0.25
	icon.ScaleType = Enum.ScaleType.Fit
	icon.Parent = btn

	self._toggleBtn = btn
	self._toggleIcon = icon

	-- Hover effect
	btn.MouseEnter:Connect(function()
		self._btnStroke.Transparency = T.plateFillLine
		btn.BackgroundTransparency = T.plateFillBg
		icon.ImageTransparency = 0
	end)

	btn.MouseLeave:Connect(function()
		self:_refreshToggleButton()
	end)

	btn.Activated:Connect(function()
		self:Toggle()
	end)
end

function InventoryHUD:_refreshToggleButton()
	if not self._toggleBtn then return end

	local open = self._isOpen
	self._btnStroke.Transparency = if open then T.plateFillLine else T.plateEmptyLine
	self._toggleBtn.BackgroundTransparency = if open then T.plateFillBg else T.plateEmptyBg
	self._toggleIcon.ImageTransparency = if open then 0 else 0.25
end

-- ═══════════════════════════════════════════════════════════
-- Quick bar
-- ═══════════════════════════════════════════════════════════

function InventoryHUD:_buildQuickBar()
	local container = Instance.new("Frame")
	container.Name = "Container"
	container.Size = UDim2.new(1, 0, 1, 0)
	container.BackgroundTransparency = 1
	container.Parent = self._qbGui

	local layout = Instance.new("UIListLayout")
	layout.FillDirection = Enum.FillDirection.Horizontal
	layout.HorizontalAlignment = Enum.HorizontalAlignment.Center
	layout.VerticalAlignment = Enum.VerticalAlignment.Center
	layout.Padding = UDim.new(0.025, 0)
	layout.SortOrder = Enum.SortOrder.LayoutOrder
	layout.Parent = container

	for i = 1, QB_SLOT_COUNT do
		local slot = self:_createSlotFrame(container, false, true)
		slot.frame.Size = UDim2.new(0.28, 0, 0.8, 0)
		slot.frame.LayoutOrder = i

		local aspect = Instance.new("UIAspectRatioConstraint")
		aspect.AspectRatio = 1
		aspect.Parent = slot.frame

		-- Número do slot (canto superior esquerdo, bem discreto)
		local index = Instance.new("TextLabel")
		index.Name = "Index"
		index.Size = UDim2.new(0, 20, 0, 16)
		index.Position = UDim2.new(0, 7, 0, 5)
		index.BackgroundTransparency = 1
		index.Text = tostring(i)
		index.TextColor3 = C.text
		index.TextTransparency = T.textFaint
		index.TextSize = 12
		index.FontFace = FONT_MEDIUM
		index.TextXAlignment = Enum.TextXAlignment.Left
		index.Parent = slot.frame

		-- Marca de "equipado": elemento próprio, não mexe no stroke/fundo que
		-- o _renderSlot reescreve a cada atualização de item.
		local equipMark = Instance.new("Frame")
		equipMark.Name = "EquipMark"
		equipMark.AnchorPoint = Vector2.new(0.5, 1)
		equipMark.Position = UDim2.new(0.5, 0, 1, -6)
		equipMark.Size = UDim2.new(0.5, 0, 0, 2)
		equipMark.BackgroundColor3 = C.accent
		equipMark.BackgroundTransparency = T.textPrimary
		equipMark.BorderSizePixel = 0
		equipMark.Visible = false
		equipMark.Parent = slot.frame

		slot.equipMark = equipMark

		-- Clique equipa/desequipa. É o único caminho no mobile, que não tem
		-- as teclas 1..N. Funciona no SurfaceGui mesmo com a Part CanQuery=false,
		-- igual ao botão de abrir o inventário.
		local button = Instance.new("TextButton")
		button.Name = "ClickArea"
		button.Size = UDim2.new(1, 0, 1, 0)
		button.BackgroundTransparency = 1
		button.Text = ""
		button.AutoButtonColor = false
		button.ZIndex = 10
		button.Parent = slot.frame

		button.Activated:Connect(function()
			if self._onHotbarActivate then
				self._onHotbarActivate(i)
			end
		end)

		slot.button = button

		self._qbSlots[i] = slot
	end
end

--- handler(slotIndex) — chamado ao clicar num slot da quick bar.
function InventoryHUD:SetHotbarHandler(handler)
	self._onHotbarActivate = handler
end

--- handler(isOpen) — chamado sempre que o inventário abre ou fecha.
function InventoryHUD:SetToggleHandler(handler)
	self._onToggle = handler
end

-- ═══════════════════════════════════════════════════════════
-- Full inventory
-- ═══════════════════════════════════════════════════════════

function InventoryHUD:_buildFullInventory()
	-- Overlay escuro tela inteira
	local bg = Instance.new("Frame")
	bg.Name = "Background"
	bg.Size = UDim2.new(1, 0, 1, 0)
	bg.BackgroundColor3 = C.overlay
	bg.BackgroundTransparency = 1          -- começa invisível
	bg.BorderSizePixel = 0
	bg.Parent = self._fullGui
	self._fullBg = bg

	-- Card central (CanvasGroup permite fade do conjunto inteiro)
	local panel = Instance.new("CanvasGroup")
	panel.Name = "Panel"
	panel.AnchorPoint = Vector2.new(0.5, 0.5)
	panel.Position = UDim2.new(0.5, 0, 0.5, 0)
	panel.Size = UDim2.new(0.82, 0, 0.78, 0)
	panel.BackgroundColor3 = C.panelBg
	panel.BackgroundTransparency = T.panel
	panel.BorderSizePixel = 0
	panel.GroupTransparency = 1
	panel.Parent = bg
	self._fullPanel = panel

	local sizeConstraint = Instance.new("UISizeConstraint")
	sizeConstraint.MaxSize = Vector2.new(1120, 700)
	sizeConstraint.MinSize = Vector2.new(420, 300)
	sizeConstraint.Parent = panel
	self._panelSizeConstraint = sizeConstraint

	addCorner(panel, 16)
	addStroke(panel, T.panelLine, 1)

	local panelPadding = Instance.new("UIPadding")
	panelPadding.PaddingTop = UDim.new(0, 26)
	panelPadding.PaddingBottom = UDim.new(0, 24)
	panelPadding.PaddingLeft = UDim.new(0, 30)
	panelPadding.PaddingRight = UDim.new(0, 30)
	panelPadding.Parent = panel
	self._panelPadding = panelPadding

	-- ══════════════════════════════════════════════
	-- Header: marca + título + BACK
	-- ══════════════════════════════════════════════
	local header = Instance.new("Frame")
	header.Name = "Header"
	header.Size = UDim2.new(1, 0, 0, 34)
	header.BackgroundTransparency = 1
	header.Parent = panel
	self._header = header

	-- Marca: duas barras inclinadas à esquerda do título
	local mark = Instance.new("Frame")
	mark.Name = "Mark"
	mark.AnchorPoint = Vector2.new(0, 0.5)
	mark.Position = UDim2.new(0, 0, 0.5, 0)
	mark.Size = UDim2.new(0, 26, 0, 26)
	mark.BackgroundTransparency = 1
	mark.Parent = header

	for i = 1, 2 do
		local bar = Instance.new("Frame")
		bar.Name = "Bar" .. i
		bar.Size = UDim2.new(0, 7, 0, 24)
		bar.Position = UDim2.new(0, (i - 1) * 12, 0, 1)
		bar.BackgroundColor3 = C.accent
		bar.BorderSizePixel = 0
		bar.Rotation = 8
		bar.Parent = mark
	end

	local title = addLabel(header, "Title", 24, FONT_BOLD, T.textPrimary)
	title.AnchorPoint = Vector2.new(0, 0.5)
	title.Position = UDim2.new(0, 44, 0.5, 0)
	title.Size = UDim2.new(0.6, 0, 1, 0)
	title.Text = spaced("INVENTORY")
	self._title = title

	-- BACK (fecha o painel)
	local backBtn = Instance.new("TextButton")
	backBtn.Name = "BackBtn"
	backBtn.AnchorPoint = Vector2.new(1, 0.5)
	backBtn.Position = UDim2.new(1, 0, 0.5, 0)
	backBtn.Size = UDim2.new(0, 120, 0, 28)
	backBtn.BackgroundTransparency = 1
	backBtn.Text = spaced("BACK") .. "   →"
	backBtn.TextColor3 = C.text
	backBtn.TextTransparency = T.textSecondary
	backBtn.TextSize = 15
	backBtn.FontFace = FONT_MEDIUM
	backBtn.TextXAlignment = Enum.TextXAlignment.Right
	backBtn.AutoButtonColor = false
	backBtn.BorderSizePixel = 0
	backBtn.Parent = header

	backBtn.MouseEnter:Connect(function()
		backBtn.TextTransparency = T.textPrimary
	end)
	backBtn.MouseLeave:Connect(function()
		backBtn.TextTransparency = T.textSecondary
	end)
	backBtn.Activated:Connect(function()
		self:Toggle()
	end)

	-- ══════════════════════════════════════════════
	-- Tabs (texto puro + underline no ativo)
	-- ══════════════════════════════════════════════
	local tabContainer = Instance.new("Frame")
	tabContainer.Name = "Tabs"
	tabContainer.Size = UDim2.new(1, 0, 0, 30)
	tabContainer.Position = UDim2.new(0, 0, 0, 52)
	tabContainer.BackgroundTransparency = 1
	tabContainer.Parent = panel
	self._tabContainer = tabContainer

	local tabLayout = Instance.new("UIListLayout")
	tabLayout.FillDirection = Enum.FillDirection.Horizontal
	tabLayout.HorizontalAlignment = Enum.HorizontalAlignment.Left
	tabLayout.VerticalAlignment = Enum.VerticalAlignment.Center
	tabLayout.Padding = UDim.new(0, 24)
	tabLayout.SortOrder = Enum.SortOrder.LayoutOrder
	tabLayout.Parent = tabContainer

	for i, tabName in ipairs(TABS) do
		local tabBtn = Instance.new("TextButton")
		tabBtn.Name = "Tab_" .. tabName
		tabBtn.Size = UDim2.new(0, 96, 1, 0)
		tabBtn.BackgroundTransparency = 1
		tabBtn.Text = spaced(string.upper(tabName))
		tabBtn.TextColor3 = C.text
		tabBtn.TextTransparency = if i == 1 then T.textPrimary else T.textMuted
		tabBtn.TextSize = 14
		tabBtn.FontFace = if i == 1 then FONT_MEDIUM else FONT_REGULAR
		tabBtn.AutoButtonColor = false
		tabBtn.BorderSizePixel = 0
		tabBtn.LayoutOrder = i
		tabBtn.Parent = tabContainer

		-- Underline do tab ativo
		local indicator = Instance.new("Frame")
		indicator.Name = "Indicator"
		indicator.AnchorPoint = Vector2.new(0.5, 1)
		indicator.Size = UDim2.new(0.8, 0, 0, 2)
		indicator.Position = UDim2.new(0.5, 0, 1, 0)
		indicator.BackgroundColor3 = C.accent
		indicator.BorderSizePixel = 0
		indicator.Visible = (i == 1)
		indicator.Parent = tabBtn

		self._tabButtons[i] = { button = tabBtn, indicator = indicator }

		tabBtn.Activated:Connect(function()
			self:_selectTab(i)
		end)
	end

	-- Linha separadora abaixo dos tabs
	local headerLine = addDivider(panel, true)
	headerLine.Name = "HeaderLine"
	headerLine.Position = UDim2.new(0, 0, 0, 84)
	self._headerLine = headerLine

	-- ══════════════════════════════════════════════
	-- Corpo: grid (esquerda) | preview (direita)
	-- ══════════════════════════════════════════════
	local body = Instance.new("Frame")
	body.Name = "Body"
	body.Size = UDim2.new(1, 0, 1, -104)
	body.Position = UDim2.new(0, 0, 0, 104)
	body.BackgroundTransparency = 1
	body.Parent = panel
	self._body = body

	-- ── Grid (sem caixa: só respiro) ──
	local scrollFrame = Instance.new("ScrollingFrame")
	scrollFrame.Name = "GridScroll"
	scrollFrame.Size = UDim2.new(0.56, 0, 1, 0)
	scrollFrame.Position = UDim2.new(0, 0, 0, 0)
	scrollFrame.BackgroundTransparency = 1
	scrollFrame.BorderSizePixel = 0
	scrollFrame.ScrollBarThickness = SCROLLBAR
	scrollFrame.ScrollBarImageColor3 = C.line
	scrollFrame.ScrollBarImageTransparency = 0.7
	scrollFrame.ScrollingDirection = Enum.ScrollingDirection.Y
	-- Calculado na mão pelo _updateGridCanvas, junto com o tamanho dos slots,
	-- em vez do AutomaticCanvasSize: garante que a última linha seja alcançável
	scrollFrame.CanvasSize = UDim2.new(0, 0, 0, 0)
	scrollFrame.Parent = body
	self._gridScroll = scrollFrame

	-- Respiro entre a borda do grid e o primeiro slot (topo/esquerda)
	local gridPadding = Instance.new("UIPadding")
	gridPadding.PaddingTop = UDim.new(0, 14)
	gridPadding.PaddingLeft = UDim.new(0, 14)
	gridPadding.PaddingRight = UDim.new(0, 10)
	gridPadding.PaddingBottom = UDim.new(0, 10)
	gridPadding.Parent = scrollFrame
	self._gridPadding = gridPadding

	local grid = Instance.new("UIGridLayout")
	grid.CellSize = UDim2.new(0, FULL_CELL, 0, FULL_CELL)
	grid.CellPadding = UDim2.new(0, FULL_CELL_GAP, 0, FULL_CELL_GAP)
	grid.FillDirection = Enum.FillDirection.Horizontal
	grid.FillDirectionMaxCells = FULL_COLS
	grid.HorizontalAlignment = Enum.HorizontalAlignment.Left
	grid.VerticalAlignment = Enum.VerticalAlignment.Top
	grid.SortOrder = Enum.SortOrder.LayoutOrder
	grid.Parent = scrollFrame
	self._gridLayout = grid

	for i = 1, FULL_SLOT_COUNT do
		local slot = self:_createSlotFrame(scrollFrame, true)
		slot.frame.LayoutOrder = i
		self:_makeSlotInteractive(slot, i)
		self._fullSlots[i] = slot
	end

	-- Divisória vertical entre grid e preview
	local bodyDivider = addDivider(body, false)
	bodyDivider.Name = "BodyDivider"
	bodyDivider.Position = UDim2.new(0.61, 0, 0, 0)

	-- ── Preview (direita) ──
	-- ScrollingFrame: no layout compacto a descrição não cabe e precisa rolar.
	-- Com CanvasSize zerado (layout normal) ele se comporta como um Frame comum.
	local previewSection = Instance.new("ScrollingFrame")
	previewSection.Name = "PreviewSection"
	previewSection.Size = UDim2.new(0.35, 0, 1, 0)
	previewSection.Position = UDim2.new(0.65, 0, 0, 0)
	previewSection.BackgroundTransparency = 1
	previewSection.BorderSizePixel = 0
	previewSection.ScrollBarThickness = SCROLLBAR
	previewSection.ScrollBarImageColor3 = C.line
	previewSection.ScrollBarImageTransparency = 0.7
	previewSection.ScrollingDirection = Enum.ScrollingDirection.Y
	previewSection.CanvasSize = UDim2.new(0, 0, 0, 0)
	previewSection.Parent = body
	self._previewSection = previewSection

	-- Mesmo respiro do grid, para "EQUIPMENT" alinhar com a primeira linha de slots.
	-- Laterais de 2px: o ScrollingFrame corta o contorno do viewport na borda
	local previewPadding = Instance.new("UIPadding")
	previewPadding.PaddingTop = UDim.new(0, 14)
	previewPadding.PaddingLeft = UDim.new(0, 2)
	previewPadding.PaddingRight = UDim.new(0, 2)
	previewPadding.Parent = previewSection
	self._previewPadding = previewPadding

	local prevTitle = addLabel(previewSection, "PreviewTitle", 13, FONT_MEDIUM, T.textMuted)
	prevTitle.Size = UDim2.new(1, 0, 0, 16)
	prevTitle.Position = UDim2.new(0, 0, 0, 0)
	prevTitle.Text = spaced("EQUIPMENT")

	-- Preview 3D: personagem por padrão, item quando há um em foco
	local viewportHolder = Instance.new("Frame")
	viewportHolder.Name = "ViewportHolder"
	viewportHolder.Size = UDim2.new(1, 0, 0.5, 0)
	viewportHolder.Position = UDim2.new(0, 0, 0, 30)
	viewportHolder.BackgroundColor3 = C.surface
	viewportHolder.BackgroundTransparency = 0.96
	viewportHolder.BorderSizePixel = 0
	viewportHolder.Parent = previewSection
	self._viewportHolder = viewportHolder

	addCorner(viewportHolder, 12)
	local previewStroke = addStroke(viewportHolder, T.slotEmptyLine, 1)
	local previewGlow, previewShine = addRarityFx(viewportHolder, previewStroke, 12)
	self._previewFx = { stroke = previewStroke, glow = previewGlow, shine = previewShine }

	local vpPlaceholder = addLabel(viewportHolder, "Placeholder", 12, FONT_REGULAR, 0.85)
	vpPlaceholder.Size = UDim2.new(1, 0, 1, 0)
	vpPlaceholder.Text = spaced("3D PREVIEW")
	vpPlaceholder.TextXAlignment = Enum.TextXAlignment.Center
	self._previewPlaceholder = vpPlaceholder

	local viewport = Instance.new("ViewportFrame")
	viewport.Name = "Viewport"
	viewport.Size = UDim2.new(1, -24, 1, -24)
	viewport.Position = UDim2.fromOffset(12, 12)
	viewport.BorderSizePixel = 0
	ItemModels.StyleViewport(viewport)
	viewport.Parent = viewportHolder
	self._previewViewport = viewport

	-- Info do item em foco (abaixo do viewport)
	local itemInfo = Instance.new("Frame")
	itemInfo.Name = "ItemInfo"
	itemInfo.Size = UDim2.new(1, 0, 0.5, -52)
	itemInfo.Position = UDim2.new(0, 0, 0.5, 48)
	itemInfo.BackgroundTransparency = 1
	itemInfo.Parent = previewSection
	self._itemInfoFrame = itemInfo

	-- Lista: a descrição tem altura variável e empurra a quantidade pra baixo
	local infoLayout = Instance.new("UIListLayout")
	infoLayout.FillDirection = Enum.FillDirection.Vertical
	infoLayout.Padding = UDim.new(0, 6)
	infoLayout.SortOrder = Enum.SortOrder.LayoutOrder
	infoLayout.Parent = itemInfo
	self._infoLayout = infoLayout

	local itemRarity = addLabel(itemInfo, "ItemRarity", 12, FONT_BOLD, T.textPrimary)
	itemRarity.Size = UDim2.new(1, 0, 0, 14)
	itemRarity.LayoutOrder = 1
	itemRarity.Visible = false
	self._previewItemRarity = itemRarity

	local itemName = addLabel(itemInfo, "ItemName", 18, FONT_MEDIUM, T.textPrimary)
	itemName.Size = UDim2.new(1, 0, 0, 22)
	itemName.LayoutOrder = 2
	itemName.TextTruncate = Enum.TextTruncate.AtEnd
	self._previewItemName = itemName

	local itemDesc = addLabel(itemInfo, "ItemDesc", 13, FONT_REGULAR, T.textSecondary)
	itemDesc.Size = UDim2.new(1, 0, 0, 0)
	itemDesc.AutomaticSize = Enum.AutomaticSize.Y
	itemDesc.LayoutOrder = 3
	itemDesc.TextYAlignment = Enum.TextYAlignment.Top
	itemDesc.TextWrapped = true
	self._previewItemDesc = itemDesc

	local itemQty = addLabel(itemInfo, "ItemQty", 13, FONT_MEDIUM, T.textMuted)
	itemQty.Size = UDim2.new(1, 0, 0, 18)
	itemQty.LayoutOrder = 4
	itemQty.Visible = false
	self._previewItemQty = itemQty

	-- Layout responsivo: recalcula quando a tela muda (rotação, janela redimensionada)
	self._fullGui:GetPropertyChangedSignal("AbsoluteSize"):Connect(function()
		self:_applyFullLayout()
	end)
	scrollFrame:GetPropertyChangedSignal("AbsoluteSize"):Connect(function()
		self:_fitGrid()
	end)
	grid:GetPropertyChangedSignal("AbsoluteContentSize"):Connect(function()
		self:_updateGridCanvas()
	end)
	infoLayout:GetPropertyChangedSignal("AbsoluteContentSize"):Connect(function()
		self:_updatePreviewCanvas()
	end)

	self:_applyFullLayout()
end

-- ═══════════════════════════════════════════════════════════
-- Layout responsivo do inventário completo
-- ═══════════════════════════════════════════════════════════

--- Alterna entre o layout normal e o compacto conforme a altura da tela.
--- No celular deitado o painel com MinSize 300 e cabeçalho de 104px não cabia.
function InventoryHUD:_applyFullLayout()
	local screen = self._fullGui.AbsoluteSize
	if screen.X <= 0 or screen.Y <= 0 then
		return
	end

	local compact = screen.Y < COMPACT_MAX_HEIGHT
	self._compact = compact

	if compact then
		self._fullPanel.Size = UDim2.new(1, -COMPACT_MARGIN * 2, 1, -COMPACT_MARGIN * 2)
		self._panelSizeConstraint.MinSize = Vector2.zero
	else
		self._fullPanel.Size = UDim2.new(0.82, 0, 0.78, 0)
		self._panelSizeConstraint.MinSize = Vector2.new(420, 300)
	end

	local pad = self._panelPadding
	pad.PaddingTop = UDim.new(0, if compact then 12 else 26)
	pad.PaddingBottom = UDim.new(0, if compact then 12 else 24)
	pad.PaddingLeft = UDim.new(0, if compact then 18 else 30)
	pad.PaddingRight = UDim.new(0, if compact then 18 else 30)

	self._header.Size = UDim2.new(1, 0, 0, if compact then 28 else 34)
	self._title.TextSize = if compact then 20 else 24
	self._tabContainer.Position = UDim2.new(0, 0, 0, if compact then 34 else 52)
	self._tabContainer.Size = UDim2.new(1, 0, 0, if compact then 26 else 30)
	self._headerLine.Position = UDim2.new(0, 0, 0, if compact then 64 else 84)

	local bodyTop = if compact then 72 else 104
	self._body.Size = UDim2.new(1, 0, 1, -bodyTop)
	self._body.Position = UDim2.new(0, 0, 0, bodyTop)

	-- Preview: no compacto vira coluna de altura fixa que rola; no normal
	-- continua dividido meio a meio entre viewport e descrição
	if compact then
		self._viewportHolder.Size = UDim2.new(1, 0, 0, COMPACT_PREVIEW_HEIGHT)
		self._itemInfoFrame.Position = UDim2.new(0, 0, 0, 30 + COMPACT_PREVIEW_HEIGHT + 14)
		self._itemInfoFrame.Size = UDim2.new(1, 0, 0, 0)
		-- A barra de rolagem ficaria por cima da borda direita do viewport
		self._previewPadding.PaddingRight = UDim.new(0, SCROLLBAR + 4)
	else
		self._viewportHolder.Size = UDim2.new(1, 0, 0.5, 0)
		self._itemInfoFrame.Position = UDim2.new(0, 0, 0.5, 48)
		self._itemInfoFrame.Size = UDim2.new(1, 0, 0.5, -52)
		self._previewPadding.PaddingRight = UDim.new(0, 2)
	end

	self:_fitGrid()
	self:_updatePreviewCanvas()
end

--- Encolhe os slots até as FULL_COLS colunas caberem na largura do grid.
--- Sem isso as últimas colunas ficavam cortadas fora da tela no mobile.
function InventoryHUD:_fitGrid()
	local scroll = self._gridScroll
	if scroll.AbsoluteSize.X <= 0 then
		return
	end

	local pad = self._gridPadding
	local inner = scroll.AbsoluteSize.X - pad.PaddingLeft.Offset - pad.PaddingRight.Offset - SCROLLBAR
	local cell = math.floor((inner - FULL_CELL_GAP * (FULL_COLS - 1)) / FULL_COLS)
	cell = math.clamp(cell, FULL_CELL_MIN, FULL_CELL)

	self._gridLayout.CellSize = UDim2.fromOffset(cell, cell)
	self:_updateGridCanvas()
end

function InventoryHUD:_updateGridCanvas()
	local pad = self._gridPadding
	local height = self._gridLayout.AbsoluteContentSize.Y + pad.PaddingTop.Offset + pad.PaddingBottom.Offset
	self._gridScroll.CanvasSize = UDim2.fromOffset(0, height)
end

function InventoryHUD:_updatePreviewCanvas()
	local section = self._previewSection
	if not self._compact then
		section.CanvasSize = UDim2.new(0, 0, 0, 0)
		return
	end

	local height = self._previewPadding.PaddingTop.Offset
		+ self._itemInfoFrame.Position.Y.Offset
		+ self._infoLayout.AbsoluteContentSize.Y
		+ 12
	section.CanvasSize = UDim2.fromOffset(0, height)
end

-- ═══════════════════════════════════════════════════════════
-- Preview 3D + descrição
-- ═══════════════════════════════════════════════════════════

--- Item sob o mouse tem prioridade; sem hover, vale o selecionado.
function InventoryHUD:_focusedSlotData()
	local hovered = self._hoveredSlot and self._fullSlots[self._hoveredSlot]
	if hovered and hovered.data then
		return hovered.data
	end

	local selected = self._selectedSlot and self._fullSlots[self._selectedSlot]
	return selected and selected.data
end

--- forceCharacter remonta o personagem mesmo se ele já estiver no preview
--- (roupa/acessórios podem ter mudado desde a última abertura).
function InventoryHUD:_refreshPreview(forceCharacter: boolean?)
	-- Painel fechado (ou fechando): nada a mostrar, e evita clonar o personagem à toa
	if not self._previewViewport or not self._isOpen then return end

	local data = self:_focusedSlotData()
	local def = data and InventoryModule.GetItemDef(data.itemId)

	if data and def then
		self:_showItemPreview(data, def)
	else
		self:_showCharacterPreview(forceCharacter)
	end
end

function InventoryHUD:_clearPreview()
	-- WorldModel é um Model, então o Clear do ItemModels leva o personagem junto
	ItemModels.Clear(self._previewViewport)
	self._previewModel = nil
	self._previewKey = nil
end

function InventoryHUD:_showItemPreview(slotData, def)
	if self._previewKey ~= slotData.itemId then
		self:_clearPreview()
		self._previewModel = ItemModels.Mount(self._previewViewport, slotData.itemId, false)
		self._previewKey = slotData.itemId
		self._previewSpin = 0
		self._previewSpinSpeed = PREVIEW_ITEM_SPIN
	end
	self._previewPlaceholder.Visible = self._previewModel == nil

	local rarity = InventoryModule.GetRarity(slotData.itemId)
	applyRarityFx(self._previewFx, rarity, C.line, T.slotEmptyLine)

	self._previewItemRarity.Visible = true
	self._previewItemRarity.Text = spaced(upper(rarity.name))
	self._previewItemRarity.TextColor3 = rarity.color

	self._previewItemName.Text = def.name
	self._previewItemDesc.Text = def.description or ""

	self._previewItemQty.Visible = def.maxStack > 1
	self._previewItemQty.Text = string.format("Quantidade: %d / %d", slotData.quantity, def.maxStack)
end

function InventoryHUD:_showCharacterPreview(force: boolean?)
	if force or self._previewKey ~= PREVIEW_CHARACTER_KEY then
		self:_clearPreview()
		self._previewModel = self:_mountCharacter()
		self._previewKey = PREVIEW_CHARACTER_KEY
		self._previewSpin = 0
		self._previewSpinSpeed = PREVIEW_CHAR_SPIN
	end
	self._previewPlaceholder.Visible = self._previewModel == nil

	applyRarityFx(self._previewFx, nil, C.line, T.slotEmptyLine)

	self._previewItemRarity.Visible = false
	self._previewItemName.Text = player.DisplayName
	self._previewItemDesc.Text = if IS_MOBILE
		then "Toque em um item para ver os detalhes."
		else "Passe o mouse sobre um item para ver os detalhes."
	self._previewItemQty.Visible = false
end

--- Cópia estática do personagem dentro de um WorldModel no viewport.
function InventoryHUD:_mountCharacter(): Model?
	local character = player.Character
	if not character or not character:FindFirstChild("HumanoidRootPart") then
		return nil
	end

	-- Character vem com Archivable = false, e aí o Clone devolve nil
	local wasArchivable = character.Archivable
	character.Archivable = true
	local clone = character:Clone()
	character.Archivable = wasArchivable
	if not clone then
		return nil
	end

	for _, inst in clone:GetDescendants() do
		if inst:IsA("Tool") or inst:IsA("LuaSourceContainer") or inst:IsA("Sound")
			or inst:IsA("Beam") or inst:IsA("Trail") or inst:IsA("ParticleEmitter")
			or inst:IsA("BillboardGui") or inst:IsA("ForceField") or inst:IsA("Highlight")
		then
			inst:Destroy()
		elseif inst:IsA("Motor6D") then
			-- Tira a pose da animação que estava tocando no momento do clone
			inst.Transform = CFrame.new()
		elseif inst:IsA("BasePart") then
			inst.CanCollide = false
			inst.CanQuery = false
			inst.CanTouch = false
			inst.CastShadow = false
		elseif inst:IsA("Humanoid") then
			inst.DisplayDistanceType = Enum.HumanoidDisplayDistanceType.None
		end
	end

	local root = clone:FindFirstChild("HumanoidRootPart") :: BasePart?
	if not root then
		clone:Destroy()
		return nil
	end
	root.Anchored = true
	clone.PrimaryPart = root

	local world = Instance.new("WorldModel")
	world.Name = "CharacterWorld"
	world.Parent = self._previewViewport
	clone.Parent = world

	-- Pivô no HumanoidRootPart: o giro fica em torno do eixo do corpo
	clone:PivotTo(CFrame.new())

	local bounds, size = clone:GetBoundingBox()
	local focus = bounds.Position
	local distance = (size.Y / 2) / math.tan(math.rad(PREVIEW_CHAR_FOV / 2)) * PREVIEW_CHAR_PADDING

	local cam = Instance.new("Camera")
	cam.FieldOfView = PREVIEW_CHAR_FOV
	cam.CFrame = CFrame.lookAt(focus + PREVIEW_CHAR_DIR * distance, focus)
	cam.Parent = self._previewViewport
	self._previewViewport.CurrentCamera = cam

	return clone
end

-- ═══════════════════════════════════════════════════════════
-- Slot rendering
-- ═══════════════════════════════════════════════════════════

--- Troca o item mostrado no slot. itemId = nil esvazia.
--- Só remonta o modelo quando o item muda: montar custa clone + câmera.
function InventoryHUD:_setSlotIcon(slotUI, itemId: string?)
	if not ICON_3D then
		-- Fallback em texto: iniciais do nome do item
		local def = itemId and InventoryModule.GetItemDef(itemId)
		local text = ""
		if def then
			for word in string.gmatch(def.name, "%S+") do
				text ..= string.upper(string.sub(word, 1, 1))
			end
		end
		slotUI.abbrLabel.Text = text
		return
	end

	slotUI.abbrLabel.Text = ""

	local viewport = slotUI.iconViewport
	if not viewport then return end

	if slotUI.iconItemId == itemId then
		return
	end
	slotUI.iconItemId = itemId

	if not itemId then
		ItemModels.Clear(viewport)
		slotUI.iconModel = nil
		viewport.Visible = false
		return
	end

	slotUI.iconModel = ItemModels.Mount(viewport, itemId, MONOCHROME and not ICON_COLOR)
	viewport.Visible = slotUI.iconModel ~= nil
end

function InventoryHUD:_renderSlot(slotUI, slotData)
	if not slotUI then return end

	if not slotData then
		slotUI.hasItem = false
		slotUI.data = nil
		applyRarityFx(slotUI, nil, C.line, slotUI.lineEmpty)
		self:_setSlotIcon(slotUI, nil)
		slotUI.qtyLabel.Text = ""
		slotUI.frame.BackgroundTransparency = slotUI.bgEmpty
		if slotUI.nameLabel then
			slotUI.nameLabel.Text = ""
		end
		return
	end

	local def = InventoryModule.GetItemDef(slotData.itemId)
	if not def then return end

	slotUI.hasItem = true
	slotUI.data = slotData

	local catColor = categoryColor(def.category)

	applyRarityFx(slotUI, InventoryModule.GetRarity(slotData.itemId), catColor, slotUI.lineFill)
	self:_setSlotIcon(slotUI, slotData.itemId)
	slotUI.abbrLabel.TextColor3 = catColor
	slotUI.abbrLabel.TextTransparency = T.textPrimary
	slotUI.frame.BackgroundTransparency = slotUI.bgFill

	if slotData.quantity > 1 then
		slotUI.qtyLabel.Text = tostring(slotData.quantity)
	else
		slotUI.qtyLabel.Text = ""
	end

	if slotUI.nameLabel then
		slotUI.nameLabel.Text = def.name
	end
end

-- ═══════════════════════════════════════════════════════════
-- Tab selection
-- ═══════════════════════════════════════════════════════════

function InventoryHUD:_selectTab(index: number)
	self._activeTab = index

	for i, tab in ipairs(self._tabButtons) do
		local isActive = (i == index)
		tab.button.TextTransparency = if isActive then T.textPrimary else T.textMuted
		tab.button.FontFace = if isActive then FONT_MEDIUM else FONT_REGULAR
		tab.indicator.Visible = isActive
	end

	-- TODO: filtrar conteúdo da grid por tab (Itens/Traje/Nave)
end

-- ═══════════════════════════════════════════════════════════
-- Public API
-- ═══════════════════════════════════════════════════════════

function InventoryHUD:UpdateSlot(slotIndex: number, slotData)
	if slotIndex >= 1 and slotIndex <= QB_SLOT_COUNT then
		self:_renderSlot(self._qbSlots[slotIndex], slotData)
	end

	if slotIndex >= 1 and slotIndex <= FULL_SLOT_COUNT then
		self:_renderSlot(self._fullSlots[slotIndex], slotData)

		-- Item em foco mudou (quantidade, trocou de lugar): atualiza o painel
		if self._isOpen and (slotIndex == self._hoveredSlot or slotIndex == self._selectedSlot) then
			self:_refreshPreview()
		end
	end
end

--- Destaca o slot da hotbar que está equipado. 0 ou nil = nenhum.
function InventoryHUD:SetEquippedSlot(slotIndex: number?)
	for i = 1, QB_SLOT_COUNT do
		local slotUI = self._qbSlots[i]
		if slotUI and slotUI.equipMark then
			slotUI.equipMark.Visible = (i == slotIndex)
		end
	end
end

function InventoryHUD:UpdateAll(inventory)
	for i = 1, FULL_SLOT_COUNT do
		self:_renderSlot(self._fullSlots[i], inventory.slots[i])
	end
	for i = 1, QB_SLOT_COUNT do
		self:_renderSlot(self._qbSlots[i], inventory.slots[i])
	end

	if self._isOpen then
		self:_refreshPreview()
	end
end

local TWEEN_OPEN  = TweenInfo.new(0.3, Enum.EasingStyle.Quart, Enum.EasingDirection.Out)
local TWEEN_CLOSE = TweenInfo.new(0.22, Enum.EasingStyle.Quart, Enum.EasingDirection.In)

function InventoryHUD:Toggle()
	self._isOpen = not self._isOpen
	self:_refreshToggleButton()

	if self._onToggle then
		self._onToggle(self._isOpen)
	end

	if self._isOpen then
		-- ── ABRIR: fade + leve subida ──────────────
		self._fullGui.Enabled = true
		-- Com a GUI desligada o AbsoluteSize pode não ter sido medido ainda
		self:_applyFullLayout()
		self:_refreshPreview(true)

		self._fullBg.BackgroundTransparency = 1
		self._fullPanel.GroupTransparency = 1
		self._fullPanel.Position = UDim2.new(0.5, 0, 0.5, 18)

		TweenService:Create(self._fullBg, TWEEN_OPEN, {
			BackgroundTransparency = T.overlay,
		}):Play()

		TweenService:Create(self._fullPanel, TWEEN_OPEN, {
			GroupTransparency = 0,
			Position = UDim2.new(0.5, 0, 0.5, 0),
		}):Play()
	else
		-- ── FECHAR ─────────────────────────────────
		-- Seleção não sobrevive ao fechamento: reabrir com um slot ainda
		-- marcado faria o próximo clique mover um item sem querer.
		-- MouseLeave não dispara com a GUI sumindo: limpa o hover na mão
		self._hoveredSlot = nil
		self:_setSelected(nil)

		TweenService:Create(self._fullBg, TWEEN_CLOSE, {
			BackgroundTransparency = 1,
		}):Play()

		local fadeTween = TweenService:Create(self._fullPanel, TWEEN_CLOSE, {
			GroupTransparency = 1,
			Position = UDim2.new(0.5, 0, 0.5, 14),
		})
		fadeTween:Play()

		-- Desabilita a GUI só depois da animação acabar
		fadeTween.Completed:Once(function()
			if not self._isOpen then
				self._fullGui.Enabled = false
				-- A cópia do personagem não precisa ficar viva com o painel fechado
				self:_clearPreview()
			end
		end)
	end
end

function InventoryHUD:IsOpen(): boolean
	return self._isOpen
end

function InventoryHUD:SetVisible(show: boolean)
	if self._qbGui then
		self._qbGui.Enabled = show
	end
	if self._tbGui then
		self._tbGui.Enabled = show
	end
	if self._folder then
		self._folder.Parent = if show then workspace else nil
	end
	-- Se escondendo, fecha o inventário completo também
	if not show and self._isOpen then
		self._isOpen = false
		self._fullGui.Enabled = false
		self:_refreshToggleButton()
	end
end

-- ═══════════════════════════════════════════════════════════
-- Camera follow (só quick bar 3D)
-- ═══════════════════════════════════════════════════════════

--- Gira os modelos dos slots visíveis. Os do inventário completo ficam
--- parados enquanto o painel está fechado — não adianta girar o que ninguém vê.
function InventoryHUD:_spinIcons(dt: number)
	if not ICON_3D or ICON_SPIN_SPEED <= 0 then return end

	self._iconSpin = (self._iconSpin + dt * ICON_SPIN_SPEED) % (2 * math.pi)
	local pivot = CFrame.Angles(0, self._iconSpin, 0)

	for _, slot in self._qbSlots do
		if slot.iconModel then
			slot.iconModel:PivotTo(pivot)
		end
	end

	if self._isOpen then
		for _, slot in self._fullSlots do
			if slot.iconModel then
				slot.iconModel:PivotTo(pivot)
			end
		end
	end
end

--- Gira o modelo do preview e anima o brilho dos itens raros.
function InventoryHUD:_animateFx(dt: number)
	self._fxTime += dt
	local pulse = 0.5 + 0.5 * math.sin(self._fxTime * RARITY_PULSE_SPEED)
	local shineRotation = (self._fxTime * RARITY_SHINE_SPEED) % 360

	for _, slot in self._qbSlots do
		animateRarityFx(slot, pulse, shineRotation)
	end

	if not self._isOpen then return end

	for _, slot in self._fullSlots do
		animateRarityFx(slot, pulse, shineRotation)
	end
	animateRarityFx(self._previewFx, pulse, shineRotation)

	if self._previewModel and self._previewSpinSpeed > 0 then
		self._previewSpin = (self._previewSpin + dt * self._previewSpinSpeed) % (2 * math.pi)
		self._previewModel:PivotTo(CFrame.Angles(0, self._previewSpin, 0))
	end
end

function InventoryHUD:_onRender(dt: number)
	self:_spinIcons(dt)
	self:_animateFx(dt)

	local cam = workspace.CurrentCamera
	if not cam then return end

	-- Calcula tamanho visível no mundo à distância QB_DEPTH usando FOV
	local fovRad = math.rad(cam.FieldOfView)
	local halfH = QB_DEPTH * math.tan(fovRad / 2)
	local halfW = halfH * (cam.ViewportSize.X / cam.ViewportSize.Y)

	local worldX = halfW * QB_SCREEN_X
	local worldY = halfH * -QB_SCREEN_Y -- Y negativo no mundo = baixo da tela

	self._qbPart.CFrame = cam.CFrame
		* CFrame.new(worldX, worldY, -QB_DEPTH)
		* CFrame.Angles(0, math.rad(QB_ROT_Y), 0)

	-- Toggle button ao lado da quick bar (compensa diferença de altura dos parts)
	local tbYOffset = (QB_PART_SIZE.Y - TB_PART_SIZE.Y) / 2 + TB_OFFSET_Y
	self._tbPart.CFrame = cam.CFrame
		* CFrame.new(worldX + TB_OFFSET_X, worldY + tbYOffset, -QB_DEPTH)
		* CFrame.Angles(0, math.rad(QB_ROT_Y), 0)
end

-- ═══════════════════════════════════════════════════════════
-- Cleanup
-- ═══════════════════════════════════════════════════════════

function InventoryHUD:Destroy()
	if self._renderConn then
		self._renderConn:Disconnect()
		self._renderConn = nil
	end
	if self._qbGui then
		self._qbGui:Destroy()
	end
	-- InventoryGui é pré-existente, só esconde
	if self._fullGui then
		self._fullGui.Enabled = false
	end
	if self._tbGui then
		self._tbGui:Destroy()
	end
	if self._folder then
		self._folder:Destroy()
	end
end

return InventoryHUD
