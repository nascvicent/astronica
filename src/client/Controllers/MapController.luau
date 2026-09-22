--[[
	MapController
	Abre e fecha o mapa do sistema (MapHUD) e alimenta ele com a posição do
	jogador, distâncias e alcance de warp.

	O mapa existe em Place de espaço com algo pra mostrar (MapConfig). Não abre
	com o warp carregando ou em viagem — a tela nessa hora é do túnel.

	Com o mapa aberto:
	  - a pé: o personagem para (controles desligados)
	  - pilotando: a nave continua no controle do piloto (não trava)
	  - o cursor fica solto, mesmo com a arma equipada
	  - WARP no painel (ou [F]) salta pro corpo selecionado, se estiver no
	    alcance. O pedido é o mesmo da mira (ShipController)

	Local: src/client/Controllers/MapController.luau
]]

local Knit = require(game:GetService("ReplicatedStorage").Packages.Knit)
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local MapConfig = require(ReplicatedStorage.Shared.MapConfig)
local PlaceConfig = require(ReplicatedStorage.Shared.PlaceConfig)
local ShipData = require(ReplicatedStorage.Shared.ShipData)
local WarpModule = require(ReplicatedStorage.Shared.WarpModule)

local MapHUD = require(script.Parent.Parent.UI.MapHUD)

local player = Players.LocalPlayer

-- De quanto em quanto tempo confere se o mapa tem o que mostrar
local AVAILABILITY_REFRESH = 1
-- Por quantos frames o estado do mouse é reafirmado depois de fechar
local MOUSE_RESTORE_FRAMES = 10

local MapController = Knit.CreateController({
	Name = "MapController",
})

function MapController:KnitInit()
	self._hud = MapHUD.new()
	self._availabilityTimer = 0
	self._available = false
end

function MapController:KnitStart()
	self._hud:SetToggleHandler(function()
		self:Toggle()
	end)
	self._hud:SetCloseHandler(function()
		self:Close()
	end)
	self._hud:SetPlayerPositionProvider(function()
		return self:_getPlayerPosition()
	end)
	self._hud:SetInfoProvider(function(body)
		return self:_getInfo(body)
	end)
	self._hud:SetWarpHandler(function(destinationId)
		-- Fecha antes: a carga e o túnel precisam da tela, e erro de pedido
		-- aparece na mensagem do WarpHUD
		self:Close()
		local shipController = Knit.GetController("ShipController")
		if shipController then
			shipController:RequestWarp(destinationId)
		end
	end)

	UserInputService.InputBegan:Connect(function(input, gameProcessed)
		if gameProcessed then
			return
		end
		if input.KeyCode == Enum.KeyCode.M then
			self:Toggle()
		elseif input.KeyCode == Enum.KeyCode.F and self._hud:IsOpen() then
			self._hud:ActivateWarp()
		end
	end)

	RunService.Heartbeat:Connect(function(dt)
		self._availabilityTimer -= dt
		if self._availabilityTimer <= 0 then
			self._availabilityTimer = AVAILABILITY_REFRESH
			self:_refreshAvailability()
		end
	end)

	-- Morrer com o mapa aberto não pode deixar os controles desligados
	player.CharacterAdded:Connect(function()
		self:Close()
	end)
end

-- ═══════════════════════════════════════════════════════════
-- Abrir / fechar
-- ═══════════════════════════════════════════════════════════

function MapController:_isPlanet(): boolean
	-- O servidor é quem sabe o tipo do Place (mesma regra do ShipController)
	local ship = Knit.GetController("ShipController")
	local state = ship and ship:GetState()
	if state and state.loaded then
		return state.isPlanet == true
	end
	return PlaceConfig.IsPlanet()
end

function MapController:_refreshAvailability()
	local available = not self:_isPlanet() and #MapConfig.GetBodies() > 0
	self._available = available
	self._hud:SetAvailable(available)
	if not available then
		self:Close()
	end
end

function MapController:_isWarpBusy(): boolean
	local ship = Knit.GetController("ShipController")
	return ship ~= nil and ship:IsWarpBusy()
end

function MapController:Open()
	if self._hud:IsOpen() or not self._available or self:_isWarpBusy() then
		return
	end

	local bodies = MapConfig.GetBodies()
	if #bodies == 0 then
		return
	end

	-- Guarda o estado do mouse de quem estava no comando (o kit de voo trava
	-- o cursor no centro pra mirar a nave) pra devolver igual ao fechar
	self._savedMouse = {
		behavior = UserInputService.MouseBehavior,
		icon = UserInputService.MouseIconEnabled,
	}

	self._hud:Open(bodies, MapConfig.SYSTEM_NAME)
	self:_setControlsEnabled(false)

	local laser = Knit.GetController("LaserToolController")
	if laser then
		laser:SetAimLocked(false)
	end
	-- Pilotando não há laser, mas o cursor também precisa estar solto
	UserInputService.MouseBehavior = Enum.MouseBehavior.Default
	UserInputService.MouseIconEnabled = true
