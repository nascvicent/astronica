--[[
	SpeedHUD
	HUD 3D holográfico de velocidade da nave.
	SurfaceGui em Part que segue a câmera — canto superior esquerdo.
	
	USO:
		local SpeedHUD = require(path.to.SpeedHUD)
		local hud = SpeedHUD.new()
		
		-- No loop de voo:
		hud:SetSpeed(body.AssemblyLinearVelocity.Magnitude)
		
		-- Ao sair da nave:
		hud:Destroy()
]]

local RunService   = game:GetService("RunService")
local Players      = game:GetService("Players")
local TweenService = game:GetService("TweenService")

local player    = Players.LocalPlayer
local playerGui = player:WaitForChild("PlayerGui")

-- ═══════════════════════════════════════════════════════════
-- Config
-- ═══════════════════════════════════════════════════════════

local PPS        = 512
local PART_SIZE  = Vector3.new(0.9, 0.45, 0.01)
local DEPTH      = 4        -- distância Z da câmera
local SCREEN_X   = -0.72   -- negativo = esquerda
local SCREEN_Y   = 0.72    -- positivo = topo
local ROT_Y      = 15      -- inclinação holográfica (espelho do InventoryHUD)

-- Cores (mesmo tema do InventoryHUD)
local C = {
	panelBg  = Color3.fromRGB(6, 10, 22),
	slotBg   = Color3.fromRGB(12, 18, 35),
	border   = Color3.fromRGB(0, 200, 240),
	title    = Color3.fromRGB(0, 200, 240),
	value    = Color3.fromRGB(240, 250, 255),
	unitDim  = Color3.fromRGB(80, 110, 140),
}

-- Limites para colorir a velocidade (branco → ciano → branco, igual ao engine)
-- Você pode ajustar MAX_SPEED para bater com config.Speed.Value da sua nave
local MAX_SPEED = 200

-- ═══════════════════════════════════════════════════════════
-- Module
-- ═══════════════════════════════════════════════════════════

local SpeedHUD = {}
SpeedHUD.__index = SpeedHUD

function SpeedHUD.new()
	local self = setmetatable({}, SpeedHUD)

	-- Pasta de workspace para organização
	self._folder = Instance.new("Folder")
	self._folder.Name = "SpeedHUD"
	self._folder.Parent = workspace

	-- Cria a Part 3D + SurfaceGui
	self._part, self._gui = self:_createSurfacePart()

	-- Constrói os elementos visuais dentro da SurfaceGui
	self:_build()

	-- Estado
	self._currentSpeed = 0

	-- Loop de câmera
	self._renderConn = RunService.RenderStepped:Connect(function()
		self:_onRender()
	end)

	return self
end

-- ═══════════════════════════════════════════════════════════
-- Part + SurfaceGui factory (idêntico ao InventoryHUD)
-- ═══════════════════════════════════════════════════════════

function SpeedHUD:_createSurfacePart()
	local part = Instance.new("Part")
	part.Name        = "SpeedHUD_Part"
	part.Size        = PART_SIZE
	part.Anchored    = true
	part.CanCollide  = false
	part.CanQuery    = false
	part.CanTouch    = false
	part.CastShadow  = false
	part.Transparency = 1
	part.Parent      = self._folder

	local gui = Instance.new("SurfaceGui")
	gui.Name          = "SpeedHUD_SGui"
	gui.Adornee       = part
	gui.Face          = Enum.NormalId.Back
	gui.AlwaysOnTop   = true
	gui.PixelsPerStud = PPS
	gui.SizingMode    = Enum.SurfaceGuiSizingMode.PixelsPerStud
	gui.LightInfluence = 0
	gui.ResetOnSpawn  = false
	gui.Parent        = playerGui

	return part, gui
end

-- ═══════════════════════════════════════════════════════════
-- Build UI
-- ═══════════════════════════════════════════════════════════

