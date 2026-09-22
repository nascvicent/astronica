--[[
	UIStyle
	Paleta, fontes e peças básicas dos painéis 2D (menu da nave, hangar, warp).
	Espelha o visual do InventoryHUD: monocromático, hierarquia por
	transparência, fonte Jura, cantos arredondados e borda fina.

	Local: src/client/UI/UIStyle.luau
]]

local TweenService = game:GetService("TweenService")
local UserInputService = game:GetService("UserInputService")

local UIStyle = {}

UIStyle.IS_MOBILE = UserInputService.TouchEnabled and not UserInputService.KeyboardEnabled

-- Abaixo desta altura (celular deitado) os painéis usam o layout compacto
UIStyle.COMPACT_MAX_HEIGHT = 600
UIStyle.SCROLLBAR = if UIStyle.IS_MOBILE then 6 else 2

local WHITE = Color3.fromRGB(255, 255, 255)

UIStyle.C = {
	overlay = Color3.fromRGB(0, 0, 0),
	panelBg = Color3.fromRGB(13, 14, 17),
	plate = Color3.fromRGB(10, 11, 14),
	surface = WHITE,
	line = WHITE,
	accent = WHITE,
	text = WHITE,
	positive = Color3.fromRGB(90, 220, 130),
	negative = Color3.fromRGB(255, 105, 95),
	-- Ícones dos prompts da nave (§9.3)
	prompt = Color3.fromHex("#45C7FF"),
}

UIStyle.T = {
	overlay = 0.42,
	panel = 0.08,
	panelLine = 0.82,
	divider = 0.9,
	slotEmptyBg = 0.94,
	slotEmptyLine = 0.88,
	slotFillBg = 0.87,
	slotFillLine = 0.45,
	textPrimary = 0,
	textSecondary = 0.35,
	textMuted = 0.62,
	textFaint = 0.8,
}

local JURA = "rbxasset://fonts/families/Jura.json"
UIStyle.FONT_REGULAR = Font.new(JURA, Enum.FontWeight.Regular, Enum.FontStyle.Normal)
UIStyle.FONT_MEDIUM = Font.new(JURA, Enum.FontWeight.Medium, Enum.FontStyle.Normal)
UIStyle.FONT_BOLD = Font.new(JURA, Enum.FontWeight.Bold, Enum.FontStyle.Normal)

UIStyle.TWEEN_OPEN = TweenInfo.new(0.3, Enum.EasingStyle.Quart, Enum.EasingDirection.Out)
UIStyle.TWEEN_CLOSE = TweenInfo.new(0.22, Enum.EasingStyle.Quart, Enum.EasingDirection.In)

local C, T = UIStyle.C, UIStyle.T

-- ═══════════════════════════════════════════════════════════
-- Texto
-- ═══════════════════════════════════════════════════════════

function UIStyle.spaced(text: string): string
	local chars = {}
	for _, code in utf8.codes(text) do
		table.insert(chars, utf8.char(code))
	end
	return table.concat(chars, " ")
end

-- string.upper só mexe em ASCII
local ACCENT_UPPER = {
	["á"] = "Á", ["à"] = "À", ["â"] = "Â", ["ã"] = "Ã",
	["é"] = "É", ["ê"] = "Ê", ["í"] = "Í",
	["ó"] = "Ó", ["ô"] = "Ô", ["õ"] = "Õ",
	["ú"] = "Ú", ["ç"] = "Ç",
}

function UIStyle.upper(text: string): string
	for lower, up in ACCENT_UPPER do
		text = string.gsub(text, lower, up)
	end
	return string.upper(text)
end

function UIStyle.formatNumber(value: number): string
	if math.abs(value - math.floor(value)) < 0.05 then
		return tostring(math.floor(value + 0.5))
	end
	return string.format("%.1f", value)
end

-- ═══════════════════════════════════════════════════════════
-- Peças
-- ═══════════════════════════════════════════════════════════

function UIStyle.corner(parent: Instance, radius: number)
	local c = Instance.new("UICorner")
	c.CornerRadius = UDim.new(0, radius)
	c.Parent = parent
	return c
end

function UIStyle.stroke(parent: Instance, transparency: number, thickness: number?)
	local s = Instance.new("UIStroke")
	s.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
	s.Color = C.line
	s.Thickness = thickness or 1
	s.Transparency = transparency
	s.Parent = parent
	return s
end

