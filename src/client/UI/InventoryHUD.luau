--[[
	InventoryHUD
	Quick bar: 3D holográfica (SurfaceGui em Part que segue a câmera).
	Full inventory: 2D ScreenGui tela inteira (usa "InventoryGui" pré-existente).
]]

local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")
local Players = game:GetService("Players")
local UserInputService = game:GetService("UserInputService")

local InventoryModule = require(game:GetService("ReplicatedStorage").Shared.InventoryModule)

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
local QB_SLOT_COUNT = 3

-- Toggle button (3D, à esquerda da quick bar)
local TB_PART_SIZE = Vector3.new(0.35, 0.35, 0.01)
local TB_OFFSET_X = 0.95    -- offset horizontal em relação à quick bar (positivo = direita)
local TB_OFFSET_Y = -0.13   -- offset vertical (negativo = para baixo)

-- Full inventory (grid 2D)
local FULL_COLS = 6
local FULL_ROWS = 6

-- Tabs
local TABS = { "Itens", "Traje", "Nave" }

-- Cores (tema sci-fi / holográfico)
local C = {
	panelBg     = Color3.fromRGB(6, 10, 22),
	slotBg      = Color3.fromRGB(12, 18, 35),
	borderEmpty = Color3.fromRGB(35, 50, 80),
	text        = Color3.fromRGB(160, 195, 230),
	textDim     = Color3.fromRGB(80, 110, 140),
	quantity    = Color3.fromRGB(240, 250, 255),
	title       = Color3.fromRGB(0, 200, 240),
	resource    = Color3.fromRGB(60, 170, 255),
	consumable  = Color3.fromRGB(70, 230, 130),
	tool        = Color3.fromRGB(255, 190, 50),
	quest       = Color3.fromRGB(190, 110, 255),
}

local CATEGORY_COLOR = {
	resource   = C.resource,
	consumable = C.consumable,
	tool       = C.tool,
	quest      = C.quest,
}

-- ═══════════════════════════════════════════════════════════
-- Helpers
-- ═══════════════════════════════════════════════════════════

local function getInitials(name: string): string
	local initials = ""
	for word in string.gmatch(name, "%S+") do
		initials ..= string.upper(string.sub(word, 1, 1))
	end
	return initials
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

	-- Render loop (só quick bar 3D)
	self._renderConn = RunService.RenderStepped:Connect(function()
		self:_onRender()
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

function InventoryHUD:_createSlotFrame(parent: Instance, showName: boolean)
	local slot = {}

	local frame = Instance.new("Frame")
	frame.BackgroundColor3 = C.slotBg
	frame.BackgroundTransparency = 0.4
	frame.BorderSizePixel = 0

	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, 8)
	corner.Parent = frame

	local stroke = Instance.new("UIStroke")
	stroke.Color = C.borderEmpty
	stroke.Thickness = 2
	stroke.Transparency = 0.5
	stroke.Parent = frame

	-- Abreviação do item (centro)
	local abbrLabel = Instance.new("TextLabel")
	abbrLabel.Name = "Abbr"
	abbrLabel.Size = UDim2.new(1, 0, 0.55, 0)
	abbrLabel.Position = UDim2.new(0, 0, 0.05, 0)
	abbrLabel.BackgroundTransparency = 1
	abbrLabel.Text = ""
	abbrLabel.TextColor3 = C.text
	abbrLabel.TextScaled = true
	abbrLabel.Font = Enum.Font.Jura
	abbrLabel.Parent = frame

	-- Quantidade (canto inferior direito)
	local qtyLabel = Instance.new("TextLabel")
	qtyLabel.Name = "Qty"
	qtyLabel.Size = UDim2.new(0.45, 0, 0.25, 0)
	qtyLabel.Position = UDim2.new(0.52, 0, 0.72, 0)
	qtyLabel.BackgroundTransparency = 1
	qtyLabel.Text = ""
	qtyLabel.TextColor3 = C.quantity
	qtyLabel.TextScaled = true

-- Bold aplicado corretamente
qtyLabel.FontFace = Font.new(
    "rbxasset://fonts/families/Jura.json",
    Enum.FontWeight.Bold,
    Enum.FontStyle.Normal
)

