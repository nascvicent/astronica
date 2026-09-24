--[[
	CombatHUD
	Tudo de combate que o piloto vê:

	  - Holograma de CASCO e ARMAS, logo abaixo do de velocidade (ShipHudModule):
	    mesma placa 3D presa à câmera, mesmo plano e inclinação, branco sobre
	    placa escura como o inventário.
	    É instrumento de voo, então mora junto com a velocidade
	  - Marcador de acerto em volta da mira (branco; vermelho no abate)
	  - Flash vermelho ao levar dano
	  - Alerta de casco baixo: a tela pulsa em vermelho algumas vezes e para
	  - Mensagem de abate / destruição (aparece mesmo fora da nave)

	Os quatro últimos são 2D de propósito: são aviso de tela, não painel.
	Quem decide os números é o CombatController; aqui só desenha.

	Local: src/client/UI/CombatHUD.luau
]]

local Players = game:GetService("Players")
local TweenService = game:GetService("TweenService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local UIStyle = require(script.Parent.UIStyle)
local Holo = require(script.Parent.Holo)
local SpeedHUD = require(ReplicatedStorage.Shared.ShipHudModule)

local player = Players.LocalPlayer
local playerGui = player:WaitForChild("PlayerGui")

local C = UIStyle.C
local spaced = UIStyle.spaced
local HOLO = Holo.THEME
local HT = Holo.T

-- ═══════════════════════════════════════════════════════════
-- Holograma (mesmo plano do SpeedHUD, cores do inventário)
-- ═══════════════════════════════════════════════════════════

-- Em studs na escala do PC (o Holo aumenta no celular, junto com o SpeedHUD)
local HOLO_SIZE = Vector2.new(0.9, 0.36)
local HOLO_GAP = 0.03 -- studs entre a placa de velocidade e esta

-- Em pixels da SurfaceGui (512 por stud de HOLO_SIZE)
local TEXT_SIZE = 34
local ROW_TEXT_HEIGHT = 40
local BAR_HEIGHT = 14
local BAR_OFFSET = 46 -- do topo da linha até a barra
local ROW_SPACING = 86

local HULL_LOW = 0.3 -- abaixo disso o casco fica vermelho

-- ═══════════════════════════════════════════════════════════
-- Tela
-- ═══════════════════════════════════════════════════════════

local HIT_SIZE = 10 -- comprimento de cada traço do marcador
local HIT_GAP = 14 -- distância do centro da mira
local HIT_FADE = TweenInfo.new(0.18, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
local DAMAGE_FADE = TweenInfo.new(0.35, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)

-- Alerta de casco baixo: poucos pulsos e para, pra avisar sem irritar
local WARNING_PULSE_IN = TweenInfo.new(0.18, Enum.EasingStyle.Sine, Enum.EasingDirection.Out)
local WARNING_PULSE_OUT = TweenInfo.new(0.32, Enum.EasingStyle.Sine, Enum.EasingDirection.In)
local WARNING_PEAK = 0.72 -- transparência no auge do pulso

local CombatHUD = {}
CombatHUD.__index = CombatHUD

function CombatHUD.new()
	local self = setmetatable({}, CombatHUD)
	self:_buildHolo()
	self:_buildScreen()
	return self
end

-- ═══════════════════════════════════════════════════════════
-- Holograma: construção
-- ═══════════════════════════════════════════════════════════

--- Uma linha: título à esquerda, valor à direita, barra embaixo.
local function holoRow(parent: Instance, y: number, title: string): (TextLabel, Frame)
	local titleLabel = Holo.Label(parent, title .. "Title", TEXT_SIZE, Holo.FONT_TITLE, HT.title)
	titleLabel.Position = UDim2.fromOffset(0, y)
	titleLabel.Size = UDim2.new(0.38, 0, 0, ROW_TEXT_HEIGHT)
	titleLabel.Text = title

	-- Valor encolhe pra caber ("SUPERAQUECIDAS")
	local value = Holo.Label(parent, title .. "Value", TEXT_SIZE, Holo.FONT_VALUE, HT.value, true)
	value.Position = UDim2.new(0.4, 0, 0, y)
	value.Size = UDim2.new(0.6, 0, 0, ROW_TEXT_HEIGHT)
	value.TextXAlignment = Enum.TextXAlignment.Right

	return value, Holo.Bar(parent, title, y + BAR_OFFSET, BAR_HEIGHT)
end

function CombatHUD:_buildHolo()
	-- Logo abaixo da placa de velocidade, no mesmo plano e inclinação
	local holo
	holo = Holo.new("CombatHUD", HOLO_SIZE, function(cam)
		local offset = -(SpeedHUD.PART_SIZE.Y / 2 + HOLO_GAP * Holo.SCALE + holo.size.Y / 2)
		return SpeedHUD.GetScreenCFrame(cam, offset)
	end)
	self._holo = holo

	local container, stroke = holo:Plate()
	self._holoStroke = stroke
	local padding = Instance.new("UIPadding")
	padding.PaddingTop = UDim.new(0.07, 0)
	padding.PaddingBottom = UDim.new(0.07, 0)
	padding.PaddingLeft = UDim.new(0.06, 0)
	padding.PaddingRight = UDim.new(0.06, 0)
	padding.Parent = container

	self._hullValue, self._hullFill = holoRow(container, 0, "CASCO")
	self._heatValue, self._heatFill = holoRow(container, ROW_SPACING, "ARMAS")
	self._heatFill.Size = UDim2.fromScale(0, 1)
end

-- ═══════════════════════════════════════════════════════════
-- Tela: construção
-- ═══════════════════════════════════════════════════════════

function CombatHUD:_buildScreen()
	local gui = Instance.new("ScreenGui")
	gui.Name = "CombatHUD"
	gui.ResetOnSpawn = false
	gui.IgnoreGuiInset = true
	gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
	gui.DisplayOrder = 6
	gui.Parent = playerGui
	self._gui = gui

	local function overlay(name: string): Frame
		local frame = Instance.new("Frame")
		frame.Name = name
		frame.Size = UDim2.fromScale(1, 1)
		frame.BackgroundColor3 = C.negative
		frame.BackgroundTransparency = 1
		frame.BorderSizePixel = 0
		frame.ZIndex = 0
		frame.Parent = gui
		return frame
	end

	-- Flash de dano e alerta de casco baixo: camadas separadas, um não corta o outro
	self._flash = overlay("DamageFlash")
	self._warning = overlay("LowHullWarning")

	-- Marcador de acerto: quatro traços diagonais em volta do centro
	local hit = Instance.new("Frame")
	hit.Name = "HitMarker"
	hit.AnchorPoint = Vector2.new(0.5, 0.5)
	hit.Position = UDim2.fromScale(0.5, 0.5)
	hit.Size = UDim2.fromOffset((HIT_GAP + HIT_SIZE) * 2, (HIT_GAP + HIT_SIZE) * 2)
	hit.BackgroundTransparency = 1
	hit.Parent = gui
	self._hitLines = {}
	for i = 0, 3 do
		local angle = math.rad(45 + 90 * i)
		local distance = HIT_GAP + HIT_SIZE / 2
		local line = Instance.new("Frame")
		line.AnchorPoint = Vector2.new(0.5, 0.5)
		line.Position = UDim2.new(0.5, math.cos(angle) * distance, 0.5, math.sin(angle) * distance)
		line.Size = UDim2.fromOffset(HIT_SIZE, 2)
		line.Rotation = math.deg(angle)
		line.BackgroundColor3 = C.text
		line.BackgroundTransparency = 1
		line.BorderSizePixel = 0
		line.Parent = hit
		table.insert(self._hitLines, line)
	end

	-- Mensagem de abate / destruição
	local message = UIStyle.label(gui, "Message", 18, UIStyle.FONT_BOLD, 0)
	message.AnchorPoint = Vector2.new(0.5, 0.5)
	message.Position = UDim2.fromScale(0.5, 0.3)
	message.Size = UDim2.new(1, -32, 0, 28)
	message.TextXAlignment = Enum.TextXAlignment.Center
	message.TextWrapped = true
	message.Visible = false
	local messageStroke = Instance.new("UIStroke")
	messageStroke.Color = C.plate
	messageStroke.Thickness = 2
	messageStroke.Transparency = 0.3
	messageStroke.Parent = message
	self._message = message
end

-- ═══════════════════════════════════════════════════════════
-- Holograma: estado
-- ═══════════════════════════════════════════════════════════

--- Só pilotando.
function CombatHUD:SetVisible(visible: boolean)
	self._holo:SetVisible(visible)
end

--- Pinta um texto do holograma: cor (branco ou com significado) + nível.
local function paint(label: TextLabel, color: Color3, transparency: number)
	label.TextColor3 = color
	label.TextTransparency = transparency
end

function CombatHUD:SetHull(current: number, max: number)
	local alpha = if max > 0 then math.clamp(current / max, 0, 1) else 0
	local low = alpha <= HULL_LOW
	self._hullFill.Size = UDim2.fromScale(alpha, 1)
	self._hullFill.BackgroundColor3 = if low then HOLO.danger else HOLO.white
	-- Casco baixo: a borda da placa acende em vermelho
	self._holoStroke.Color = if low then HOLO.danger else HOLO.white
	self._holoStroke.Transparency = if low then HT.lineHover else HT.line
	-- Dano por tiro é fracionado: arredonda pra cima (casco 0 só quando morre)
	self._hullValue.Text = string.format("%d / %s", math.ceil(math.max(current, 0)), UIStyle.formatNumber(max))
	paint(self._hullValue, if low then HOLO.danger else HOLO.white, HT.value)
end

--[[
	status:
	  nil          armas prontas, mostra o calor
	  "overheated" travadas até esfriar (pisca)
	  "hangar"     dentro do hangar: não atiram
	  "safe"       atiram (mineração), mas não ferem naves
	  "offline"    nave sem armas
]]
function CombatHUD:SetWeapons(heat: number, status: string?)
	self._heatFill.Size = UDim2.fromScale(math.clamp(heat, 0, 1), 1)

	if status == "overheated" then
		local blink = math.floor(os.clock() * 6) % 2 == 0
		self._heatFill.BackgroundColor3 = HOLO.danger
		self._heatFill.BackgroundTransparency = if blink then 0 else 0.5
		self._heatValue.Text = "SUPERAQUECIDAS"
		paint(self._heatValue, HOLO.danger, HT.value)
		return
	end

	-- Branco; só perto do limite puxa pro vermelho
	self._heatFill.BackgroundColor3 = HOLO.white:Lerp(HOLO.danger, math.clamp((heat - 0.7) / 0.3, 0, 1))
	self._heatFill.BackgroundTransparency = 0

	if status == "hangar" then
		self._heatValue.Text = "TRAVADAS"
		paint(self._heatValue, HOLO.white, HT.title)
	elseif status == "safe" then
		self._heatValue.Text = "ZONA SEGURA"
		paint(self._heatValue, HOLO.safe, HT.value)
	elseif status == "offline" then
		self._heatValue.Text = "SEM ARMAS"
		paint(self._heatValue, HOLO.white, HT.title)
	else
		self._heatValue.Text = string.format("%d%%", math.floor(heat * 100 + 0.5))
		paint(self._heatValue, HOLO.white, HT.value)
	end
end

-- ═══════════════════════════════════════════════════════════
-- Tela: feedback
-- ═══════════════════════════════════════════════════════════

function CombatHUD:ShowHit(destroyed: boolean)
	local color = if destroyed then C.negative else C.text
	for _, line in self._hitLines do
		line.BackgroundColor3 = color
		line.BackgroundTransparency = 0
		TweenService:Create(line, HIT_FADE, { BackgroundTransparency = 1 }):Play()
	end
end

function CombatHUD:ShowDamage(intensity: number)
	self._flash.BackgroundTransparency = 1 - math.clamp(intensity, 0.08, 0.35)
	TweenService:Create(self._flash, DAMAGE_FADE, { BackgroundTransparency = 1 }):Play()
end

--- Pisca a tela em vermelho `pulses` vezes. Um alerta novo substitui o que
--- estiver em andamento.
function CombatHUD:PulseWarning(pulses: number)
	local token = {}
	self._warningToken = token
	local warning = self._warning

	task.spawn(function()
		for _ = 1, pulses do
			if self._warningToken ~= token then
				return
			end
			local up = TweenService:Create(warning, WARNING_PULSE_IN, { BackgroundTransparency = WARNING_PEAK })
			up:Play()
			up.Completed:Wait()
			local down = TweenService:Create(warning, WARNING_PULSE_OUT, { BackgroundTransparency = 1 })
			down:Play()
			down.Completed:Wait()
		end
	end)
end

function CombatHUD:ShowMessage(text: string, color: Color3?, duration: number?)
	local message = self._message
	message.Text = spaced(text)
	message.TextColor3 = color or C.text
	message.Visible = true

	local token = {}
	self._messageToken = token
	task.delay(duration or 3, function()
		if self._messageToken == token then
			message.Visible = false
		end
	end)
end

return CombatHUD