function UIStyle.padding(parent: Instance, top: number, right: number, bottom: number, left: number)
	local p = Instance.new("UIPadding")
	p.PaddingTop = UDim.new(0, top)
	p.PaddingRight = UDim.new(0, right)
	p.PaddingBottom = UDim.new(0, bottom)
	p.PaddingLeft = UDim.new(0, left)
	p.Parent = parent
	return p
end

function UIStyle.label(parent: Instance, name: string, textSize: number, font: Font, transparency: number)
	local l = Instance.new("TextLabel")
	l.Name = name
	l.BackgroundTransparency = 1
	l.BorderSizePixel = 0
	l.Text = ""
	l.TextColor3 = C.text
	l.TextTransparency = transparency
	l.TextSize = textSize
	l.FontFace = font
	l.TextXAlignment = Enum.TextXAlignment.Left
	l.Parent = parent
	return l
end

function UIStyle.divider(parent: Instance, horizontal: boolean)
	local d = Instance.new("Frame")
	d.Name = "Divider"
	d.BackgroundColor3 = C.line
	d.BackgroundTransparency = T.divider
	d.BorderSizePixel = 0
	d.Size = if horizontal then UDim2.new(1, 0, 0, 1) else UDim2.new(0, 1, 1, 0)
	d.Parent = parent
	return d
end

function UIStyle.list(parent: Instance, padding: number, horizontal: boolean?)
	local layout = Instance.new("UIListLayout")
	layout.FillDirection = if horizontal then Enum.FillDirection.Horizontal else Enum.FillDirection.Vertical
	layout.Padding = UDim.new(0, padding)
	layout.SortOrder = Enum.SortOrder.LayoutOrder
	layout.Parent = parent
	return layout
end

--- Botão com borda. primary = fundo branco e texto escuro (ação principal).
--- Retorna o botão e set(enabled) pra ligar/desligar sem recriar.
function UIStyle.button(parent: Instance, text: string, primary: boolean?)
	local btn = Instance.new("TextButton")
	btn.Name = "Button"
	btn.AutoButtonColor = false
	btn.BorderSizePixel = 0
	btn.BackgroundColor3 = C.surface
	btn.Text = UIStyle.spaced(text)
	btn.TextSize = 13
	btn.FontFace = UIStyle.FONT_BOLD
	btn.Size = UDim2.new(0, 140, 0, 34)
	btn.Parent = parent
	UIStyle.corner(btn, 8)
	local line = UIStyle.stroke(btn, T.slotFillLine, 1)

	local enabled = true
	local hovered = false

	local function paint()
		if primary then
			btn.BackgroundTransparency = if not enabled then 0.85 elseif hovered then 0 else 0.08
			btn.TextColor3 = if enabled then C.plate else C.text
			btn.TextTransparency = if enabled then 0 else T.textMuted
		else
			btn.BackgroundTransparency = if hovered and enabled then 0.86 else 0.94
			btn.TextColor3 = C.text
			btn.TextTransparency = if enabled then T.textPrimary else T.textMuted
		end
		line.Transparency = if enabled then T.slotFillLine else T.slotEmptyLine
	end

	btn.MouseEnter:Connect(function()
		hovered = true
		paint()
	end)
	btn.MouseLeave:Connect(function()
		hovered = false
		paint()
	end)
	paint()

	local function set(isEnabled: boolean, newText: string?)
		enabled = isEnabled
		btn.Active = isEnabled
		if newText then
			btn.Text = UIStyle.spaced(newText)
		end
		paint()
	end

	return btn, set
end

--[[
	Dica de tecla discreta: tecla num quadradinho + rótulo, sem placa. É o
	jeito dos atalhos da HUD de voo ([M] MAPA, [G] WARP) ficarem no canto sem
	pesar. No celular não há tecla: vira só o rótulo numa pílula leve, que é o
	botão de toque.

	Cresce pra esquerda a partir do AnchorPoint (1, 0), pra empilhar encostado
	na borda direita. Retorna o botão e set(label, key?).
]]
UIStyle.HINT_HEIGHT = if UIStyle.IS_MOBILE then 32 else 24
UIStyle.HINT_GAP = 6

