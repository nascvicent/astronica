--[[
	SprintController
	Corrida: segurar Shift no PC, botão RUN (liga/desliga) no mobile.

	Tudo roda no client: a WalkSpeed do próprio personagem e as animações
	tocadas no Animator local replicam sozinhas pro servidor e pros outros.

	Local: src/client/Controllers/SprintController.luau
]]

local Knit = require(game:GetService("ReplicatedStorage").Packages.Knit)
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")

local SprintHUD = require(script.Parent.Parent.UI.SprintHUD)

local player = Players.LocalPlayer

local RUN_SPEED = 26
local RUN_ANIMATION_ID = "rbxassetid://119123113969135"
local ANIM_FADE = 0.2

-- Abaixo disso o personagem está parado: corrida sem animação
local MOVE_THRESHOLD = 0.1

local SprintController = Knit.CreateController({
	Name = "SprintController",
})

local function isShift(input: InputObject): boolean
	return input.KeyCode == Enum.KeyCode.LeftShift or input.KeyCode == Enum.KeyCode.RightShift
end

-- ═══════════════════════════════════════════════════════════
-- Setup
-- ═══════════════════════════════════════════════════════════

function SprintController:KnitInit()
	self._shiftHeld = false
	self._toggled = false -- botão do mobile
	self._running = false
	self._animPlaying = false
	self._baseSpeed = 16
	self._humanoid = nil
	self._track = nil

	self._hud = SprintHUD.new()
end

function SprintController:KnitStart()
	self._hud:SetToggleHandler(function()
		self._toggled = not self._toggled
		self._hud:SetActive(self._toggled)
	end)

	UserInputService.InputBegan:Connect(function(input, gpe)
		if gpe then return end
		if isShift(input) then
			self._shiftHeld = true
		end
	end)

	-- Sem checar gpe: soltar o Shift com o chat aberto não pode deixar a corrida presa
	UserInputService.InputEnded:Connect(function(input)
		if isShift(input) then
			self._shiftHeld = false
		end
	end)

	-- Alt+Tab com Shift apertado: o InputEnded nunca chega
	UserInputService.WindowFocusReleased:Connect(function()
		self._shiftHeld = false
	end)

	player.CharacterAdded:Connect(function(character)
		self:_onCharacter(character)
	end)
	if player.Character then
		task.spawn(self._onCharacter, self, player.Character)
	end

	RunService.Heartbeat:Connect(function()
		self:_update()
	end)
end

function SprintController:_onCharacter(character: Model)
	if self._track then
		self._track:Stop(0)
	end
	self._track = nil
	self._humanoid = nil
	self._running = false
	self._animPlaying = false
	self._toggled = false
	self._hud:SetActive(false)

	local humanoid = character:WaitForChild("Humanoid", 5)
	local animator = humanoid and humanoid:WaitForChild("Animator", 5)
	if not animator or player.Character ~= character then
		return
	end

	local animation = Instance.new("Animation")
	animation.AnimationId = RUN_ANIMATION_ID

	local ok, track = pcall(function()
		return (animator :: Animator):LoadAnimation(animation)
	end)

	if ok and track then
		-- Movement passa por cima do run padrão do Animate (Core)
		track.Priority = Enum.AnimationPriority.Movement
		track.Looped = true
		self._track = track
	else
		warn("[Sprint] Não foi possível carregar a animação de corrida: " .. tostring(track))
	end

	self._humanoid = humanoid
end

-- ═══════════════════════════════════════════════════════════
-- Loop
-- ═══════════════════════════════════════════════════════════

function SprintController:_update()
	local humanoid = self._humanoid
	if not humanoid or not humanoid.Parent or humanoid.Health <= 0 then
		self._hud:SetVisible(false)
		return
	end

	-- Dentro da nave não tem corrida nem botão
	local seated = humanoid.SeatPart ~= nil
	self._hud:SetVisible(not seated)

	local wantsRun = (self._shiftHeld or self._toggled) and not seated
	self:_setRunning(humanoid, wantsRun)

	-- No ar deixa o pulo/queda do Animate tocar
	local moving = humanoid.MoveDirection.Magnitude > MOVE_THRESHOLD
		and humanoid.FloorMaterial ~= Enum.Material.Air
	self:_setAnimPlaying(wantsRun and moving)
end

function SprintController:_setRunning(humanoid: Humanoid, running: boolean)
	if self._running == running then
		return
	end
	self._running = running

	if running then
		-- Guarda a velocidade do momento, não a do spawn, pra não sobrescrever
		-- outra mudança de WalkSpeed quando a corrida acabar
		self._baseSpeed = humanoid.WalkSpeed
		humanoid.WalkSpeed = RUN_SPEED
	else
		humanoid.WalkSpeed = self._baseSpeed
	end
end

function SprintController:_setAnimPlaying(playing: boolean)
	if not self._track or self._animPlaying == playing then
		return
	end
	self._animPlaying = playing

	if playing then
		self._track:Play(ANIM_FADE)
	else
		self._track:Stop(ANIM_FADE)
	end
end

-- ═══════════════════════════════════════════════════════════
-- API pública
-- ═══════════════════════════════════════════════════════════

function SprintController:IsRunning(): boolean
	return self._running
end

return SprintController
