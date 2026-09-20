--[[
	HangarHUD
	Hangar: MINHAS NAVES (ver stats, comparar, trocar de nave, melhorar) e a aba
	LOJA reservada como placeholder desabilitado (§0).

	Abre SÓ pelo prompt HANGAR do HangarTerminal — nunca por entrar num volume:
	o hangar é corredor de passagem.

	Dois caminhos pra lançar: o botão LANÇAR daqui (primeiro pad livre) e o
	prompt LANÇAR de cada pad, pra quem já sabe o que quer.

	Pedestal ≠ pad: o ShipPedestal é só vitrine local da nave selecionada; a
	nave de verdade nasce num dos HangarPads.

	  - Cards com ViewportFrame 3D, badge de tipo, tier, borda por raridade e
	    tag EQUIPADA. Só os cards visíveis montam viewport (mobile cai acima de ~6).
	  - Nave selecionada no pedestal 3D (ShipPedestal): clone local, ancorado e
	    sem colisão. Cada jogador vê a própria no mesmo pedestal; a instância
	    nunca existe no servidor. Câmera no CameraPart, se existir.
	  - Stats com delta contra a nave equipada.

	Local: src/client/UI/HangarHUD.luau
]]

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local ShipData = require(ReplicatedStorage.Shared.ShipData)
local PlaceConfig = require(ReplicatedStorage.Shared.PlaceConfig)
local UIStyle = require(script.Parent.UIStyle)
local ShipViewport = require(script.Parent.ShipViewport)

local player = Players.LocalPlayer
local playerGui = player:WaitForChild("PlayerGui")

local C, T = UIStyle.C, UIStyle.T
local spaced, upper, formatNumber = UIStyle.spaced, UIStyle.upper, UIStyle.formatNumber

local DISPLAY_ORDER = 11
local CARD_MIN = 150
local CARD_MAX = 190
local CARD_GAP = 10
local CARD_TEXT_HEIGHT = 46
local SPIN_SPEED = 0.5
local PEDESTAL_SPIN = 0.25
local CAMERA_TWEEN = TweenInfo.new(0.6, Enum.EasingStyle.Quart, Enum.EasingDirection.Out)

-- Linhas de comparação. lowerIsBetter inverte a cor do delta.
local COMPARE = {
	{ stat = "speed", label = "Velocidade" },
	{ stat = "turnSpeed", label = "Manobra" },
	{ stat = "damage", label = "Dano" },
	{ stat = "maxShots", label = "Tiros" },
	{ stat = "fireRate", label = "Cadência", lowerIsBetter = true, suffix = "s", decimals = 2 },
	{ stat = "miningQuality", label = "Mineração" },
	{ stat = "maxHull", label = "Casco" },
	{ stat = "warpRange", label = "Alcance do warp", unlimitedAtZero = true },
	{ stat = "warpChargeTime", label = "Carga do warp", lowerIsBetter = true, suffix = "s" },
}

local HangarHUD = {}
HangarHUD.__index = HangarHUD

function HangarHUD.new()
	local self = setmetatable({}, HangarHUD)

	self._open = false
	self._state = nil
	self._selected = nil
	self._cards = {} :: { [string]: any }
	self._spin = 0
	self._pedestalSpin = 0

	self._ui = UIStyle.panel({
		name = "HangarHUD",
		title = "HANGAR",
		displayOrder = DISPLAY_ORDER,
		side = "left",
		maxSize = Vector2.new(980, 760),
		tabs = { { label = "MINHAS NAVES" }, { label = "LOJA  ·  EM BREVE", disabled = true } },
		onBack = function()
			self:Close()
		end,
		onLayout = function(compact)
			self:_applyLayout(compact)
		end,
	}, playerGui)

	self:_buildBody()

	return self
end

-- ═══════════════════════════════════════════════════════════
-- Build
-- ═══════════════════════════════════════════════════════════

