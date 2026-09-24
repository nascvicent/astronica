--[[
	SuitService
	Trajes: posse, equipar, desbloqueio por objetivo/compra e a lanterna.

	Troca o personagem do player pelo personagem completo do traje
	(ReplicatedStorage/Assets/Suits/<suit>/StarterCharacter), mantendo a
	cabeça e o cabelo originais do player (ver SuitBuilder).

	Save (PlayerDataService):
	  profile.suits    = { equipped = id, owned = { id, ... },
	                       visorColors = { [suitId] = { colorId, ... } },  -- compradas, por traje
	                       visors = { [suitId] = colorId } }  -- escolha por traje
	  profile.progress = { minedOres = { [itemId] = true } }

	O traje em uso também fica no attribute "SuitId" do Player; mudar o
	attribute troca o personagem na hora.

	Local: src/server/Services/SuitService.luau
]]

local Knit = require(game:GetService("ReplicatedStorage").Packages.Knit)
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local SuitConfig = require(ReplicatedStorage.Shared.SuitConfig)
local SuitBuilder = require(ReplicatedStorage.Shared.SuitBuilder)
local LaserConfig = require(ReplicatedStorage.Shared.LaserConfig)

local SuitService = Knit.CreateService({
	Name = "SuitService",
	Client = {
		-- server → client: estado dos trajes mudou (posse, progresso, equipado).
		-- unlockedId vem preenchido quando um traje acabou de ser liberado.
		StateChanged = Knit.CreateSignal(), -- (state, unlockedId: string?)
		-- client → server
		SetFlashlight = Knit.CreateSignal(), -- (on: boolean)
	},
})

local SUIT_ATTRIBUTE = SuitConfig.SUIT_ATTRIBUTE
local FLASHLIGHT_ATTRIBUTE = SuitConfig.FLASHLIGHT_ATTRIBUTE
local APPEARANCE_TIMEOUT = 5
-- Espera curta pelo perfil no spawn: se o save demorar, nasce com o padrão e
-- troca quando o perfil chegar
local PROFILE_TIMEOUT = 8
local FLASHLIGHT_COOLDOWN = 0.15

local lastFlashlight: { [Player]: number } = {}

-- ═══════════════════════════════════════════════════════════
-- Perfil
-- ═══════════════════════════════════════════════════════════

--- Garante os campos de traje/progresso no perfil (saves antigos não têm).
local function ensureSuitData(profile)
	if typeof(profile.suits) ~= "table" then
		profile.suits = {}
	end
	if typeof(profile.suits.owned) ~= "table" then
		profile.suits.owned = {}
	end
	-- Formato antigo (lista global de cores) não vale mais: cor é por traje
	if typeof(profile.suits.visorColors) ~= "table" or profile.suits.visorColors[1] ~= nil then
		profile.suits.visorColors = {}
	end
	if typeof(profile.suits.visors) ~= "table" then
		profile.suits.visors = {}
	end
	if typeof(profile.progress) ~= "table" then
		profile.progress = {}
	end
	if typeof(profile.progress.minedOres) ~= "table" then
		profile.progress.minedOres = {}
	end
end

local function ownsSuit(profile, suitId: string): boolean
	local suit = SuitConfig.Get(suitId)
	if not suit then return false end
	if suit.unlock.kind == "default" then return true end
	return profile ~= nil and table.find(profile.suits.owned, suitId) ~= nil
end

--- A cor está liberada NAQUELE traje (padrão dele ou comprada pra ele).
local function ownsVisorColor(profile, suitId: string, colorId: string): boolean
	if not SuitConfig.GetVisorColor(colorId) then return false end
	if SuitConfig.IsDefaultVisor(suitId, colorId) then return true end
	local bought = profile and profile.suits.visorColors[suitId]
	return typeof(bought) == "table" and table.find(bought, colorId) ~= nil
end

--- Cor do visor escolhida pra aquele traje (ou a padrão dele).
local function getVisor(profile, suitId: string): string
	local chosen = profile and profile.suits.visors[suitId]
	if typeof(chosen) == "string" and ownsVisorColor(profile, suitId, chosen) then
		return chosen
	end
	local suit = SuitConfig.Get(suitId)
	return suit and suit.defaultVisor or "gold"
end

local function applyVisor(character: Model, colorId: string)
	local def = SuitConfig.GetVisorColor(colorId)
	if def then
		SuitBuilder.SetVisorColor(character, def.color)
	end
