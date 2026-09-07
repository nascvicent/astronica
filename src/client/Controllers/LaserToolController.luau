--[[
	LaserToolController
	Input + visual da pistola laser no client.
	Toda decisão de dano é do servidor — aqui é só mira, feixe e feedback.

	Local: src/client/Controllers/LaserToolController.luau
]]

local Knit = require(game:GetService("ReplicatedStorage").Packages.Knit)
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")

local LaserConfig = require(ReplicatedStorage.Shared.LaserConfig)
local LaserHUD = require(script.Parent.Parent.UI.LaserHUD)

local UserGameSettings = UserSettings():GetService("UserGameSettings")

local player = Players.LocalPlayer

local IS_MOBILE = UserInputService.TouchEnabled and not UserInputService.MouseEnabled

-- ═══════════════════════════════════════════════════════════
-- Câmera de ombro (aim mode)
-- ═══════════════════════════════════════════════════════════

-- Offset da câmera em relação ao personagem: X positivo = ombro direito.
local AIM_OFFSET = Vector3.new(2.2, 0.5, 0)

-- FOV enquanto mira / enquanto atira. O default do Roblox é 70; fechar um
-- pouco aproxima o alvo e dá o peso de arma apontada.
local AIM_FOV = 64
local FIRING_FOV = 60
local FOV_LERP = 6
local OFFSET_LERP = 10

-- Tremor da câmera enquanto o feixe está ligado (studs)
local SHAKE_AMPLITUDE = 0.05

-- Transição de saída, quando desequipa
local EXIT_TWEEN = TweenInfo.new(0.25, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)

local LaserToolController = Knit.CreateController({
	Name = "LaserToolController",
})

-- ═══════════════════════════════════════════════════════════
-- Setup
-- ═══════════════════════════════════════════════════════════

function LaserToolController:KnitInit()
	self._mode = LaserConfig.DEFAULT_MODE
	self._firing = false
	self._accum = 0
	self._boundTools = setmetatable({}, { __mode = "k" })
	self._activeTool = nil

	self._aiming = false
	self._aimLockSuspended = false
	self._camOffset = Vector3.zero
	self._fov = nil

	self._crosshair = LaserHUD.new()
end

function LaserToolController:KnitStart()
	self._mining = Knit.GetService("MiningService")

	self:_buildBeam()
	self._crosshair:SetColor(LaserConfig.GetMode(self._mode).Color)

	-- No mobile o Tool.Activated também dispara ao tocar a tela, mas isso
	-- conflita com girar a câmera. O botão dedicado é o caminho de verdade.
	self._crosshair:SetFireHandlers(function()
		self:_startFiring()
	end, function()
		self:_stopFiring()
	end)

	self._mining.NodeDepleted:Connect(function(_node, itemId, amount)
		print(string.format("[Laser] +%d %s", amount, itemId))
		self._crosshair:Hit()
		self:_stopFiring()
	end)

	self._mining.MiningFailed:Connect(function(reason)
		warn("[Laser] " .. tostring(reason))
	end)

	-- Observa tools que chegam no backpack e no personagem
	local function watch(container: Instance)
		for _, child in container:GetChildren() do
			self:_bindTool(child)
		end
		container.ChildAdded:Connect(function(child)
			self:_bindTool(child)
		end)
	end

	-- O Backpack é destruído e recriado a cada respawn, então não basta observar
	-- a instância inicial: sem isso a arma para de funcionar depois da 1ª morte.
	watch(player:WaitForChild("Backpack"))

	player.ChildAdded:Connect(function(child)
		if child:IsA("Backpack") then
			watch(child)
		end
	end)

	local function onCharacter(character: Model)
		self:_stopFiring()
		self:_exitAimMode()
		watch(character)

		-- Sem isso o mouse continua travado no centro durante a tela de morte
		local humanoid = character:WaitForChild("Humanoid", 5)
		if humanoid then
			humanoid.Died:Connect(function()
				self:_onUnequipped()
			end)
		end
	end

	if player.Character then
		onCharacter(player.Character)
	end
	player.CharacterAdded:Connect(onCharacter)

	-- Troca de modo (PC). No mobile, chame :SetMode() por um botão da HUD.
	UserInputService.InputBegan:Connect(function(input, gpe)
		if gpe then return end
		if input.KeyCode == Enum.KeyCode.R and self._activeTool then
			self:SetMode(if self._mode == "Mining" then "Combat" else "Mining")
		end
	end)
