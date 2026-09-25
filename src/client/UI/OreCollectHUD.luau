--[[
	OreCollectHUD
	Cartão de coleta: aparece na lateral direita quando um item entra no
	inventário pela mineração da nave. Modelo 3D girando, nome na cor da
	raridade, quantidade e a descrição do item.

	Vários cartões empilham (o mais novo embaixo). O mesmo item coletado de
	novo enquanto o cartão dele está na tela soma na quantidade em vez de abrir
	outro.

	Local: src/client/UI/OreCollectHUD.luau
]]

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local InventoryModule = require(ReplicatedStorage.Shared.InventoryModule)
local ItemModels = require(ReplicatedStorage.Shared.ItemModels)
local UIStyle = require(script.Parent.UIStyle)

local player = Players.LocalPlayer
local playerGui = player:WaitForChild("PlayerGui")

local C, T = UIStyle.C, UIStyle.T

local MAX_CARDS = 3
local HOLD_TIME = 5 -- segundos na tela, item comum
local HOLD_PER_TIER = 0.75 -- a mais por nível de raridade acima de comum
local SPIN_SPEED = math.rad(50) -- giro do modelo no viewport (rad/s)
local SLIDE = 36 -- px que o cartão anda ao entrar/sair

local TWEEN_IN = TweenInfo.new(0.35, Enum.EasingStyle.Quart, Enum.EasingDirection.Out)
local TWEEN_OUT = TweenInfo.new(0.25, Enum.EasingStyle.Quart, Enum.EasingDirection.In)
local TWEEN_POP = TweenInfo.new(0.14, Enum.EasingStyle.Quad, Enum.EasingDirection.Out, 0, true)

local LAYOUT = {
	regular = { width = 310, icon = 68, name = 18, amount = 16, desc = 12, caption = 10, pad = 12 },
	compact = { width = 240, icon = 50, name = 15, amount = 13, desc = 11, caption = 9, pad = 9 },
}

local OreCollectHUD = {}
OreCollectHUD.__index = OreCollectHUD

type Card = {
	itemId: string,
	amount: number,
	holder: Frame,
	frame: Frame,
	amountLabel: TextLabel,
	model: Model?,
	fades: { { inst: Instance, prop: string, value: number } },
	stroke: UIStroke,
	token: any,
	closing: boolean,
}

function OreCollectHUD.new()
	local self = setmetatable({}, OreCollectHUD)
	self._cards = {} :: { Card }
	self._order = 0

	local gui = Instance.new("ScreenGui")
	gui.Name = "OreCollectHUD"
	gui.ResetOnSpawn = false
	gui.IgnoreGuiInset = true
	gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
	gui.DisplayOrder = 8
	gui.Parent = playerGui
	self._gui = gui

	local stack = Instance.new("Frame")
	stack.Name = "Stack"
	stack.AnchorPoint = Vector2.new(1, 0)
	stack.BackgroundTransparency = 1
	stack.Size = UDim2.fromOffset(LAYOUT.regular.width, 0)
	stack.AutomaticSize = Enum.AutomaticSize.Y
	stack.Parent = gui
	UIStyle.list(stack, 8)
	self._stack = stack

	local camera = workspace.CurrentCamera
	local function relayout()
		local compact = camera.ViewportSize.Y <= UIStyle.COMPACT_MAX_HEIGHT
		self._layout = if compact then LAYOUT.compact else LAYOUT.regular
		stack.Size = UDim2.fromOffset(self._layout.width, 0)
		stack.Position = if compact then UDim2.new(1, -12, 0.2, 0) else UDim2.new(1, -24, 0.3, 0)
	end
	relayout()
	camera:GetPropertyChangedSignal("ViewportSize"):Connect(relayout)

	RunService.RenderStepped:Connect(function(dt)
		for _, card in self._cards do
			if card.model then
				card.model:PivotTo(card.model:GetPivot() * CFrame.Angles(0, SPIN_SPEED * dt, 0))
			end
		end
	end)

	return self
end

-- ═══════════════════════════════════════════════════════════
-- Construção
-- ═══════════════════════════════════════════════════════════

local function track(card: Card, inst: Instance, prop: string)
	table.insert(card.fades, { inst = inst, prop = prop, value = (inst :: any)[prop] })
end

