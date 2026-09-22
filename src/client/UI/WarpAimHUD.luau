--[[
	WarpAimHUD
	Mirar num marcador de warp pilotando: um losango marca o alvo na tela e,
	abaixo da mira, aparece "[F] WARP PARA <NOME>".

	Quem escolhe o alvo (ângulo da câmera até cada marcador) e pede o warp é o
	ShipController; aqui é só desenho. No celular o prompt é o botão de toque.

	Local: src/client/UI/WarpAimHUD.luau
]]

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")

local UIStyle = require(script.Parent.UIStyle)

local player = Players.LocalPlayer
local playerGui = player:WaitForChild("PlayerGui")

local C, T = UIStyle.C, UIStyle.T
local spaced, upper = UIStyle.spaced, UIStyle.upper

local PROMPT_OFFSET = 70 -- abaixo do centro da tela
local RETICLE_SIZE = 30

export type Target = {
	id: string,
	name: string,
	position: Vector3,
	distance: number,
	inRange: boolean,
}

local WarpAimHUD = {}
WarpAimHUD.__index = WarpAimHUD

local function formatDistance(studs: number): string
	if studs >= 1000 then
		return string.format("%.1fk studs", studs / 1000)
	end
	return string.format("%d studs", math.floor(studs))
end

function WarpAimHUD.new()
	local self = setmetatable({}, WarpAimHUD)
	self._target = nil :: Target?
	self:_build()
	return self
end

function WarpAimHUD:_build()
	local gui = Instance.new("ScreenGui")
	gui.Name = "WarpAimHUD"
	gui.ResetOnSpawn = false
	gui.IgnoreGuiInset = true -- casa com Camera:WorldToViewportPoint
	gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
	gui.DisplayOrder = 5
	gui.Enabled = false
	gui.Parent = playerGui
	self._gui = gui

	-- Losango em volta do marcador
	local reticle = Instance.new("Frame")
	reticle.Name = "Reticle"
	reticle.AnchorPoint = Vector2.new(0.5, 0.5)
	reticle.Size = UDim2.fromOffset(RETICLE_SIZE, RETICLE_SIZE)
	reticle.Rotation = 45
	reticle.BackgroundTransparency = 1
	reticle.Parent = gui
	self._reticleStroke = UIStyle.stroke(reticle, 0.15, 1.5)
	self._reticle = reticle

	-- Prompt
	local prompt = Instance.new("TextButton")
	prompt.Name = "Prompt"
	prompt.AnchorPoint = Vector2.new(0.5, 0)
	prompt.Position = UDim2.new(0.5, 0, 0.5, PROMPT_OFFSET)
	prompt.AutomaticSize = Enum.AutomaticSize.X
	prompt.Size = UDim2.fromOffset(0, 24)
	prompt.BackgroundColor3 = C.plate
	prompt.BackgroundTransparency = if UIStyle.IS_MOBILE then 0.35 else 1
	prompt.BorderSizePixel = 0
	prompt.AutoButtonColor = false
	prompt.Text = ""
	prompt.Parent = gui
	prompt.Activated:Connect(function()
		if self._onActivate then
			self._onActivate()
		end
	end)
	if UIStyle.IS_MOBILE then
		prompt.Size = UDim2.fromOffset(0, 34)
		UIStyle.corner(prompt, 17)
		UIStyle.stroke(prompt, T.panelLine, 1)
		UIStyle.padding(prompt, 0, 16, 0, 16)
	end
	self._prompt = prompt

	local layout = UIStyle.list(prompt, 8, true)
	layout.VerticalAlignment = Enum.VerticalAlignment.Center
	layout.HorizontalAlignment = Enum.HorizontalAlignment.Center

	local cap = Instance.new("TextLabel")
	cap.Name = "Key"
	cap.Size = UDim2.fromOffset(22, 22)
	cap.BackgroundColor3 = C.plate
	cap.BackgroundTransparency = 0.35
	cap.BorderSizePixel = 0
	cap.Text = "F"
	cap.TextColor3 = C.text
	cap.TextSize = 13
	cap.FontFace = UIStyle.FONT_BOLD
	cap.LayoutOrder = 1
	cap.Visible = not UIStyle.IS_MOBILE
	cap.Parent = prompt
	UIStyle.corner(cap, 5)
	UIStyle.stroke(cap, 0.45, 1)
	self._cap = cap

	local label = UIStyle.label(prompt, "Label", 14, UIStyle.FONT_BOLD, T.textPrimary)
	label.AutomaticSize = Enum.AutomaticSize.X
	label.Size = UDim2.fromScale(0, 1)
	label.LayoutOrder = 2
	local shadow = Instance.new("UIStroke")
	shadow.Color = C.plate
	shadow.Thickness = 1.5
	shadow.Transparency = 0.3
	shadow.Parent = label
	self._label = label

	local detail = UIStyle.label(gui, "Detail", 11, UIStyle.FONT_MEDIUM, T.textSecondary)
	detail.AnchorPoint = Vector2.new(0.5, 0)
	detail.Size = UDim2.fromOffset(300, 14)
	detail.TextXAlignment = Enum.TextXAlignment.Center
	local detailShadow = Instance.new("UIStroke")
	detailShadow.Color = C.plate
	detailShadow.Thickness = 1.5
	detailShadow.Transparency = 0.3
	detailShadow.Parent = detail
	self._detail = detail
end

function WarpAimHUD:_place()
	local target = self._target
	if not target then
		return
	end
	local camera = workspace.CurrentCamera
	local point, onScreen = camera:WorldToViewportPoint(target.position)
	self._reticle.Visible = onScreen
	if onScreen then
		self._reticle.Position = UDim2.fromOffset(point.X, point.Y)
	end
	local promptHeight = self._prompt.AbsoluteSize.Y
	self._detail.Position = UDim2.new(0.5, 0, 0.5, PROMPT_OFFSET + promptHeight + 4)
end

--- Alvo atual (ou nil pra esconder). Pode ser chamado todo frame.
function WarpAimHUD:SetTarget(target: Target?)
	self._target = target
	if not target then
		if self._gui.Enabled then
			self._gui.Enabled = false
		end
		if self._renderConn then
			self._renderConn:Disconnect()
			self._renderConn = nil
		end
		return
	end

	local color = if target.inRange then C.prompt else C.negative
	self._reticleStroke.Color = color
	self._label.Text = spaced("WARP PARA") .. "  " .. spaced(upper(target.name))
	self._label.TextTransparency = if target.inRange then T.textPrimary else T.textMuted
	self._cap.TextTransparency = if target.inRange then 0 else T.textMuted
	if target.inRange then
		self._detail.Text = formatDistance(target.distance)
		self._detail.TextColor3 = C.text
	else
		self._detail.Text = formatDistance(target.distance) .. "  ·  fora do alcance"
		self._detail.TextColor3 = C.negative
	end

	self._gui.Enabled = true
	if not self._renderConn then
		self._renderConn = RunService.RenderStepped:Connect(function()
			self:_place()
		end)
	end
	self:_place()
end

function WarpAimHUD:GetTarget(): Target?
	return self._target
end

function WarpAimHUD:SetActivateHandler(handler: () -> ())
	self._onActivate = handler
end

return WarpAimHUD
