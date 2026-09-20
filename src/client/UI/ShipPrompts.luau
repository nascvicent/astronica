--[[
	ShipPrompts
	Visual dos dois ProximityPrompts da nave (EnterPrompt no Seat, MenuPrompt
	no Body) com Style = Custom: um BillboardGui por prompt.

	O prompt continua cuidando de distância, oclusão e tecla. Aqui é só:
	  - ligar localmente os prompts da nave do jogador local (nascem Enabled = false)
	  - desligar tudo enquanto ele estiver sentado
	  - ActionText contextual: PILOTAR no espaço, DECOLAR no planeta,
	    GUARDAR NAVE no MenuPrompt com a nave dentro do hangar
	  - desenhar o ícone e aceitar toque direto no mobile

	Quem reage ao disparo é o ShipController (PromptTriggered).

	Local: src/client/UI/ShipPrompts.luau
]]

local Players = game:GetService("Players")
local CollectionService = game:GetService("CollectionService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local ShipData = require(ReplicatedStorage.Shared.ShipData)
local PlaceConfig = require(ReplicatedStorage.Shared.PlaceConfig)
local UIStyle = require(script.Parent.UIStyle)

local player = Players.LocalPlayer
local playerGui = player:WaitForChild("PlayerGui")

local C, T = UIStyle.C, UIStyle.T

-- Asset ids dos ícones publicados (§11.1 passo 11). Vazio = glifo em texto.
local ICON_SEAT = "rbxassetid://121878147196895"
local ICON_WRENCH = "rbxassetid://121878147196895"

local ICON_HANGAR = "rbxassetid://121878147196895"

-- Glifos que a Jura com certeza renderiza (a seta já é usada no InventoryHUD)
local GLYPH_SEAT = "↑"
local GLYPH_WRENCH = "+"
local GLYPH_HANGAR = "H"

local BILLBOARD_SIZE = 120
-- O ícone some um pouco depois do prompt, pra não piscar na borda do alcance
local BILLBOARD_MAX_DISTANCE = ShipData.PROMPT_DISTANCE + 5

local ShipPrompts = {}
ShipPrompts.__index = ShipPrompts

function ShipPrompts.new()
	local self = setmetatable({}, ShipPrompts)

	self._isPlanet = PlaceConfig.IsPlanet()
	self._seated = false
	self._stow = false
	self._entries = {} :: { [ProximityPrompt]: any }
	self._shipConns = {} :: { [Model]: { RBXScriptConnection } }

	self._folder = Instance.new("Folder")
	self._folder.Name = "ShipPrompts"
	self._folder.Parent = playerGui

	for _, model in CollectionService:GetTagged(ShipData.SHIP_TAG) do
		self:_watchShip(model)
	end
	CollectionService:GetInstanceAddedSignal(ShipData.SHIP_TAG):Connect(function(model)
		self:_watchShip(model)
	end)
	CollectionService:GetInstanceRemovedSignal(ShipData.SHIP_TAG):Connect(function(model)
		self:_unwatchShip(model)
	end)

	return self
end

-- ═══════════════════════════════════════════════════════════
-- Descoberta
-- ═══════════════════════════════════════════════════════════

local function isOwnShip(model: Instance): boolean
	return model:GetAttribute(ShipData.OWNER_ATTRIBUTE) == player.UserId
end

function ShipPrompts:_watchShip(model: Instance)
	if not model:IsA("Model") or self._shipConns[model] then
		return
	end

	local conns = {}
	self._shipConns[model] = conns

	local function consider(inst: Instance)
		if inst:IsA("ProximityPrompt")
			and (inst.Name == ShipData.PARTS.enterPrompt or inst.Name == ShipData.PARTS.menuPrompt)
		then
			self:_bindPrompt(model, inst)
		end
	end

	for _, inst in model:GetDescendants() do
		consider(inst)
	end
	table.insert(conns, model.DescendantAdded:Connect(consider))

	-- Dono pode chegar depois do modelo (ordem de replicação)
	table.insert(conns, model:GetAttributeChangedSignal(ShipData.OWNER_ATTRIBUTE):Connect(function()
		self:Refresh()
	end))
end

function ShipPrompts:_unwatchShip(model: Instance)
	local conns = self._shipConns[model :: Model]
	if conns then
		for _, conn in conns do
			conn:Disconnect()
		end
		self._shipConns[model :: Model] = nil
	end

	for prompt, entry in self._entries do
		if entry.model == model then
			self:_unbindPrompt(prompt)
		end
	end
end

-- ═══════════════════════════════════════════════════════════
-- Prompt + billboard
-- ═══════════════════════════════════════════════════════════

function ShipPrompts:_bindPrompt(model: Model, prompt: ProximityPrompt)
	if self._entries[prompt] then
		return
	end

	local isEnter = prompt.Name == ShipData.PARTS.enterPrompt
	local def = ShipData.GetShip(model:GetAttribute(ShipData.SHIP_ID_ATTRIBUTE))

	prompt.Style = Enum.ProximityPromptStyle.Custom
	prompt.RequiresLineOfSight = false
	prompt.MaxActivationDistance = ShipData.PROMPT_DISTANCE -- sobrescreve o valor do Studio
	-- Sem isso a Roblox mostra um prompt por tecla de cada vez, escolhendo o mais
	-- alinhado com o centro da tela: os da nave só apareciam mirando neles
	prompt.Exclusivity = Enum.ProximityPromptExclusivity.AlwaysShow
	prompt.ObjectText = if def then def.displayName else model.Name
	if isEnter then
		prompt.ActionText = if self._isPlanet then "DECOLAR" else "PILOTAR"
	else
		prompt.ActionText = if self._stow then "GUARDAR NAVE" else "AJUSTES"
		-- Tecla própria: com os dois prompts visíveis ao mesmo tempo, dividir o E
		-- deixaria o resultado dependendo de qual está mais perto
		prompt.KeyboardKeyCode = Enum.KeyCode.F
		prompt.GamepadKeyCode = Enum.KeyCode.ButtonY
	end

	local billboard = self:_buildBillboard(prompt, if isEnter then ICON_SEAT else ICON_WRENCH, if isEnter then GLYPH_SEAT else GLYPH_WRENCH)

	local entry = {
		model = model,
		prompt = prompt,
		billboard = billboard,
		conns = {},
	}
	self._entries[prompt] = entry

	table.insert(entry.conns, prompt.PromptShown:Connect(function()
		billboard.Enabled = true
	end))
	table.insert(entry.conns, prompt.PromptHidden:Connect(function()
		billboard.Enabled = false
	end))
	table.insert(entry.conns, prompt.AncestryChanged:Connect(function()
		if not prompt:IsDescendantOf(workspace) then
			self:_unbindPrompt(prompt)
		end
	end))

	-- O PlaneScript liga/desliga os prompts no servidor ao entrar e sair do
	-- assento, e isso replica pra todo mundo. Sem reafirmar aqui, sair da nave
	-- faria o prompt dela aparecer pros outros jogadores.
	table.insert(entry.conns, prompt:GetPropertyChangedSignal("Enabled"):Connect(function()
		self:_applyEnabled(entry)
	end))

	self:_applyEnabled(entry)
end

function ShipPrompts:_unbindPrompt(prompt: ProximityPrompt)
	local entry = self._entries[prompt]
	if not entry then
		return
	end
	self._entries[prompt] = nil
	for _, conn in entry.conns do
		conn:Disconnect()
	end
	entry.billboard:Destroy()
end

function ShipPrompts:_buildBillboard(prompt: ProximityPrompt, iconId: string, glyphText: string): BillboardGui
	local billboard = Instance.new("BillboardGui")
	billboard.Name = "Prompt_" .. prompt.Name
	billboard.Adornee = prompt.Parent :: Instance
	billboard.AlwaysOnTop = true
	billboard.Size = UDim2.fromOffset(BILLBOARD_SIZE, BILLBOARD_SIZE)
	billboard.StudsOffsetWorldSpace = Vector3.new(0, 2, 0)
	billboard.MaxDistance = BILLBOARD_MAX_DISTANCE
	billboard.LightInfluence = 0
	billboard.ResetOnSpawn = false
	billboard.Active = true -- recebe toque no mobile
	billboard.Enabled = false
	billboard.Parent = self._folder

	-- Placa do ícone (clicável: no mobile não há tecla)
	local plate = Instance.new("ImageButton")
	plate.Name = "Plate"
	plate.AnchorPoint = Vector2.new(0.5, 0)
	plate.Position = UDim2.fromScale(0.5, 0)
	plate.Size = UDim2.fromOffset(64, 64)
	plate.BackgroundColor3 = C.plate
	plate.BackgroundTransparency = 0.2
	plate.AutoButtonColor = false
	plate.Image = ""
	plate.Parent = billboard
	UIStyle.corner(plate, 14)
	local plateStroke = UIStyle.stroke(plate, 0.35, 1.5)
	plateStroke.Color = C.prompt

	if iconId ~= "" then
		local icon = Instance.new("ImageLabel")
		icon.Name = "Icon"
		icon.AnchorPoint = Vector2.new(0.5, 0.5)
		icon.Position = UDim2.fromScale(0.5, 0.5)
		icon.Size = UDim2.fromScale(0.6, 0.6)
		icon.BackgroundTransparency = 1
		icon.Image = iconId
		icon.ImageColor3 = C.prompt
		icon.ScaleType = Enum.ScaleType.Fit
		icon.Parent = plate
	else
		local glyph = UIStyle.label(plate, "Glyph", 30, UIStyle.FONT_BOLD, 0)
		glyph.Size = UDim2.fromScale(1, 1)
		glyph.TextXAlignment = Enum.TextXAlignment.Center
		glyph.TextColor3 = C.prompt
		glyph.Text = glyphText
	end

	-- Tecla (PC/console) — some no mobile, onde o toque é na própria placa
	if not UIStyle.IS_MOBILE then
		local key = Instance.new("TextLabel")
		key.Name = "Key"
		key.AnchorPoint = Vector2.new(1, 1)
		key.Position = UDim2.new(1, 6, 1, 6)
		key.Size = UDim2.fromOffset(22, 22)
		key.BackgroundColor3 = C.surface
		key.TextColor3 = C.plate
		key.FontFace = UIStyle.FONT_BOLD
		key.TextSize = 13
		key.Text = string.sub(prompt.KeyboardKeyCode.Name, 1, 1)
		key.Parent = plate
		UIStyle.corner(key, 6)
	end

	local action = UIStyle.label(billboard, "Action", 15, UIStyle.FONT_BOLD, T.textPrimary)
	action.AnchorPoint = Vector2.new(0.5, 0)
	action.Position = UDim2.new(0.5, 0, 0, 70)
	action.Size = UDim2.new(1, 0, 0, 18)
	action.TextXAlignment = Enum.TextXAlignment.Center
	action.Text = UIStyle.spaced(prompt.ActionText)
	local actionStroke = Instance.new("UIStroke")
	actionStroke.Color = C.plate
	actionStroke.Thickness = 2
	actionStroke.Transparency = 0.3
	actionStroke.Parent = action

	local object = UIStyle.label(billboard, "Object", 12, UIStyle.FONT_MEDIUM, T.textSecondary)
	object.AnchorPoint = Vector2.new(0.5, 0)
	object.Position = UDim2.new(0.5, 0, 0, 90)
	object.Size = UDim2.new(1, 0, 0, 14)
	object.TextXAlignment = Enum.TextXAlignment.Center
	object.Text = prompt.ObjectText

	prompt:GetPropertyChangedSignal("ActionText"):Connect(function()
		action.Text = UIStyle.spaced(prompt.ActionText)
	end)
	prompt:GetPropertyChangedSignal("ObjectText"):Connect(function()
		object.Text = prompt.ObjectText
	end)

	plate.Activated:Connect(function()
		if prompt.Enabled then
			prompt:InputHoldBegin()
			prompt:InputHoldEnd()
		end
	end)

	return billboard
end

-- ═══════════════════════════════════════════════════════════
-- Habilitação
-- ═══════════════════════════════════════════════════════════

--- Só a nave do dono, e nunca com o jogador sentado (prompt no voo é bug).
function ShipPrompts:_applyEnabled(entry)
	local enabled = isOwnShip(entry.model) and not self._seated
	if entry.prompt.Enabled ~= enabled then
		entry.prompt.Enabled = enabled
	end
	if not enabled then
		entry.billboard.Enabled = false
	end
end

--- Nave dentro da HangarZone: o MenuPrompt vira GUARDAR NAVE.
function ShipPrompts:SetStowMode(stow: boolean)
	if self._stow == stow then
		return
	end
	self._stow = stow
	for _, entry in self._entries do
		if entry.prompt.Name == ShipData.PARTS.menuPrompt then
			entry.prompt.ActionText = if stow then "GUARDAR NAVE" else "AJUSTES"
		end
	end
end

function ShipPrompts:IsStowMode(): boolean
	return self._stow == true
end

function ShipPrompts:SetSeated(seated: boolean)
	if self._seated == seated then
		return
	end
	self._seated = seated
	self:Refresh()
end

function ShipPrompts:Refresh()
	for _, entry in self._entries do
		self:_applyEnabled(entry)
	end
	self:_refreshHangar()
end

-- ═══════════════════════════════════════════════════════════
-- Hangar: terminal (HANGAR) e pads (LANÇAR)
-- ═══════════════════════════════════════════════════════════

--- Usa o ProximityPrompt feito no Studio, ou cria um local com as mesmas
--- propriedades de §9.1. Local não replica: não há conflito entre jogadores.
local function ensurePrompt(parent: BasePart, name: string): ProximityPrompt
	local existing = parent:FindFirstChild(name)
	if existing and existing:IsA("ProximityPrompt") then
		return existing
	end

	local prompt = Instance.new("ProximityPrompt")
	prompt.Name = name
	prompt.MaxActivationDistance = ShipData.PROMPT_DISTANCE
	prompt.HoldDuration = 0
	prompt.KeyboardKeyCode = Enum.KeyCode.E
	prompt.GamepadKeyCode = Enum.KeyCode.ButtonX
	prompt.Exclusivity = Enum.ProximityPromptExclusivity.AlwaysShow
	prompt.Enabled = false
	prompt.Parent = parent
	return prompt
end

function ShipPrompts:_bindHangarPrompt(parent: BasePart, name: string, action: string, glyph: string)
	local prompt = ensurePrompt(parent, name)
	prompt.MaxActivationDistance = ShipData.PROMPT_DISTANCE -- vale também pro feito no Studio
	prompt.Exclusivity = Enum.ProximityPromptExclusivity.AlwaysShow
	prompt.Style = Enum.ProximityPromptStyle.Custom
	prompt.RequiresLineOfSight = false
	prompt.ActionText = action

	local billboard = self:_buildBillboard(prompt, ICON_HANGAR, glyph)
	prompt.PromptShown:Connect(function()
		billboard.Enabled = true
	end)
	prompt.PromptHidden:Connect(function()
		billboard.Enabled = false
	end)

	return { prompt = prompt, billboard = billboard, part = parent }
end

--- Tipo do Place vindo do SERVIDOR. Deduzir no client pelos objetos da cena
--- falha com StreamingEnabled (o LandingPad pode não ter chegado) e aí client
--- e servidor discordam: o client mostra LANÇAR e o servidor recusa.
function ShipPrompts:SetPlanet(isPlanet: boolean)
	if self._isPlanet == isPlanet then
		return
	end
	self._isPlanet = isPlanet
	for _, entry in self._entries do
		if entry.prompt.Name == ShipData.PARTS.enterPrompt then
			entry.prompt.ActionText = if isPlanet then "DECOLAR" else "PILOTAR"
		end
	end
	self:_refreshHangar()
end

--- Chamado pelo controller quando o servidor confirma que é Place de espaço.
--- Idempotente. Place sem terminal/pads não cria nada.
function ShipPrompts:SetupHangar()
	if self._hangarReady or self._isPlanet then
		return
	end
	self._hangarReady = true

	local terminal = PlaceConfig.GetHangarTerminal()
	if terminal then
		self._terminal = self:_bindHangarPrompt(terminal, PlaceConfig.TERMINAL_PROMPT, "HANGAR", GLYPH_HANGAR)
		self._terminal.prompt.ObjectText = "Terminal"
	end

	self._pads = {}
	for _, pad in PlaceConfig.GetHangarPads() do
		local entry = self:_bindHangarPrompt(pad, PlaceConfig.LAUNCH_PROMPT, "LANÇAR", GLYPH_SEAT)
		table.insert(self._pads, entry)
		pad:GetAttributeChangedSignal(PlaceConfig.PAD_OCCUPIED_ATTRIBUTE):Connect(function()
			self:_refreshHangar()
		end)
	end

	self:_refreshHangar()
end

--- shipName = nave equipada (aparece embaixo do LANÇAR). nil = perfil não carregou.
function ShipPrompts:SetEquippedName(shipName: string?)
	self._equippedName = shipName
	self:_refreshHangar()
end

function ShipPrompts:_refreshHangar()
	local function apply(entry, enabled: boolean)
		entry.prompt.Enabled = enabled
		if not enabled then
			entry.billboard.Enabled = false
		end
	end

	if self._terminal then
		apply(self._terminal, not self._seated and not self._isPlanet)
	end

	for _, entry in self._pads or {} do
		local occupied = entry.part:GetAttribute(PlaceConfig.PAD_OCCUPIED_ATTRIBUTE) ~= nil
		entry.prompt.ObjectText = self._equippedName or ""
		apply(entry, not self._seated and not self._isPlanet and not occupied and self._equippedName ~= nil)
	end
end

--- Pad de um prompt LANÇAR, ou nil.
function ShipPrompts:GetPadForPrompt(prompt: ProximityPrompt): BasePart?
	for _, entry in self._pads or {} do
		if entry.prompt == prompt then
			return entry.part
		end
	end
	return nil
end

function ShipPrompts:IsTerminalPrompt(prompt: ProximityPrompt): boolean
	return self._terminal ~= nil and self._terminal.prompt == prompt
end

return ShipPrompts