function OreCollectHUD:_build(itemId: string, amount: number): Card
	local L = self._layout
	local def = InventoryModule.GetItemDef(itemId)
	local rarity = InventoryModule.GetRarity(itemId)
	local color = rarity.color

	self._order += 1

	-- O holder ocupa o lugar na pilha; o cartão desliza dentro dele
	local holder = Instance.new("Frame")
	holder.Name = "Card_" .. itemId
	holder.BackgroundTransparency = 1
	holder.Size = UDim2.new(1, 0, 0, 0)
	holder.AutomaticSize = Enum.AutomaticSize.Y
	holder.LayoutOrder = self._order
	holder.Parent = self._stack

	local frame = Instance.new("Frame")
	frame.Name = "Card"
	frame.BackgroundColor3 = C.plate
	frame.BackgroundTransparency = 0.15
	frame.BorderSizePixel = 0
	frame.Size = UDim2.new(1, 0, 0, 0)
	frame.AutomaticSize = Enum.AutomaticSize.Y
	frame.Parent = holder
	UIStyle.corner(frame, 10)
	local stroke = UIStyle.stroke(frame, 0.45, 1)
	stroke.Color = color

	local card: Card = {
		itemId = itemId,
		amount = amount,
		holder = holder,
		frame = frame,
		amountLabel = nil :: any,
		model = nil,
		fades = {},
		stroke = stroke,
		token = nil,
		closing = false,
	}
	track(card, frame, "BackgroundTransparency")
	track(card, stroke, "Transparency")

	-- Faixa da raridade na borda esquerda
	local accent = Instance.new("Frame")
	accent.Name = "Accent"
	accent.BackgroundColor3 = color
	accent.BorderSizePixel = 0
	accent.AnchorPoint = Vector2.new(0, 0.5)
	accent.Position = UDim2.new(0, 0, 0.5, 0)
	accent.Size = UDim2.new(0, 3, 1, -16)
	accent.Parent = frame
	UIStyle.corner(accent, 2)
	track(card, accent, "BackgroundTransparency")

	-- Ícone 3D
	local iconBox = Instance.new("Frame")
	iconBox.Name = "Icon"
	iconBox.BackgroundColor3 = color
	iconBox.BackgroundTransparency = 0.9
	iconBox.BorderSizePixel = 0
	iconBox.Position = UDim2.fromOffset(L.pad + 4, L.pad)
	iconBox.Size = UDim2.fromOffset(L.icon, L.icon)
	iconBox.Parent = frame
	UIStyle.corner(iconBox, 8)
	track(card, iconBox, "BackgroundTransparency")

	local viewport = Instance.new("ViewportFrame")
	viewport.Name = "Viewport"
	viewport.Size = UDim2.fromScale(1, 1)
	viewport.Parent = iconBox
	ItemModels.StyleViewport(viewport)
	card.model = ItemModels.Mount(viewport, itemId)
	track(card, viewport, "ImageTransparency")

	-- Coluna de texto
	local column = Instance.new("Frame")
	column.Name = "Text"
	column.BackgroundTransparency = 1
	column.Position = UDim2.fromOffset(L.pad + 4 + L.icon + L.pad, L.pad - 2)
	column.Size = UDim2.new(1, -(L.pad + 4 + L.icon + L.pad * 2), 0, 0)
	column.AutomaticSize = Enum.AutomaticSize.Y
	column.Parent = frame
	UIStyle.list(column, 2)

	-- Folga embaixo do cartão (o AutomaticSize não soma padding de filho absoluto)
	local bottom = Instance.new("Frame")
	bottom.Name = "BottomPad"
	bottom.BackgroundTransparency = 1
	bottom.Size = UDim2.new(0, 1, 0, L.pad)
	bottom.Position = UDim2.new(0, 0, 0, L.pad + L.icon)
	bottom.Parent = frame

	local captionText = if def and def.category == "resource" then "Minério coletado" else "Item coletado"
	local caption = UIStyle.label(column, "Caption", L.caption, UIStyle.FONT_BOLD, T.textMuted)
	caption.Text = UIStyle.spaced(UIStyle.upper(captionText))
	caption.Size = UDim2.new(1, 0, 0, L.caption + 4)
	caption.LayoutOrder = 1
	track(card, caption, "TextTransparency")

	local nameRow = Instance.new("Frame")
	nameRow.Name = "NameRow"
	nameRow.BackgroundTransparency = 1
	nameRow.Size = UDim2.new(1, 0, 0, L.name + 4)
	nameRow.LayoutOrder = 2
	nameRow.Parent = column
	UIStyle.list(nameRow, 8, true).VerticalAlignment = Enum.VerticalAlignment.Bottom

	local name = UIStyle.label(nameRow, "Name", L.name, UIStyle.FONT_BOLD, 0)
	name.Text = if def then def.name else itemId
	name.TextColor3 = color
	name.AutomaticSize = Enum.AutomaticSize.X
	name.Size = UDim2.new(0, 0, 1, 0)
	name.LayoutOrder = 1
	track(card, name, "TextTransparency")

	local amountLabel = UIStyle.label(nameRow, "Amount", L.amount, UIStyle.FONT_BOLD, 0)
	amountLabel.Text = "+" .. amount
	amountLabel.AutomaticSize = Enum.AutomaticSize.X
	amountLabel.Size = UDim2.new(0, 0, 1, 0)
	amountLabel.LayoutOrder = 2
	track(card, amountLabel, "TextTransparency")
	card.amountLabel = amountLabel

	local rarityLabel = UIStyle.label(column, "Rarity", L.caption, UIStyle.FONT_BOLD, 0.15)
	rarityLabel.Text = UIStyle.spaced(UIStyle.upper(rarity.name))
	rarityLabel.TextColor3 = color
	rarityLabel.Size = UDim2.new(1, 0, 0, L.caption + 4)
	rarityLabel.LayoutOrder = 3
	track(card, rarityLabel, "TextTransparency")

	local description = UIStyle.label(column, "Description", L.desc, UIStyle.FONT_MEDIUM, T.textSecondary)
	description.Text = InventoryModule.GetDescription(itemId)
	description.TextWrapped = true
	description.TextYAlignment = Enum.TextYAlignment.Top
	description.Size = UDim2.new(1, 0, 0, 0)
	description.AutomaticSize = Enum.AutomaticSize.Y
	description.LayoutOrder = 4
	track(card, description, "TextTransparency")

	local descPad = Instance.new("UIPadding")
	descPad.PaddingTop = UDim.new(0, 3)
	descPad.PaddingBottom = UDim.new(0, L.pad - 2)
	descPad.Parent = description

	return card