end

function MapController:Close()
	if not self._hud:IsOpen() then
		return
	end

	self._hud:Close()
	self:_setControlsEnabled(true)

	local laser = Knit.GetController("LaserToolController")
	if laser then
		laser:SetAimLocked(true)
	end

	local saved = self._savedMouse
	self._savedMouse = nil
	if saved then
		self:_restoreMouse(saved)
	end
end

--[[
	Devolve o mouse como estava antes do mapa. Sem isso, pilotando, a nave
	ficava sem controle: o kit de voo trava o cursor no centro uma vez (ao
	sentar) e não reaplica, então o Default que o mapa pôs ficava valendo.

	Reaplica por alguns frames porque o PlayerModule às vezes devolve o
	MouseBehavior pro Default no frame seguinte a uma mudança de GUI.
]]
function MapController:_restoreMouse(saved)
	local frames = 0
	local conn
	conn = RunService.RenderStepped:Connect(function()
		frames += 1
		if self._hud:IsOpen() or frames > MOUSE_RESTORE_FRAMES then
			conn:Disconnect()
			return
		end
		UserInputService.MouseBehavior = saved.behavior
		UserInputService.MouseIconEnabled = saved.icon
	end)
	UserInputService.MouseBehavior = saved.behavior
	UserInputService.MouseIconEnabled = saved.icon
end

function MapController:Toggle()
	if self._hud:IsOpen() then
		self:Close()
	else
		self:Open()
	end
end

function MapController:IsOpen(): boolean
	return self._hud:IsOpen()
end

--- Liga/desliga o andar do personagem (PlayerModule). A nave não passa por
--- aqui: o kit de voo lê o teclado por conta própria e segue voando.
function MapController:_setControlsEnabled(enabled: boolean)
	-- Sentado (pilotando) não mexe: o voo segue normal com o mapa aberto
	if not enabled then
		local character = player.Character
		local humanoid = character and character:FindFirstChildOfClass("Humanoid")
		self._controlsDisabled = not (humanoid and humanoid.SeatPart)
		if not self._controlsDisabled then
			return
		end
	elseif not self._controlsDisabled then
		return
	else
		self._controlsDisabled = false
	end

	local ok, err = pcall(function()
		local playerModule = require(player:WaitForChild("PlayerScripts"):WaitForChild("PlayerModule") :: any)
		local controls = playerModule:GetControls()
		if enabled then
			controls:Enable()
		else
			controls:Disable()
		end
	end)
	if not ok then
		warn("[MapController] Não foi possível mexer nos controles:", err)
	end
end

-- ═══════════════════════════════════════════════════════════
-- Dados pro mapa
-- ═══════════════════════════════════════════════════════════

--- Nave pilotada, se for o caso (pelo Body, nunca pelo pivô).
function MapController:_getPilotedShipBody(): BasePart?
	local character = player.Character
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	local seat = humanoid and humanoid.SeatPart
	local shipController = Knit.GetController("ShipController")
	local ship = shipController and shipController:GetOwnShip()
	if not seat or not ship or not seat:IsDescendantOf(ship) then
		return nil
	end
	local body = ship:FindFirstChild(ShipData.PARTS.body)
	return if body and body:IsA("BasePart") then body else nil
end

function MapController:_getPlayerPosition(): Vector3?
	local body = self:_getPilotedShipBody()
	if body then
		return body.Position
	end
	local character = player.Character
	local root = character and character:FindFirstChild("HumanoidRootPart")
	return if root and root:IsA("BasePart") then root.Position else nil
end

function MapController:_getInfo(body)
	local info = {}

	local from = self:_getPlayerPosition()
	if from then
		info.distance = (body.position - from).Magnitude
	end

	-- Alcance só faz sentido pilotando e num destino de warp
	local shipBody = self:_getPilotedShipBody()
	local shipController = Knit.GetController("ShipController")
	local stats = shipController and shipController:GetEquippedStats()
	if body.isWarp and shipBody and stats then
		if WarpModule.IsTooClose(shipBody.Position, body.position) then
			info.warp = "tooClose"
		elseif WarpModule.IsUnlimited(stats.warpRange) then
			info.warp = "unlimited"
		elseif WarpModule.IsInRange(stats.warpRange, shipBody.Position, body.position) then
			info.warp = "inRange"
		else
			info.warp = "outOfRange"
		end
	end

	return info
end

return MapController