end

-- ═══════════════════════════════════════════════════════════
-- Beam (feixe visual)
-- ═══════════════════════════════════════════════════════════

function LaserToolController:_buildBeam()
	self._folder = Instance.new("Folder")
	self._folder.Name = "LaserVFX"
	self._folder.Parent = workspace.CurrentCamera

	-- Part invisível que marca o ponto de impacto
	local endPart = Instance.new("Part")
	endPart.Name = "LaserEnd"
	endPart.Size = Vector3.new(0.1, 0.1, 0.1)
	endPart.Anchored = true
	endPart.CanCollide = false
	endPart.CanQuery = false
	endPart.CanTouch = false
	endPart.Transparency = 1
	endPart.Parent = self._folder
	self._endPart = endPart

	self._endAttachment = Instance.new("Attachment")
	self._endAttachment.Parent = endPart

	local beam = Instance.new("Beam")
	beam.Name = "LaserBeam"
	beam.Attachment1 = self._endAttachment
	beam.FaceCamera = true
	beam.LightEmission = 1
	beam.LightInfluence = 0
	beam.Transparency = NumberSequence.new(0.1)
	beam.Enabled = false
	beam.Parent = endPart
	self._beam = beam

	-- Faíscas no ponto de impacto
	local sparks = Instance.new("ParticleEmitter")
	sparks.Name = "ImpactSparks"
	sparks.Rate = 0
	sparks.Speed = NumberRange.new(4, 9)
	sparks.Lifetime = NumberRange.new(0.15, 0.35)
	sparks.SpreadAngle = Vector2.new(180, 180)
	sparks.Size = NumberSequence.new(0.18, 0)
	sparks.LightEmission = 1
	sparks.Parent = endPart
	self._sparks = sparks

	self:_applyModeVisuals()
end

function LaserToolController:_applyModeVisuals()
	local mode = LaserConfig.GetMode(self._mode)
	self._beam.Color = ColorSequence.new(mode.Color)
	self._beam.Width0 = mode.BeamWidth
	self._beam.Width1 = mode.BeamWidth * 0.5
	self._sparks.Color = ColorSequence.new(mode.Color)
end

-- ═══════════════════════════════════════════════════════════
-- Tool binding
-- ═══════════════════════════════════════════════════════════

function LaserToolController:_bindTool(tool: Instance)
	if not tool:IsA("Tool") then
		return
	end

	if not tool:GetAttribute(LaserConfig.TOOL_ATTRIBUTE) then
		warn(string.format(
			"[Laser] Tool '%s' ignorada — falta o atributo %s = true",
			tool.Name,
			LaserConfig.TOOL_ATTRIBUTE
		))
		return
	end

	-- A Tool reaparece em Backpack/Character a cada equip/unequip: sem esse guard
	-- os eventos seriam conectados de novo e o disparo aconteceria em duplicidade.
	if self._boundTools[tool] then
		return
	end
	self._boundTools[tool] = true

	tool.Equipped:Connect(function()
		self:_onEquipped(tool)
	end)

	tool.Unequipped:Connect(function()
		self:_onUnequipped()
	end)

	tool.Activated:Connect(function()
		self:_startFiring()
	end)

	tool.Deactivated:Connect(function()
		self:_stopFiring()
	end)

	tool.AncestryChanged:Connect(function()
		if not tool:IsDescendantOf(game) and self._activeTool == tool then
			self:_onUnequipped()
		end
	end)
end

function LaserToolController:_onEquipped(tool: Tool)
	self._activeTool = tool

	local handle = tool:FindFirstChild("Handle")
	local muzzle = LaserConfig.FindMuzzle(tool)

	if muzzle then
		self._beam.Attachment0 = muzzle
	else
		warn("[Laser] Tool sem Attachment 'Muzzle' dentro de uma BasePart — feixe vai sair do centro do Handle")
		if handle then
			local fallback = handle:FindFirstChild("MuzzleFallback")
			if not fallback then
				fallback = Instance.new("Attachment")
				fallback.Name = "MuzzleFallback"
				fallback.Parent = handle
			end
			self._beam.Attachment0 = fallback
		end
	end

	self:_enterAimMode()

	if self._renderConn then
		self._renderConn:Disconnect()
	end

	self._renderConn = RunService.RenderStepped:Connect(function(dt)
		self:_onRender(dt)
	end)
