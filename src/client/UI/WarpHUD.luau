--[[
	WarpHUD
	Só aparece pilotando a própria nave num Place com WarpDestinations.

	  - Barra de carga: progresso + cancelar [X]
	  - Mensagem curta (fora de alcance, interrompido, chegada)

	O destino é escolhido mirando no marcador (WarpAimHUD, [F]) ou pelo mapa
	(MapHUD). Quem decide e valida é o servidor.

	Local: src/client/UI/WarpHUD.luau
]]

local Players = game:GetService("Players")
local TweenService = game:GetService("TweenService")
local GuiService = game:GetService("GuiService")

local UIStyle = require(script.Parent.UIStyle)

local player = Players.LocalPlayer
local playerGui = player:WaitForChild("PlayerGui")

local C, T = UIStyle.C, UIStyle.T
local spaced, upper = UIStyle.spaced, UIStyle.upper

-- Layout: margem da borda. Tela compacta (altura <=
-- UIStyle.COMPACT_MAX_HEIGHT) aperta tudo.
local MARGIN = 24
local MARGIN_COMPACT = 12
local GAP = 8
-- Largura reservada pra coluna das dicas de tecla (a barra de carga não invade)
local HINT_COLUMN = 130
local CHARGE_WIDTH = 360
local CHARGE_HEIGHT = 62
local CHARGE_TOP = 70
local MESSAGE_WIDTH = 480

local WarpHUD = {}
WarpHUD.__index = WarpHUD

function WarpHUD.new()
	local self = setmetatable({}, WarpHUD)

	self._visible = false
	self._charging = false
	self._travelling = false

	self:_build()
	return self
end

function WarpHUD:_build()
	local gui = Instance.new("ScreenGui")
	gui.Name = "WarpHUD"
	gui.ResetOnSpawn = false
	gui.IgnoreGuiInset = true
	gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
	gui.DisplayOrder = 6
	gui.Enabled = false
	gui.Parent = playerGui
	self._gui = gui

	-- Carga
	local charge = Instance.new("Frame")
	charge.Name = "Charge"
	charge.AnchorPoint = Vector2.new(0.5, 0)
	charge.BackgroundColor3 = C.plate
	charge.BackgroundTransparency = 0.2
	charge.Visible = false
	charge.Parent = gui
	UIStyle.corner(charge, 12)
	UIStyle.stroke(charge, T.slotFillLine, 1)
	UIStyle.padding(charge, 10, 14, 10, 14)
	self._charge = charge

	local chargeLabel = UIStyle.label(charge, "Label", 13, UIStyle.FONT_BOLD, T.textPrimary)
	chargeLabel.Size = UDim2.new(1, -100, 0, 18)
	self._chargeLabel = chargeLabel

	local cancel = Instance.new("TextButton")
	cancel.Name = "Cancel"
	cancel.AnchorPoint = Vector2.new(1, 0)
	cancel.Position = UDim2.fromScale(1, 0)
	cancel.Size = UDim2.fromOffset(96, 18)
	cancel.BackgroundTransparency = 1
	cancel.Text = if UIStyle.IS_MOBILE then spaced("CANCELAR") else spaced("CANCELAR") .. " [X]"
	cancel.TextColor3 = C.text
	cancel.TextTransparency = T.textSecondary
	cancel.TextSize = 11
	cancel.FontFace = UIStyle.FONT_MEDIUM
	cancel.TextXAlignment = Enum.TextXAlignment.Right
	cancel.Parent = charge
	cancel.Activated:Connect(function()
		if self._onCancel then
			self._onCancel()
		end
	end)
	self._cancel = cancel

	local track = Instance.new("Frame")
	track.Name = "Track"
	track.Position = UDim2.fromOffset(0, 30)
	track.Size = UDim2.new(1, 0, 0, 6)
	track.BackgroundColor3 = C.surface
	track.BackgroundTransparency = 0.88
	track.BorderSizePixel = 0
	track.Parent = charge
	UIStyle.corner(track, 3)

	local fill = Instance.new("Frame")
	fill.Name = "Fill"
	fill.Size = UDim2.fromScale(0, 1)
	fill.BackgroundColor3 = C.prompt
	fill.BorderSizePixel = 0
	fill.Parent = track
	UIStyle.corner(fill, 3)
	self._chargeFill = fill

	-- Mensagem curta (fora de alcance, interrompido)
	local message = UIStyle.label(gui, "Message", 14, UIStyle.FONT_BOLD, 0)
	message.AnchorPoint = Vector2.new(0.5, 0)
	message.TextXAlignment = Enum.TextXAlignment.Center
	message.Visible = false
	local messageStroke = Instance.new("UIStroke")
	messageStroke.Color = C.plate
	messageStroke.Thickness = 2
	messageStroke.Transparency = 0.3
	messageStroke.Parent = message
	self._message = message

	gui:GetPropertyChangedSignal("AbsoluteSize"):Connect(function()
		self:_layout()
	end)
	self:_layout()
