--[[
	ShipMenuHUD
	Menu de proximidade da nave (MenuPrompt → AJUSTES): abas STATUS e MELHORIAS.
	Também desenha o modal de confirmação de decolagem em planeta.

	UI reativa, nunca otimista: clicar em MELHORAR só chama o handler; o nível
	novo aparece quando o servidor devolve o ShipStateChanged.

	Local: src/client/UI/ShipMenuHUD.luau
]]

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local ShipData = require(ReplicatedStorage.Shared.ShipData)
local InventoryModule = require(ReplicatedStorage.Shared.InventoryModule)
local UIStyle = require(script.Parent.UIStyle)
local ShipViewport = require(script.Parent.ShipViewport)

local player = Players.LocalPlayer
local playerGui = player:WaitForChild("PlayerGui")

local C, T = UIStyle.C, UIStyle.T
local spaced, upper, formatNumber = UIStyle.spaced, UIStyle.upper, UIStyle.formatNumber

local DISPLAY_ORDER = 12
local SPIN_SPEED = 0.45
local ROW_HEIGHT = 112

local TAB_STATUS = 1
local TAB_UPGRADES = 2

-- Teto de cada barra de status (só visual)
local BAR_MAX = {
	speed = 220,
	turnSpeed = 200,
	damage = 250,
	miningQuality = 100,
	hull = 420,
}

-- O que cada módulo mexe, pra prévia "atual → próximo"
local MODULE_EFFECTS = {
	engine = { { stat = "speed", label = "Velocidade" }, { stat = "turnSpeed", label = "Manobra" } },
	weapon = { { stat = "damage", label = "Dano" }, { stat = "maxShots", label = "Tiros" } },
	drill = { { stat = "miningQuality", label = "Mineração" } },
	plating = { { stat = "maxHull", label = "Casco" } },
}

local ShipMenuHUD = {}
ShipMenuHUD.__index = ShipMenuHUD

function ShipMenuHUD.new()
	local self = setmetatable({}, ShipMenuHUD)

	self._open = false
	self._model = nil
	self._state = nil
	self._inventory = nil
	self._tab = TAB_STATUS
	self._spin = 0
	self._onUpgrade = nil
	self._upgradeAvailable = true
	self._rows = {}

	self._ui = UIStyle.panel({
		name = "ShipMenuHUD",
		title = "NAVE",
		displayOrder = DISPLAY_ORDER,
		maxSize = Vector2.new(980, 640),
		tabs = { { label = "STATUS" }, { label = "MELHORIAS" } },
		onBack = function()
			self:Close()
		end,
		onTab = function(index)
			self:_selectTab(index)
		end,
		onLayout = function(compact)
			self:_applyLayout(compact)
		end,
	}, playerGui)

	self:_buildStatus()
	self:_buildUpgrades()
	self:_buildFooter()
	self:_buildConfirm()
	self:_selectTab(TAB_STATUS)

	return self
end

-- ═══════════════════════════════════════════════════════════
-- STATUS
-- ═══════════════════════════════════════════════════════════