end

function LaserToolController:_onUnequipped()
	self:_stopFiring()
	self:_exitAimMode()
	self._activeTool = nil

	if self._renderConn then
		self._renderConn:Disconnect()
		self._renderConn = nil
	end
end

-- ═══════════════════════════════════════════════════════════
-- Aim mode (câmera de ombro + mouse travado)
-- ═══════════════════════════════════════════════════════════

function LaserToolController:_enterAimMode()
	local camera = workspace.CurrentCamera
	local character = player.Character
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")

	self._humanoid = humanoid
	self._camOffset = if humanoid then humanoid.CameraOffset else Vector3.zero
	self._fov = camera.FieldOfView
	self._prevFov = camera.FieldOfView

	-- Faz o personagem girar junto com a câmera, como no shift lock. Sem isso
	-- ele continua virando só na direção do movimento e a arma aponta pro lado.
	if not IS_MOBILE then
		-- Só a mira fica na tela: o cursor do sistema sairia por cima dela
		self._prevMouseIcon = UserInputService.MouseIconEnabled
		UserInputService.MouseIconEnabled = false

		self._prevRotationType = UserGameSettings.RotationType

		local ok = pcall(function()
			UserGameSettings.RotationType = Enum.RotationType.CameraRelative
		end)

		if not ok then
			warn("[Laser] Não foi possível travar a rotação na câmera")
			self._prevRotationType = nil
		end
	end

	self._aiming = true
	self._crosshair:SetVisible(true)
end

function LaserToolController:_exitAimMode()
	if not self._aiming then
		return
	end
	self._aiming = false

	self._crosshair:SetVisible(false)

	if not IS_MOBILE then
		UserInputService.MouseBehavior = Enum.MouseBehavior.Default

		if self._prevMouseIcon ~= nil then
			UserInputService.MouseIconEnabled = self._prevMouseIcon
			self._prevMouseIcon = nil
		end

		if self._prevRotationType then
			pcall(function()
				UserGameSettings.RotationType = self._prevRotationType
			end)
			self._prevRotationType = nil
		end
	end

	-- O render loop morre junto com o unequip, então a volta ao normal é tween.
	local camera = workspace.CurrentCamera
	if self._prevFov then
		TweenService:Create(camera, EXIT_TWEEN, { FieldOfView = self._prevFov }):Play()
		self._prevFov = nil
	end

	local humanoid = self._humanoid
	if humanoid and humanoid.Parent then
		TweenService:Create(humanoid, EXIT_TWEEN, { CameraOffset = Vector3.zero }):Play()
	end
	self._humanoid = nil
end

--- Atualiza ombro, FOV e tremor. Roda todo frame enquanto a arma está equipada,
--- atirando ou não.
function LaserToolController:_updateCamera(dt: number)
	local camera = workspace.CurrentCamera

	-- O PlayerModule reseta o MouseBehavior em algumas transições (respawn,
	-- primeira pessoa), então reafirma em vez de setar só uma vez.
	if
		not IS_MOBILE
		and not self._aimLockSuspended
		and UserInputService.MouseBehavior ~= Enum.MouseBehavior.LockCenter
	then
		UserInputService.MouseBehavior = Enum.MouseBehavior.LockCenter
	end

	local humanoid = self._humanoid
	if not humanoid or not humanoid.Parent then
		humanoid = player.Character and player.Character:FindFirstChildOfClass("Humanoid")
		self._humanoid = humanoid
	end

	local target = AIM_OFFSET
	if self._firing then
		target += Vector3.new(
			(math.random() - 0.5) * SHAKE_AMPLITUDE,
			(math.random() - 0.5) * SHAKE_AMPLITUDE,
			0
		)
	end

	self._camOffset = self._camOffset:Lerp(target, math.min(dt * OFFSET_LERP, 1))
	if humanoid then
		humanoid.CameraOffset = self._camOffset
	end

	local targetFov = if self._firing then FIRING_FOV else AIM_FOV
	self._fov += (targetFov - self._fov) * math.min(dt * FOV_LERP, 1)
	camera.FieldOfView = self._fov