qtyLabel.TextXAlignment = Enum.TextXAlignment.Right
qtyLabel.Parent = frame

	-- Nome do item (inferior, só no inventário completo)
	local nameLabel = nil
	if showName then
		nameLabel = Instance.new("TextLabel")
		nameLabel.Name = "ItemName"
		nameLabel.Size = UDim2.new(1, -4, 0.18, 0)
		nameLabel.Position = UDim2.new(0, 2, 0.8, 0)
		nameLabel.BackgroundTransparency = 1
		nameLabel.Text = ""
		nameLabel.TextColor3 = C.textDim
		nameLabel.TextScaled = true
		nameLabel.Font = Enum.Font.Jura
		nameLabel.TextTruncate = Enum.TextTruncate.AtEnd
		nameLabel.Parent = frame
	end

	slot.frame = frame
	slot.stroke = stroke
	slot.abbrLabel = abbrLabel
	slot.qtyLabel = qtyLabel
	slot.nameLabel = nameLabel
	frame.Parent = parent

	return slot
end

-- ═══════════════════════════════════════════════════════════
-- Toggle button (ScreenGui lateral)
-- ═══════════════════════════════════════════════════════════

function InventoryHUD:_buildToggleButton()
	local container = Instance.new("Frame")
	container.Name = "Container"
	container.Size = UDim2.new(1, 0, 1, 0)
	container.BackgroundTransparency = 1
	container.Parent = self._tbGui

	-- Botão 3D holográfico
	local btn = Instance.new("TextButton")
	btn.Name = "ToggleBtn"
	btn.Size = UDim2.new(0.85, 0, 0.85, 0)
	btn.Position = UDim2.new(0.075, 0, 0.075, 0)
	btn.BackgroundColor3 = C.slotBg
	btn.BackgroundTransparency = 0.4
	btn.Text = ""
	btn.AutoButtonColor = false
	btn.Parent = container

	local btnCorner = Instance.new("UICorner")
	btnCorner.CornerRadius = UDim.new(0, 8)
	btnCorner.Parent = btn

	local btnStroke = Instance.new("UIStroke")
	btnStroke.Color = C.title
	btnStroke.Thickness = 2
	btnStroke.Transparency = 0.4
	btnStroke.Parent = btn
	self._btnStroke = btnStroke

	-- Ícone
	local icon = Instance.new("ImageLabel")
	icon.Name = "Icon"
	icon.Size = UDim2.new(0.7, 0, 0.7, 0)
	icon.Position = UDim2.new(0.15, 0, 0.15, 0)
	icon.BackgroundTransparency = 1
	icon.Image = "rbxassetid://96507897375758"
	icon.ImageColor3 = C.title
	icon.ScaleType = Enum.ScaleType.Fit
	icon.Parent = btn

	self._toggleBtn = btn
	self._toggleIcon = icon

	-- Hover effect
	btn.MouseEnter:Connect(function()
		btnStroke.Transparency = 0
		btn.BackgroundTransparency = 0.15
	end)

	btn.MouseLeave:Connect(function()
		local t = if self._isOpen then 0.1 else 0.4
		btnStroke.Transparency = t
		btn.BackgroundTransparency = 0.4
	end)

	-- Click toggle
	btn.Activated:Connect(function()
		self:Toggle()
	end)
end

-- ═══════════════════════════════════════════════════════════
-- Build UI layouts
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
	layout.Padding = UDim.new(0.02, 0)
	layout.Parent = container

	for i = 1, QB_SLOT_COUNT do
		local slot = self:_createSlotFrame(container, false)
		slot.frame.Size = UDim2.new(0.3, 0, 0.85, 0)
		slot.frame.LayoutOrder = i

		local aspect = Instance.new("UIAspectRatioConstraint")
		aspect.AspectRatio = 1
		aspect.Parent = slot.frame

		self._qbSlots[i] = slot
	end
end