function ShipMenuHUD:_buildStatus()
	local page = Instance.new("Frame")
	page.Name = "StatusPage"
	page.Size = UDim2.new(1, 0, 1, -30)
	page.BackgroundTransparency = 1
	page.Parent = self._ui.body
	self._statusPage = page

	-- Viewport da nave (esquerda)
	local holder = Instance.new("Frame")
	holder.Name = "ViewportHolder"
	holder.Size = UDim2.new(0.42, 0, 1, 0)
	holder.BackgroundColor3 = C.surface
	holder.BackgroundTransparency = 0.96
	holder.BorderSizePixel = 0
	holder.Parent = page
	UIStyle.corner(holder, 12)
	self._viewportStroke = UIStyle.stroke(holder, T.slotEmptyLine, 1)
	self._viewportHolder = holder

	local viewport = Instance.new("ViewportFrame")
	viewport.Name = "Viewport"
	viewport.Size = UDim2.new(1, -24, 1, -24)
	viewport.Position = UDim2.fromOffset(12, 12)
	ShipViewport.Style(viewport)
	viewport.Parent = holder
	self._viewport = viewport

	-- Informações (direita)
	local info = Instance.new("ScrollingFrame")
	info.Name = "Info"
	info.Size = UDim2.new(0.54, 0, 1, 0)
	info.Position = UDim2.fromScale(0.46, 0)
	info.BackgroundTransparency = 1
	info.BorderSizePixel = 0
	info.ScrollBarThickness = UIStyle.SCROLLBAR
	info.ScrollBarImageColor3 = C.line
	info.ScrollBarImageTransparency = 0.7
	info.AutomaticCanvasSize = Enum.AutomaticSize.Y
	info.CanvasSize = UDim2.new()
	info.Parent = page
	self._statusInfo = info

	UIStyle.padding(info, 4, UIStyle.SCROLLBAR + 6, 8, 2)
	UIStyle.list(info, 6)

	local rarity = UIStyle.label(info, "Rarity", 12, UIStyle.FONT_BOLD, T.textPrimary)
	rarity.Size = UDim2.new(1, 0, 0, 14)
	rarity.LayoutOrder = 1
	self._rarityLabel = rarity

	local name = UIStyle.label(info, "Name", 22, UIStyle.FONT_BOLD, T.textPrimary)
	name.Size = UDim2.new(1, 0, 0, 26)
	name.LayoutOrder = 2
	name.TextTruncate = Enum.TextTruncate.AtEnd
	self._nameLabel = name

	local desc = UIStyle.label(info, "Description", 13, UIStyle.FONT_REGULAR, T.textSecondary)
	desc.Size = UDim2.new(1, 0, 0, 0)
	desc.AutomaticSize = Enum.AutomaticSize.Y
	desc.TextWrapped = true
	desc.LayoutOrder = 3
	self._descLabel = desc

	local spacer = Instance.new("Frame")
	spacer.Size = UDim2.new(1, 0, 0, 6)
	spacer.BackgroundTransparency = 1
	spacer.LayoutOrder = 4
	spacer.Parent = info

	self._statRows = {}
	local stats = {
		{ key = "speed", label = "Velocidade", bar = true },
		{ key = "turnSpeed", label = "Manobra", bar = true },
		{ key = "damage", label = "Dano", bar = true },
		{ key = "overheat", label = "Disparo" },
		{ key = "miningQuality", label = "Mineração", bar = true },
		{ key = "hull", label = "Casco", bar = true },
		{ key = "warp", label = "Warp" },
	}
	for i, stat in stats do
		self._statRows[stat.key] = self:_createStatRow(info, stat.label, stat.bar, 10 + i)
	end
end

function ShipMenuHUD:_createStatRow(parent: Instance, labelText: string, withBar: boolean?, order: number)
	local row = Instance.new("Frame")
	row.Name = "Stat_" .. labelText
	row.Size = UDim2.new(1, 0, 0, if withBar then 34 else 22)
	row.BackgroundTransparency = 1
	row.LayoutOrder = order
	row.Parent = parent

	local label = UIStyle.label(row, "Label", 13, UIStyle.FONT_MEDIUM, T.textMuted)
	label.Size = UDim2.new(0.5, 0, 0, 18)
	label.Text = spaced(upper(labelText))

	local value = UIStyle.label(row, "Value", 14, UIStyle.FONT_BOLD, T.textPrimary)
	value.AnchorPoint = Vector2.new(1, 0)
	value.Position = UDim2.fromScale(1, 0)
	value.Size = UDim2.new(0.5, 0, 0, 18)
	value.TextXAlignment = Enum.TextXAlignment.Right

	local fill
	if withBar then
		local track = Instance.new("Frame")
		track.Name = "Track"
		track.Position = UDim2.fromOffset(0, 24)
		track.Size = UDim2.new(1, 0, 0, 4)
		track.BackgroundColor3 = C.surface
		track.BackgroundTransparency = 0.9
		track.BorderSizePixel = 0
		track.Parent = row
		UIStyle.corner(track, 2)

		fill = Instance.new("Frame")
		fill.Name = "Fill"
		fill.Size = UDim2.fromScale(0, 1)
		fill.BackgroundColor3 = C.accent
		fill.BackgroundTransparency = 0.1
		fill.BorderSizePixel = 0
		fill.Parent = track
		UIStyle.corner(fill, 2)
	end

	return { value = value, fill = fill }
