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
local FULL_COLS = 6
local FULL_ROWS = 6

-- Tabs
local TABS = { "Itens", "Traje", "Nave" }

-- Ícone 3D do item (ViewportFrame). Com false, volta pra abreviação em texto.
local ICON_3D = true
local ICON_SPIN_SPEED = 0.7   -- rad/s; 0 deixa o item parado no ângulo 3/4

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
	self._onMove = nil

	-- Render loop (só quick bar 3D)
	self._iconSpin = 0
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

	-- Ícone 3D do item (centro) — modelo num ViewportFrame
	local iconViewport = nil
	if ICON_3D then
		iconViewport = Instance.new("ViewportFrame")
		iconViewport.Name = "Icon3D"
		iconViewport.AnchorPoint = Vector2.new(0.5, 0.5)
		iconViewport.Size = UDim2.fromScale(0.7, if showName then 0.54 else 0.7)
		iconViewport.Position = UDim2.fromScale(0.5, if showName then 0.32 else 0.5)
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
	qtyLabel.Size = UDim2.new(0.6, 0, 0, 14)
	qtyLabel.Position = if showName then UDim2.new(1, -7, 0.66, 0) else UDim2.new(1, -7, 1, -6)
	qtyLabel.BackgroundTransparency = 1
	qtyLabel.Text = ""
	qtyLabel.TextColor3 = C.text
	qtyLabel.TextTransparency = T.textPrimary
	qtyLabel.TextSize = 13
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

	addCorner(panel, 16)
	addStroke(panel, T.panelLine, 1)

	local panelPadding = Instance.new("UIPadding")
	panelPadding.PaddingTop = UDim.new(0, 26)
	panelPadding.PaddingBottom = UDim.new(0, 24)
	panelPadding.PaddingLeft = UDim.new(0, 30)
	panelPadding.PaddingRight = UDim.new(0, 30)
	panelPadding.Parent = panel

	-- ══════════════════════════════════════════════
	-- Header: marca + título + BACK
	-- ══════════════════════════════════════════════
	local header = Instance.new("Frame")
	header.Name = "Header"
	header.Size = UDim2.new(1, 0, 0, 34)
	header.BackgroundTransparency = 1
	header.Parent = panel

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

	-- ══════════════════════════════════════════════
	-- Corpo: grid (esquerda) | preview (direita)
	-- ══════════════════════════════════════════════
	local body = Instance.new("Frame")
	body.Name = "Body"
	body.Size = UDim2.new(1, 0, 1, -104)
	body.Position = UDim2.new(0, 0, 0, 104)
	body.BackgroundTransparency = 1
	body.Parent = panel

	-- ── Grid (sem caixa: só respiro) ──
	local scrollFrame = Instance.new("ScrollingFrame")
	scrollFrame.Name = "GridScroll"
	scrollFrame.Size = UDim2.new(0.56, 0, 1, 0)
	scrollFrame.Position = UDim2.new(0, 0, 0, 0)
	scrollFrame.BackgroundTransparency = 1
	scrollFrame.BorderSizePixel = 0
	scrollFrame.ScrollBarThickness = 2
	scrollFrame.ScrollBarImageColor3 = C.line
	scrollFrame.ScrollBarImageTransparency = 0.7
	scrollFrame.CanvasSize = UDim2.new(0, 0, 0, 0) -- auto-ajustado pelo grid
	scrollFrame.AutomaticCanvasSize = Enum.AutomaticSize.Y
	scrollFrame.Parent = body

	-- Respiro entre a borda do grid e o primeiro slot (topo/esquerda)
	local gridPadding = Instance.new("UIPadding")
	gridPadding.PaddingTop = UDim.new(0, 14)
	gridPadding.PaddingLeft = UDim.new(0, 14)
	gridPadding.PaddingRight = UDim.new(0, 10)
	gridPadding.PaddingBottom = UDim.new(0, 10)
	gridPadding.Parent = scrollFrame

	local grid = Instance.new("UIGridLayout")
	grid.CellSize = UDim2.new(0, 74, 0, 74)
	grid.CellPadding = UDim2.new(0, 10, 0, 10)
	grid.FillDirection = Enum.FillDirection.Horizontal
	grid.HorizontalAlignment = Enum.HorizontalAlignment.Left
	grid.VerticalAlignment = Enum.VerticalAlignment.Top
	grid.SortOrder = Enum.SortOrder.LayoutOrder
	grid.Parent = scrollFrame
	self._gridLayout = grid

	for i = 1, FULL_COLS * FULL_ROWS do
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
	local previewSection = Instance.new("Frame")
	previewSection.Name = "PreviewSection"
	previewSection.Size = UDim2.new(0.35, 0, 1, 0)
	previewSection.Position = UDim2.new(0.65, 0, 0, 0)
	previewSection.BackgroundTransparency = 1
	previewSection.Parent = body

	-- Mesmo respiro do grid, para "EQUIPMENT" alinhar com a primeira linha de slots
	local previewPadding = Instance.new("UIPadding")
	previewPadding.PaddingTop = UDim.new(0, 14)
	previewPadding.Parent = previewSection

	local prevTitle = addLabel(previewSection, "PreviewTitle", 13, FONT_MEDIUM, T.textMuted)
	prevTitle.Size = UDim2.new(1, 0, 0, 16)
	prevTitle.Position = UDim2.new(0, 0, 0, 0)
	prevTitle.Text = spaced("EQUIPMENT")

	-- Frame reservado para ViewportFrame (preview 3D do item)
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
	addStroke(viewportHolder, T.slotEmptyLine, 1)

	local vpPlaceholder = addLabel(viewportHolder, "Placeholder", 12, FONT_REGULAR, 0.85)
	vpPlaceholder.Size = UDim2.new(1, 0, 1, 0)
	vpPlaceholder.Text = spaced("3D PREVIEW")
	vpPlaceholder.TextXAlignment = Enum.TextXAlignment.Center

	-- Info do item selecionado (abaixo do viewport)
	local itemInfo = Instance.new("Frame")
	itemInfo.Name = "ItemInfo"
	itemInfo.Size = UDim2.new(1, 0, 0.5, -52)
	itemInfo.Position = UDim2.new(0, 0, 0.5, 48)
	itemInfo.BackgroundTransparency = 1
	itemInfo.Parent = previewSection
	self._itemInfoFrame = itemInfo

	local itemName = addLabel(itemInfo, "ItemName", 18, FONT_MEDIUM, T.textPrimary)
	itemName.Size = UDim2.new(1, 0, 0, 22)
	itemName.Position = UDim2.new(0, 0, 0, 0)
	self._previewItemName = itemName

	local itemDesc = addLabel(itemInfo, "ItemDesc", 12, FONT_REGULAR, T.textMuted)
	itemDesc.Size = UDim2.new(1, 0, 0, 36)
	itemDesc.Position = UDim2.new(0, 0, 0, 28)
	itemDesc.TextYAlignment = Enum.TextYAlignment.Top
	itemDesc.TextWrapped = true
	self._previewItemDesc = itemDesc

	local itemQty = addLabel(itemInfo, "ItemQty", 13, FONT_MEDIUM, T.textSecondary)
	itemQty.Size = UDim2.new(1, 0, 0, 18)
	itemQty.Position = UDim2.new(0, 0, 0, 70)
	self._previewItemQty = itemQty
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

	slotUI.iconModel = ItemModels.Mount(viewport, itemId, MONOCHROME)
	viewport.Visible = slotUI.iconModel ~= nil
end

function InventoryHUD:_renderSlot(slotUI, slotData)
	if not slotUI then return end

	if not slotData then
		slotUI.hasItem = false
		slotUI.stroke.Color = C.line
		slotUI.stroke.Transparency = slotUI.lineEmpty
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

	local catColor = categoryColor(def.category)

	slotUI.stroke.Color = catColor
	slotUI.stroke.Transparency = slotUI.lineFill
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

	if slotIndex >= 1 and slotIndex <= FULL_COLS * FULL_ROWS then
		self:_renderSlot(self._fullSlots[slotIndex], slotData)
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
	for i = 1, FULL_COLS * FULL_ROWS do
		self:_renderSlot(self._fullSlots[i], inventory.slots[i])
	end
	for i = 1, QB_SLOT_COUNT do
		self:_renderSlot(self._qbSlots[i], inventory.slots[i])
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

function InventoryHUD:_onRender(dt: number)
	self:_spinIcons(dt)

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