end

-- ═══════════════════════════════════════════════════════════
-- Animação
-- ═══════════════════════════════════════════════════════════

function OreCollectHUD:_fadeIn(card: Card)
	for _, fade in card.fades do
		local target = fade.value
		;(fade.inst :: any)[fade.prop] = 1
		TweenService:Create(fade.inst, TWEEN_IN, { [fade.prop] = target }):Play()
	end
	card.frame.Position = UDim2.fromOffset(SLIDE, 0)
	TweenService:Create(card.frame, TWEEN_IN, { Position = UDim2.fromOffset(0, 0) }):Play()

	-- Raro pra cima: a borda pulsa algumas vezes ao chegar
	if InventoryModule.GetRarity(card.itemId).tier >= 3 then
		task.delay(TWEEN_IN.Time, function()
			if card.closing then
				return
			end
			local pulse = TweenInfo.new(0.35, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut, 2, true)
			TweenService:Create(card.stroke, pulse, { Transparency = 0, Thickness = 2 }):Play()
		end)
	end
end

function OreCollectHUD:_close(card: Card)
	if card.closing then
		return
	end
	card.closing = true

	for _, fade in card.fades do
		TweenService:Create(fade.inst, TWEEN_OUT, { [fade.prop] = 1 }):Play()
	end
	local slide = TweenService:Create(card.frame, TWEEN_OUT, { Position = UDim2.fromOffset(SLIDE, 0) })
	slide.Completed:Connect(function()
		local index = table.find(self._cards, card)
		if index then
			table.remove(self._cards, index)
		end
		card.holder:Destroy()
	end)
	slide:Play()
end

function OreCollectHUD:_schedule(card: Card)
	local token = {}
	card.token = token
	local tier = InventoryModule.GetRarity(card.itemId).tier
	task.delay(HOLD_TIME + HOLD_PER_TIER * (tier - 1), function()
		if card.token == token then
			self:_close(card)
		end
	end)
end

-- ═══════════════════════════════════════════════════════════
-- API
-- ═══════════════════════════════════════════════════════════

--- Mostra a coleta de amount unidades de itemId.
function OreCollectHUD:Show(itemId: string, amount: number)
	if not InventoryModule.IsValidItem(itemId) or amount <= 0 then
		return
	end

	for _, card in self._cards do
		if card.itemId == itemId and not card.closing then
			card.amount += amount
			card.amountLabel.Text = "+" .. card.amount
			TweenService:Create(card.amountLabel, TWEEN_POP, { TextSize = self._layout.amount + 5 }):Play()
			self:_schedule(card)
			return
		end
	end

	-- Pilha cheia: o mais antigo sai
	local open = 0
	for _, card in self._cards do
		if not card.closing then
			open += 1
		end
	end
	if open >= MAX_CARDS then
		for _, card in self._cards do
			if not card.closing then
				self:_close(card)
				break
			end
		end
	end

	local card = self:_build(itemId, amount)
	table.insert(self._cards, card)
	self:_fadeIn(card)
	self:_schedule(card)
end

return OreCollectHUD