end

local function setStat(row, text: string, ratio: number?)
	row.value.Text = text
	if row.fill and ratio then
		row.fill.Size = UDim2.fromScale(math.clamp(ratio, 0, 1), 1)
	end
end

--- Hull atual vem da instância (dano sofrido); o resto sai do ComputeStats.
local function readLiveHull(model: Model?): number?
	local config = model and model:FindFirstChild(ShipData.PARTS.configurations)
	local hull = config and config:FindFirstChild("Hull")
	return if hull and hull:IsA("NumberValue") then hull.Value else nil
end

function ShipMenuHUD:_renderStatus()
	local shipId, stats, def = self:_currentShip()
	if not stats or not def then
		return
	end

	local rarity = ShipData.GetRarity(shipId)
	self._rarityLabel.Text = spaced(upper(rarity.name)) .. "   ·   " .. spaced(upper(ShipData.GetTypeName(def.shipType)))
		.. "   ·   " .. spaced("TIER " .. def.tier)
	self._rarityLabel.TextColor3 = rarity.color
	self._nameLabel.Text = def.displayName
	self._descLabel.Text = def.description
	self._viewportStroke.Color = rarity.color
	self._viewportStroke.Transparency = 0.5

	local rows = self._statRows
	setStat(rows.speed, formatNumber(stats.speed) .. " u/s", stats.speed / BAR_MAX.speed)
	setStat(rows.turnSpeed, formatNumber(stats.turnSpeed), stats.turnSpeed / BAR_MAX.turnSpeed)
	setStat(rows.damage, if stats.gunsEnabled then formatNumber(stats.damage) else "—", stats.damage / BAR_MAX.damage)
	setStat(
		rows.overheat,
		if stats.gunsEnabled
			then string.format(
				"%d tiros  ·  %.2fs/tiro  ·  %ss resfriar",
				stats.maxShots,
				stats.fireRate,
				formatNumber(stats.cooldownTime)
			)
			else "Sem armamento"
	)
	setStat(rows.miningQuality, formatNumber(stats.miningQuality), stats.miningQuality / BAR_MAX.miningQuality)

	local hull = readLiveHull(self._model) or stats.maxHull
	setStat(rows.hull, string.format("%s / %s", formatNumber(hull), formatNumber(stats.maxHull)), stats.maxHull / BAR_MAX.hull)

	local range = if stats.warpRange <= 0 then "Ilimitado" else formatNumber(stats.warpRange) .. " studs"
	setStat(rows.warp, string.format("%s  ·  carga %ss", range, formatNumber(stats.warpChargeTime)))

	if self._viewportShipId ~= shipId then
		self._viewportShipId = shipId
		self._viewportModel = ShipViewport.Mount(self._viewport, shipId)
	end
end

-- ═══════════════════════════════════════════════════════════
-- MELHORIAS
-- ═══════════════════════════════════════════════════════════

function ShipMenuHUD:_buildUpgrades()
	local page = Instance.new("ScrollingFrame")
	page.Name = "UpgradesPage"
	page.Size = UDim2.new(1, 0, 1, -30)
	page.BackgroundTransparency = 1
	page.BorderSizePixel = 0
	page.ScrollBarThickness = UIStyle.SCROLLBAR
	page.ScrollBarImageColor3 = C.line
	page.ScrollBarImageTransparency = 0.7
	page.AutomaticCanvasSize = Enum.AutomaticSize.Y
	page.CanvasSize = UDim2.new()
	page.Visible = false
	page.Parent = self._ui.body
	self._upgradesPage = page

	UIStyle.padding(page, 4, UIStyle.SCROLLBAR + 6, 8, 2)
	UIStyle.list(page, 10)

	-- Melhorar é serviço de hangar. A aba continua abrindo de qualquer lugar —
	-- só os botões é que travam.
	local hint = UIStyle.label(page, "Hint", 13, UIStyle.FONT_MEDIUM, 0)
	hint.Size = UDim2.new(1, 0, 0, 0)
	hint.AutomaticSize = Enum.AutomaticSize.Y
	hint.TextWrapped = true
	hint.TextColor3 = C.negative
	hint.LayoutOrder = 0
	hint.Visible = false
	hint.Text = "Ancore a nave numa plataforma do hangar para trabalhar nas melhorias."
	self._upgradeHint = hint

	for i, moduleId in ShipData.MODULE_ORDER do
		self._rows[moduleId] = self:_createModuleRow(page, moduleId, i)
	end
