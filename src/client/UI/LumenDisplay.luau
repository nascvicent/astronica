local Players = game:GetService("Players")

local LumenDisplay = {}
LumenDisplay.__index = LumenDisplay

function LumenDisplay.new()
	local self = setmetatable({}, LumenDisplay)
	self._gui = nil
	self._label = nil
	self:_build()
	return self
end

function LumenDisplay:_build()
	local playerGui = Players.LocalPlayer:WaitForChild("PlayerGui")

	local screenGui = Instance.new("ScreenGui")
	screenGui.Name = "LumenDisplayGui"
	screenGui.ResetOnSpawn = false
	screenGui.IgnoreGuiInset = false
	screenGui.DisplayOrder = 10

	local frame = Instance.new("Frame")
	frame.Name = "LumenFrame"
	frame.AnchorPoint = Vector2.new(0.5, 0)
	frame.Position = UDim2.new(0.5, 0, 0, 12)
	frame.AutomaticSize = Enum.AutomaticSize.X
	frame.Size = UDim2.new(0, 0, 0, 44)
	frame.BackgroundColor3 = Color3.fromRGB(20, 20, 30)
	frame.BackgroundTransparency = 0.15
	frame.BorderSizePixel = 0
	frame.Parent = screenGui

	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, 12)
	corner.Parent = frame

	local padding = Instance.new("UIPadding")
	padding.PaddingLeft = UDim.new(0, 16)
	padding.PaddingRight = UDim.new(0, 16)
	padding.PaddingTop = UDim.new(0, 8)
	padding.PaddingBottom = UDim.new(0, 8)
	padding.Parent = frame

	local layout = Instance.new("UIListLayout")
	layout.FillDirection = Enum.FillDirection.Horizontal
	layout.VerticalAlignment = Enum.VerticalAlignment.Center
	layout.Padding = UDim.new(0, 8)
	layout.SortOrder = Enum.SortOrder.LayoutOrder
	layout.Parent = frame

	local icon = Instance.new("TextLabel")
	icon.Name = "LumenIcon"
	icon.Size = UDim2.new(0, 28, 0, 28)
	icon.BackgroundColor3 = Color3.fromRGB(180, 200, 255)
	icon.Text = "✦"
	icon.TextColor3 = Color3.fromRGB(255, 255, 255)
	icon.TextSize = 18
	icon.Font = Enum.Font.GothamBold
	icon.BorderSizePixel = 0
	icon.LayoutOrder = 1
	icon.Parent = frame

	local iconCorner = Instance.new("UICorner")
	iconCorner.CornerRadius = UDim.new(1, 0)
	iconCorner.Parent = icon

	local label = Instance.new("TextLabel")
	label.Name = "LumenAmount"
	label.AutomaticSize = Enum.AutomaticSize.X
	label.Size = UDim2.new(0, 0, 1, 0)
	label.BackgroundTransparency = 1
	label.Text = "0 LUM"
	label.TextColor3 = Color3.fromRGB(200, 220, 255)
	label.TextSize = 22
	label.Font = Enum.Font.GothamBold
	label.TextXAlignment = Enum.TextXAlignment.Left
	label.LayoutOrder = 2
	label.Parent = frame

	screenGui.Parent = playerGui

	self._gui = screenGui
	self._label = label
end

function LumenDisplay:Update(amount: number)
	if self._label then
		self._label.Text = tostring(amount) .. " LUM"
	end
end

function LumenDisplay:Destroy()
	if self._gui then
		self._gui:Destroy()
		self._gui = nil
		self._label = nil
	end
end

return LumenDisplay
