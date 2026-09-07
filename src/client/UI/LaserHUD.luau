--[[
	LaserHUD
	HUD da pistola laser: mira central + botão de disparo no mobile.

	Diferente do HealthHUD/InventoryHUD (que são placas 3D no mundo), a mira
	precisa ser ScreenGui: ela tem que cair exatamente no pixel central do
	viewport, que é de onde o LaserToolController dispara o raycast.

	IgnoreGuiInset = true é obrigatório aqui — sem isso o centro do ScreenGui
	fica 36px abaixo do centro real do viewport e a mira mente sobre onde acerta.
]]

local Players = game:GetService("Players")
local TweenService = game:GetService("TweenService")
local UserInputService = game:GetService("UserInputService")

local player = Players.LocalPlayer
local playerGui = player:WaitForChild("PlayerGui")

local LaserHUD = {}
LaserHUD.__index = LaserHUD

-- Geometria (px)
local TICK_LENGTH = 9
local TICK_THICKNESS = 2
local DOT_SIZE = 3
local GAP_IDLE = 5     -- distância do centro até o começo do traço
local GAP_FIRING = 12  -- abre quando está atirando

local GAP_LERP = 12    -- velocidade da abertura/fechamento

local BASE_COLOR = Color3.fromRGB(255, 255, 255)
local PLATE_COLOR = Color3.fromRGB(10, 11, 14) -- mesma placa escura dos outros HUDs

local IS_MOBILE = UserInputService.TouchEnabled and not UserInputService.MouseEnabled

-- Botão de disparo (mobile). Fica acima e à esquerda do botão de pulo nativo,
-- que ocupa o canto inferior direito.
local FIRE_SIZE = 92
local FIRE_MARGIN_X = 46
local FIRE_MARGIN_Y = 150

-- Direção de cada traço: {x, y} em pixels normalizados
local TICKS = {
	up = { dx = 0, dy = -1, anchor = Vector2.new(0.5, 1), horizontal = false },
	down = { dx = 0, dy = 1, anchor = Vector2.new(0.5, 0), horizontal = false },
	left = { dx = -1, dy = 0, anchor = Vector2.new(1, 0.5), horizontal = true },
	right = { dx = 1, dy = 0, anchor = Vector2.new(0, 0.5), horizontal = true },
}

function LaserHUD.new()
	local self = setmetatable({}, LaserHUD)

	self._gap = GAP_IDLE
	self._targetGap = GAP_IDLE
	self._ticks = {}

	self:_build()

	return self
end

function LaserHUD:_build()
	local gui = Instance.new("ScreenGui")
	gui.Name = "LaserHUD"
	gui.ResetOnSpawn = false
	gui.IgnoreGuiInset = true
	gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
	gui.DisplayOrder = 5
	gui.Enabled = false
	gui.Parent = playerGui
	self._gui = gui

	local container = Instance.new("Frame")
	container.Name = "Center"
	container.AnchorPoint = Vector2.new(0.5, 0.5)
	container.Position = UDim2.fromScale(0.5, 0.5)
	container.Size = UDim2.fromOffset(80, 80)
	container.BackgroundTransparency = 1
	container.Parent = gui
	self._container = container

	for name, spec in TICKS do
		local tick = Instance.new("Frame")
		tick.Name = name
		tick.AnchorPoint = spec.anchor
		tick.BackgroundColor3 = BASE_COLOR
		tick.BorderSizePixel = 0
		tick.Size = if spec.horizontal
			then UDim2.fromOffset(TICK_LENGTH, TICK_THICKNESS)
			else UDim2.fromOffset(TICK_THICKNESS, TICK_LENGTH)
		tick.Parent = container

		-- Contorno escuro: contra o céu claro o traço branco sozinho some
		local stroke = Instance.new("UIStroke")
		stroke.Color = Color3.new(0, 0, 0)
		stroke.Thickness = 1
		stroke.Transparency = 0.45
		stroke.Parent = tick

		self._ticks[tick] = spec
	end

	local dot = Instance.new("Frame")
	dot.Name = "Dot"
	dot.AnchorPoint = Vector2.new(0.5, 0.5)
	dot.Position = UDim2.fromScale(0.5, 0.5)
	dot.Size = UDim2.fromOffset(DOT_SIZE, DOT_SIZE)
	dot.BackgroundColor3 = BASE_COLOR
	dot.BorderSizePixel = 0
	dot.Parent = container

	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(1, 0)
	corner.Parent = dot

	self._dot = dot

	self:_applyGap()
	self:_buildFireButton()
end

-- ═══════════════════════════════════════════════════════════
-- Botão de disparo (mobile)
-- ═══════════════════════════════════════════════════════════