end

function ShipMenuHUD:_createModuleRow(parent: Instance, moduleId: string, order: number)
	local module = ShipData.Modules[moduleId]

	local row = Instance.new("Frame")
	row.Name = "Module_" .. moduleId
	row.Size = UDim2.new(1, 0, 0, ROW_HEIGHT)
	row.BackgroundColor3 = C.surface
	row.BackgroundTransparency = T.slotEmptyBg
	row.BorderSizePixel = 0
	row.LayoutOrder = order
	row.Parent = parent
	UIStyle.corner(row, 10)
	UIStyle.stroke(row, T.slotEmptyLine, 1)
	UIStyle.padding(row, 12, 14, 12, 16)

	local name = UIStyle.label(row, "Name", 16, UIStyle.FONT_BOLD, T.textPrimary)
	name.Size = UDim2.new(1, -170, 0, 20)
	name.Text = spaced(upper(module.name))

	local level = UIStyle.label(row, "Level", 12, UIStyle.FONT_MEDIUM, T.textMuted)
	level.Position = UDim2.fromOffset(0, 22)
	level.Size = UDim2.new(1, -170, 0, 14)

	local effect = UIStyle.label(row, "Effect", 13, UIStyle.FONT_REGULAR, T.textSecondary)
	effect.Position = UDim2.fromOffset(0, 42)
	effect.Size = UDim2.new(1, -170, 0, 16)
	effect.TextTruncate = Enum.TextTruncate.AtEnd

	local costs = Instance.new("Frame")
	costs.Name = "Costs"
	costs.Position = UDim2.fromOffset(0, 64)
	costs.Size = UDim2.new(1, -170, 0, 22)
	costs.BackgroundTransparency = 1
	costs.Parent = row
	UIStyle.list(costs, 8, true)

	local button, setButton = UIStyle.button(row, "MELHORAR", true)
	button.AnchorPoint = Vector2.new(1, 0.5)
	button.Position = UDim2.fromScale(1, 0.5)
	button.Size = UDim2.fromOffset(150, 38)

	button.Activated:Connect(function()
		local entry = self._rows[moduleId]
		if entry.canUpgrade and self._onUpgrade then
			self:ShowMessage("Melhorando...", false)
			self._onUpgrade(moduleId)
		end
	end)

	return {
		level = level,
		effect = effect,
		costs = costs,
		setButton = setButton,
		canUpgrade = false,
	}
end

local function costChip(parent: Instance, itemId: string, need: number, have: number)
	local def = InventoryModule.GetItemDef(itemId)
	local enough = have >= need

	local chip = Instance.new("TextLabel")
	chip.Name = "Cost_" .. itemId
	chip.AutomaticSize = Enum.AutomaticSize.X
	chip.Size = UDim2.fromOffset(0, 22)
	chip.BackgroundColor3 = C.surface
	chip.BackgroundTransparency = 0.92
	chip.Text = string.format("%s  %d/%d", if def then def.name else itemId, have, need)
	chip.TextColor3 = if enough then C.text else C.negative
	chip.TextTransparency = if enough then T.textSecondary else 0
	chip.TextSize = 12
	chip.FontFace = UIStyle.FONT_MEDIUM
	chip.Parent = parent
	UIStyle.corner(chip, 6)
	UIStyle.padding(chip, 0, 8, 0, 8)
	return chip