function HangarHUD:_buildBody()
	local body = self._ui.body

	-- Cards (esquerda)
	local scroll = Instance.new("ScrollingFrame")
	scroll.Name = "Cards"
	scroll.Size = UDim2.new(0.5, 0, 1, 0)
	scroll.BackgroundTransparency = 1
	scroll.BorderSizePixel = 0
	scroll.ScrollBarThickness = UIStyle.SCROLLBAR
	scroll.ScrollBarImageColor3 = C.line
	scroll.ScrollBarImageTransparency = 0.7
	scroll.ScrollingDirection = Enum.ScrollingDirection.Y
	scroll.AutomaticCanvasSize = Enum.AutomaticSize.Y
	scroll.CanvasSize = UDim2.new()
	scroll.Parent = body
	self._scroll = scroll

	UIStyle.padding(scroll, 6, UIStyle.SCROLLBAR + 6, 10, 6)

	local grid = Instance.new("UIGridLayout")
	grid.CellSize = UDim2.fromOffset(CARD_MAX, CARD_MAX + CARD_TEXT_HEIGHT)
	grid.CellPadding = UDim2.fromOffset(CARD_GAP, CARD_GAP)
	grid.SortOrder = Enum.SortOrder.LayoutOrder
	grid.Parent = scroll
	self._grid = grid

	scroll:GetPropertyChangedSignal("CanvasPosition"):Connect(function()
		self:_updateVisibleViewports()
	end)
	scroll:GetPropertyChangedSignal("AbsoluteSize"):Connect(function()
		self:_fitCards()
	end)

	-- Detalhe (direita)
	local detail = Instance.new("ScrollingFrame")
	detail.Name = "Detail"
	detail.Size = UDim2.new(0.46, 0, 1, 0)
	detail.Position = UDim2.fromScale(0.54, 0)
	detail.BackgroundTransparency = 1
	detail.BorderSizePixel = 0
	detail.ScrollBarThickness = UIStyle.SCROLLBAR
	detail.ScrollBarImageColor3 = C.line
	detail.ScrollBarImageTransparency = 0.7
	detail.AutomaticCanvasSize = Enum.AutomaticSize.Y
	detail.CanvasSize = UDim2.new()
	detail.Parent = body
	self._detail = detail

	UIStyle.padding(detail, 6, UIStyle.SCROLLBAR + 6, 10, 2)
	UIStyle.list(detail, 6)

	-- Viewport do detalhe: só aparece sem pedestal no mundo
	local holder = Instance.new("Frame")
	holder.Name = "ViewportHolder"
	holder.Size = UDim2.new(1, 0, 0, 170)
	holder.BackgroundColor3 = C.surface
	holder.BackgroundTransparency = 0.96
	holder.LayoutOrder = 0
	holder.Visible = false
	holder.Parent = detail
	UIStyle.corner(holder, 12)
	self._detailViewportStroke = UIStyle.stroke(holder, T.slotEmptyLine, 1)
	self._detailViewportHolder = holder

	local viewport = Instance.new("ViewportFrame")
	viewport.Size = UDim2.new(1, -16, 1, -16)
	viewport.Position = UDim2.fromOffset(8, 8)
	ShipViewport.Style(viewport)
	viewport.Parent = holder
	self._detailViewport = viewport

	local rarity = UIStyle.label(detail, "Rarity", 12, UIStyle.FONT_BOLD, 0)
	rarity.Size = UDim2.new(1, 0, 0, 14)
	rarity.LayoutOrder = 1
	self._rarity = rarity

	local name = UIStyle.label(detail, "Name", 22, UIStyle.FONT_BOLD, 0)
	name.Size = UDim2.new(1, 0, 0, 26)
	name.TextTruncate = Enum.TextTruncate.AtEnd
	name.LayoutOrder = 2
	self._name = name

	local desc = UIStyle.label(detail, "Description", 13, UIStyle.FONT_REGULAR, T.textSecondary)
	desc.Size = UDim2.new(1, 0, 0, 0)
	desc.AutomaticSize = Enum.AutomaticSize.Y
	desc.TextWrapped = true
	desc.LayoutOrder = 3
	self._desc = desc

	local compareTitle = UIStyle.label(detail, "CompareTitle", 11, UIStyle.FONT_MEDIUM, T.textMuted)
	compareTitle.Size = UDim2.new(1, 0, 0, 22)
	compareTitle.TextYAlignment = Enum.TextYAlignment.Bottom
	compareTitle.LayoutOrder = 4
	self._compareTitle = compareTitle

	self._compareRows = {}
	for i, entry in COMPARE do
		local row = Instance.new("Frame")
		row.Name = "Compare_" .. entry.stat
		row.Size = UDim2.new(1, 0, 0, 20)
		row.BackgroundTransparency = 1
		row.LayoutOrder = 10 + i
		row.Parent = detail

		local label = UIStyle.label(row, "Label", 13, UIStyle.FONT_MEDIUM, T.textMuted)
		label.Size = UDim2.fromScale(0.5, 1)
		label.Text = entry.label

		local value = UIStyle.label(row, "Value", 13, UIStyle.FONT_BOLD, 0)
		value.Position = UDim2.fromScale(0.5, 0)
		value.Size = UDim2.fromScale(0.25, 1)
		value.TextXAlignment = Enum.TextXAlignment.Right

		local delta = UIStyle.label(row, "Delta", 12, UIStyle.FONT_BOLD, 0)
		delta.Position = UDim2.fromScale(0.75, 0)
		delta.Size = UDim2.fromScale(0.25, 1)
		delta.TextXAlignment = Enum.TextXAlignment.Right

		self._compareRows[i] = { value = value, delta = delta }
	end

	local buttons = Instance.new("Frame")
	buttons.Name = "Buttons"
	buttons.Size = UDim2.new(1, 0, 0, 92)
	buttons.BackgroundTransparency = 1
	buttons.LayoutOrder = 100
	buttons.Parent = detail
	UIStyle.padding(buttons, 12, 0, 0, 0)
	UIStyle.list(buttons, 8)

	-- Principal: EQUIPAR a selecionada; se ela já é a equipada, LANÇAR
	-- (primeiro pad livre). O prompt de cada pad continua sendo o atalho.
	local primary, setPrimary = UIStyle.button(buttons, "EQUIPAR", true)
	primary.Size = UDim2.new(1, 0, 0, 38)
	primary.LayoutOrder = 1
	self._setPrimary = setPrimary
	primary.Activated:Connect(function()
		local shipId = self._selected
		if not shipId or not self._state then
			return
		end
		if self._state.equipped == shipId then
			if self._onLaunch then
				self:ShowMessage("Preparando lançamento...", false)
				self._onLaunch()
			end
		elseif self._onEquip then
			self:ShowMessage("Equipando...", false)
			self._onEquip(shipId)
		end
	end)

	local upgrade, setUpgrade = UIStyle.button(buttons, "MELHORAR", false)
	upgrade.Size = UDim2.new(1, 0, 0, 34)
	upgrade.LayoutOrder = 2
	self._setUpgrade = setUpgrade
	upgrade.Activated:Connect(function()
		if self._canUpgrade and self._onUpgrade then
			self._onUpgrade()
		end
	end)

	local message = UIStyle.label(detail, "Message", 12, UIStyle.FONT_MEDIUM, T.textSecondary)
	message.Size = UDim2.new(1, 0, 0, 0)
	message.AutomaticSize = Enum.AutomaticSize.Y
	message.TextWrapped = true
	message.LayoutOrder = 101
	self._message = message