function LaserHUD:_buildFireButton()
	if not IS_MOBILE then
		return
	end

	local button = Instance.new("TextButton")
	button.Name = "FireButton"
	button.AnchorPoint = Vector2.new(1, 1)
	button.Position = UDim2.new(1, -FIRE_MARGIN_X, 1, -FIRE_MARGIN_Y)
	button.Size = UDim2.fromOffset(FIRE_SIZE, FIRE_SIZE)
	button.BackgroundColor3 = PLATE_COLOR
	button.BackgroundTransparency = 0.35
	button.Text = ""
	button.AutoButtonColor = false
	button.BorderSizePixel = 0
	button.Parent = self._gui

	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(1, 0)
	corner.Parent = button

	local ring = Instance.new("UIStroke")
	ring.Color = BASE_COLOR
	ring.Thickness = 2
	ring.Transparency = 0.35
	ring.Parent = button

	-- Miolo: recebe a cor do modo ativo, igual à mira
	local core = Instance.new("Frame")
	core.Name = "Core"
	core.AnchorPoint = Vector2.new(0.5, 0.5)
	core.Position = UDim2.fromScale(0.5, 0.5)
	core.Size = UDim2.fromOffset(FIRE_SIZE * 0.34, FIRE_SIZE * 0.34)
	core.BackgroundColor3 = BASE_COLOR
	core.BorderSizePixel = 0
	core.Parent = button

	local coreCorner = Instance.new("UICorner")
	coreCorner.CornerRadius = UDim.new(1, 0)
	coreCorner.Parent = core

	-- Segurar dispara, soltar para. Activated não serve: ele só avisa do toque
	-- completo, e o laser é feixe contínuo.
	button.InputBegan:Connect(function(input)
		if input.UserInputType == Enum.UserInputType.Touch
			or input.UserInputType == Enum.UserInputType.MouseButton1
		then
			self._firePressed = true
			self:_setFireButtonHeld(true)
			if self._onFirePress then
				self._onFirePress()
			end
		end
	end)

	local function release()
		if not self._firePressed then
			return
		end
		self._firePressed = false
		self:_setFireButtonHeld(false)
		if self._onFireRelease then
			self._onFireRelease()
		end
	end

	button.InputEnded:Connect(release)

	-- Rede de segurança: se o dedo sair do botão antes de soltar, o InputEnded
	-- do botão não dispara e o laser ficaria ligado pra sempre.
	UserInputService.InputEnded:Connect(function(input)
		if input.UserInputType == Enum.UserInputType.Touch
			or input.UserInputType == Enum.UserInputType.MouseButton1
		then
			release()
		end
	end)

	self._fireButton = button
	self._fireRing = ring
	self._fireCore = core
end

function LaserHUD:_setFireButtonHeld(held: boolean)
	if not self._fireButton then
		return
	end

	self._fireButton.BackgroundTransparency = if held then 0.15 else 0.35
	self._fireRing.Transparency = if held then 0 else 0.35
end

--- onPress/onRelease — quem decide o que é disparar é o controller.
function LaserHUD:SetFireHandlers(onPress, onRelease)
	self._onFirePress = onPress
	self._onFireRelease = onRelease
end

function LaserHUD:_applyGap()
	for tick, spec in self._ticks do
		tick.Position = UDim2.new(0.5, spec.dx * self._gap, 0.5, spec.dy * self._gap)
	end
end

--- Chamado todo frame pelo controller enquanto a arma está equipada.
function LaserHUD:Update(dt: number)
	if math.abs(self._targetGap - self._gap) < 0.05 then
		return
	end

	self._gap += (self._targetGap - self._gap) * math.min(dt * GAP_LERP, 1)
	self:_applyGap()
end

function LaserHUD:SetFiring(firing: boolean)
	self._targetGap = if firing then GAP_FIRING else GAP_IDLE
end

--- Tinge a mira com a cor do modo ativo (ciano = mineração, laranja = combate).
function LaserHUD:SetColor(color: Color3)
	for tick in self._ticks do
		tick.BackgroundColor3 = color
	end
	self._dot.BackgroundColor3 = color

	if self._fireCore then
		self._fireCore.BackgroundColor3 = color
	end
end

--- Flash rápido quando um node é destruído.
function LaserHUD:Hit()
	local info = TweenInfo.new(0.12, Enum.EasingStyle.Quad, Enum.EasingDirection.Out, 0, true)
	TweenService:Create(self._dot, info, { Size = UDim2.fromOffset(DOT_SIZE * 3, DOT_SIZE * 3) }):Play()
end

function LaserHUD:SetVisible(show: boolean)
	if not self._gui then
		return
	end

	self._gui.Enabled = show

	if not show then
		-- Reseta a abertura pra próxima vez que equipar
		self._gap = GAP_IDLE
		self._targetGap = GAP_IDLE
		self:_applyGap()

		-- Desequipar com o dedo no botão deixaria ele aceso na próxima vez
		self._firePressed = false
		self:_setFireButtonHeld(false)
	end
end

function LaserHUD:Destroy()
	if self._gui then
		self._gui:Destroy()
		self._gui = nil
	end
end

return LaserHUD
