--[[
	WarpHUD
	Só aparece pilotando a própria nave num Place com WarpDestinations.

	  - Carga: holograma no topo, ao centro — destino, progresso e cancelar [X]
	  - Mensagem curta (fora de alcance, interrompido, chegada): linha
	    holográfica logo abaixo da carga, sem placa

	É instrumento de voo como a velocidade e o casco, então usa o mesmo
	sistema de placa presa à câmera (Holo). O destino é escolhido mirando no
	marcador (WarpAimHUD, [F]) ou pelo mapa (MapHUD). Quem decide e valida é
	o servidor.

	Local: src/client/UI/WarpHUD.luau
]]

local TweenService = game:GetService("TweenService")

local UIStyle = require(script.Parent.UIStyle)
local Holo = require(script.Parent.Holo)

local THEME = Holo.THEME
local HT = Holo.T
local upper = UIStyle.upper

-- Placas, em studs na escala do PC
local CHARGE_SIZE = Vector2.new(1.1, 0.26)
local MESSAGE_SIZE = Vector2.new(1.5, 0.12)
local SCREEN_Y = 0.8 -- topo, centralizado
local MESSAGE_GAP = 0.02
-- O warp é o momento de destaque do voo: as duas placas são maiores que as
-- de instrumento (conteúdo junto, mesmo layout)
local WARP_SCALE = 1.5

-- Conteúdo, em pixels da SurfaceGui
local PADDING = 18
local LABEL_SIZE = 30
local CANCEL_SIZE = 24
local CANCEL_WIDTH = 190
local BAR_Y = 62
local BAR_HEIGHT = 14
local MESSAGE_TEXT_SIZE = 30

local MESSAGE_TIME = 2.5

local WarpHUD = {}
WarpHUD.__index = WarpHUD

function WarpHUD.new()
	local self = setmetatable({}, WarpHUD)

	self._visible = false
	self._charging = false
	self._travelling = false
	self._messageShown = false

	self:_build()
	return self
end

function WarpHUD:_build()
	-- Carga
	local charge = Holo.new("WarpCharge", CHARGE_SIZE, function(cam)
		return Holo.ScreenCFrame(cam, 0, SCREEN_Y, 0)
	end, WARP_SCALE)
	self._chargeHolo = charge

	local container = charge:Plate()
	local padding = Instance.new("UIPadding")
	padding.PaddingTop = UDim.new(0, PADDING)
	padding.PaddingBottom = UDim.new(0, PADDING)
	padding.PaddingLeft = UDim.new(0, PADDING + 4)
	padding.PaddingRight = UDim.new(0, PADDING + 4)
	padding.Parent = container

	local label = Holo.Label(container, "Label", LABEL_SIZE, Holo.FONT_VALUE, HT.value, true)
	label.Size = UDim2.new(1, -CANCEL_WIDTH - 12, 0, 40)
	self._chargeLabel = label

	local cancel = Instance.new("TextButton")
	cancel.Name = "Cancel"
	cancel.AnchorPoint = Vector2.new(1, 0)
	cancel.Position = UDim2.fromScale(1, 0)
	cancel.Size = UDim2.fromOffset(CANCEL_WIDTH, 40)
	cancel.BackgroundTransparency = 1
	cancel.AutoButtonColor = false
	cancel.Text = if UIStyle.IS_MOBILE then "CANCELAR" else "CANCELAR [X]"
	cancel.TextColor3 = THEME.white
	cancel.TextTransparency = HT.title
	cancel.TextSize = CANCEL_SIZE
	cancel.FontFace = Holo.FONT_TITLE
	cancel.TextXAlignment = Enum.TextXAlignment.Right
	cancel.Parent = container
	cancel.MouseEnter:Connect(function()
		cancel.TextTransparency = HT.value
	end)
	cancel.MouseLeave:Connect(function()
		cancel.TextTransparency = HT.title
	end)
	cancel.Activated:Connect(function()
		if self._onCancel then
			self._onCancel()
		end
	end)
	self._cancel = cancel

	self._chargeFill = Holo.Bar(container, "Charge", BAR_Y, BAR_HEIGHT)
	self._chargeFill.Size = UDim2.fromScale(0, 1)

	-- Mensagem: logo abaixo da carga, no mesmo lugar com ou sem carga na tela
	local message
	message = Holo.new("WarpMessage", MESSAGE_SIZE, function(cam)
		local down = charge.size.Y / 2 + MESSAGE_GAP * Holo.SCALE * WARP_SCALE + message.size.Y / 2
		return Holo.ScreenCFrame(cam, 0, SCREEN_Y, 0, Vector3.new(0, -down, 0))
	end, WARP_SCALE)
	self._messageHolo = message

	local text = Holo.Label(message.gui, "Message", MESSAGE_TEXT_SIZE, Holo.FONT_VALUE, HT.value, true)
	text.Size = UDim2.fromScale(1, 1)
	text.TextXAlignment = Enum.TextXAlignment.Center
	local stroke = Instance.new("UIStroke")
	stroke.Color = THEME.plate
	stroke.Thickness = 3
	stroke.Transparency = 0.2
	stroke.Parent = text
	self._message = text
end

function WarpHUD:_refresh()
	self._chargeHolo:SetVisible(self._visible and self._charging)
	self._messageHolo:SetVisible(self._visible and self._messageShown)
end

-- ═══════════════════════════════════════════════════════════
-- Carga
-- ═══════════════════════════════════════════════════════════

function WarpHUD:SetCharging(destinationId: string?)
	self:_stopTravelTween()
	self._charging = destinationId ~= nil
	self._travelling = false
	self._cancel.Visible = true
	if destinationId then
		self._chargeLabel.Text = "WARP  →  " .. upper(destinationId)
		self._chargeFill.Size = UDim2.fromScale(0, 1)
	end
	self:_refresh()
end

--- Dentro do túnel: a barra vira contagem de chegada e não dá mais pra cancelar.
function WarpHUD:SetTravelling(destinationId: string, duration: number)
	self:_stopTravelTween()
	self._charging = true
	self._travelling = true
	self._cancel.Visible = false
	self._chargeLabel.Text = "SALTO  →  " .. upper(destinationId)
	self._chargeFill.Size = UDim2.fromScale(0, 1)
	self:_refresh()

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
	self._message.Text = upper(text)
	self._message.TextColor3 = if isError then THEME.danger else THEME.white
	self._messageShown = true
	self:_refresh()

	local token = {}
	self._messageToken = token
	task.delay(MESSAGE_TIME, function()
		if self._messageToken == token then
			self._messageShown = false
			self:_refresh()
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
	if not visible then
		self._messageShown = false
		self:SetCharging(nil)
	end
	self:_refresh()
end

function WarpHUD:IsVisible(): boolean
	return self._visible
end

return WarpHUD