end

-- ═══════════════════════════════════════════════════════════
-- Layout
-- ═══════════════════════════════════════════════════════════

function HangarHUD:_applyLayout(compact: boolean)
	self._detailViewportHolder.Size = UDim2.new(1, 0, 0, if compact then 110 else 170)
	self:_fitCards()
end

--- Quantas colunas cabem, com card entre CARD_MIN e CARD_MAX.
function HangarHUD:_fitCards()
	local width = self._scroll.AbsoluteSize.X - (UIStyle.SCROLLBAR + 12)
	if width <= 0 then
		return
	end
	local columns = math.max(1, math.floor((width + CARD_GAP) / (CARD_MIN + CARD_GAP)))
	local cell = math.clamp(math.floor((width - CARD_GAP * (columns - 1)) / columns), 100, CARD_MAX)
	self._grid.CellSize = UDim2.fromOffset(cell, math.floor(cell * 0.72) + CARD_TEXT_HEIGHT)
	task.defer(function()
		self:_updateVisibleViewports()
	end)
end

-- ═══════════════════════════════════════════════════════════
-- Cards
-- ═══════════════════════════════════════════════════════════

function HangarHUD:_createCard(shipId: string)
	local def = ShipData.GetShip(shipId)
	local rarity = ShipData.GetRarity(shipId)

	local card = Instance.new("TextButton")
	card.Name = "Card_" .. shipId
	card.AutoButtonColor = false
	card.Text = ""
	card.BackgroundColor3 = C.surface
	card.BackgroundTransparency = T.slotEmptyBg
	card.Parent = self._scroll
	UIStyle.corner(card, 12)
	local stroke = UIStyle.stroke(card, 0.45, 1)
	stroke.Color = rarity.color

	local viewport = Instance.new("ViewportFrame")
	viewport.Name = "Viewport"
	viewport.Position = UDim2.fromOffset(6, 6)
	viewport.Size = UDim2.new(1, -12, 1, -(CARD_TEXT_HEIGHT + 6))
	ShipViewport.Style(viewport)
	viewport.Parent = card

	local badge = UIStyle.label(card, "Type", 10, UIStyle.FONT_BOLD, 0)
	badge.Position = UDim2.fromOffset(8, 8)
	badge.AutomaticSize = Enum.AutomaticSize.X
	badge.Size = UDim2.fromOffset(0, 16)
	badge.BackgroundColor3 = C.plate
	badge.BackgroundTransparency = 0.3
	badge.Text = spaced(upper(ShipData.GetTypeName(def.shipType)))
	badge.ZIndex = 2
	UIStyle.corner(badge, 4)
	UIStyle.padding(badge, 0, 6, 0, 6)

	local tier = UIStyle.label(card, "Tier", 10, UIStyle.FONT_BOLD, T.textSecondary)
	tier.AnchorPoint = Vector2.new(1, 0)
	tier.Position = UDim2.new(1, -8, 0, 8)
	tier.Size = UDim2.fromOffset(40, 16)
	tier.TextXAlignment = Enum.TextXAlignment.Right
	tier.Text = "T" .. def.tier
	tier.ZIndex = 2

	local equipped = UIStyle.label(card, "Equipped", 10, UIStyle.FONT_BOLD, 0)
	equipped.AnchorPoint = Vector2.new(0.5, 1)
	equipped.Position = UDim2.new(0.5, 0, 1, -(CARD_TEXT_HEIGHT + 2))
	equipped.AutomaticSize = Enum.AutomaticSize.X
	equipped.Size = UDim2.fromOffset(0, 16)
	equipped.BackgroundColor3 = C.surface
	equipped.BackgroundTransparency = 0
	equipped.TextColor3 = C.plate
	equipped.Text = spaced("EQUIPADA")
	equipped.ZIndex = 2
	equipped.Visible = false
	UIStyle.corner(equipped, 4)
	UIStyle.padding(equipped, 0, 6, 0, 6)

	local name = UIStyle.label(card, "Name", 13, UIStyle.FONT_BOLD, 0)
	name.AnchorPoint = Vector2.new(0, 1)
	name.Position = UDim2.new(0, 10, 1, -22)
	name.Size = UDim2.new(1, -20, 0, 16)
	name.TextTruncate = Enum.TextTruncate.AtEnd
	name.Text = def.displayName

	local rarityLabel = UIStyle.label(card, "Rarity", 10, UIStyle.FONT_MEDIUM, 0)
	rarityLabel.AnchorPoint = Vector2.new(0, 1)
	rarityLabel.Position = UDim2.new(0, 10, 1, -8)
	rarityLabel.Size = UDim2.new(1, -20, 0, 12)
	rarityLabel.TextColor3 = rarity.color
	rarityLabel.Text = spaced(upper(rarity.name))

	local selectMark = Instance.new("Frame")
	selectMark.Name = "Selected"
	selectMark.Size = UDim2.fromScale(1, 1)
	selectMark.BackgroundColor3 = C.accent
	selectMark.BackgroundTransparency = 0.88
	selectMark.Visible = false
	selectMark.ZIndex = 0
	selectMark.Parent = card
	UIStyle.corner(selectMark, 12)

	card.Activated:Connect(function()
		self:_select(shipId)
	end)

	return {
		frame = card,
		viewport = viewport,
		stroke = stroke,
		equipped = equipped,
		selectMark = selectMark,
		model = nil,
	}