function InventoryHUD:_buildFullInventory()
	-- Fundo escuro tela inteira (overlay)
	local bg = Instance.new("Frame")
	bg.Name = "Background"
	bg.Size = UDim2.new(1, 0, 1, 0)
	bg.BackgroundColor3 = Color3.fromRGB(0, 0, 0)
	bg.BackgroundTransparency = 1          -- começa invisível
	bg.BorderSizePixel = 0
	bg.ClipsDescendants = true
	bg.Parent = self._fullGui
	self._fullBg = bg

	-- Painel principal — começa fora da tela (à direita)
	local panel = Instance.new("Frame")
	panel.Name = "Panel"
	panel.Size = UDim2.new(1, 0, 1, 0)
	panel.Position = UDim2.new(1, 0, 0, 0)   -- fora da tela (direita)
	panel.BackgroundColor3 = C.panelBg
	panel.BackgroundTransparency = 0.15
	panel.BorderSizePixel = 0
	panel.Parent = bg
	self._fullPanel = panel

	-- ══════════════════════════════════════════════
	-- Header com tabs (Itens | Traje | Nave)
	-- ══════════════════════════════════════════════
	local header = Instance.new("Frame")
	header.Name = "Header"
	header.Size = UDim2.new(1, 0, 0, 48)
	header.Position = UDim2.new(0, 0, 0, 0)
	header.BackgroundColor3 = Color3.fromRGB(10, 15, 30)
	header.BackgroundTransparency = 0.2
	header.BorderSizePixel = 0
	header.Parent = panel

	local headerCorner = Instance.new("UICorner")
	headerCorner.CornerRadius = UDim.new(0, 6)
	headerCorner.Parent = header

	-- Linha separadora abaixo do header
	local headerLine = Instance.new("Frame")
	headerLine.Name = "HeaderLine"
	headerLine.Size = UDim2.new(1, 0, 0, 1)
	headerLine.Position = UDim2.new(0, 0, 1, -1)
	headerLine.BackgroundColor3 = C.title
	headerLine.BackgroundTransparency = 0.5
	headerLine.BorderSizePixel = 0
	headerLine.Parent = header

	-- Container dos tabs
	local tabContainer = Instance.new("Frame")
	tabContainer.Name = "Tabs"
	tabContainer.Size = UDim2.new(0.5, 0, 1, 0)
	tabContainer.Position = UDim2.new(0.25, 0, 0, 0)
	tabContainer.BackgroundTransparency = 1
	tabContainer.Parent = header

	local tabLayout = Instance.new("UIListLayout")
	tabLayout.FillDirection = Enum.FillDirection.Horizontal
	tabLayout.HorizontalAlignment = Enum.HorizontalAlignment.Center
	tabLayout.VerticalAlignment = Enum.VerticalAlignment.Center
	tabLayout.Padding = UDim.new(0, 4)
	tabLayout.Parent = tabContainer

	for i, tabName in ipairs(TABS) do
		local tabBtn = Instance.new("TextButton")
		tabBtn.Name = "Tab_" .. tabName
		tabBtn.Size = UDim2.new(0, 120, 0, 36)
		tabBtn.BackgroundColor3 = if i == 1 then Color3.fromRGB(20, 30, 55) else Color3.fromRGB(10, 15, 28)
		tabBtn.BackgroundTransparency = if i == 1 then 0 else 0.5
		tabBtn.Text = string.upper(tabName)
		tabBtn.TextColor3 = if i == 1 then C.title else C.textDim
		tabBtn.TextScaled = true
		tabBtn.Font = Enum.Font.Jura
		tabBtn.AutoButtonColor = false
		tabBtn.BorderSizePixel = 0
		tabBtn.LayoutOrder = i
		tabBtn.Parent = tabContainer

		local tabCorner = Instance.new("UICorner")
		tabCorner.CornerRadius = UDim.new(0, 4)
		tabCorner.Parent = tabBtn

		-- Indicador ativo (linha inferior)
		local indicator = Instance.new("Frame")
		indicator.Name = "Indicator"
		indicator.Size = UDim2.new(0.8, 0, 0, 2)
		indicator.Position = UDim2.new(0.1, 0, 1, -3)
		indicator.BackgroundColor3 = C.title
		indicator.BorderSizePixel = 0
		indicator.Visible = (i == 1)
		indicator.Parent = tabBtn

		local indCorner = Instance.new("UICorner")
		indCorner.CornerRadius = UDim.new(0, 1)
		indCorner.Parent = indicator

		local textPadding = Instance.new("UIPadding")
		textPadding.PaddingTop = UDim.new(0, 4)
		textPadding.PaddingBottom = UDim.new(0, 6)
		textPadding.PaddingLeft = UDim.new(0, 8)
		textPadding.PaddingRight = UDim.new(0, 8)
		textPadding.Parent = tabBtn

		self._tabButtons[i] = { button = tabBtn, indicator = indicator }

		tabBtn.Activated:Connect(function()
			self:_selectTab(i)
		end)
	end

	-- Botão fechar (X) no canto direito do header
	local closeBtn = Instance.new("TextButton")
	closeBtn.Name = "CloseBtn"
	closeBtn.Size = UDim2.new(0, 36, 0, 36)
	closeBtn.Position = UDim2.new(1, -44, 0, 6)
	closeBtn.BackgroundTransparency = 1
	closeBtn.Text = "X"
	closeBtn.TextColor3 = C.textDim
	closeBtn.TextScaled = true
	closeBtn.Font = Enum.Font.Jura
	closeBtn.Parent = header

	closeBtn.Activated:Connect(function()
		self:Toggle()
	end)

	-- ══════════════════════════════════════════════
	-- Corpo: Grid (esquerda) + Preview (direita)
	-- ══════════════════════════════════════════════
	local body = Instance.new("Frame")
	body.Name = "Body"
	body.Size = UDim2.new(1, -32, 1, -64)
	body.Position = UDim2.new(0, 16, 0, 56)
	body.BackgroundTransparency = 1
	body.Parent = panel

	-- ── Grid lado esquerdo ──
	local gridSection = Instance.new("Frame")
	gridSection.Name = "GridSection"
	gridSection.Size = UDim2.new(0.58, 0, 1, 0)
	gridSection.Position = UDim2.new(0, 0, 0, 0)
	gridSection.BackgroundColor3 = Color3.fromRGB(8, 12, 26)
	gridSection.BackgroundTransparency = 0.3
	gridSection.BorderSizePixel = 0
	gridSection.Parent = body

	local gridCorner = Instance.new("UICorner")
	gridCorner.CornerRadius = UDim.new(0, 6)
	gridCorner.Parent = gridSection

	local gridStroke = Instance.new("UIStroke")
	gridStroke.Color = Color3.fromRGB(30, 45, 70)
	gridStroke.Thickness = 1
	gridStroke.Transparency = 0.4
	gridStroke.Parent = gridSection

	-- ScrollingFrame para a grid
	local scrollFrame = Instance.new("ScrollingFrame")
	scrollFrame.Name = "GridScroll"
	scrollFrame.Size = UDim2.new(1, -16, 1, -16)
	scrollFrame.Position = UDim2.new(0, 8, 0, 8)
	scrollFrame.BackgroundTransparency = 1
	scrollFrame.BorderSizePixel = 0
	scrollFrame.ScrollBarThickness = 4
	scrollFrame.ScrollBarImageColor3 = C.title
	scrollFrame.ScrollBarImageTransparency = 0.5
	scrollFrame.CanvasSize = UDim2.new(0, 0, 0, 0) -- auto-ajustado pelo grid
	scrollFrame.AutomaticCanvasSize = Enum.AutomaticSize.Y
	scrollFrame.Parent = gridSection

	local grid = Instance.new("UIGridLayout")
	grid.CellSize = UDim2.new(0, 72, 0, 82)
	grid.CellPadding = UDim2.new(0, 6, 0, 6)
	grid.FillDirection = Enum.FillDirection.Horizontal
	grid.HorizontalAlignment = Enum.HorizontalAlignment.Left
	grid.VerticalAlignment = Enum.VerticalAlignment.Top
	grid.SortOrder = Enum.SortOrder.LayoutOrder
	grid.Parent = scrollFrame
	self._gridLayout = grid

	for i = 1, FULL_COLS * FULL_ROWS do
		local slot = self:_createSlotFrame(scrollFrame, true)
		slot.frame.LayoutOrder = i
		self._fullSlots[i] = slot
	end

	-- ── Preview lado direito ──
	local previewSection = Instance.new("Frame")
	previewSection.Name = "PreviewSection"
	previewSection.Size = UDim2.new(0.38, 0, 1, 0)
	previewSection.Position = UDim2.new(0.62, 0, 0, 0)
	previewSection.BackgroundColor3 = Color3.fromRGB(8, 12, 26)
	previewSection.BackgroundTransparency = 0.3
	previewSection.BorderSizePixel = 0
	previewSection.Parent = body

	local prevCorner = Instance.new("UICorner")
	prevCorner.CornerRadius = UDim.new(0, 6)
	prevCorner.Parent = previewSection

	local prevStroke = Instance.new("UIStroke")
	prevStroke.Color = Color3.fromRGB(30, 45, 70)
	prevStroke.Thickness = 1
	prevStroke.Transparency = 0.4
	prevStroke.Parent = previewSection

	-- Título "Equipment" / preview
	local prevTitle = Instance.new("TextLabel")
	prevTitle.Name = "PreviewTitle"
	prevTitle.Size = UDim2.new(1, -16, 0, 28)
	prevTitle.Position = UDim2.new(0, 8, 0, 8)
	prevTitle.BackgroundTransparency = 1
	prevTitle.Text = "EQUIPMENT"
	prevTitle.TextColor3 = C.title
	prevTitle.TextScaled = true
	prevTitle.Font = Enum.Font.Jura
	prevTitle.TextXAlignment = Enum.TextXAlignment.Left
	prevTitle.Parent = previewSection

	-- Frame reservado para ViewportFrame (preview 3D do item)
	local viewportHolder = Instance.new("Frame")
	viewportHolder.Name = "ViewportHolder"
	viewportHolder.Size = UDim2.new(0.9, 0, 0.5, 0)
	viewportHolder.Position = UDim2.new(0.05, 0, 0.08, 0)
	viewportHolder.BackgroundColor3 = Color3.fromRGB(4, 6, 16)
	viewportHolder.BackgroundTransparency = 0.2
	viewportHolder.BorderSizePixel = 0
	viewportHolder.Parent = previewSection
	self._viewportHolder = viewportHolder

	local vpCorner = Instance.new("UICorner")
	vpCorner.CornerRadius = UDim.new(0, 6)
	vpCorner.Parent = viewportHolder

	local vpStroke = Instance.new("UIStroke")
	vpStroke.Color = Color3.fromRGB(25, 40, 65)
	vpStroke.Thickness = 1
	vpStroke.Transparency = 0.5
	vpStroke.Parent = viewportHolder

	-- Placeholder text (remover quando adicionar ViewportFrame)
	local vpPlaceholder = Instance.new("TextLabel")
	vpPlaceholder.Name = "Placeholder"
	vpPlaceholder.Size = UDim2.new(1, 0, 1, 0)
	vpPlaceholder.BackgroundTransparency = 1
	vpPlaceholder.Text = "3D PREVIEW"
	vpPlaceholder.TextColor3 = Color3.fromRGB(30, 45, 70)
	vpPlaceholder.TextScaled = true
	vpPlaceholder.Font = Enum.Font.Jura
	vpPlaceholder.Parent = viewportHolder

	-- Info do item selecionado (abaixo do viewport)
	local itemInfo = Instance.new("Frame")
	itemInfo.Name = "ItemInfo"
	itemInfo.Size = UDim2.new(0.9, 0, 0.35, 0)
	itemInfo.Position = UDim2.new(0.05, 0, 0.6, 0)
	itemInfo.BackgroundTransparency = 1
	itemInfo.Parent = previewSection
	self._itemInfoFrame = itemInfo

	local itemName = Instance.new("TextLabel")
	itemName.Name = "ItemName"
	itemName.Size = UDim2.new(1, 0, 0, 28)
	itemName.Position = UDim2.new(0, 0, 0, 0)
	itemName.BackgroundTransparency = 1
	itemName.Text = ""
	itemName.TextColor3 = C.quantity
	itemName.TextScaled = true
	itemName.Font = Enum.Font.Jura
	itemName.TextXAlignment = Enum.TextXAlignment.Left
	itemName.Parent = itemInfo
	self._previewItemName = itemName

	local itemDesc = Instance.new("TextLabel")
	itemDesc.Name = "ItemDesc"
	itemDesc.Size = UDim2.new(1, 0, 0, 40)
	itemDesc.Position = UDim2.new(0, 0, 0, 32)
	itemDesc.BackgroundTransparency = 1
	itemDesc.Text = ""
	itemDesc.TextColor3 = C.textDim
	itemDesc.TextScaled = true
	itemDesc.Font = Enum.Font.Jura
	itemDesc.TextXAlignment = Enum.TextXAlignment.Left
	itemDesc.TextYAlignment = Enum.TextYAlignment.Top
	itemDesc.TextWrapped = true
	itemDesc.Parent = itemInfo
	self._previewItemDesc = itemDesc

	local itemQty = Instance.new("TextLabel")
	itemQty.Name = "ItemQty"
	itemQty.Size = UDim2.new(1, 0, 0, 24)
	itemQty.Position = UDim2.new(0, 0, 0, 76)
	itemQty.BackgroundTransparency = 1
	itemQty.Text = ""
	itemQty.TextColor3 = C.resource
	itemQty.TextScaled = true
	itemQty.Font = Enum.Font.Jura
	itemQty.TextXAlignment = Enum.TextXAlignment.Left
	itemQty.Parent = itemInfo
	self._previewItemQty = itemQty