end

function ShipMenuHUD:_countItem(itemId: string): number
	local total = 0
	local inventory = self._inventory
	if inventory and inventory.slots then
		for _, slot in inventory.slots do
			if slot and slot.itemId == itemId then
				total += slot.quantity
			end
		end
	end
	return total
end

function ShipMenuHUD:_renderUpgrades()
	local shipId, stats, _def, levels = self:_currentShip()
	if not stats or not levels then
		return
	end

	local available = self._upgradeAvailable ~= false
	self._upgradeHint.Visible = not available

	for _, moduleId in ShipData.MODULE_ORDER do
		local entry = self._rows[moduleId]
		local current = levels[moduleId] or 0
		local max = ShipData.GetMaxModuleLevel(shipId, moduleId)

		for _, child in entry.costs:GetChildren() do
			if child:IsA("GuiObject") then
				child:Destroy()
			end
		end

		if max <= 0 then
			entry.level.Text = spaced("NÃO DISPONÍVEL NESTA NAVE")
			entry.effect.Text = ShipData.Modules[moduleId].description
			entry.canUpgrade = false
			entry.setButton(false, "—")
			continue
		end

		entry.level.Text = spaced(string.format("NÍVEL %d / %d", current, max))

		local cost = ShipData.GetUpgradeCost(shipId, moduleId, current)
		if not cost then
			entry.effect.Text = ShipData.Modules[moduleId].description
			entry.canUpgrade = false
			entry.setButton(false, "MÁXIMO")
			continue
		end

		-- Prévia: a mesma fórmula do servidor com o próximo nível
		local nextLevels = table.clone(levels)
		nextLevels[moduleId] = current + 1
		local nextStats = ShipData.ComputeStats(shipId, nextLevels)

		local parts = {}
		for _, effect in MODULE_EFFECTS[moduleId] do
			local before = (stats :: any)[effect.stat]
			local after = nextStats and (nextStats :: any)[effect.stat] or before
			table.insert(parts, string.format("%s %s → %s", effect.label, formatNumber(before), formatNumber(after)))
		end
		entry.effect.Text = table.concat(parts, "   ·   ")

		local affordable = true
		for _, item in cost do
			local have = self:_countItem(item.itemId)
			costChip(entry.costs, item.itemId, item.quantity, have)
			if have < item.quantity then
				affordable = false
			end
		end

		entry.canUpgrade = affordable and available
		entry.setButton(entry.canUpgrade, "MELHORAR")
	end
end

-- ═══════════════════════════════════════════════════════════
-- Rodapé (mensagens do servidor)
-- ═══════════════════════════════════════════════════════════

function ShipMenuHUD:_buildFooter()
	local message = UIStyle.label(self._ui.body, "Message", 13, UIStyle.FONT_MEDIUM, T.textSecondary)
	message.AnchorPoint = Vector2.new(0, 1)
	message.Position = UDim2.fromScale(0, 1)
	message.Size = UDim2.new(1, 0, 0, 20)
	self._message = message
end

function ShipMenuHUD:ShowMessage(text: string, isError: boolean?)
	self._message.Text = text
	self._message.TextColor3 = if isError then C.negative else C.text
	self._message.TextTransparency = if isError then 0 else T.textSecondary
end

-- ═══════════════════════════════════════════════════════════
-- Modal de confirmação (DECOLAR no planeta, GUARDAR NAVE no hangar)
-- ═══════════════════════════════════════════════════════════

