--[[
	FuelHUD
	HUD 3D holográfico de combustível — barra horizontal com título "FUEL".
	SurfaceGui em Part que segue a câmera — canto superior esquerdo, abaixo do SpeedHUD.

	USO:
		local FuelHUD = require(path.to.FuelHUD)
		local hud = FuelHUD.new(plane)  -- plane precisa ter Attributes "Fuel" e "MaxFuel"

		-- No loop de voo (opcional — ele já escuta AttributeChanged):
		-- Se quiser forçar: hud:SetFuel(0.75)

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
local PART_SIZE  = Vector3.new(0.9, 0.25, 0.01)  -- mais largo e baixo que SpeedHUD
local DEPTH      = 4
local SCREEN_X   = -0.72    -- mesma coluna do SpeedHUD
local SCREEN_Y   = -0.72     -- abaixo do SpeedHUD (0.72 → 0.50)
local ROT_Y      = 15

-- Cores — mesmo tema holográfico
local C = {
	panelBg     = Color3.fromRGB(6, 10, 22),
	border      = Color3.fromRGB(0, 200, 240),
	title       = Color3.fromRGB(0, 200, 240),
	barBg       = Color3.fromRGB(12, 18, 35),
	fuelHigh    = Color3.fromRGB(0, 220, 180),   -- cheio (verde-ciano)
	fuelMid     = Color3.fromRGB(220, 200, 0),    -- metade (amarelo)
	fuelLow     = Color3.fromRGB(255, 50, 30),    -- vazio (vermelho)
	fuelEmpty   = Color3.fromRGB(120, 20, 10),    -- crítico
}

-- ═══════════════════════════════════════════════════════════
-- Module
-- ═══════════════════════════════════════════════════════════

local FuelHUD = {}
FuelHUD.__index = FuelHUD

function FuelHUD.new(plane: Model)
	local self = setmetatable({}, FuelHUD)

	self._plane  = plane
	self._percent = 1

	-- Pasta no workspace
	self._folder = Instance.new("Folder")
	self._folder.Name = "FuelHUD"
	self._folder.Parent = workspace

	-- Part 3D + SurfaceGui
	self._part, self._gui = self:_createSurfacePart()

	-- UI
	self:_build()

	-- Escuta atributo replicado pelo FuelSystem (server → client)
	self._attrConn = plane:GetAttributeChangedSignal("Fuel"):Connect(function()
		local fuel    = plane:GetAttribute("Fuel") or 0
		local maxFuel = plane:GetAttribute("MaxFuel") or 1
		self:SetFuel(fuel / maxFuel)
	end)

	-- Camera follow
	self._renderConn = RunService.RenderStepped:Connect(function()
		self:_onRender()
	end)

	-- Preenche estado inicial
	local initFuel = plane:GetAttribute("Fuel") or 0
	local initMax  = plane:GetAttribute("MaxFuel") or 1
	self:SetFuel(initFuel / initMax)

	return self
end

-- ═══════════════════════════════════════════════════════════
-- Part + SurfaceGui
-- ═══════════════════════════════════════════════════════════

function FuelHUD:_createSurfacePart()
	local part = Instance.new("Part")
	part.Name         = "FuelHUD_Part"
	part.Size         = PART_SIZE
	part.Anchored     = true
	part.CanCollide   = false
	part.CanQuery     = false
	part.CanTouch     = false
	part.CastShadow   = false
	part.Transparency  = 1
	part.Parent       = self._folder

	local gui = Instance.new("SurfaceGui")
	gui.Name           = "FuelHUD_SGui"
	gui.Adornee        = part
	gui.Face           = Enum.NormalId.Back
	gui.AlwaysOnTop    = true
	gui.PixelsPerStud  = PPS
	gui.SizingMode     = Enum.SurfaceGuiSizingMode.PixelsPerStud
	gui.LightInfluence = 0
	gui.ResetOnSpawn   = false
	gui.Parent         = playerGui

	return part, gui
end

-- ═══════════════════════════════════════════════════════════
-- Build UI
-- ═══════════════════════════════════════════════════════════

function FuelHUD:_build()
	-- Container raiz
	local container = Instance.new("Frame")
	container.Name                 = "Container"
	container.Size                 = UDim2.new(1, 0, 1, 0)
	container.BackgroundColor3     = C.panelBg
	container.BackgroundTransparency = 0.4
	container.BorderSizePixel      = 0
	container.Parent               = self._gui

	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, 8)
	corner.Parent = container

	local stroke = Instance.new("UIStroke")
	stroke.Color       = C.border
	stroke.Thickness   = 2
	stroke.Transparency = 0.4
	stroke.Parent      = container
	self._stroke = stroke

	-- Padding
	local padding = Instance.new("UIPadding")
	padding.PaddingTop    = UDim.new(0.08, 0)
	padding.PaddingBottom = UDim.new(0.08, 0)
	padding.PaddingLeft   = UDim.new(0.04, 0)
	padding.PaddingRight  = UDim.new(0.04, 0)
	padding.Parent = container

	-- Título "FUEL"
	local titleLabel = Instance.new("TextLabel")
	titleLabel.Name                 = "Title"
	titleLabel.Size                 = UDim2.new(0.3, 0, 0.5, 0)
	titleLabel.Position             = UDim2.new(0, 0, 0, 0)
	titleLabel.BackgroundTransparency = 1
	titleLabel.Text                 = "FUEL"
	titleLabel.TextColor3           = C.title
	titleLabel.TextScaled           = true
	titleLabel.Font                 = Enum.Font.Jura
	titleLabel.TextXAlignment       = Enum.TextXAlignment.Left
	titleLabel.Parent               = container

	-- Percentual numérico (direita do título)
	local pctLabel = Instance.new("TextLabel")
	pctLabel.Name                 = "Percent"
	pctLabel.Size                 = UDim2.new(0.2, 0, 0.5, 0)
	pctLabel.Position             = UDim2.new(0.8, 0, 0, 0)
	pctLabel.BackgroundTransparency = 1
	pctLabel.Text                 = "100%"
	pctLabel.TextColor3           = C.fuelHigh
	pctLabel.TextScaled           = true
	pctLabel.FontFace             = Font.new(
		"rbxasset://fonts/families/Jura.json",
		Enum.FontWeight.Bold,
		Enum.FontStyle.Normal
	)
	pctLabel.TextXAlignment = Enum.TextXAlignment.Right
	pctLabel.Parent         = container
	self._pctLabel          = pctLabel

	-- Fundo da barra
	local barBg = Instance.new("Frame")
	barBg.Name                 = "BarBg"
	barBg.Size                 = UDim2.new(1, 0, 0.38, 0)
	barBg.Position             = UDim2.new(0, 0, 0.56, 0)
	barBg.BackgroundColor3     = C.barBg
	barBg.BackgroundTransparency = 0.3
	barBg.BorderSizePixel      = 0
	barBg.Parent               = container

	local barBgCorner = Instance.new("UICorner")
	barBgCorner.CornerRadius = UDim.new(0, 4)
	barBgCorner.Parent = barBg

	local barBgStroke = Instance.new("UIStroke")
	barBgStroke.Color       = C.border
	barBgStroke.Thickness   = 1
	barBgStroke.Transparency = 0.6
	barBgStroke.Parent      = barBg

	-- Barra de preenchimento (fill)
	local barFill = Instance.new("Frame")
	barFill.Name                 = "BarFill"
	barFill.Size                 = UDim2.new(1, 0, 1, 0)
	barFill.BackgroundColor3     = C.fuelHigh
	barFill.BackgroundTransparency = 0.15
	barFill.BorderSizePixel      = 0
	barFill.Parent               = barBg

	local fillCorner = Instance.new("UICorner")
	fillCorner.CornerRadius = UDim.new(0, 4)
	fillCorner.Parent = barFill
	self._barFill = barFill

	-- Brilho/glow dentro da barra (sutil)
	local glow = Instance.new("UIGradient")
	glow.Transparency = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0.6),
		NumberSequenceKeypoint.new(0.5, 0),
		NumberSequenceKeypoint.new(1, 0.6),
	})
	glow.Rotation = 90
	glow.Parent = barFill

	-- Marcações de segmentos (linhas finas a cada 25%)
	for i = 1, 3 do
		local tick = Instance.new("Frame")
		tick.Name                 = "Tick" .. i
		tick.Size                 = UDim2.new(0, 1, 1, 0)
		tick.Position             = UDim2.new(i * 0.25, 0, 0, 0)
		tick.BackgroundColor3     = C.border
		tick.BackgroundTransparency = 0.7
		tick.BorderSizePixel      = 0
		tick.ZIndex               = 2
		tick.Parent               = barBg
	end
