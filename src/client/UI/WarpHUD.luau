--[[
	WarpHUD
	Só aparece pilotando a própria nave num Place com WarpDestinations.

	  - Botão WARP [G]: abre/fecha a lista de destinos
	  - Lista: marcador orbital, distância e se está no alcance do tipo equipado
	  - Barra de carga: progresso + cancelar [X]

	Quem decide e valida é o servidor; a lista é só leitura do alcance.

	Local: src/client/UI/WarpHUD.luau
]]

local Players = game:GetService("Players")

local UIStyle = require(script.Parent.UIStyle)

local player = Players.LocalPlayer
local playerGui = player:WaitForChild("PlayerGui")

local C, T = UIStyle.C, UIStyle.T
local spaced, upper = UIStyle.spaced, UIStyle.upper

local LIST_WIDTH = 290
local ROW_HEIGHT = 44
local MAX_ROWS_VISIBLE = 6

local WarpHUD = {}
WarpHUD.__index = WarpHUD

local function formatDistance(studs: number): string
	if studs >= 1000 then
		return string.format("%.1fk studs", studs / 1000)
	end
	return string.format("%d studs", math.floor(studs))
end

function WarpHUD.new()
	local self = setmetatable({}, WarpHUD)

	self._visible = false
	self._listOpen = false
	self._rows = {}
	self._charging = false

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

	-- Botão
	local toggle, _ = UIStyle.button(gui, if UIStyle.IS_MOBILE then "WARP" else "WARP  [G]", false)
	toggle.Name = "Toggle"
	toggle.AnchorPoint = Vector2.new(1, 0.5)
	toggle.Position = UDim2.new(1, -24, 0.5, -((ROW_HEIGHT * MAX_ROWS_VISIBLE) / 2) - 40)
	toggle.Size = UDim2.fromOffset(if UIStyle.IS_MOBILE then 110 else 130, 36)
	toggle.BackgroundColor3 = C.plate
	toggle.BackgroundTransparency = 0.25
	toggle.Activated:Connect(function()
		self:ToggleList()
	end)
	self._toggle = toggle

	-- Lista
	local list = Instance.new("ScrollingFrame")
	list.Name = "Destinations"
	list.AnchorPoint = Vector2.new(1, 0)
	list.Position = UDim2.new(1, -24, 0.5, -((ROW_HEIGHT * MAX_ROWS_VISIBLE) / 2) - 14)
	list.Size = UDim2.fromOffset(LIST_WIDTH, ROW_HEIGHT * MAX_ROWS_VISIBLE)
	list.BackgroundColor3 = C.plate
	list.BackgroundTransparency = 0.2
	list.BorderSizePixel = 0
	list.ScrollBarThickness = UIStyle.SCROLLBAR
	list.ScrollBarImageColor3 = C.line
	list.ScrollBarImageTransparency = 0.7
	list.AutomaticCanvasSize = Enum.AutomaticSize.Y
	list.CanvasSize = UDim2.new()
	list.Visible = false
	list.Parent = gui
	UIStyle.corner(list, 12)
	UIStyle.stroke(list, T.panelLine, 1)
	UIStyle.padding(list, 6, 6, 6, 6)
	UIStyle.list(list, 4)
	self._list = list

	local empty = UIStyle.label(list, "Empty", 13, UIStyle.FONT_REGULAR, T.textMuted)
	empty.Size = UDim2.new(1, 0, 0, ROW_HEIGHT)
	empty.TextXAlignment = Enum.TextXAlignment.Center
	empty.Text = "Nenhum destino neste setor."
	self._empty = empty

	-- Carga
	local charge = Instance.new("Frame")
	charge.Name = "Charge"
	charge.AnchorPoint = Vector2.new(0.5, 0)
	charge.Position = UDim2.new(0.5, 0, 0, 70)
	charge.Size = UDim2.fromOffset(360, 62)
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
	message.Position = UDim2.new(0.5, 0, 0, 140)
	message.Size = UDim2.fromOffset(480, 20)
	message.TextXAlignment = Enum.TextXAlignment.Center
	message.Visible = false
	local messageStroke = Instance.new("UIStroke")
	messageStroke.Color = C.plate
	messageStroke.Thickness = 2
	messageStroke.Transparency = 0.3
	messageStroke.Parent = message
	self._message = message
end

-- ═══════════════════════════════════════════════════════════
-- Lista
-- ═══════════════════════════════════════════════════════════