end

-- ═══════════════════════════════════════════════════════════
-- Mira e disparo
-- ═══════════════════════════════════════════════════════════

function LaserToolController:_getAimPoint(range: number): Vector3
	local camera = workspace.CurrentCamera

	-- Com a mira travada no centro, o ponto de partida do raio é sempre o
	-- centro do viewport — que é exatamente onde o crosshair é desenhado.
	local screen = if IS_MOBILE or self._aiming
		then camera.ViewportSize / 2
		else UserInputService:GetMouseLocation()

	local ray = camera:ViewportPointToRay(screen.X, screen.Y)

	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	params.FilterDescendantsInstances = { player.Character, self._folder }
	params.IgnoreWater = true

	local result = workspace:Raycast(ray.Origin, ray.Direction * (range * 2), params)
	return if result then result.Position else ray.Origin + ray.Direction * (range * 2)
end

function LaserToolController:_startFiring()
	if self._firing or not self._activeTool then
		return
	end
	self._firing = true
	self._accum = LaserConfig.TICK_RATE -- primeiro tick imediato
	self._beam.Enabled = true
	self._sparks.Rate = 25
	self._crosshair:SetFiring(true)
end

function LaserToolController:_stopFiring()
	if not self._firing then
		return
	end
	self._firing = false
	self._beam.Enabled = false
	self._sparks.Rate = 0
	self._crosshair:SetFiring(false)
end

function LaserToolController:_onRender(dt: number)
	-- Câmera e mira acompanham a arma equipada, atirando ou não
	self:_updateCamera(dt)
	self._crosshair:Update(dt)

	if not self._firing then
		return
	end

	local tool = self._activeTool
	local handle = tool and tool:FindFirstChild("Handle")
	if not handle then
		self:_stopFiring()
		return
	end

	local mode = LaserConfig.GetMode(self._mode)
	local aimPoint = self:_getAimPoint(mode.Range)

	-- Segundo raycast a partir do muzzle: o feixe para em obstáculos
	local origin = self._beam.Attachment0 and self._beam.Attachment0.WorldPosition or handle.Position
	local delta = aimPoint - origin

	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	params.FilterDescendantsInstances = { player.Character, self._folder }
	params.IgnoreWater = true

	local result = workspace:Raycast(origin, delta.Unit * mode.Range, params)
	local endPoint = if result then result.Position else origin + delta.Unit * mode.Range

	self._endPart.Position = endPoint
	self._sparks.Enabled = result ~= nil

	-- Reporta pro servidor no tick rate
	self._accum += dt
	if self._accum >= LaserConfig.TICK_RATE then
		self._accum = 0
		self._mining.FireLaser:Fire(aimPoint, self._mode)
	end
end

-- ═══════════════════════════════════════════════════════════
-- API pública (pra HUD / botão de modo no mobile)
-- ═══════════════════════════════════════════════════════════

function LaserToolController:SetMode(modeName: string)
	if not LaserConfig.Modes[modeName] then
		return
	end
	self._mode = modeName
	self:_applyModeVisuals()
	self._crosshair:SetColor(LaserConfig.GetMode(modeName).Color)
	print("[Laser] Modo: " .. modeName)
end

function LaserToolController:GetMode(): string
	return self._mode
end

--- Solta ou reprende o cursor. Usado pela UI que precisa de clique — com a
--- arma equipada o mouse fica travado no centro e nada seria clicável.
--- Não desliga o modo de mira: ombro, FOV e crosshair continuam.
function LaserToolController:SetAimLocked(locked: boolean)
	self._aimLockSuspended = not locked

	if IS_MOBILE then
		return
	end

	if not locked then
		UserInputService.MouseBehavior = Enum.MouseBehavior.Default
		-- Sem cursor visível não dá pra clicar em nada
		UserInputService.MouseIconEnabled = true
	elseif self._aiming then
		UserInputService.MouseIconEnabled = false
	end
	-- O MouseBehavior é reaplicado pelo _updateCamera no próximo frame
end

return LaserToolController
