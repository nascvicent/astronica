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

local RunService      = game:GetService("RunService")
local Players         = game:GetService("Players")
local TweenService    = game:GetService("TweenService")
local UserInputService = game:GetService("UserInputService")

local player    = Players.LocalPlayer
local playerGui = player:WaitForChild("PlayerGui")

-- ═══════════════════════════════════════════════════════════
-- Config
-- ═══════════════════════════════════════════════════════════

local IS_MOBILE  = UserInputService.TouchEnabled and not UserInputService.KeyboardEnabled

-- No celular a tela é fisicamente pequena: a placa cresce e o PPS cai na
-- mesma proporção, então o conteúdo (em pixels da SurfaceGui) não muda, só
-- fica maior na tela. Os hologramas da nave (CombatHUD, Holo) leem daqui.
local SCALE      = if IS_MOBILE then 1.4 else 1

local PPS        = 512 / SCALE
local PART_SIZE  = Vector3.new(0.9 * SCALE, 0.45 * SCALE, 0.01)
local DEPTH      = 4        -- distância Z da câmera
local SCREEN_X   = -0.72   -- negativo = esquerda
local SCREEN_X_MOBILE = -0.52  -- mais próximo do centro no celular
local SCREEN_Y   = 0.72    -- positivo = topo
local ROT_Y      = 15      -- inclinação holográfica (espelho do InventoryHUD)

-- O LocalPlaneScript abre o FOV de 70 a 95 com a velocidade. A placa fica a
-- uma distância fixa da câmera, então com FOV maior ela encolheria na tela.
-- Em vez disso ela se aproxima na mesma proporção (ver GetDepth): a câmera
-- continua se afastando, a HUD fica do mesmo tamanho.
local REFERENCE_FOV = 70

-- Modo cruzeiro: as placas de informação (velocidade, casco/armas) deslizam
-- pra fora da tela pela esquerda. 0 = na tela, 1 = fora. Quem decide e anima
-- é o FlightHudController; aqui só é aplicado. Fica no módulo (não na
-- instância) porque a placa de velocidade é criada pelo LocalPlaneScript e a
-- de casco pelo CombatHUD: as duas leem o mesmo valor e saem juntas.
local SLIDE_DISTANCE = 0.9 -- em largura normalizada da tela (-1..1)
local slide = 0

-- Cores — monocromático branco sobre placa escura, igual ao inventário e ao
-- HealthHUD: a hierarquia vem da transparência, não da cor
local WHITE = Color3.fromRGB(255, 255, 255)
local C = {
	plate    = Color3.fromRGB(10, 11, 14),
	line     = WHITE,
	text     = WHITE,
}
local T = {
	plate    = 0.32,  -- a placa é o que dá contraste ao branco contra o céu
	line     = 0.85,  -- borda em repouso
	lineMax  = 0.35,  -- borda na velocidade máxima (acende com o motor)
	title    = 0.35,
	unit     = 0.62,
}

-- Escala da cor da velocidade (branco → ciano → branco, igual ao engine).
-- O teto real vem de Configurations.Speed da nave em que o jogador está
-- sentado — muda com upgrade de motor. Este número só vale se não achar.
local FALLBACK_MAX_SPEED = 200

--- Configurations.Speed da nave onde o jogador local está sentado.
local function findSeatedMaxSpeed(): number?
	local character = player.Character
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	local seat = humanoid and humanoid.SeatPart
	if not seat then
		return nil
	end

	local node: Instance? = seat.Parent
	while node and node ~= workspace do
		local config = node:FindFirstChild("Configurations")
		local speed = config and config:FindFirstChild("Speed")
		if speed and speed:IsA("NumberValue") and speed.Value > 0 then
			return speed.Value
		end
		node = node.Parent
	end
	return nil
end

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
	self._maxSpeed = nil -- nil = procura na nave em que o jogador está sentado

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
	container.BackgroundColor3    = C.plate
	container.BackgroundTransparency = T.plate
	container.BorderSizePixel     = 0
	container.Parent              = self._gui

	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, 8)
	corner.Parent = container

	local stroke = Instance.new("UIStroke")
	stroke.Color       = C.line
	stroke.Thickness   = 2
	stroke.Transparency = T.line
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
	titleLabel.TextColor3           = C.text
	titleLabel.TextTransparency     = T.title
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
	valueLabel.TextColor3           = C.text
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
	unitLabel.TextColor3           = C.text
	unitLabel.TextTransparency     = T.unit
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

	-- A borda acende com a potência (branco, só a transparência muda)
	local maxSpeed = self._maxSpeed or findSeatedMaxSpeed() or FALLBACK_MAX_SPEED
	local power = math.clamp(speed / maxSpeed, 0, 1)
	self._stroke.Transparency = T.line + (T.lineMax - T.line) * power
end

--- Fixa o teto da escala de cor. nil volta a ler do Configurations da nave.
function SpeedHUD:SetMaxSpeed(maxSpeed: number?)
	self._maxSpeed = maxSpeed
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

-- Tamanho da placa (já escalado), pra quem empilha outro holograma embaixo
SpeedHUD.PART_SIZE = PART_SIZE
SpeedHUD.SCALE = SCALE
SpeedHUD.REFERENCE_FOV = REFERENCE_FOV

--- 0 = placas na tela, 1 = fora dela (já com easing aplicado por quem chama).
function SpeedHUD.SetSlide(alpha: number)
	slide = math.clamp(alpha, 0, 1)
end

function SpeedHUD.GetSlide(): number
	return slide
end

--- Distância da placa à câmera pro FOV atual: no FOV de referência é DEPTH;
--- com FOV maior, mais perto, na proporção exata que mantém o tamanho na tela.
--- Todo holograma de voo usa isto (Holo), pra ficarem no mesmo plano.
function SpeedHUD.GetDepth(cam: Camera): number
	local reference = math.tan(math.rad(REFERENCE_FOV) / 2)
	return DEPTH * reference / math.tan(math.rad(cam.FieldOfView) / 2)
end

--- CFrame da placa de velocidade na frente da câmera. offsetY (studs) desce
--- ou sobe a partir dela, no mesmo plano e com a mesma inclinação: é assim
--- que outro holograma (casco/armas) fica alinhado logo abaixo.
function SpeedHUD.GetScreenCFrame(cam: Camera, offsetY: number?): CFrame
	local depth  = SpeedHUD.GetDepth(cam)
	local halfH  = depth * math.tan(math.rad(cam.FieldOfView) / 2)
	local halfW  = halfH * (cam.ViewportSize.X / cam.ViewportSize.Y)

	local screenX = (if IS_MOBILE then SCREEN_X_MOBILE else SCREEN_X) - SLIDE_DISTANCE * slide
	local worldX = halfW * screenX
	local worldY = halfH * SCREEN_Y + (offsetY or 0)

	return cam.CFrame
		* CFrame.new(worldX, worldY, -depth)
		* CFrame.Angles(0, math.rad(ROT_Y), 0)
end

function SpeedHUD:_onRender()
	local cam = workspace.CurrentCamera
	if not cam then return end

	self._part.CFrame = SpeedHUD.GetScreenCFrame(cam)
end

return SpeedHUD