--[[
	SuitTab
	Aba "Traje" do inventário: preview 3D do player vestindo o traje em foco
	(com a cabeça e o cabelo dele), lista de trajes, requisito de desbloqueio,
	botão de equipar/comprar e cor do visor do capacete.

	Clicar numa cor pinta o preview na hora (mesmo bloqueada, pra ver antes de
	comprar). Cor liberada num traje liberado já é salva no servidor. Cor é
	por traje: liberar uma cor no Pathfinder não libera no Prospector.

	Mesma divisão da aba Nave: preview à esquerda, ficha à direita.
	Quem decide equipar/comprar é o servidor (SuitService) via SuitController.

	Local: src/client/UI/SuitTab.luau
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local UIStyle = require(script.Parent.UIStyle)
local ItemModels = require(ReplicatedStorage.Shared.ItemModels)
local InventoryModule = require(ReplicatedStorage.Shared.InventoryModule)
local SuitConfig = require(ReplicatedStorage.Shared.SuitConfig)
local SuitBuilder = require(ReplicatedStorage.Shared.SuitBuilder)

local player = Players.LocalPlayer

local C, T = UIStyle.C, UIStyle.T
local spaced, upper = UIStyle.spaced, UIStyle.upper

local ROW_HEIGHT = 40
local SWATCH_SIZE = 26
local SWATCH_GAP = 8
local RARITY_LINE = 0.3

local PREVIEW_SPIN = 0.35 -- rad/s
local PREVIEW_FOV = 30
local PREVIEW_PADDING = 1.12
local PREVIEW_DIR = Vector3.new(0.3, 0.12, -1).Unit -- de frente, levemente de cima

local SuitTab = {}
SuitTab.__index = SuitTab

function SuitTab.new(parent: Instance)
	local self = setmetatable({}, SuitTab)

	self._state = nil
	self._selected = nil :: string?
	self._rows = {}
	self._handlers = {}
	self._spin = 0
	self._visorPick = nil :: string? -- cor em foco no preview (pode estar bloqueada)
	self._swatches = {}

	local tab = Instance.new("Frame")
	tab.Name = "SuitTab"
	tab.Size = UDim2.fromScale(1, 1)
	tab.BackgroundTransparency = 1
	tab.Visible = false
	tab.Parent = parent
	self._frame = tab

	-- ── Preview (esquerda) ──
	local holder = Instance.new("Frame")
	holder.Name = "SuitViewportHolder"
	holder.Size = UDim2.new(0.56, 0, 1, 0)
	holder.BackgroundColor3 = C.surface
	holder.BackgroundTransparency = 0.96
	holder.BorderSizePixel = 0
	holder.Parent = tab
	UIStyle.corner(holder, 12)
	self._previewStroke = UIStyle.stroke(holder, T.slotEmptyLine, 1)

	local placeholder = UIStyle.label(holder, "Placeholder", 12, UIStyle.FONT_REGULAR, 0.85)
	placeholder.Size = UDim2.fromScale(1, 1)
	placeholder.Text = spaced("3D PREVIEW")
	placeholder.TextXAlignment = Enum.TextXAlignment.Center
	self._placeholder = placeholder

	local viewport = Instance.new("ViewportFrame")
	viewport.Name = "SuitViewport"
	viewport.Size = UDim2.new(1, -24, 1, -24)
	viewport.Position = UDim2.fromOffset(12, 12)
	viewport.BorderSizePixel = 0
	ItemModels.StyleViewport(viewport)
	viewport.Parent = holder
	self._viewport = viewport

	local divider = UIStyle.divider(tab, false)
	divider.Position = UDim2.new(0.61, 0, 0, 0)

	-- ── Ficha (direita) ──
	local info = Instance.new("ScrollingFrame")
	info.Name = "SuitInfo"
	info.Size = UDim2.new(0.35, 0, 1, 0)
	info.Position = UDim2.new(0.65, 0, 0, 0)
	info.BackgroundTransparency = 1
	info.BorderSizePixel = 0
	info.ScrollBarThickness = UIStyle.SCROLLBAR
	info.ScrollBarImageColor3 = C.line
	info.ScrollBarImageTransparency = 0.7
	info.ScrollingDirection = Enum.ScrollingDirection.Y
	info.AutomaticCanvasSize = Enum.AutomaticSize.Y
	info.CanvasSize = UDim2.new()
	info.Parent = tab
	UIStyle.padding(info, 14, UIStyle.SCROLLBAR + 4, 12, 2)
	UIStyle.list(info, 8)

	local listTitle = UIStyle.label(info, "ListTitle", 13, UIStyle.FONT_MEDIUM, T.textMuted)
	listTitle.Size = UDim2.new(1, 0, 0, 16)
	listTitle.Text = spaced("TRAJES")
	listTitle.LayoutOrder = 1

	local list = Instance.new("Frame")
	list.Name = "List"
	list.Size = UDim2.new(1, 0, 0, 0)
	list.AutomaticSize = Enum.AutomaticSize.Y
	list.BackgroundTransparency = 1
	list.LayoutOrder = 2
	list.Parent = info
	UIStyle.list(list, 6)

	for i, suitId in SuitConfig.GetOrdered() do
		self._rows[suitId] = self:_buildRow(list, suitId, i)
	end

	local sep = UIStyle.divider(info, true)
	sep.LayoutOrder = 3

	local rarity = UIStyle.label(info, "Rarity", 12, UIStyle.FONT_BOLD, T.textPrimary)
	rarity.Size = UDim2.new(1, 0, 0, 14)
	rarity.LayoutOrder = 4
	self._rarity = rarity

	local name = UIStyle.label(info, "Name", 18, UIStyle.FONT_MEDIUM, T.textPrimary)
	name.Size = UDim2.new(1, 0, 0, 22)
	name.TextTruncate = Enum.TextTruncate.AtEnd
	name.LayoutOrder = 5
	self._name = name

	local desc = UIStyle.label(info, "Description", 13, UIStyle.FONT_REGULAR, T.textSecondary)
	desc.Size = UDim2.new(1, 0, 0, 0)
	desc.AutomaticSize = Enum.AutomaticSize.Y
	desc.TextWrapped = true
	desc.TextYAlignment = Enum.TextYAlignment.Top
	desc.LayoutOrder = 6
	self._desc = desc

	-- Requisito de desbloqueio + barra de progresso (só pra objetivo)
	local requirement = UIStyle.label(info, "Requirement", 12, UIStyle.FONT_MEDIUM, T.textMuted)
	requirement.Size = UDim2.new(1, 0, 0, 0)
	requirement.AutomaticSize = Enum.AutomaticSize.Y
	requirement.TextWrapped = true
	requirement.LayoutOrder = 7
	self._requirement = requirement

	local bar = Instance.new("Frame")
	bar.Name = "ProgressBar"
	bar.Size = UDim2.new(1, 0, 0, 6)
	bar.BackgroundColor3 = C.surface
	bar.BackgroundTransparency = 0.9
	bar.BorderSizePixel = 0
	bar.LayoutOrder = 8
	bar.Parent = info
	UIStyle.corner(bar, 3)
	self._bar = bar

	local fill = Instance.new("Frame")
	fill.Name = "Fill"
	fill.Size = UDim2.fromScale(0, 1)
	fill.BackgroundColor3 = C.surface
	fill.BorderSizePixel = 0
	fill.Parent = bar
	UIStyle.corner(fill, 3)
	self._fill = fill

	local button, setButton = UIStyle.button(info, "EQUIPAR", true)
	button.Size = UDim2.new(1, 0, 0, 36)
	button.LayoutOrder = 9
	self._setButton = setButton
	button.Activated:Connect(function()
		self:_onAction()
	end)

	-- ── Visor ──
	local visorSep = UIStyle.divider(info, true)
	visorSep.LayoutOrder = 10

	local visorTitle = UIStyle.label(info, "VisorTitle", 13, UIStyle.FONT_MEDIUM, T.textMuted)
	visorTitle.Size = UDim2.new(1, 0, 0, 16)
	visorTitle.Text = spaced("VISOR")
	visorTitle.LayoutOrder = 11

	local swatches = Instance.new("Frame")
	swatches.Name = "Swatches"
	swatches.Size = UDim2.new(1, 0, 0, 0)
	swatches.AutomaticSize = Enum.AutomaticSize.Y
	swatches.BackgroundTransparency = 1
	swatches.LayoutOrder = 12
	swatches.Parent = info
	local grid = Instance.new("UIGridLayout")
	grid.CellSize = UDim2.fromOffset(SWATCH_SIZE, SWATCH_SIZE)
	grid.CellPadding = UDim2.fromOffset(SWATCH_GAP, SWATCH_GAP)
	grid.SortOrder = Enum.SortOrder.LayoutOrder
	grid.Parent = swatches
	UIStyle.padding(swatches, 3, 3, 3, 3) -- a borda da cor selecionada não é cortada

	for i, colorId in SuitConfig.GetOrderedVisorColors() do
		self._swatches[colorId] = self:_buildSwatch(swatches, colorId, i)
	end

	local visorLabel = UIStyle.label(info, "VisorLabel", 12, UIStyle.FONT_MEDIUM, T.textSecondary)
	visorLabel.Size = UDim2.new(1, 0, 0, 16)
	visorLabel.LayoutOrder = 13
	self._visorLabel = visorLabel

	local visorButton, setVisorButton = UIStyle.button(info, "DESBLOQUEAR", false)
	visorButton.Size = UDim2.new(1, 0, 0, 32)
	visorButton.LayoutOrder = 14
	self._visorButton = visorButton
	self._setVisorButton = setVisorButton
	visorButton.Activated:Connect(function()
		self:_onBuyVisor()
	end)

	return self
end

function SuitTab:_buildSwatch(parent: Instance, colorId: string, order: number)
	local def = SuitConfig.VisorColors[colorId]

	local swatch = Instance.new("TextButton")
	swatch.Name = "Swatch_" .. colorId
	swatch.Text = ""
	swatch.AutoButtonColor = false
	swatch.BorderSizePixel = 0
	swatch.BackgroundColor3 = def.color
	swatch.LayoutOrder = order
	swatch.Parent = parent
	UIStyle.corner(swatch, SWATCH_SIZE // 2)
	local stroke = UIStyle.stroke(swatch, 0.7, 1)

	-- Véu escuro nas cores bloqueadas
	local veil = Instance.new("Frame")
	veil.Name = "LockVeil"
	veil.Size = UDim2.fromScale(1, 1)
	veil.BackgroundColor3 = C.plate
	veil.BackgroundTransparency = 0.45
	veil.BorderSizePixel = 0
	veil.Parent = swatch
	UIStyle.corner(veil, SWATCH_SIZE // 2)

	swatch.Activated:Connect(function()
		self:_onPickVisor(colorId)
	end)

	return { button = swatch, stroke = stroke, veil = veil }
end

function SuitTab:_buildRow(parent: Instance, suitId: string, order: number)
	local suit = SuitConfig.Suits[suitId]

	local row = Instance.new("TextButton")
	row.Name = "Row_" .. suitId
	row.Size = UDim2.new(1, 0, 0, ROW_HEIGHT)
	row.BackgroundColor3 = C.surface
	row.BackgroundTransparency = T.slotEmptyBg
	row.AutoButtonColor = false
	row.BorderSizePixel = 0
	row.Text = ""
	row.LayoutOrder = order
	row.Parent = parent
	UIStyle.corner(row, 8)
	local stroke = UIStyle.stroke(row, T.slotEmptyLine, 1)
	UIStyle.padding(row, 0, 12, 0, 12)

	local name = UIStyle.label(row, "Name", 14, UIStyle.FONT_MEDIUM, T.textPrimary)
	name.Size = UDim2.fromScale(0.6, 1)
	name.Text = suit.displayName

	local status = UIStyle.label(row, "Status", 11, UIStyle.FONT_BOLD, T.textMuted)
	status.AnchorPoint = Vector2.new(1, 0)
	status.Position = UDim2.fromScale(1, 0)
	status.Size = UDim2.fromScale(0.4, 1)
	status.TextXAlignment = Enum.TextXAlignment.Right

	row.Activated:Connect(function()
		self:Select(suitId)
	end)

	return { button = row, stroke = stroke, name = name, status = status }
end

-- ═══════════════════════════════════════════════════════════
-- Estado
-- ═══════════════════════════════════════════════════════════

function SuitTab:_entry(suitId: string)
	local state = self._state
	return state and state.suits and state.suits[suitId]
end

--- Texto curto do lado direito da linha.
function SuitTab:_statusText(suitId: string): string
	local suit = SuitConfig.Suits[suitId]
	local entry = self:_entry(suitId)
	if not entry then return "" end

	if self._state.equipped == suitId then
		return spaced("EM USO")
	elseif entry.owned then
		return spaced("LIBERADO")
	elseif suit.unlock.kind == "price" then
		return UIStyle.formatNumber(suit.unlock.price) .. " LUM"
	elseif entry.progress then
		return string.format("%d / %d", entry.progress.current, entry.progress.total)
	end
	return spaced("BLOQUEADO")
end

--- A cor está liberada naquele traje.
function SuitTab:_ownsColor(suitId: string, colorId: string): boolean
	local state = self._state
	local owned = state and state.visorColors and state.visorColors[suitId]
	return owned ~= nil and owned[colorId] == true
end

--- Cor salva pro traje (a que o servidor usa).
function SuitTab:_savedVisor(suitId: string): string
	local state = self._state
	local saved = state and state.visors and state.visors[suitId]
	local suit = SuitConfig.Get(suitId)
	return saved or (suit and suit.defaultVisor) or "gold"
end

function SuitTab:SetHandlers(handlers: {
	onEquip: (string) -> (),
	onBuy: (string) -> (),
	onSetVisor: (string, string) -> (),
	onBuyVisor: (string, string) -> (),
})
	self._handlers = handlers
end

function SuitTab:SetState(state)
	self._state = state
	if not self._selected and state and state.equipped then
		self._selected = state.equipped
	end
	if self._frame.Visible then
		self:Render()
	end
end

function SuitTab:Select(suitId: string)
	if self._selected == suitId then return end
	self._selected = suitId
	self._visorPick = nil
	self:Render()
end

function SuitTab:SetVisible(visible: boolean)
	self._frame.Visible = visible
	if visible then
		-- Abre sempre no traje em uso
		if self._state and self._state.equipped then
			self._selected = self._state.equipped
		end
		self._visorPick = nil
		self:Render()
	else
		self:Clear()
	end
end

-- ═══════════════════════════════════════════════════════════
-- Render
-- ═══════════════════════════════════════════════════════════

function SuitTab:Render()
	local suitId = self._selected or SuitConfig.DEFAULT_SUIT
	local suit = SuitConfig.Get(suitId)
	if not suit then return end

	for id, row in self._rows do
		local selected = id == suitId
		row.button.BackgroundTransparency = if selected then T.slotFillBg else T.slotEmptyBg
		row.stroke.Transparency = if selected then T.slotFillLine else T.slotEmptyLine
		row.status.Text = self:_statusText(id)
		row.status.TextTransparency = if self._state and self._state.equipped == id then T.textPrimary else T.textMuted
	end

	local rarity = InventoryModule.Rarities[suit.rarity] or InventoryModule.Rarities[InventoryModule.DEFAULT_RARITY]
	self._rarity.Text = spaced(upper(rarity.name))
	self._rarity.TextColor3 = rarity.color
	self._previewStroke.Color = rarity.color
	self._previewStroke.Transparency = if rarity.tier >= 2 then RARITY_LINE else T.slotEmptyLine

	self._name.Text = suit.displayName
	self._desc.Text = suit.description or ""

	local entry = self:_entry(suitId)
	local owned = entry ~= nil and entry.owned
	local equipped = self._state ~= nil and self._state.equipped == suitId

	-- Requisito
	local unlock = suit.unlock
	if owned or unlock.kind == "default" then
		self._requirement.Visible = false
		self._bar.Visible = false
	elseif unlock.kind == "objective" then
		local objective = SuitConfig.Objectives[unlock.objective]
		local progress = entry and entry.progress
		self._requirement.Visible = true
		self._requirement.Text = string.format(
			"%s  ·  %d / %d",
			if objective then objective.text else "Objetivo",
			if progress then progress.current else 0,
			if progress then progress.total else 1
		)
		self._bar.Visible = true
		local ratio = if progress and progress.total > 0 then progress.current / progress.total else 0
		self._fill.Size = UDim2.fromScale(math.clamp(ratio, 0, 1), 1)
	else
		self._requirement.Visible = true
		self._requirement.Text = "Disponível na loja por " .. UIStyle.formatNumber(unlock.price) .. " Lúmens"
		self._bar.Visible = false
	end

	-- Botão
	if not self._state or not self._state.loaded then
		self._setButton(false, "CARREGANDO")
	elseif equipped then
		self._setButton(false, "EM USO")
	elseif owned then
		self._setButton(true, "EQUIPAR")
	elseif unlock.kind == "price" then
		self._setButton(true, "COMPRAR  ·  " .. UIStyle.formatNumber(unlock.price) .. " LUM")
	else
		self._setButton(false, "BLOQUEADO")
	end

	-- Preview: só remonta quando o traje em foco muda
	if self._previewId ~= suitId then
		self:_mountPreview(suitId)
	end

	self:_renderVisor(suitId, owned)
end

function SuitTab:_renderVisor(suitId: string, suitOwned: boolean)
	local saved = self:_savedVisor(suitId)
	local pick = self._visorPick or saved

	for colorId, swatch in self._swatches do
		local selected = colorId == pick
		swatch.stroke.Thickness = if selected then 2 else 1
		swatch.stroke.Transparency = if selected then 0 else 0.7
		swatch.veil.Visible = not self:_ownsColor(suitId, colorId)
	end

	local def = SuitConfig.VisorColors[pick]
	if not def then return end

	if self:_ownsColor(suitId, pick) then
		local note = if not suitOwned then "libere o traje para usar"
			elseif pick == saved then "em uso"
			else "liberada"
		self._visorLabel.Text = def.name .. "  ·  " .. note
		self._visorButton.Visible = false
	else
		self._visorLabel.Text = def.name .. "  ·  " .. UIStyle.formatNumber(def.price) .. " Lúmens"
		self._visorButton.Visible = true
		-- Cor só pode ser comprada pra um traje que o player já tem
		local canBuy = suitOwned and self._state ~= nil and self._state.loaded == true
		self._setVisorButton(
			canBuy,
			if suitOwned then "DESBLOQUEAR  ·  " .. UIStyle.formatNumber(def.price) .. " LUM" else "LIBERE O TRAJE"
		)
	end

	if self._model then
		SuitBuilder.SetVisorColor(self._model, def.color)
	end
end

function SuitTab:_onPickVisor(colorId: string)
	local suitId = self._selected
	if not suitId then return end
	self._visorPick = colorId

	-- Cor liberada num traje liberado: já vale (o preview pinta no Render)
	local entry = self:_entry(suitId)
	if entry and entry.owned and self:_ownsColor(suitId, colorId) and colorId ~= self:_savedVisor(suitId) then
		if self._handlers.onSetVisor then
			self._handlers.onSetVisor(suitId, colorId)
		end
	end
	self:Render()
end

function SuitTab:_onBuyVisor()
	local suitId, colorId = self._selected, self._visorPick
	local entry = suitId and self:_entry(suitId)
	if not suitId or not colorId or not entry or not entry.owned or self:_ownsColor(suitId, colorId) then return end
	if self._handlers.onBuyVisor then
		self._handlers.onBuyVisor(suitId, colorId)
	end
end

function SuitTab:_onAction()
	local suitId = self._selected
	local suit = SuitConfig.Get(suitId)
	local entry = suitId and self:_entry(suitId)
	if not suit or not entry or not self._state or self._state.equipped == suitId then return end

	if entry.owned then
		if self._handlers.onEquip then
			self._handlers.onEquip(suitId)
		end
	elseif suit.unlock.kind == "price" and self._handlers.onBuy then
		self._handlers.onBuy(suitId)
	end
end

-- ═══════════════════════════════════════════════════════════
-- Preview 3D
-- ═══════════════════════════════════════════════════════════

--- Cópia inerte do traje com a cabeça/cabelo do player dentro de um WorldModel.
function SuitTab:_mountPreview(suitId: string)
	self:Clear()
	self._previewId = suitId

	local character = player.Character
	local model = character and SuitBuilder.Build(suitId, character)
	if not model then
		self._placeholder.Visible = true
		return
	end

	for _, inst in model:GetDescendants() do
		if inst:IsA("LuaSourceContainer") or inst:IsA("Sound") or inst:IsA("Tool")
			or inst:IsA("Beam") or inst:IsA("Trail") or inst:IsA("ParticleEmitter")
			or inst:IsA("BillboardGui") or inst:IsA("ProximityPrompt")
		then
			inst:Destroy()
		elseif inst:IsA("Motor6D") then
			inst.Transform = CFrame.new()
		elseif inst:IsA("BasePart") then
			inst.CanCollide = false
			inst.CanQuery = false
			inst.CanTouch = false
			inst.CastShadow = false
		elseif inst:IsA("Humanoid") then
			inst.DisplayDistanceType = Enum.HumanoidDisplayDistanceType.None
		end
	end

	local root = model:FindFirstChild("HumanoidRootPart") :: BasePart?
	if not root then
		model:Destroy()
		self._placeholder.Visible = true
		return
	end
	root.Anchored = true
	model.PrimaryPart = root

	local world = Instance.new("WorldModel")
	world.Name = "SuitWorld"
	world.Parent = self._viewport
	model.Parent = world
	model:PivotTo(CFrame.new())

	local bounds, size = model:GetBoundingBox()
	local focus = bounds.Position
	local distance = (size.Y / 2) / math.tan(math.rad(PREVIEW_FOV / 2)) * PREVIEW_PADDING

	local cam = Instance.new("Camera")
	cam.FieldOfView = PREVIEW_FOV
	cam.CFrame = CFrame.lookAt(focus + PREVIEW_DIR * distance, focus)
	cam.Parent = self._viewport
	self._viewport.CurrentCamera = cam

	self._model = model
	self._spin = 0
	self._placeholder.Visible = false

	local def = SuitConfig.GetVisorColor(self._visorPick or self:_savedVisor(suitId))
	if def then
		SuitBuilder.SetVisorColor(model, def.color)
	end
end

--- Gira o preview. Chamado pelo loop de render do inventário.
function SuitTab:Step(dt: number)
	if not self._model or not self._frame.Visible then return end
	self._spin = (self._spin + dt * PREVIEW_SPIN) % (2 * math.pi)
	self._model:PivotTo(CFrame.Angles(0, self._spin, 0))
end

function SuitTab:Clear()
	ItemModels.Clear(self._viewport)
	self._model = nil
	self._previewId = nil
end

return SuitTab