end

function HangarHUD:_rebuildCards()
	local state = self._state
	local owned = {}
	if state and state.owned then
		for shipId in state.owned do
			table.insert(owned, shipId)
		end
	end
	local sorted = ShipData.GetSortedIds(owned)

	local keep = {}
	for i, shipId in sorted do
		keep[shipId] = true
		local card = self._cards[shipId]
		if not card then
			card = self:_createCard(shipId)
			self._cards[shipId] = card
		end
		card.frame.LayoutOrder = i
		card.equipped.Visible = state.equipped == shipId
		card.selectMark.Visible = self._selected == shipId
		card.stroke.Transparency = if self._selected == shipId then 0 else 0.45
	end

	for shipId, card in self._cards do
		if not keep[shipId] then
			card.frame:Destroy()
			self._cards[shipId] = nil
		end
	end

	task.defer(function()
		self:_updateVisibleViewports()
	end)
end

--- Monta viewport só nos cards que aparecem dentro do scroll; desmonta o resto.
function HangarHUD:_updateVisibleViewports()
	if not self._open then
		return
	end

	local scroll = self._scroll
	local top = scroll.AbsolutePosition.Y
	local bottom = top + scroll.AbsoluteSize.Y

	for shipId, card in self._cards do
		local frame = card.frame
		local y0 = frame.AbsolutePosition.Y
		local y1 = y0 + frame.AbsoluteSize.Y
		local visible = y1 > top and y0 < bottom

		if visible and not card.model then
			card.model = ShipViewport.Mount(card.viewport, shipId)
		elseif not visible and card.model then
			ShipViewport.Clear(card.viewport)
			card.model = nil
		end
	end