end

--- Progresso de um objetivo: (atual, total).
local function objectiveProgress(profile, objectiveId: string): (number, number)
	if objectiveId == "mine_all_ores" then
		local current, total = 0, 0
		for oreId in LaserConfig.Nodes do
			total += 1
			if profile and profile.progress.minedOres[oreId] then
				current += 1
			end
		end
		return current, total
	end
	return 0, 1
end

-- ═══════════════════════════════════════════════════════════
-- Estado pro client
-- ═══════════════════════════════════════════════════════════

function SuitService:_getProfile(player: Player)
	local profile = self._data:GetProfile(player)
	if profile then
		ensureSuitData(profile)
	end
	return profile
end

function SuitService:_buildState(player: Player)
	local profile = self:_getProfile(player)
	local visorColors, visors = {}, {}
	for suitId in SuitConfig.Suits do
		local owned = {}
		for colorId in SuitConfig.VisorColors do
			owned[colorId] = ownsVisorColor(profile, suitId, colorId)
		end
		visorColors[suitId] = owned
		visors[suitId] = getVisor(profile, suitId)
	end

	local suits = {}
	for suitId, suit in SuitConfig.Suits do
		local entry = { owned = ownsSuit(profile, suitId) }
		if suit.unlock.kind == "objective" then
			local current, total = objectiveProgress(profile, suit.unlock.objective)
			entry.progress = { current = current, total = total }
		end
		suits[suitId] = entry
	end

	return {
		loaded = profile ~= nil,
		equipped = self:_getEquipped(player),
		suits = suits,
		visorColors = visorColors, -- [suitId][colorId] = tem
		visors = visors, -- [suitId] = colorId
	}
end

function SuitService:_pushState(player: Player, unlockedId: string?)
	self.Client.StateChanged:Fire(player, self:_buildState(player), unlockedId)
end

function SuitService:_getEquipped(player: Player): string
	local profile = self:_getProfile(player)
	local equipped = profile and profile.suits.equipped
	if typeof(equipped) == "string" and ownsSuit(profile, equipped) then
		return equipped
	end
	return SuitConfig.DEFAULT_SUIT
end

-- ═══════════════════════════════════════════════════════════
-- Troca de personagem
-- ═══════════════════════════════════════════════════════════

--- Scripts que o personagem antigo tinha (Animate, Health, StarterCharacterScripts)
--- e o do traje não tem.
local function copyCharacterScripts(from: Model, to: Model)
	for _, child in from:GetChildren() do
		if child:IsA("BaseScript") and not to:FindFirstChild(child.Name) then
			child:Clone().Parent = to
		end
	end
end

--- Substitui o personagem atual do player pelo do traje.
function SuitService:ApplySuit(player: Player, suitId: string)
	local oldCharacter = player.Character
	if not (oldCharacter and oldCharacter.Parent) then return end

	local character = SuitBuilder.Build(suitId, oldCharacter)
	if not character then return end

	character.Name = player.Name
	character:SetAttribute(SUIT_ATTRIBUTE, suitId)

	local rootPart = character:FindFirstChild("HumanoidRootPart")
	if rootPart and rootPart:IsA("BasePart") then
		character.PrimaryPart = rootPart
	else
		warn("[SuitService] StarterCharacter do traje sem HumanoidRootPart:", suitId)
	end

	copyCharacterScripts(oldCharacter, character)
	applyVisor(character, getVisor(self:_getProfile(player), suitId))
	SuitBuilder.SetLights(character, player:GetAttribute(FLASHLIGHT_ATTRIBUTE) == true)

	-- Ferramentas equipadas voltam pra mochila
	local backpack = player:FindFirstChildOfClass("Backpack")
	for _, child in oldCharacter:GetChildren() do
		if child:IsA("Tool") and backpack then
			child.Parent = backpack
		end
	end

	character:PivotTo(oldCharacter:GetPivot())
	character.Parent = workspace
	player.Character = character
	oldCharacter:Destroy()
end

-- ═══════════════════════════════════════════════════════════
-- API (server)
-- ═══════════════════════════════════════════════════════════