function SpeedHUD:_build()
	-- Container raiz
	local container = Instance.new("Frame")
	container.Name                = "Container"
	container.Size                = UDim2.new(1, 0, 1, 0)
	container.BackgroundColor3    = C.panelBg
	container.BackgroundTransparency = 0.4
	container.BorderSizePixel     = 0
	container.Parent              = self._gui

	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, 8)
	corner.Parent = container

	local stroke = Instance.new("UIStroke")
	stroke.Color       = C.border
	stroke.Thickness   = 2
	stroke.Transparency = 0.4
	stroke.Parent      = container
	self._stroke = stroke

	-- Padding interno
	local padding = Instance.new("UIPadding")
	padding.PaddingTop    = UDim.new(0.05, 0)
	padding.PaddingBottom = UDim.new(0.05, 0)
	padding.PaddingLeft   = UDim.new(0.06, 0)
	padding.PaddingRight  = UDim.new(0.06, 0)
	padding.Parent = container

	-- Label "SPEED" (título)
	local titleLabel = Instance.new("TextLabel")
	titleLabel.Name                 = "Title"
	titleLabel.Size                 = UDim2.new(1, 0, 0.38, 0)
	titleLabel.Position             = UDim2.new(0, 0, 0, 0)
	titleLabel.BackgroundTransparency = 1
	titleLabel.Text                 = "SPEED"
	titleLabel.TextColor3           = C.title
	titleLabel.TextScaled           = true
	titleLabel.Font                 = Enum.Font.Jura
	titleLabel.TextXAlignment       = Enum.TextXAlignment.Left
	titleLabel.Parent               = container

	-- Label de valor numérico
	local valueLabel = Instance.new("TextLabel")
	valueLabel.Name                 = "Value"
	valueLabel.Size                 = UDim2.new(0.72, 0, 0.52, 0)
	valueLabel.Position             = UDim2.new(0, 0, 0.42, 0)
	valueLabel.BackgroundTransparency = 1
	valueLabel.Text                 = "0"
	valueLabel.TextColor3           = C.value
	valueLabel.TextScaled           = true
	valueLabel.FontFace             = Font.new(
		"rbxasset://fonts/families/Jura.json",
		Enum.FontWeight.Bold,
		Enum.FontStyle.Normal
	)
	valueLabel.TextXAlignment = Enum.TextXAlignment.Left
	valueLabel.Parent         = container
	self._valueLabel          = valueLabel

	-- Label de unidade "u/s" (menor, canto inferior direito do valor)
	local unitLabel = Instance.new("TextLabel")
	unitLabel.Name                 = "Unit"
	unitLabel.Size                 = UDim2.new(0.28, 0, 0.28, 0)
	unitLabel.Position             = UDim2.new(0.72, 0, 0.68, 0)
	unitLabel.BackgroundTransparency = 1
	unitLabel.Text                 = "u/s"
	unitLabel.TextColor3           = C.unitDim
	unitLabel.TextScaled           = true
	unitLabel.Font                 = Enum.Font.Jura
	unitLabel.TextXAlignment       = Enum.TextXAlignment.Right
	unitLabel.TextYAlignment       = Enum.TextYAlignment.Bottom
	unitLabel.Parent               = container
end

-- ═══════════════════════════════════════════════════════════
-- Public API
-- ═══════════════════════════════════════════════════════════

-- Chame isso no RenderStepped do LocalPlaneScript passando a velocidade real
function SpeedHUD:SetSpeed(speed: number)
	local rounded = math.floor(speed)
	self._valueLabel.Text = tostring(rounded)

	-- Cor do valor espelha o efeito do engine (branco → ciano → branco)
	local power = math.clamp(speed / MAX_SPEED, 0, 1)
	local color
	if power < 0.5 then
		color = Color3.new(1, 1, 1):Lerp(Color3.fromRGB(0, 200, 255), power * 2)
	else
		color = Color3.fromRGB(0, 200, 255):Lerp(Color3.new(1, 1, 1), (power - 0.5) * 2)
	end
	self._valueLabel.TextColor3 = color
	self._stroke.Color          = color
end

function SpeedHUD:SetVisible(show: boolean)
	self._gui.Enabled = show
	self._folder.Parent = if show then workspace else nil
end

function SpeedHUD:Destroy()
	if self._renderConn then
		self._renderConn:Disconnect()
		self._renderConn = nil
	end
	if self._gui then
		self._gui:Destroy()
	end
	if self._folder then
		self._folder:Destroy()
	end
end

-- ═══════════════════════════════════════════════════════════
-- Camera follow (idêntico ao InventoryHUD)
-- ═══════════════════════════════════════════════════════════

function SpeedHUD:_onRender()
	local cam = workspace.CurrentCamera
	if not cam then return end

	local fovRad = math.rad(cam.FieldOfView)
	local halfH  = DEPTH * math.tan(fovRad / 2)
	local halfW  = halfH * (cam.ViewportSize.X / cam.ViewportSize.Y)

	local worldX = halfW * SCREEN_X
	local worldY = halfH * SCREEN_Y

	self._part.CFrame = cam.CFrame
		* CFrame.new(worldX, worldY, -DEPTH)
		* CFrame.Angles(0, math.rad(ROT_Y), 0)
end

return SpeedHUD