end

function HangarHUD:_unmountAll()
	for _, card in self._cards do
		if card.model then
			ShipViewport.Clear(card.viewport)
			card.model = nil
		end
	end
	ShipViewport.Clear(self._detailViewport)
	self._detailModel = nil
	self._detailShipId = nil
end

-- ═══════════════════════════════════════════════════════════
-- Seleção + detalhe
-- ═══════════════════════════════════════════════════════════

function HangarHUD:_select(shipId: string)
	self._selected = shipId
	self:_rebuildCards()
	self:_renderDetail()
	self:_updatePedestal()
end

local function statValue(stats, entry): number
	local value = stats[entry.stat]
	if entry.unlimitedAtZero and value <= 0 then
		return math.huge
	end
	return value
end

local function statText(stats, entry): string
	local value = stats[entry.stat]
	if entry.unlimitedAtZero and value <= 0 then
		return "Ilimitado"
	end
	local text = if entry.decimals
		then string.format("%." .. entry.decimals .. "f", value)
		else formatNumber(value)
	return text .. (entry.suffix or "")
end

function HangarHUD:_renderDetail()
	local state = self._state
	local shipId = self._selected
	local def = ShipData.GetShip(shipId)
	if not state or not def or not state.owned[shipId] then
		return
	end

	local rarity = ShipData.GetRarity(shipId)
	self._rarity.Text = spaced(upper(rarity.name)) .. "   ·   " .. spaced(upper(ShipData.GetTypeName(def.shipType)))
		.. "   ·   " .. spaced("TIER " .. def.tier)
	self._rarity.TextColor3 = rarity.color
	self._name.Text = def.displayName
	self._desc.Text = def.description
	self._detailViewportStroke.Color = rarity.color
	self._detailViewportStroke.Transparency = 0.5

	local stats = ShipData.ComputeStats(shipId, state.owned[shipId])
	local equippedId = state.equipped
	local isEquipped = equippedId == shipId
	local base = if isEquipped then nil else ShipData.ComputeStats(equippedId, state.owned[equippedId])

	local equippedDef = ShipData.GetShip(equippedId)
	self._compareTitle.Text = if isEquipped
		then spaced("NAVE EQUIPADA")
		else spaced("COMPARADO À " .. upper(equippedDef and equippedDef.displayName or "EQUIPADA"))

	for i, entry in COMPARE do
		local row = self._compareRows[i]
		row.value.Text = statText(stats, entry)

		if not base then
			row.delta.Text = ""
			continue
		end

		local a, b = statValue(stats, entry), statValue(base, entry)
		if a == b then
			row.delta.Text = "="
			row.delta.TextColor3 = C.text
			row.delta.TextTransparency = T.textMuted
		else
			local better = if entry.lowerIsBetter then a < b else a > b
			local arrow = if a > b then "↑" else "↓"
			local diff = if a == math.huge or b == math.huge then "ilim." else formatNumber(math.abs(a - b))
			row.delta.Text = arrow .. " " .. diff
			row.delta.TextColor3 = if better then C.positive else C.negative
			row.delta.TextTransparency = 0
		end
	end

	self._setPrimary(true, if isEquipped then "LANÇAR" else "EQUIPAR")

	self._canUpgrade = isEquipped
	self._setUpgrade(isEquipped, if isEquipped then "MELHORAR" else "EQUIPE PARA MELHORAR")

	local pedestal = workspace:FindFirstChild(PlaceConfig.SHIP_PEDESTAL)
	self._detailViewportHolder.Visible = pedestal == nil
	if pedestal == nil and self._detailShipId ~= shipId then
		self._detailShipId = shipId
		self._detailModel = ShipViewport.Mount(self._detailViewport, shipId)
	end