function ShipMenuHUD:_buildConfirm()
	local gui = Instance.new("ScreenGui")
	gui.Name = "ShipConfirmModal"
	gui.ResetOnSpawn = false
	gui.IgnoreGuiInset = true
	gui.DisplayOrder = DISPLAY_ORDER + 1
	gui.Enabled = false
	gui.Parent = playerGui
	self._confirmGui = gui

	local overlay = Instance.new("Frame")
	overlay.Size = UDim2.fromScale(1, 1)
	overlay.BackgroundColor3 = C.overlay
	overlay.BackgroundTransparency = T.overlay
	overlay.Active = true
	overlay.Parent = gui

	local card = Instance.new("Frame")
	card.Name = "Card"
	card.AnchorPoint = Vector2.new(0.5, 0.5)
	card.Position = UDim2.fromScale(0.5, 0.5)
	card.Size = UDim2.new(0.9, 0, 0, 0)
	card.AutomaticSize = Enum.AutomaticSize.Y
	card.BackgroundColor3 = C.panelBg
	card.BackgroundTransparency = T.panel
	card.Parent = overlay
	UIStyle.corner(card, 16)
	UIStyle.stroke(card, T.panelLine, 1)
	UIStyle.padding(card, 24, 26, 22, 26)
	UIStyle.list(card, 10)

	local sizeLimit = Instance.new("UISizeConstraint")
	sizeLimit.MaxSize = Vector2.new(440, math.huge)
	sizeLimit.Parent = card

	local title = UIStyle.label(card, "Title", 20, UIStyle.FONT_BOLD, T.textPrimary)
	title.Size = UDim2.new(1, 0, 0, 0)
	title.AutomaticSize = Enum.AutomaticSize.Y
	title.TextWrapped = true
	title.LayoutOrder = 1
	self._confirmTitle = title

	local body = UIStyle.label(card, "Body", 14, UIStyle.FONT_REGULAR, T.textSecondary)
	body.Size = UDim2.new(1, 0, 0, 0)
	body.AutomaticSize = Enum.AutomaticSize.Y
	body.TextWrapped = true
	body.LayoutOrder = 2
	self._confirmBody = body

	local warning = UIStyle.label(card, "Warning", 13, UIStyle.FONT_MEDIUM, 0)
	warning.Size = UDim2.new(1, 0, 0, 18)
	warning.TextColor3 = C.negative
	warning.LayoutOrder = 3
	self._confirmWarning = warning

	local buttons = Instance.new("Frame")
	buttons.Size = UDim2.new(1, 0, 0, 40)
	buttons.BackgroundTransparency = 1
	buttons.LayoutOrder = 4
	buttons.Parent = card
	local layout = UIStyle.list(buttons, 10, true)
	layout.HorizontalAlignment = Enum.HorizontalAlignment.Right

	local cancel = UIStyle.button(buttons, "CANCELAR", false)
	cancel.Size = UDim2.fromOffset(130, 38)
	cancel.LayoutOrder = 1
	cancel.Activated:Connect(function()
		self:CloseConfirm()
	end)

	local confirm, setConfirm = UIStyle.button(buttons, "CONFIRMAR", true)
	confirm.Size = UDim2.fromOffset(150, 38)
	confirm.LayoutOrder = 2
	self._setConfirmButton = setConfirm
	confirm.Activated:Connect(function()
		local handler = self._onConfirm
		if handler then
			self._onConfirm = nil
			setConfirm(false, self._busyText)
			handler()
		end
	end)
end

--[[
	Abre a confirmação. onConfirm é chamado uma vez; quem fecha é o controller.
	options = { title, body, warning?, confirmText, busyText }
]]
function ShipMenuHUD:OpenConfirm(options, onConfirm: () -> ())
	self._confirmTitle.Text = options.title
	self._confirmBody.Text = options.body
	self._confirmWarning.Text = options.warning or ""
	self._confirmWarning.Visible = options.warning ~= nil
	self._busyText = options.busyText or options.confirmText
	self._onConfirm = onConfirm
	self._setConfirmButton(true, options.confirmText)
	self._confirmGui.Enabled = true
end

function ShipMenuHUD:CloseConfirm()
	self._onConfirm = nil
	self._confirmGui.Enabled = false
end

function ShipMenuHUD:IsConfirmOpen(): boolean
	return self._confirmGui.Enabled
end

-- ═══════════════════════════════════════════════════════════
-- Estado
-- ═══════════════════════════════════════════════════════════