end

-- ═══════════════════════════════════════════════════════════
-- Public API
-- ═══════════════════════════════════════════════════════════

--- percent: 0‑1
function FuelHUD:SetFuel(percent: number)
	percent = math.clamp(percent, 0, 1)
	self._percent = percent

	-- Anima a barra com tween suave
	TweenService:Create(self._barFill, TweenInfo.new(0.25, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
		Size = UDim2.new(percent, 0, 1, 0)
	}):Play()

	-- Cor baseada no nível
	local color
	if percent > 0.55 then
		-- Alto → ciano/verde
		color = C.fuelMid:Lerp(C.fuelHigh, (percent - 0.55) / 0.45)
	elseif percent > 0.25 then
		-- Médio → amarelo
		color = C.fuelLow:Lerp(C.fuelMid, (percent - 0.25) / 0.30)
	elseif percent > 0.05 then
		-- Baixo → vermelho
		color = C.fuelEmpty:Lerp(C.fuelLow, (percent - 0.05) / 0.20)
	else
		-- Crítico
		color = C.fuelEmpty
	end

	self._barFill.BackgroundColor3 = color
	self._pctLabel.Text       = math.floor(percent * 100) .. "%"
	self._pctLabel.TextColor3 = color
	self._stroke.Color        = percent <= 0.15 and C.fuelLow or C.border
end

function FuelHUD:SetVisible(show: boolean)
	self._gui.Enabled = show
	self._folder.Parent = if show then workspace else nil
end

function FuelHUD:Destroy()
	if self._renderConn then
		self._renderConn:Disconnect()
		self._renderConn = nil
	end
	if self._attrConn then
		self._attrConn:Disconnect()
		self._attrConn = nil
	end
	if self._gui then
		self._gui:Destroy()
	end
	if self._folder then
		self._folder:Destroy()
	end
end

-- ═══════════════════════════════════════════════════════════
-- Camera follow
-- ═══════════════════════════════════════════════════════════

function FuelHUD:_onRender()
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

return FuelHUD