function WarpHUD:_getRow(index: number)
	local row = self._rows[index]
	if row then
		return row
	end

	local button = Instance.new("TextButton")
	button.Name = "Row" .. index
	button.Size = UDim2.new(1, 0, 0, ROW_HEIGHT - 4)
	button.BackgroundColor3 = C.surface
	button.BackgroundTransparency = T.slotEmptyBg
	button.AutoButtonColor = false
	button.Text = ""
	button.LayoutOrder = index
	button.Parent = self._list
	UIStyle.corner(button, 8)
	UIStyle.padding(button, 4, 10, 4, 10)

	local key = UIStyle.label(button, "Key", 12, UIStyle.FONT_BOLD, T.textMuted)
	key.Size = UDim2.new(0, 18, 1, 0)
	key.Text = if UIStyle.IS_MOBILE or index > 9 then "" else tostring(index)

	local name = UIStyle.label(button, "Name", 14, UIStyle.FONT_BOLD, T.textPrimary)
	name.Position = UDim2.fromOffset(22, 0)
	name.Size = UDim2.new(1, -22, 0.55, 0)
	name.TextTruncate = Enum.TextTruncate.AtEnd

	local detail = UIStyle.label(button, "Detail", 11, UIStyle.FONT_MEDIUM, T.textMuted)
	detail.Position = UDim2.new(0, 22, 0.55, 0)
	detail.Size = UDim2.new(1, -22, 0.45, 0)

	row = { button = button, name = name, detail = detail, id = nil, inRange = false }
	self._rows[index] = row

	button.MouseEnter:Connect(function()
		button.BackgroundTransparency = T.slotFillBg
	end)
	button.MouseLeave:Connect(function()
		button.BackgroundTransparency = T.slotEmptyBg
	end)
	button.Activated:Connect(function()
		self:_activate(index)
	end)

	return row
end

function WarpHUD:_activate(index: number)
	local row = self._rows[index]
	if not row or not row.id or not row.button.Visible then
		return
	end
	if self._onWarp then
		self._onWarp(row.id)
	end
end

--- destinations = { { id, distance, inRange } } já ordenado.
function WarpHUD:SetDestinations(destinations, unlimited: boolean)
	self._empty.Visible = #destinations == 0

	for i, dest in destinations do
		local row = self:_getRow(i)
		row.id = dest.id
		row.inRange = dest.inRange
		row.button.Visible = true
		row.name.Text = spaced(upper(dest.id))
		row.name.TextTransparency = if dest.inRange then T.textPrimary else T.textMuted
		if dest.inRange then
			row.detail.Text = formatDistance(dest.distance) .. (if unlimited then "  ·  alcance ilimitado" else "  ·  no alcance")
			row.detail.TextColor3 = C.text
		else
			row.detail.Text = formatDistance(dest.distance) .. "  ·  fora do alcance"
			row.detail.TextColor3 = C.negative
		end
	end

	for i = #destinations + 1, #self._rows do
		self._rows[i].button.Visible = false
		self._rows[i].id = nil
	end
end

--- Tecla 1..9 com a lista aberta.
function WarpHUD:ActivateIndex(index: number): boolean
	if not self._listOpen then
		return false
	end
	self:_activate(index)
	return true
end

function WarpHUD:SetListOpen(open: boolean)
	self._listOpen = open
	self._list.Visible = open and self._visible
end

function WarpHUD:ToggleList()
	self:SetListOpen(not self._listOpen)
end

function WarpHUD:IsListOpen(): boolean
	return self._listOpen
end

-- ═══════════════════════════════════════════════════════════
-- Carga
-- ═══════════════════════════════════════════════════════════

function WarpHUD:SetCharging(destinationId: string?)
	self._charging = destinationId ~= nil
	self._charge.Visible = self._charging
	if destinationId then
		self._chargeLabel.Text = spaced("WARP") .. "  →  " .. spaced(upper(destinationId))
		self._chargeFill.Size = UDim2.fromScale(0, 1)
		self:SetListOpen(false)
	end
end

function WarpHUD:SetProgress(alpha: number)
	self._chargeFill.Size = UDim2.fromScale(math.clamp(alpha, 0, 1), 1)
end

function WarpHUD:IsCharging(): boolean
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

function WarpHUD:SetWarpHandler(handler: (string) -> ())
	self._onWarp = handler
end

function WarpHUD:SetCancelHandler(handler: () -> ())
	self._onCancel = handler
end

function WarpHUD:SetVisible(visible: boolean)
	if self._visible == visible then
		return
	end
	self._visible = visible
	self._gui.Enabled = visible
	if not visible then
		self:SetListOpen(false)
		self:SetCharging(nil)
	end
end

function WarpHUD:IsVisible(): boolean
	return self._visible
end

return WarpHUD
