--[[
	SuitController
	- Câmera: o SuitService troca o personagem no servidor e a câmera padrão
	  continuaria presa no Humanoid antigo (destruído); aqui ela é reapontada.
	- Lanterna: L (teclado), DPad ↑ (controle) ou botão de toque. Liga local
	  na hora e pede pro servidor, que replica pros outros.
	- Aba "Traje" do inventário: repassa o estado do SuitService e manda
	  equipar/comprar traje e escolher/comprar cor do visor.

	Local: src/client/Controllers/SuitController.luau
]]

local Knit = require(game:GetService("ReplicatedStorage").Packages.Knit)
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ContextActionService = game:GetService("ContextActionService")

local SuitConfig = require(ReplicatedStorage.Shared.SuitConfig)
local SuitBuilder = require(ReplicatedStorage.Shared.SuitBuilder)
local ShipToast = require(script.Parent.Parent.UI.ShipToast)
local UIStyle = require(script.Parent.Parent.UI.UIStyle)

local player = Players.LocalPlayer

local SUIT_ATTRIBUTE = SuitConfig.SUIT_ATTRIBUTE
local FLASHLIGHT_ATTRIBUTE = SuitConfig.FLASHLIGHT_ATTRIBUTE
local FLASHLIGHT_ACTION = "SuitFlashlight"
local TOAST_TIME = 3

local SuitController = Knit.CreateController({
	Name = "SuitController",
})

local function onCharacter(character: Model)
	-- Só personagens de traje (os que o servidor trocou)
	if not character:GetAttribute(SUIT_ATTRIBUTE) then return end

	local humanoid = character:WaitForChild("Humanoid", 10)
	if not humanoid or player.Character ~= character then return end

	local camera = workspace.CurrentCamera
	camera.CameraSubject = humanoid
	camera.CameraType = Enum.CameraType.Custom
end

-- ═══════════════════════════════════════════════════════════
-- Lanterna
-- ═══════════════════════════════════════════════════════════

function SuitController:ToggleFlashlight()
	local on = not self._flashlightOn
	self._flashlightOn = on

	-- Resposta imediata; o servidor confirma e replica
	local character = player.Character
	if character and character:GetAttribute(SUIT_ATTRIBUTE) then
		SuitBuilder.SetLights(character, on)
	end
	self._service.SetFlashlight:Fire(on)
end

function SuitController:_bindFlashlight()
	self._flashlightOn = player:GetAttribute(FLASHLIGHT_ATTRIBUTE) == true
	player:GetAttributeChangedSignal(FLASHLIGHT_ATTRIBUTE):Connect(function()
		self._flashlightOn = player:GetAttribute(FLASHLIGHT_ATTRIBUTE) == true
	end)

	ContextActionService:BindAction(FLASHLIGHT_ACTION, function(_, inputState)
		if inputState == Enum.UserInputState.Begin then
			self:ToggleFlashlight()
		end
		return Enum.ContextActionResult.Sink
	end, true, SuitConfig.FLASHLIGHT_KEY, SuitConfig.FLASHLIGHT_GAMEPAD)

	ContextActionService:SetTitle(FLASHLIGHT_ACTION, "LUZ")
	ContextActionService:SetPosition(FLASHLIGHT_ACTION, UDim2.new(1, -150, 0, 20))
end

-- ═══════════════════════════════════════════════════════════
-- Aba Traje
-- ═══════════════════════════════════════════════════════════

function SuitController:_setState(state, unlockedId: string?)
	self._state = state
	local inventory = Knit.GetController("InventoryController")
	if inventory and inventory.SetSuitState then
		inventory:SetSuitState(state)
	end

	local unlocked = unlockedId and SuitConfig.Get(unlockedId)
	if unlocked then
		self._toast:Flash("TRAJE DESBLOQUEADO  ·  " .. UIStyle.upper(unlocked.displayName), TOAST_TIME, UIStyle.C.positive)
	end
end

--- Chama o SuitService; erro vira aviso. onOk roda só se deu certo.
function SuitController:_request(method: string, args: { any }, onOk: (() -> ())?)
	self._service[method](self._service, table.unpack(args)):andThen(function(ok: boolean, msg: string)
		if not ok then
			self._toast:Flash(UIStyle.upper(msg), TOAST_TIME, UIStyle.C.negative)
		elseif onOk then
			onOk()
		end
	end):catch(function(err)
		warn("[SuitController] " .. method .. " failed:", err)
	end)
end

function SuitController:GetState()
	return self._state
end

-- ═══════════════════════════════════════════════════════════
-- Knit lifecycle
-- ═══════════════════════════════════════════════════════════

function SuitController:KnitStart()
	self._service = Knit.GetService("SuitService")
	self._toast = ShipToast.new()

	player.CharacterAdded:Connect(onCharacter)
	if player.Character then
		task.spawn(onCharacter, player.Character)
	end

	self:_bindFlashlight()

	local inventory = Knit.GetController("InventoryController")
	inventory:SetSuitHandlers({
		onEquip = function(suitId: string)
			self:_request("EquipSuit", { suitId })
		end,
		onBuy = function(suitId: string)
			self:_request("BuySuit", { suitId })
		end,
		onSetVisor = function(suitId: string, colorId: string)
			self:_request("SetVisor", { suitId, colorId })
		end,
		-- Comprou: já aplica no traje
		onBuyVisor = function(suitId: string, colorId: string)
			self:_request("BuyVisorColor", { suitId, colorId }, function()
				self:_request("SetVisor", { suitId, colorId })
			end)
		end,
	})

	self._service.StateChanged:Connect(function(state, unlockedId)
		self:_setState(state, unlockedId)
	end)
	self._service:GetState():andThen(function(state)
		self:_setState(state)
	end):catch(function(err)
		warn("[SuitController] GetState failed:", err)
	end)
end

return SuitController