end

-- ═══════════════════════════════════════════════════════════
-- Slot rendering
-- ═══════════════════════════════════════════════════════════

function InventoryHUD:_renderSlot(slotUI, slotData)
	if not slotUI then return end

	if not slotData then
		slotUI.stroke.Color = C.borderEmpty
		slotUI.stroke.Transparency = 0.5
		slotUI.abbrLabel.Text = ""
		slotUI.qtyLabel.Text = ""
		slotUI.frame.BackgroundTransparency = 0.4
		if slotUI.nameLabel then
			slotUI.nameLabel.Text = ""
		end
		return
	end

	local def = InventoryModule.GetItemDef(slotData.itemId)
	if not def then return end

	local catColor = CATEGORY_COLOR[def.category] or C.borderEmpty

	slotUI.stroke.Color = catColor
	slotUI.stroke.Transparency = 0.1
	slotUI.abbrLabel.Text = getInitials(def.name)
	slotUI.abbrLabel.TextColor3 = catColor
	slotUI.frame.BackgroundTransparency = 0.15

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
		tab.button.BackgroundColor3 = if isActive then Color3.fromRGB(20, 30, 55) else Color3.fromRGB(10, 15, 28)
		tab.button.BackgroundTransparency = if isActive then 0 else 0.5
		tab.button.TextColor3 = if isActive then C.title else C.textDim
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

