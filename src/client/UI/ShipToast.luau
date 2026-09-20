--[[
	ShipToast
	Aviso curto no rodapé, pra estado da nave que acontece no mundo e não em
	painel: ancorando, ancorada, liberada da plataforma.

	Uma linha só, sempre a mais recente. Quem decide o texto é o ShipController.

	Local: src/client/UI/ShipToast.luau
]]

local Players = game:GetService("Players")
local TweenService = game:GetService("TweenService")

local UIStyle = require(script.Parent.UIStyle)

local player = Players.LocalPlayer
local playerGui = player:WaitForChild("PlayerGui")

local C, T = UIStyle.C, UIStyle.T

local FADE = TweenInfo.new(0.2, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)

local ShipToast = {}
ShipToast.__index = ShipToast

function ShipToast.new()
	local self = setmetatable({}, ShipToast)

	local gui = Instance.new("ScreenGui")
	gui.Name = "ShipToast"
	gui.ResetOnSpawn = false
	gui.IgnoreGuiInset = true
	gui.DisplayOrder = 7
	gui.Enabled = false
	gui.Parent = playerGui
	self._gui = gui

	-- Botão, não Frame: no mobile não existe tecla pra soltar a nave do pad
	local frame = Instance.new("TextButton")
	frame.Name = "Card"
	frame.Text = ""
	frame.AutoButtonColor = false
	frame.AnchorPoint = Vector2.new(0.5, 1)
	frame.Position = UDim2.new(0.5, 0, 1, -110)
	frame.Size = UDim2.fromOffset(0, 34)
	frame.AutomaticSize = Enum.AutomaticSize.X
	frame.BackgroundColor3 = C.plate
	frame.BackgroundTransparency = 0.2
	frame.BorderSizePixel = 0
	frame.Parent = gui
	UIStyle.corner(frame, 8)
	self._stroke = UIStyle.stroke(frame, 0.45, 1)
	UIStyle.padding(frame, 0, 16, 0, 16)
	self._frame = frame

	local label = UIStyle.label(frame, "Text", 14, UIStyle.FONT_BOLD, T.textPrimary)
	label.AutomaticSize = Enum.AutomaticSize.X
	label.Size = UDim2.fromOffset(0, 34)
	label.TextXAlignment = Enum.TextXAlignment.Center
	self._label = label

	frame.Activated:Connect(function()
		if self._action then
			self._action()
		end
	end)

	return self
end

--- text = nil esconde. color pinta a borda (estado em andamento x concluído).
--- onActivate torna o aviso clicável/tocável.
function ShipToast:Show(text: string?, color: Color3?, onActivate: (() -> ())?)
	if not text then
		self:Hide()
		return
	end

	self._action = onActivate
	self._frame.Active = onActivate ~= nil
	self._frame.AutoButtonColor = onActivate ~= nil

	if self._text ~= text then
		self._text = text
		self._label.Text = UIStyle.spaced(text)
	end
	self._stroke.Color = color or C.prompt

	if not self._gui.Enabled then
		self._gui.Enabled = true
		self._frame.BackgroundTransparency = 1
		self._label.TextTransparency = 1
		TweenService:Create(self._frame, FADE, { BackgroundTransparency = 0.2 }):Play()
		TweenService:Create(self._label, FADE, { TextTransparency = 0 }):Play()
	end
end

function ShipToast:Hide()
	if not self._gui.Enabled then
		return
	end
	self._text = nil
	self._action = nil
	self._gui.Enabled = false
end

--- Mostra por alguns segundos e some sozinho (a menos que algo mostre outra
--- coisa nesse meio tempo).
function ShipToast:Flash(text: string, duration: number, color: Color3?)
	self:Show(text, color)

	local token = {}
	self._token = token
	task.delay(duration, function()
		if self._token == token then
			self:Hide()
		end
	end)
end

return ShipToast