--- (shipId, stats, def, levels) da nave aberta no menu.
function ShipMenuHUD:_currentShip()
	local state = self._state
	if not state or not state.loaded then
		return nil
	end

	local shipId = self._model and self._model:GetAttribute(ShipData.SHIP_ID_ATTRIBUTE) or state.equipped
	local levels = state.owned and state.owned[shipId]
	local def = ShipData.GetShip(shipId)
	if not levels or not def then
		return nil
	end

	return shipId, ShipData.ComputeStats(shipId, levels), def, levels
end

function ShipMenuHUD:_selectTab(index: number)
	self._tab = index
	self._ui.selectTab(index)
	self._statusPage.Visible = index == TAB_STATUS
	self._upgradesPage.Visible = index == TAB_UPGRADES
	self:_render()
end

function ShipMenuHUD:_applyLayout(compact: boolean)
	-- Compacto: viewport encolhe pra coluna estreita e as infos ganham espaço
	self._viewportHolder.Size = UDim2.new(if compact then 0.34 else 0.42, 0, 1, 0)
	self._statusInfo.Position = UDim2.fromScale(if compact then 0.37 else 0.46, 0)
	self._statusInfo.Size = UDim2.new(if compact then 0.63 else 0.54, 0, 1, 0)
end

function ShipMenuHUD:_render()
	if not self._open then
		return
	end
	if self._tab == TAB_STATUS then
		self:_renderStatus()
	else
		self:_renderUpgrades()
	end
end

-- ═══════════════════════════════════════════════════════════
-- API pública
-- ═══════════════════════════════════════════════════════════

function ShipMenuHUD:SetState(state)
	self._state = state
	self:_render()
end

--- Se dá pra melhorar daqui (perto da nave ou no terminal). Só trava os botões
--- da aba MELHORIAS: STATUS funciona de qualquer lugar.
function ShipMenuHUD:SetUpgradeAvailable(available: boolean)
	if self._upgradeAvailable == available then
		return
	end
	self._upgradeAvailable = available
	if self._open and self._tab == TAB_UPGRADES then
		self:_render()
	end
end

function ShipMenuHUD:SetInventory(inventory)
	self._inventory = inventory
	if self._tab == TAB_UPGRADES then
		self:_render()
	end
end

--- handler(moduleId) — quem fala com o servidor é o controller.
function ShipMenuHUD:SetUpgradeHandler(handler: (string) -> ())
	self._onUpgrade = handler
end

function ShipMenuHUD:Open(model: Model?, tab: number?)
	self._model = model
	self._open = true
	self:ShowMessage("", false)
	self._ui.setOpen(true)
	self:_selectTab(tab or TAB_STATUS)

	if not self._spinConn then
		self._spinConn = RunService.RenderStepped:Connect(function(dt)
			if self._viewportModel and self._statusPage.Visible then
				self._spin = (self._spin + dt * SPIN_SPEED) % (2 * math.pi)
				self._viewportModel:PivotTo(CFrame.Angles(0, self._spin, 0))
			end
			-- Hull ao vivo (dano sofrido) no STATUS
			if self._tab == TAB_STATUS and self._model then
				local hull = readLiveHull(self._model)
				if hull ~= self._lastHull then
					self._lastHull = hull
					self:_renderStatus()
				end
			end
		end)
	end
end

function ShipMenuHUD:Close()
	if not self._open then
		return
	end
	self._open = false
	self._model = nil
	self._ui.setOpen(false)

	if self._spinConn then
		self._spinConn:Disconnect()
		self._spinConn = nil
	end

	ShipViewport.Clear(self._viewport)
	self._viewportModel = nil
	self._viewportShipId = nil

	if self._onClose then
		self._onClose()
	end
end

function ShipMenuHUD:SetCloseHandler(handler: () -> ())
	self._onClose = handler
end

function ShipMenuHUD:IsOpen(): boolean
	return self._open
end

function ShipMenuHUD:GetModel(): Model?
	return self._model
end

ShipMenuHUD.TAB_STATUS = TAB_STATUS
ShipMenuHUD.TAB_UPGRADES = TAB_UPGRADES

return ShipMenuHUD
