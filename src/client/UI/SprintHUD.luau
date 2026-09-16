--[[
	SprintHUD
	Botão RUN no mobile. No PC não cria nada — a corrida é pelo Shift.

	Fica à esquerda do botão de pulo nativo e abaixo do botão de disparo do
	LaserHUD, sem sobrepor nenhum dos dois.
]]

local Players = game:GetService("Players")
local UserInputService = game:GetService("UserInputService")

local player = Players.LocalPlayer
local playerGui = player:WaitForChild("PlayerGui")

local SprintHUD = {}
SprintHUD.__index = SprintHUD

local IS_MOBILE = UserInputService.TouchEnabled and not UserInputService.MouseEnabled

-- Geometria (px)
local BUTTON_SIZE = 72
local MARGIN_X = 190
local MARGIN_Y = 60

local BASE_COLOR = Color3.fromRGB(255, 255, 255)
local ACTIVE_COLOR = Color3.fromRGB(255, 196, 64)
local PLATE_COLOR = Color3.fromRGB(10, 11, 14) -- mesma placa escura dos outros HUDs

function SprintHUD.new()
	local self = setmetatable({}, SprintHUD)

	self._active = false
	self._visible = false

	if IS_MOBILE then
		self:_build()
	end

	return self
end

function SprintHUD:_build()
	local gui = Instance.new("ScreenGui")
	gui.Name = "SprintHUD"
	gui.ResetOnSpawn = false
	gui.IgnoreGuiInset = true
	gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
	gui.DisplayOrder = 5
	gui.Enabled = false
	gui.Parent = playerGui
	self._gui = gui

	local button = Instance.new("TextButton")
	button.Name = "RunButton"
	button.AnchorPoint = Vector2.new(1, 1)
	button.Position = UDim2.new(1, -MARGIN_X, 1, -MARGIN_Y)
	button.Size = UDim2.fromOffset(BUTTON_SIZE, BUTTON_SIZE)
	button.BackgroundColor3 = PLATE_COLOR
	button.BackgroundTransparency = 0.35
	button.AutoButtonColor = false
	button.BorderSizePixel = 0
	button.Text = "RUN"
	button.Font = Enum.Font.GothamBold
	button.TextSize = 18
	button.TextColor3 = BASE_COLOR
	button.Parent = gui

	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(1, 0)
	corner.Parent = button

	local ring = Instance.new("UIStroke")
	-- Num TextButton o stroke contorna o texto por padrão
	ring.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
	ring.Color = BASE_COLOR
	ring.Thickness = 2
	ring.Transparency = 0.35
	ring.Parent = button

	-- Toque liga/desliga: segurar o botão prenderia o polegar que gira a câmera
	button.Activated:Connect(function()
		if self._onToggle then
			self._onToggle()
		end
	end)

	self._button = button
	self._ring = ring
end

function SprintHUD:SetToggleHandler(onToggle)
	self._onToggle = onToggle
end

function SprintHUD:SetActive(active: boolean)
	self._active = active

	if not self._button then
		return
	end

	local color = if active then ACTIVE_COLOR else BASE_COLOR
	self._button.BackgroundTransparency = if active then 0.15 else 0.35
	self._button.TextColor3 = color
	self._ring.Color = color
	self._ring.Transparency = if active then 0 else 0.35
end

--- Chamado todo frame pelo controller, então só toca na instância quando muda.
function SprintHUD:SetVisible(show: boolean)
	if not self._gui or self._visible == show then
		return
	end

	self._visible = show
	self._gui.Enabled = show
end

function SprintHUD:Destroy()
	if self._gui then
		self._gui:Destroy()
		self._gui = nil
	end
end

return SprintHUD