function UIStyle.keyHint(parent: Instance, key: string, label: string)
	local btn = Instance.new("TextButton")
	btn.Name = "KeyHint"
	btn.AnchorPoint = Vector2.new(1, 0)
	btn.AutomaticSize = Enum.AutomaticSize.X
	btn.Size = UDim2.fromOffset(0, UIStyle.HINT_HEIGHT)
	btn.BackgroundColor3 = C.plate
	btn.BackgroundTransparency = if UIStyle.IS_MOBILE then 0.45 else 1
	btn.BorderSizePixel = 0
	btn.AutoButtonColor = false
	btn.Text = ""
	btn.Parent = parent
	if UIStyle.IS_MOBILE then
		UIStyle.corner(btn, UIStyle.HINT_HEIGHT // 2)
		UIStyle.stroke(btn, T.panelLine, 1)
		UIStyle.padding(btn, 0, 14, 0, 14)
	end

	local layout = UIStyle.list(btn, 8, true)
	layout.VerticalAlignment = Enum.VerticalAlignment.Center
	layout.HorizontalAlignment = Enum.HorizontalAlignment.Right

	local cap = Instance.new("TextLabel")
	cap.Name = "Key"
	cap.Size = UDim2.fromOffset(20, 20)
	cap.BackgroundColor3 = C.plate
	cap.BackgroundTransparency = 0.45
	cap.BorderSizePixel = 0
	cap.TextColor3 = C.text
	cap.TextSize = 12
	cap.FontFace = UIStyle.FONT_BOLD
	cap.LayoutOrder = 1
	cap.Visible = not UIStyle.IS_MOBILE
	cap.Parent = btn
	UIStyle.corner(cap, 5)
	UIStyle.stroke(cap, 0.55, 1)

	local text = UIStyle.label(btn, "Label", 12, UIStyle.FONT_BOLD, T.textSecondary)
	text.AutomaticSize = Enum.AutomaticSize.X
	text.Size = UDim2.fromScale(0, 1)
	text.LayoutOrder = 2
	local shadow = Instance.new("UIStroke")
	shadow.Color = C.plate
	shadow.Thickness = 1.5
	shadow.Transparency = 0.4
	shadow.Parent = text

	btn.MouseEnter:Connect(function()
		text.TextTransparency = T.textPrimary
	end)
	btn.MouseLeave:Connect(function()
		text.TextTransparency = T.textSecondary
	end)

	local function set(newLabel: string, newKey: string?)
		text.Text = UIStyle.spaced(newLabel)
		if newKey then
			cap.Text = newKey
		end
	end
	set(label, key)

	return btn, set
end

--- Topo da dica número `slot` (1, 2, ...) na pilha do canto superior direito.
function UIStyle.hintSlotY(top: number, slot: number): number
	return top + (slot - 1) * (UIStyle.HINT_HEIGHT + UIStyle.HINT_GAP)
end

-- ═══════════════════════════════════════════════════════════
-- Painel modal (overlay + card + cabeçalho + abas)
-- ═══════════════════════════════════════════════════════════

--[[
	Cria o esqueleto padrão de painel. Retorna uma tabela com:
	  gui, overlay, panel, header, title, backBtn, tabs, tabButtons, headerLine,
	  body, sizeConstraint, padding
	e as funções:
	  setOpen(open)     — anima abrir/fechar
	  selectTab(i)      — pinta a aba ativa (quem reage é o onTab)
	  applyLayout()     — recalcula compacto/normal
	  isCompact()

	side = "left" encosta o painel na esquerda com overlay leve, pra o mundo
	(pedestal do hangar) continuar visível à direita.
]]
function UIStyle.panel(options: {
	name: string,
	title: string,
	displayOrder: number,
	tabs: { { label: string, disabled: boolean? } }?,
	maxSize: Vector2?,
	side: string?,
	onBack: () -> (),
	onTab: ((index: number) -> ())?,
	onLayout: ((compact: boolean) -> ())?,
}, parentGui: Instance)
	local ui = {}

	local sideLeft = options.side == "left"
	local overlayTarget = if sideLeft then 0.85 else T.overlay
	local restPosition = if sideLeft then UDim2.new(0, 24, 0.5, 0) else UDim2.fromScale(0.5, 0.5)
	local anchor = if sideLeft then Vector2.new(0, 0.5) else Vector2.new(0.5, 0.5)

	local gui = Instance.new("ScreenGui")
	gui.Name = options.name
	gui.ResetOnSpawn = false
	gui.IgnoreGuiInset = true
	gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
	gui.DisplayOrder = options.displayOrder
	gui.Enabled = false
	gui.Parent = parentGui
	ui.gui = gui

	local overlay = Instance.new("Frame")
	overlay.Name = "Background"
	overlay.Size = UDim2.fromScale(1, 1)
	overlay.BackgroundColor3 = C.overlay
	overlay.BackgroundTransparency = 1
	overlay.BorderSizePixel = 0
	overlay.Active = true -- não deixa clique vazar pro mundo
	overlay.Parent = gui
	ui.overlay = overlay

	local panel = Instance.new("CanvasGroup")
	panel.Name = "Panel"
	panel.AnchorPoint = anchor
	panel.Position = restPosition
	panel.Size = UDim2.fromScale(0.82, 0.78)
	panel.BackgroundColor3 = C.panelBg
	panel.BackgroundTransparency = T.panel
	panel.BorderSizePixel = 0
	panel.GroupTransparency = 1
	panel.Parent = overlay
	ui.panel = panel

	local sizeConstraint = Instance.new("UISizeConstraint")
	sizeConstraint.MaxSize = options.maxSize or Vector2.new(1120, 700)
	sizeConstraint.MinSize = Vector2.new(420, 300)
	sizeConstraint.Parent = panel
	ui.sizeConstraint = sizeConstraint

	UIStyle.corner(panel, 16)
	UIStyle.stroke(panel, T.panelLine, 1)
	ui.padding = UIStyle.padding(panel, 26, 30, 24, 30)

	-- Cabeçalho
	local header = Instance.new("Frame")
	header.Name = "Header"
	header.Size = UDim2.new(1, 0, 0, 34)
	header.BackgroundTransparency = 1
	header.Parent = panel
	ui.header = header

	local mark = Instance.new("Frame")
	mark.Name = "Mark"
	mark.AnchorPoint = Vector2.new(0, 0.5)
	mark.Position = UDim2.fromScale(0, 0.5)
	mark.Size = UDim2.fromOffset(26, 26)
	mark.BackgroundTransparency = 1
	mark.Parent = header
	for i = 1, 2 do
		local bar = Instance.new("Frame")
		bar.Size = UDim2.fromOffset(7, 24)
		bar.Position = UDim2.fromOffset((i - 1) * 12, 1)
		bar.BackgroundColor3 = C.accent
		bar.BorderSizePixel = 0
		bar.Rotation = 8
		bar.Parent = mark
	end

	local title = UIStyle.label(header, "Title", 24, UIStyle.FONT_BOLD, T.textPrimary)
	title.AnchorPoint = Vector2.new(0, 0.5)
	title.Position = UDim2.new(0, 44, 0.5, 0)
	title.Size = UDim2.new(1, -180, 1, 0)
	title.TextTruncate = Enum.TextTruncate.AtEnd
	title.Text = UIStyle.spaced(options.title)
	ui.title = title

	local backBtn = Instance.new("TextButton")
	backBtn.Name = "BackBtn"
	backBtn.AnchorPoint = Vector2.new(1, 0.5)
	backBtn.Position = UDim2.fromScale(1, 0.5)
	backBtn.Size = UDim2.fromOffset(120, 28)
	backBtn.BackgroundTransparency = 1
	backBtn.Text = UIStyle.spaced("VOLTAR") .. "   →"
	backBtn.TextColor3 = C.text
	backBtn.TextTransparency = T.textSecondary
	backBtn.TextSize = 15
	backBtn.FontFace = UIStyle.FONT_MEDIUM
	backBtn.TextXAlignment = Enum.TextXAlignment.Right
	backBtn.AutoButtonColor = false
	backBtn.Parent = header
	backBtn.MouseEnter:Connect(function()
		backBtn.TextTransparency = T.textPrimary
	end)
	backBtn.MouseLeave:Connect(function()
		backBtn.TextTransparency = T.textSecondary
	end)
	backBtn.Activated:Connect(options.onBack)
	ui.backBtn = backBtn

	-- Abas
	local tabs = Instance.new("Frame")
	tabs.Name = "Tabs"
	tabs.Size = UDim2.new(1, 0, 0, 30)
	tabs.Position = UDim2.fromOffset(0, 52)
	tabs.BackgroundTransparency = 1
	tabs.Parent = panel
	ui.tabs = tabs

	local tabLayout = UIStyle.list(tabs, 24, true)
	tabLayout.VerticalAlignment = Enum.VerticalAlignment.Center

	ui.tabButtons = {}
	for i, tab in options.tabs or {} do
		local btn = Instance.new("TextButton")
		btn.Name = "Tab_" .. tab.label
		btn.AutomaticSize = Enum.AutomaticSize.X
		btn.Size = UDim2.fromScale(0, 1)
		btn.BackgroundTransparency = 1
		btn.Text = UIStyle.spaced(tab.label)
		btn.TextColor3 = C.text
		btn.TextSize = 14
		btn.AutoButtonColor = false
		btn.LayoutOrder = i
		btn.Parent = tabs
		UIStyle.padding(btn, 0, 6, 0, 6)

		local indicator = Instance.new("Frame")
		indicator.Name = "Indicator"
		indicator.AnchorPoint = Vector2.new(0.5, 1)
		indicator.Size = UDim2.new(0.8, 0, 0, 2)
		indicator.Position = UDim2.fromScale(0.5, 1)
		indicator.BackgroundColor3 = C.accent
		indicator.BorderSizePixel = 0
		indicator.Parent = btn

		ui.tabButtons[i] = { button = btn, indicator = indicator, disabled = tab.disabled }

		btn.Activated:Connect(function()
			if tab.disabled then
				return
			end
			ui.selectTab(i)
			if options.onTab then
				options.onTab(i)
			end
		end)
	end

	function ui.selectTab(index: number)
		for i, tab in ui.tabButtons do
			local active = i == index
			tab.button.TextTransparency = if tab.disabled then T.textFaint elseif active then T.textPrimary else T.textMuted
			tab.button.FontFace = if active then UIStyle.FONT_MEDIUM else UIStyle.FONT_REGULAR
			tab.indicator.Visible = active
		end
	end
	ui.selectTab(1)

	local headerLine = UIStyle.divider(panel, true)
	headerLine.Name = "HeaderLine"
	headerLine.Position = UDim2.fromOffset(0, 84)
	ui.headerLine = headerLine

	local body = Instance.new("Frame")
	body.Name = "Body"
	body.Size = UDim2.new(1, 0, 1, -104)
	body.Position = UDim2.fromOffset(0, 104)
	body.BackgroundTransparency = 1
	body.Parent = panel
	ui.body = body

	local compact = false
	local open = false

	function ui.isCompact(): boolean
		return compact
	end

	function ui.applyLayout()
		local screen = gui.AbsoluteSize
		if screen.X <= 0 or screen.Y <= 0 then
			return
		end
		compact = screen.Y < UIStyle.COMPACT_MAX_HEIGHT

		if compact then
			panel.Size = if sideLeft then UDim2.new(0.62, 0, 1, -24) else UDim2.new(1, -24, 1, -24)
			sizeConstraint.MinSize = Vector2.zero
		else
			panel.Size = if sideLeft then UDim2.fromScale(0.56, 0.86) else UDim2.fromScale(0.82, 0.78)
			sizeConstraint.MinSize = Vector2.new(420, 300)
		end
		restPosition = if sideLeft then UDim2.new(0, if compact then 12 else 24, 0.5, 0) else UDim2.fromScale(0.5, 0.5)

		ui.padding.PaddingTop = UDim.new(0, if compact then 12 else 26)
		ui.padding.PaddingBottom = UDim.new(0, if compact then 12 else 24)
		ui.padding.PaddingLeft = UDim.new(0, if compact then 18 else 30)
		ui.padding.PaddingRight = UDim.new(0, if compact then 18 else 30)

		header.Size = UDim2.new(1, 0, 0, if compact then 28 else 34)
		title.TextSize = if compact then 20 else 24
		tabs.Position = UDim2.fromOffset(0, if compact then 34 else 52)
		tabs.Size = UDim2.new(1, 0, 0, if compact then 26 else 30)
		headerLine.Position = UDim2.fromOffset(0, if compact then 64 else 84)

		local bodyTop = if compact then 72 else 104
		body.Size = UDim2.new(1, 0, 1, -bodyTop)
		body.Position = UDim2.fromOffset(0, bodyTop)

		if options.onLayout then
			options.onLayout(compact)
		end
	end

	gui:GetPropertyChangedSignal("AbsoluteSize"):Connect(ui.applyLayout)

	function ui.setOpen(isOpen: boolean)
		if open == isOpen then
			return
		end
		open = isOpen

		if isOpen then
			gui.Enabled = true
			ui.applyLayout()
			overlay.BackgroundTransparency = 1
			panel.GroupTransparency = 1
			panel.Position = restPosition + UDim2.fromOffset(0, 18)
			TweenService:Create(overlay, UIStyle.TWEEN_OPEN, { BackgroundTransparency = overlayTarget }):Play()
			TweenService:Create(panel, UIStyle.TWEEN_OPEN, {
				GroupTransparency = 0,
				Position = restPosition,
			}):Play()
		else
			TweenService:Create(overlay, UIStyle.TWEEN_CLOSE, { BackgroundTransparency = 1 }):Play()
			local fade = TweenService:Create(panel, UIStyle.TWEEN_CLOSE, {
				GroupTransparency = 1,
				Position = restPosition + UDim2.fromOffset(0, 14),
			})
			fade:Play()
			fade.Completed:Once(function()
				if not open then
					gui.Enabled = false
				end
			end)
		end
	end

	return ui
end

return UIStyle
