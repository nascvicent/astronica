--[[
	InventoryHUD
	UI 3D holográfica usando SurfaceGui em Parts que seguem a câmera.
	Quick bar (3 slots, bottom-right) + Full inventory (grid 5x4, toggle com slide-in).
]]

local RunService = game:GetService("RunService")
local Players = game:GetService("Players")

local InventoryModule = require(game:GetService("ReplicatedStorage").Shared.InventoryModule)

local player = Players.LocalPlayer
local playerGui = player:WaitForChild("PlayerGui")

-- ═══════════════════════════════════════════════════════════
-- Config
-- ═══════════════════════════════════════════════════════════

local PPS = 512
local LERP_SPEED = 12
local BASE_ASPECT = 16 / 9

-- Quick bar (3 slots, bottom-right, ângulo holográfico)
local QB_PART_SIZE = Vector3.new(1.6, 0.45, 0.01)
local QB_OFFSET = Vector3.new(2.0, -1.3, -4)
local QB_ROT_Y = -15
local QB_SLOT_COUNT = 3

-- Full inventory (grid central, slide-in da direita)
local FULL_PART_SIZE = Vector3.new(2.8, 3.0, 0.01)
local FULL_OFFSET_Y = 0.2
local FULL_OFFSET_Z = -3.5
local FULL_OPEN_X = 0
local FULL_CLOSED_X = 6
local FULL_ROT_Y = -8
local FULL_COLS = 5
local FULL_ROWS = 4

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

	-- Quick bar
	self._qbPart, self._qbGui = self:_createSurfacePart("QuickBar", QB_PART_SIZE)
	self._qbSlots = {}
	self:_buildQuickBar()

	-- Full inventory
	self._fullPart, self._fullGui = self:_createSurfacePart("FullInv", FULL_PART_SIZE)
	self._fullSlots = {}
	self:_buildFullInventory()

	-- State
	self._isOpen = false
	local cam = workspace.CurrentCamera
	local cf = cam and cam.CFrame or CFrame.new()
	self._qbCF = cf * CFrame.new(QB_OFFSET.X, QB_OFFSET.Y, QB_OFFSET.Z)
	self._fullCF = cf * CFrame.new(FULL_CLOSED_X, FULL_OFFSET_Y, FULL_OFFSET_Z)

	-- Render loop
	self._renderConn = RunService.RenderStepped:Connect(function(dt)
		self:_onRender(dt)
	end)

	return self
end

-- ═══════════════════════════════════════════════════════════
-- Part + SurfaceGui factory
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
	abbrLabel.Font = Enum.Font.GothamBold
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
	qtyLabel.Font = Enum.Font.GothamBold
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
		nameLabel.Font = Enum.Font.Gotham
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
	-- Painel de fundo
	local panel = Instance.new("Frame")
	panel.Name = "Panel"
	panel.Size = UDim2.new(0.95, 0, 0.96, 0)
	panel.Position = UDim2.new(0.025, 0, 0.02, 0)
	panel.BackgroundColor3 = C.panelBg
	panel.BackgroundTransparency = 0.12
	panel.BorderSizePixel = 0
	panel.Parent = self._fullGui

	local panelCorner = Instance.new("UICorner")
	panelCorner.CornerRadius = UDim.new(0, 12)
	panelCorner.Parent = panel

	local panelStroke = Instance.new("UIStroke")
	panelStroke.Color = C.title
	panelStroke.Thickness = 1.5
	panelStroke.Transparency = 0.5
	panelStroke.Parent = panel

	-- Título
	local title = Instance.new("TextLabel")
	title.Name = "Title"
	title.Size = UDim2.new(1, 0, 0.06, 0)
	title.Position = UDim2.new(0, 0, 0.02, 0)
	title.BackgroundTransparency = 1
	title.Text = "INVENTORY"
	title.TextColor3 = C.title
	title.TextScaled = true
	title.Font = Enum.Font.GothamBold
	title.Parent = panel

	-- Container da grid
	local gridContainer = Instance.new("Frame")
	gridContainer.Name = "Grid"
	gridContainer.Size = UDim2.new(0.92, 0, 0.85, 0)
	gridContainer.Position = UDim2.new(0.04, 0, 0.1, 0)
	gridContainer.BackgroundTransparency = 1
	gridContainer.Parent = panel

	local grid = Instance.new("UIGridLayout")
	grid.CellSize = UDim2.new(0.185, 0, 0.23, 0)
	grid.CellPadding = UDim2.new(0.01, 0, 0.01, 0)
	grid.FillDirection = Enum.FillDirection.Horizontal
	grid.HorizontalAlignment = Enum.HorizontalAlignment.Center
	grid.VerticalAlignment = Enum.VerticalAlignment.Top
	grid.SortOrder = Enum.SortOrder.LayoutOrder
	grid.Parent = gridContainer

	for i = 1, FULL_COLS * FULL_ROWS do
		local slot = self:_createSlotFrame(gridContainer, true)
		slot.frame.LayoutOrder = i
		self._fullSlots[i] = slot
	end
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

function InventoryHUD:Toggle()
	self._isOpen = not self._isOpen
end

function InventoryHUD:IsOpen(): boolean
	return self._isOpen
end

-- ═══════════════════════════════════════════════════════════
-- Camera follow (RenderStepped)
-- ═══════════════════════════════════════════════════════════

function InventoryHUD:_onRender(dt: number)
	local cam = workspace.CurrentCamera
	if not cam then return end

	local alpha = math.min(1, dt * LERP_SPEED)

	-- Compensação de aspect ratio
	local vp = cam.ViewportSize
	local aspectScale = (vp.X / vp.Y) / BASE_ASPECT

	-- Quick bar
	local qbTarget = cam.CFrame
		* CFrame.new(QB_OFFSET.X * aspectScale, QB_OFFSET.Y, QB_OFFSET.Z)
		* CFrame.Angles(0, math.rad(QB_ROT_Y), 0)

	self._qbCF = self._qbCF:Lerp(qbTarget, alpha)
	self._qbPart.CFrame = self._qbCF

	-- Full inventory (slide entre open/closed)
	local fullX = if self._isOpen then FULL_OPEN_X else FULL_CLOSED_X
	local fullTarget = cam.CFrame
		* CFrame.new(fullX * aspectScale, FULL_OFFSET_Y, FULL_OFFSET_Z)
		* CFrame.Angles(0, math.rad(FULL_ROT_Y), 0)

	self._fullCF = self._fullCF:Lerp(fullTarget, alpha)
	self._fullPart.CFrame = self._fullCF
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
	if self._fullGui then
		self._fullGui:Destroy()
	end
	if self._folder then
		self._folder:Destroy()
	end
end

return InventoryHUD