--- Registra um minério extraído (chamado pelo MiningService).
--- Tipo novo avança o objetivo e pode liberar traje.
function SuitService:RecordOreMined(player: Player, oreId: string)
	local profile = self:_getProfile(player)
	if not profile or profile.progress.minedOres[oreId] then return end

	profile.progress.minedOres[oreId] = true

	local unlockedId = nil
	for _, suitId in SuitConfig.GetOrdered() do
		local suit = SuitConfig.Suits[suitId]
		if suit.unlock.kind == "objective" and not ownsSuit(profile, suitId) then
			local current, total = objectiveProgress(profile, suit.unlock.objective)
			if current >= total then
				table.insert(profile.suits.owned, suitId)
				unlockedId = unlockedId or suitId
				print(string.format("[SuitService] %s desbloqueou o traje %s", player.Name, suitId))
			end
		end
	end

	self:_pushState(player, unlockedId)
end

function SuitService:EquipSuit(player: Player, suitId: string): (boolean, string)
	local profile = self:_getProfile(player)
	if not profile then return false, "Perfil ainda carregando" end
	if not SuitConfig.Get(suitId) then return false, "Traje inválido" end
	if not ownsSuit(profile, suitId) then return false, "Traje bloqueado" end

	local character = player.Character
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	if not humanoid or humanoid.Health <= 0 then return false, "Aguarde renascer" end
	-- Trocar o personagem sentado tira o player do assento da nave
	if humanoid.SeatPart then return false, "Saia da nave para trocar de traje" end

	profile.suits.equipped = suitId
	player:SetAttribute(SUIT_ATTRIBUTE, suitId)
	self:_pushState(player)
	return true, "ok"
end

function SuitService:BuySuit(player: Player, suitId: string): (boolean, string)
	local profile = self:_getProfile(player)
	local suit = SuitConfig.Get(suitId)
	if not profile then return false, "Perfil ainda carregando" end
	if not suit or suit.unlock.kind ~= "price" then return false, "Traje não está à venda" end
	if ownsSuit(profile, suitId) then return false, "Você já tem este traje" end

	local price = suit.unlock.price
	if self._lumens:GetLumens(player) < price then return false, "Lúmens insuficientes" end

	self._lumens:RemoveLumens(player, price)
	table.insert(profile.suits.owned, suitId)
	self:_pushState(player, suitId)
	return true, "ok"
end

--- Escolhe a cor do visor de um traje. Traje em uso é repintado na hora.
function SuitService:SetVisor(player: Player, suitId: string, colorId: string): (boolean, string)
	local profile = self:_getProfile(player)
	if not profile then return false, "Perfil ainda carregando" end
	if not ownsSuit(profile, suitId) then return false, "Traje bloqueado" end
	if not ownsVisorColor(profile, suitId, colorId) then return false, "Cor bloqueada" end

	profile.suits.visors[suitId] = colorId

	local character = player.Character
	if character and character:GetAttribute(SUIT_ATTRIBUTE) == suitId then
		applyVisor(character, colorId)
	end
	self:_pushState(player)
	return true, "ok"
end

--- Libera uma cor do visor para um traje específico.
function SuitService:BuyVisorColor(player: Player, suitId: string, colorId: string): (boolean, string)
	local profile = self:_getProfile(player)
	local def = SuitConfig.GetVisorColor(colorId)
	if not profile then return false, "Perfil ainda carregando" end
	if not def then return false, "Cor inválida" end
	if not ownsSuit(profile, suitId) then return false, "Libere o traje primeiro" end
	if ownsVisorColor(profile, suitId, colorId) then return false, "Este traje já tem esta cor" end
	if self._lumens:GetLumens(player) < def.price then return false, "Lúmens insuficientes" end

	self._lumens:RemoveLumens(player, def.price)
	local bought = profile.suits.visorColors[suitId]
	if typeof(bought) ~= "table" then
		bought = {}
		profile.suits.visorColors[suitId] = bought
	end
	table.insert(bought, colorId)
	self:_pushState(player)
	return true, "ok"
end

-- ═══════════════════════════════════════════════════════════
-- API (client)
-- ═══════════════════════════════════════════════════════════

function SuitService.Client:GetState(player: Player)
	self.Server._data:WaitForProfile(player)
	return self.Server:_buildState(player)
end

function SuitService.Client:EquipSuit(player: Player, suitId: any)
	if typeof(suitId) ~= "string" then return false, "Traje inválido" end
	return self.Server:EquipSuit(player, suitId)
end