function InventoryHUD:UpdateAll(inventory)
	for i = 1, FULL_COLS * FULL_ROWS do
		self:_renderSlot(self._fullSlots[i], inventory.slots[i])
	end
	for i = 1, QB_SLOT_COUNT do
		self:_renderSlot(self._qbSlots[i], inventory.slots[i])
	end
end

local TWEEN_OPEN  = TweenInfo.new(0.35, Enum.EasingStyle.Quart, Enum.EasingDirection.Out)
local TWEEN_CLOSE = TweenInfo.new(0.28, Enum.EasingStyle.Quart, Enum.EasingDirection.In)

function InventoryHUD:Toggle()
	self._isOpen = not self._isOpen

	-- Atualiza visual do botão
	if self._btnStroke then
		self._btnStroke.Transparency = if self._isOpen then 0.1 else 0.4
	end
	if self._toggleIcon then
		self._toggleIcon.ImageColor3 = if self._isOpen then C.consumable else C.title
	end

	if self._isOpen then
		-- ── ABRIR ──────────────────────────────────
		self._fullGui.Enabled = true

		-- Reseta posições antes de animar
		self._fullBg.BackgroundTransparency = 1
		self._fullPanel.Position = UDim2.new(1, 0, 0, 0)

		-- Fundo escurece suavemente
		TweenService:Create(self._fullBg, TWEEN_OPEN, {
			BackgroundTransparency = 0.3,
		}):Play()

		-- Painel desliza da direita para o centro
		TweenService:Create(self._fullPanel, TWEEN_OPEN, {
			Position = UDim2.new(0, 0, 0, 0),
		}):Play()
	else
		-- ── FECHAR ─────────────────────────────────
		-- Fundo clareia
		TweenService:Create(self._fullBg, TWEEN_CLOSE, {
			BackgroundTransparency = 1,
		}):Play()

		-- Painel desliza para a direita
		local slideTween = TweenService:Create(self._fullPanel, TWEEN_CLOSE, {
			Position = UDim2.new(1, 0, 0, 0),
		})
		slideTween:Play()

		-- Desabilita a GUI só depois da animação acabar
		slideTween.Completed:Once(function()
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
	end
end

-- ═══════════════════════════════════════════════════════════
-- Camera follow (só quick bar 3D)
-- ═══════════════════════════════════════════════════════════

function InventoryHUD:_onRender()
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