end

--[[
	Recalcula tudo a partir do tamanho real da tela. Roda no build e toda vez
	que ela muda (girar o celular, redimensionar a janela).

	A área útil desconta o inset do topo (barra do Roblox), porque a ScreenGui
	usa IgnoreGuiInset e, sem isso, a barra entraria embaixo dela.
]]
function WarpHUD:_layout()
	local size = self._gui.AbsoluteSize
	if size.X <= 0 or size.Y <= 0 then
		return -- ainda sem tamanho (primeiro frame)
	end

	local compact = size.Y <= UIStyle.COMPACT_MAX_HEIGHT
	local margin = if compact then MARGIN_COMPACT else MARGIN
	local inset = GuiService:GetGuiInset().Y
	local top = inset + margin

	-- Carga e mensagem: centradas no topo, nunca mais largas que a tela
	local chargeTop = if compact then top else math.max(CHARGE_TOP, top)
	self._charge.Position = UDim2.new(0.5, 0, 0, chargeTop)
	-- Centrada, a barra não pode invadir a coluna das dicas na direita
	local chargeRoom = size.X - 2 * (margin + HINT_COLUMN + GAP)
	self._charge.Size = UDim2.fromOffset(math.clamp(chargeRoom, 200, CHARGE_WIDTH), CHARGE_HEIGHT)

	self._message.Position = UDim2.new(0.5, 0, 0, chargeTop + CHARGE_HEIGHT + 8)
	self._message.Size = UDim2.fromOffset(math.min(MESSAGE_WIDTH, size.X - margin * 2), 20)
end

-- ═══════════════════════════════════════════════════════════
-- Carga
-- ═══════════════════════════════════════════════════════════

function WarpHUD:SetCharging(destinationId: string?)
	self:_stopTravelTween()
	self._charging = destinationId ~= nil
	self._travelling = false
	self._charge.Visible = self._charging
	self._cancel.Visible = true
	if destinationId then
		self._chargeLabel.Text = spaced("WARP") .. "  →  " .. spaced(upper(destinationId))
		self._chargeFill.Size = UDim2.fromScale(0, 1)
	end
end

--- Dentro do túnel: a barra vira contagem de chegada e não dá mais pra cancelar.
function WarpHUD:SetTravelling(destinationId: string, duration: number)
	self:_stopTravelTween()
	self._charging = true
	self._travelling = true
	self._charge.Visible = true
	self._cancel.Visible = false
	self._chargeLabel.Text = spaced("SALTO") .. "  →  " .. spaced(upper(destinationId))
	self._chargeFill.Size = UDim2.fromScale(0, 1)

	self._travelTween = TweenService:Create(
		self._chargeFill,
		TweenInfo.new(math.max(duration, 0.01), Enum.EasingStyle.Linear),
		{ Size = UDim2.fromScale(1, 1) }
	)
	self._travelTween:Play()
end

function WarpHUD:_stopTravelTween()
	if self._travelTween then
		self._travelTween:Cancel()
		self._travelTween = nil
	end
end

function WarpHUD:SetProgress(alpha: number)
	if self._travelling then
		return
	end
	self._chargeFill.Size = UDim2.fromScale(math.clamp(alpha, 0, 1), 1)
end

--- Só a carga é cancelável; o salto, não.
function WarpHUD:IsCharging(): boolean
	return self._charging and not self._travelling
end

--- Carga ou viagem em andamento (inclui o túnel, que não é cancelável).
function WarpHUD:IsBusy(): boolean
	return self._charging
end

function WarpHUD:ShowMessage(text: string, isError: boolean?)
	local message = self._message
	message.Text = text
	message.TextColor3 = if isError then C.negative else C.text
	message.Visible = true

	local token = {}
	self._messageToken = token
	task.delay(2.5, function()
		if self._messageToken == token then
			message.Visible = false
		end
	end)
end

-- ═══════════════════════════════════════════════════════════
-- Visibilidade
-- ═══════════════════════════════════════════════════════════

function WarpHUD:SetCancelHandler(handler: () -> ())
	self._onCancel = handler
end

function WarpHUD:SetVisible(visible: boolean)
	if self._visible == visible then
		return
	end
	self._visible = visible
	self._gui.Enabled = visible
	if visible then
		-- A tela pode ter girado com a HUD escondida
		self:_layout()
	end
	if not visible then
		self:SetCharging(nil)
	end
end

function WarpHUD:IsVisible(): boolean
	return self._visible
end

return WarpHUD