function SuitService.Client:BuySuit(player: Player, suitId: any)
	if typeof(suitId) ~= "string" then return false, "Traje inválido" end
	return self.Server:BuySuit(player, suitId)
end

function SuitService.Client:SetVisor(player: Player, suitId: any, colorId: any)
	if typeof(suitId) ~= "string" or typeof(colorId) ~= "string" then return false, "Cor inválida" end
	return self.Server:SetVisor(player, suitId, colorId)
end

function SuitService.Client:BuyVisorColor(player: Player, suitId: any, colorId: any)
	if typeof(suitId) ~= "string" or typeof(colorId) ~= "string" then return false, "Cor inválida" end
	return self.Server:BuyVisorColor(player, suitId, colorId)
end

-- ═══════════════════════════════════════════════════════════
-- Setup por jogador
-- ═══════════════════════════════════════════════════════════

local function getPlayerSuit(player: Player): string
	local suitId = player:GetAttribute(SUIT_ATTRIBUTE)
	if typeof(suitId) == "string" and SuitConfig.Get(suitId) then
		return suitId
	end
	return SuitConfig.DEFAULT_SUIT
end

function SuitService:_onCharacterAdded(player: Player, character: Model)
	-- Personagem que já é de traje (acabou de ser trocado): nada a fazer
	if character:GetAttribute(SUIT_ATTRIBUTE) then return end

	-- Cabeça/cabelo do avatar chegam depois do CharacterAdded
	local waited = 0
	while not player:HasAppearanceLoaded() and waited < APPEARANCE_TIMEOUT do
		waited += task.wait(0.1)
	end
	while not self._data:IsLoaded(player) and waited < PROFILE_TIMEOUT do
		waited += task.wait(0.1)
	end
	if player.Character ~= character or character.Parent == nil then return end

	self:ApplySuit(player, getPlayerSuit(player))
end

function SuitService:_onPlayer(player: Player)
	if player:GetAttribute(SUIT_ATTRIBUTE) == nil then
		player:SetAttribute(SUIT_ATTRIBUTE, SuitConfig.DEFAULT_SUIT)
	end

	player.CharacterAdded:Connect(function(character)
		self:_onCharacterAdded(player, character)
	end)
	if player.Character then
		task.spawn(self._onCharacterAdded, self, player, player.Character)
	end

	-- Troca na hora quando o attribute muda. Só mexe em personagem que já é
	-- de traje: o avatar recém-nascido ainda está carregando e o
	-- _onCharacterAdded cuida dele.
	player:GetAttributeChangedSignal(SUIT_ATTRIBUTE):Connect(function()
		local character = player.Character
		local current = character and character:GetAttribute(SUIT_ATTRIBUTE)
		local suitId = getPlayerSuit(player)
		if current and current ~= suitId then
			self:ApplySuit(player, suitId)
		end
	end)
end

function SuitService:_setFlashlight(player: Player, on: any)
	if typeof(on) ~= "boolean" then return end

	local now = os.clock()
	if now - (lastFlashlight[player] or 0) < FLASHLIGHT_COOLDOWN then return end
	lastFlashlight[player] = now

	player:SetAttribute(FLASHLIGHT_ATTRIBUTE, on)
	local character = player.Character
	if character and character:GetAttribute(SUIT_ATTRIBUTE) then
		SuitBuilder.SetLights(character, on)
	end
end

-- ═══════════════════════════════════════════════════════════
-- Knit lifecycle
-- ═══════════════════════════════════════════════════════════

function SuitService:KnitStart()
	self._data = Knit.GetService("PlayerDataService")
	self._lumens = Knit.GetService("LumenService")

	-- Perfil carregado: traje salvo vira o atual (troca se já nasceu com o padrão)
	self._data:OnProfileLoaded(function(player, profile)
		ensureSuitData(profile)
		player:SetAttribute(SUIT_ATTRIBUTE, self:_getEquipped(player))
		self:_pushState(player)
	end)

	self.Client.SetFlashlight:Connect(function(player, on)
		self:_setFlashlight(player, on)
	end)

	Players.PlayerAdded:Connect(function(player)
		self:_onPlayer(player)
	end)
	for _, player in Players:GetPlayers() do
		self:_onPlayer(player)
	end
	Players.PlayerRemoving:Connect(function(player)
		lastFlashlight[player] = nil
	end)

	print("[SuitService] Started")
end

return SuitService