end

function HangarHUD:ShowMessage(text: string, isError: boolean?)
	self._message.Text = text
	self._message.TextColor3 = if isError then C.negative else C.text
	self._message.TextTransparency = if isError then 0 else T.textSecondary
end

-- ═══════════════════════════════════════════════════════════
-- Pedestal + câmera
-- ═══════════════════════════════════════════════════════════

function HangarHUD:_clearPedestal()
	if self._pedestalModel then
		self._pedestalModel:Destroy()
		self._pedestalModel = nil
	end
	self._pedestalShipId = nil
end

--- Cópia local (não replica) da nave selecionada em cima do ShipPedestal.
function HangarHUD:_updatePedestal()
	local pedestal = workspace:FindFirstChild(PlaceConfig.SHIP_PEDESTAL)
	if not self._open or not pedestal or not pedestal:IsA("BasePart") or not self._selected then
		self:_clearPedestal()
		return
	end
	if self._pedestalShipId == self._selected then
		return
	end

	self:_clearPedestal()
	local model = ShipViewport.CreateModel(self._selected)
	if not model then
		return
	end

	local boxCf, size = model:GetBoundingBox()
	model.PrimaryPart = nil
	-- Pivô no centro da base: gira no eixo e assenta no topo do pedestal
	model.WorldPivot = CFrame.new(boxCf.Position - Vector3.new(0, size.Y / 2, 0))
	self._pedestalBase = pedestal.CFrame * CFrame.new(0, pedestal.Size.Y / 2, 0)
	model:PivotTo(self._pedestalBase)
	model.Parent = workspace.CurrentCamera

	self._pedestalModel = model
	self._pedestalShipId = self._selected
