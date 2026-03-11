local RunService = game:GetService("RunService")
local Players = game:GetService("Players")
local TweenService = game:GetService("TweenService")

local player = Players.LocalPlayer
local playerGui = player:WaitForChild("PlayerGui")

local HealthHUD = {}
HealthHUD.__index = HealthHUD

-- 3D config (same system as InventoryHUD)
local PPS = 512
local BASE_ASPECT = 16 / 9

-- Part size and camera offset (bottom-right, below quick bar)
-- Novo (Left)
local PART_SIZE = Vector3.new(1.2, 0.18, 0.01)
local OFFSET = Vector3.new(-2.45, -1.65, -4) -- X negativo move para a esquerda
local ROT_Y = 15 -- Invertendo a rotação para apontar para o centro

-- Layout (proportional)
local ICON_SCALE = 0.85  -- 85% da altura do container
local BAR_X_START = 0.18 -- onde a barra começa (após o ícone)
local BAR_HEIGHT = 0.35  -- altura da barra relativa ao container

-- Colors
local BAR_BG_COLOR = Color3.fromRGB(30, 34, 50)
local BAR_FILL_COLOR = Color3.fromRGB(230, 235, 245)
local BAR_LOW_COLOR = Color3.fromRGB(220, 60, 60)
local LOW_HEALTH_THRESHOLD = 0.25

function HealthHUD.new()
	local self = setmetatable({}, HealthHUD)

	self._folder = Instance.new("Folder")
	self._folder.Name = "HealthHUD"
	self._folder.Parent = workspace

	self._currentHealth = 100
	self._maxHealth = 100

	self:_build()

	-- Render loop (camera follow)
	self._renderConn = RunService.RenderStepped:Connect(function()
		self:_onRender()
	end)

	return self
end

function HealthHUD:_build()
	-- Invisible part
	local part = Instance.new("Part")
	part.Name = "HealthHUD_Part"
	part.Size = PART_SIZE
	part.Anchored = true
	part.CanCollide = false
	part.CanQuery = false
	part.CanTouch = false
	part.CastShadow = false
	part.Transparency = 1
	part.Parent = self._folder
	self._part = part

	-- SurfaceGui
	local gui = Instance.new("SurfaceGui")
	gui.Name = "HealthHUD_SGui"
	gui.Adornee = part
	gui.Face = Enum.NormalId.Back
	gui.AlwaysOnTop = true
	gui.PixelsPerStud = PPS
	gui.SizingMode = Enum.SurfaceGuiSizingMode.PixelsPerStud
	gui.LightInfluence = 0
	gui.ResetOnSpawn = false
	gui.Parent = playerGui
	self._gui = gui

	-- Container (full surface)
	local container = Instance.new("Frame")
	container.Name = "Container"
	container.Size = UDim2.new(1, 0, 1, 0)
	container.BackgroundTransparency = 1
	container.Parent = gui

	-- Icon (left side) — COLOQUE O ASSET ID AQUI
	local icon = Instance.new("ImageLabel")
	icon.Name = "HealthIcon"
	icon.AnchorPoint = Vector2.new(0, 0.5)
	icon.Position = UDim2.new(0, 0, 0.5, 0)
	icon.Size = UDim2.new(ICON_SCALE, 0, ICON_SCALE, 0)
	icon.BackgroundTransparency = 1
	icon.Image = "rbxassetid://117486382135129" -- <<< COLOQUE O rbxassetid:// AQUI
	icon.ImageColor3 = Color3.fromRGB(255, 255, 255)
	icon.ScaleType = Enum.ScaleType.Fit
	icon.Parent = container
	self._icon = icon

	local iconAspect = Instance.new("UIAspectRatioConstraint")
	iconAspect.AspectRatio = 1
	iconAspect.Parent = icon

	-- Bar background (square, no rounded corners)
	local barBg = Instance.new("Frame")
	barBg.Name = "BarBackground"
	barBg.AnchorPoint = Vector2.new(0, 0.5)
	barBg.Position = UDim2.new(BAR_X_START, 0, 0.5, 0)
	barBg.Size = UDim2.new(1 - BAR_X_START, 0, BAR_HEIGHT, 0)
	barBg.BackgroundColor3 = BAR_BG_COLOR
	barBg.BorderSizePixel = 0
	barBg.Parent = container

	-- Bar fill (square, no rounded corners)
	local barFill = Instance.new("Frame")
	barFill.Name = "BarFill"
	barFill.Size = UDim2.new(1, 0, 1, 0)
	barFill.BackgroundColor3 = BAR_FILL_COLOR
	barFill.BorderSizePixel = 0
	barFill.Parent = barBg
	self._barFill = barFill
end

function HealthHUD:_onRender()
	local cam = workspace.CurrentCamera
	if not cam then return end

	local vp = cam.ViewportSize
	local aspectScale = (vp.X / vp.Y) / BASE_ASPECT

	self._part.CFrame = cam.CFrame
		* CFrame.new(OFFSET.X * aspectScale, OFFSET.Y, OFFSET.Z)
		* CFrame.Angles(0, math.rad(ROT_Y), 0)
end

function HealthHUD:Update(health: number, maxHealth: number)
	self._currentHealth = health
	self._maxHealth = maxHealth

	local ratio = math.clamp(health / maxHealth, 0, 1)
	local isLow = ratio <= LOW_HEALTH_THRESHOLD
	local targetColor = if isLow then BAR_LOW_COLOR else BAR_FILL_COLOR

	local tweenInfo = TweenInfo.new(0.3, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)

	TweenService:Create(self._barFill, tweenInfo, {
		Size = UDim2.new(ratio, 0, 1, 0),
		BackgroundColor3 = targetColor,
	}):Play()
end

function HealthHUD:Destroy()
	if self._renderConn then
		self._renderConn:Disconnect()
		self._renderConn = nil
	end
	if self._gui then
		self._gui:Destroy()
		self._gui = nil
	end
	if self._folder then
		self._folder:Destroy()
		self._folder = nil
	end
end

return HealthHUD
