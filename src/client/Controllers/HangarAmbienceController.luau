--[[
	HangarAmbienceController
	A HangarZone serve só pra ambiência: entrar no hangar acende as luzes,
	sobe a trilha e ajusta o enquadramento da câmera. Nunca abre menu — o HUD
	é do terminal (HangarTerminal).

	Tudo aqui é local: cada jogador vê as luzes acenderem pra si, sem replicar.

	SETUP NO STUDIO (tudo opcional):
		Luzes   — PointLight/SpotLight/SurfaceLight com a tag "HangarLight"
		          Atributos opcionais: OnBrightness (padrão: o Brightness do Studio)
		                               OffBrightness (padrão: 0)
		Trilha  — Sound com a tag "HangarMusic"
		          Atributo opcional: TargetVolume (padrão: o Volume do Studio)
		Câmera  — atributo CameraMaxZoom (number) na HangarZone: limita o zoom
		          máximo enquanto dentro do hangar (espaço fechado)

	Local: src/client/Controllers/HangarAmbienceController.luau
]]

local Knit = require(game:GetService("ReplicatedStorage").Packages.Knit)
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")
local CollectionService = game:GetService("CollectionService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local PlaceConfig = require(ReplicatedStorage.Shared.PlaceConfig)

local player = Players.LocalPlayer

local LIGHT_TAG = "HangarLight"
local MUSIC_TAG = "HangarMusic"
local CHECK_INTERVAL = 0.2

local LIGHT_TWEEN = TweenInfo.new(1.2, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
local MUSIC_IN = TweenInfo.new(2, Enum.EasingStyle.Sine, Enum.EasingDirection.Out)
local MUSIC_OUT = TweenInfo.new(1.5, Enum.EasingStyle.Sine, Enum.EasingDirection.In)

local HangarAmbienceController = Knit.CreateController({
	Name = "HangarAmbienceController",
})

function HangarAmbienceController:KnitInit()
	self._inside = false
	self._timer = 0
	self._lights = {} :: { [Light]: { on: number, off: number } }
	self._music = {} :: { [Sound]: number }
end

function HangarAmbienceController:KnitStart()
	if PlaceConfig.IsPlanet() or not workspace:FindFirstChild(PlaceConfig.HANGAR_ZONE) then
		return
	end

	local function addLight(inst: Instance)
		if not inst:IsA("Light") or self._lights[inst] then
			return
		end
		local on = inst:GetAttribute("OnBrightness")
		local off = inst:GetAttribute("OffBrightness")
		self._lights[inst] = {
			on = if typeof(on) == "number" then on else inst.Brightness,
			off = if typeof(off) == "number" then off else 0,
		}
		inst.Brightness = if self._inside then self._lights[inst].on else self._lights[inst].off
	end

	local function addMusic(inst: Instance)
		if not inst:IsA("Sound") or self._music[inst] then
			return
		end
		local target = inst:GetAttribute("TargetVolume")
		self._music[inst] = if typeof(target) == "number" then target else inst.Volume
		inst.Looped = true
		if not self._inside then
			inst.Volume = 0
			inst:Stop()
		end
	end

	for _, inst in CollectionService:GetTagged(LIGHT_TAG) do
		addLight(inst)
	end
	CollectionService:GetInstanceAddedSignal(LIGHT_TAG):Connect(addLight)
	CollectionService:GetInstanceRemovedSignal(LIGHT_TAG):Connect(function(inst)
		self._lights[inst :: Light] = nil
	end)

	for _, inst in CollectionService:GetTagged(MUSIC_TAG) do
		addMusic(inst)
	end
	CollectionService:GetInstanceAddedSignal(MUSIC_TAG):Connect(addMusic)
	CollectionService:GetInstanceRemovedSignal(MUSIC_TAG):Connect(function(inst)
		self._music[inst :: Sound] = nil
	end)

	RunService.Heartbeat:Connect(function(dt)
		self._timer -= dt
		if self._timer > 0 then
			return
		end
		self._timer = CHECK_INTERVAL

		local character = player.Character
		local root = character and character:FindFirstChild("HumanoidRootPart")
		local inside = root ~= nil and PlaceConfig.IsInHangarZone((root :: BasePart).Position)
		if inside ~= self._inside then
			self._inside = inside
			self:_apply(inside)
		end
	end)
end

function HangarAmbienceController:_apply(inside: boolean)
	for light, levels in self._lights do
		TweenService:Create(light, LIGHT_TWEEN, { Brightness = if inside then levels.on else levels.off }):Play()
	end

	for sound, volume in self._music do
		if inside then
			if not sound.IsPlaying then
				sound.Volume = 0
				sound:Play()
			end
			TweenService:Create(sound, MUSIC_IN, { Volume = volume }):Play()
		else
			local fade = TweenService:Create(sound, MUSIC_OUT, { Volume = 0 })
			fade:Play()
			fade.Completed:Once(function()
				if not self._inside then
					sound:Stop()
				end
			end)
		end
	end

	-- Espaço fechado: zoom máximo menor pra câmera não atravessar as paredes
	local zone = workspace:FindFirstChild(PlaceConfig.HANGAR_ZONE)
	local maxZoom = zone and zone:GetAttribute("CameraMaxZoom")
	if typeof(maxZoom) == "number" then
		if inside then
			self._prevMaxZoom = player.CameraMaxZoomDistance
			player.CameraMaxZoomDistance = math.min(self._prevMaxZoom, maxZoom)
		elseif self._prevMaxZoom then
			player.CameraMaxZoomDistance = self._prevMaxZoom
			self._prevMaxZoom = nil
		end
	end
end

--- Jogador local está dentro da HangarZone.
function HangarAmbienceController:IsInHangar(): boolean
	return self._inside
end

return HangarAmbienceController