end

function HangarHUD:_enterCamera()
	local cameraPart = workspace:FindFirstChild(PlaceConfig.HANGAR_CAMERA)
	local camera = workspace.CurrentCamera
	if not cameraPart or not cameraPart:IsA("BasePart") or not camera then
		return
	end

	self._prevCameraType = camera.CameraType
	self._hangarCameraCFrame = cameraPart.CFrame
	camera.CameraType = Enum.CameraType.Scriptable
	TweenService:Create(camera, CAMERA_TWEEN, { CFrame = cameraPart.CFrame }):Play()
end

function HangarHUD:_exitCamera()
	local camera = workspace.CurrentCamera
	-- Só devolve a câmera se ela ainda for a nossa: fechar o HUD ao lançar não
	-- pode arrancar a câmera de voo que o LocalPlaneScript acabou de assumir
	if self._prevCameraType and camera and camera.CFrame == self._hangarCameraCFrame then
		camera.CameraType = self._prevCameraType
	end
	self._prevCameraType = nil
end

-- ═══════════════════════════════════════════════════════════
-- API pública
-- ═══════════════════════════════════════════════════════════

function HangarHUD:SetState(state)
	self._state = state
	if not state or not state.loaded then
		return
	end

	if not self._selected or not state.owned[self._selected] then
		self._selected = state.equipped
	end

	if self._open then
		self:_rebuildCards()
		self:_renderDetail()
		self:_updatePedestal()
	end
end

--- handler(shipId) pra EQUIPAR; handler() pra LANÇAR e pra MELHORAR (abre o menu da nave).
function HangarHUD:SetEquipHandler(handler: (string) -> ())
	self._onEquip = handler
end

function HangarHUD:SetLaunchHandler(handler: () -> ())
	self._onLaunch = handler
end

function HangarHUD:SetUpgradeHandler(handler: () -> ())
	self._onUpgrade = handler
end

function HangarHUD:Open()
	if self._open or not self._state or not self._state.loaded then
		return
	end
	self._open = true
	self:ShowMessage("", false)

	self._ui.setOpen(true)
	self:_enterCamera()

	self._selected = self._state.equipped
	self:_rebuildCards()
	self:_renderDetail()
	self:_updatePedestal()

	self._renderConn = RunService.RenderStepped:Connect(function(dt)
		self._spin = (self._spin + dt * SPIN_SPEED) % (2 * math.pi)
		local rotation = CFrame.Angles(0, self._spin, 0)
		for _, card in self._cards do
			if card.model then
				card.model:PivotTo(rotation)
			end
		end
		if self._detailModel then
			self._detailModel:PivotTo(rotation)
		end
		if self._pedestalModel and self._pedestalBase then
			self._pedestalSpin = (self._pedestalSpin + dt * PEDESTAL_SPIN) % (2 * math.pi)
			self._pedestalModel:PivotTo(self._pedestalBase * CFrame.Angles(0, self._pedestalSpin, 0))
		end
	end)

	if self._onToggle then
		self._onToggle(true)
	end
end

function HangarHUD:Close()
	if not self._open then
		return
	end
	self._open = false
	self._ui.setOpen(false)
	self:_exitCamera()

	if self._renderConn then
		self._renderConn:Disconnect()
		self._renderConn = nil
	end

	self:_unmountAll()
	self:_clearPedestal()

	if self._onToggle then
		self._onToggle(false)
	end
end

function HangarHUD:SetToggleHandler(handler: (boolean) -> ())
	self._onToggle = handler
end

function HangarHUD:IsOpen(): boolean
	return self._open
end

return HangarHUD
