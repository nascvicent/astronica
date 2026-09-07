--[[
	ToolService
	Liga a hotbar (slots 1..N do inventário) às Tools do Roblox.

	O client só pede "equipa o slot 3". Quem lê o inventário, decide se aquele
	item é equipável e materializa a Tool é o servidor — o client nunca cria
	Tool nem escolhe qual arma recebe.

	Local: src/server/Services/ToolService.luau

	SETUP:
		ServerStorage/
			Tools/
				LaserPistol   <- Tool (o nome bate com o toolTemplate do item
				                 em InventoryModule.Items)
]]

local Knit = require(game:GetService("ReplicatedStorage").Packages.Knit)
local Players = game:GetService("Players")
local ServerStorage = game:GetService("ServerStorage")

local InventoryModule = require(game:GetService("ReplicatedStorage").Shared.InventoryModule)

local TOOL_FOLDER = "Tools"

-- Atributo que marca de qual item do inventário aquela Tool nasceu.
-- É como o serviço reconhece Tools que ele mesmo entregou.
local SOURCE_ATTRIBUTE = "HotbarItemId"

local ToolService = Knit.CreateService({
	Name = "ToolService",

	Client = {
		-- server → client: (slotIndex: number) — 0 significa "nada equipado"
		SlotEquipped = Knit.CreateSignal(),
	},

	_equipped = {} :: { [number]: number },
})

-- ═══════════════════════════════════════════════════════════
-- Helpers
-- ═══════════════════════════════════════════════════════════

local function getHumanoid(player: Player): Humanoid?
	local character = player.Character
	if not character then
		return nil
	end
	return character:FindFirstChildOfClass("Humanoid")
end

--- Backpack e personagem: os dois lugares onde uma Tool do jogador pode estar.
local function getToolContainers(player: Player): { Instance }
	local containers = {}

	local backpack = player:FindFirstChildOfClass("Backpack")
	if backpack then
		table.insert(containers, backpack)
	end

	if player.Character then
		table.insert(containers, player.Character)
	end

	return containers
end

function ToolService:_getTemplate(itemId: string): Tool?
	local templateName = InventoryModule.GetToolTemplate(itemId)
	if not templateName then
		return nil
	end

	local folder = ServerStorage:FindFirstChild(TOOL_FOLDER)
	if not folder then
		warn(string.format("[ToolService] ServerStorage.%s não existe", TOOL_FOLDER))
		return nil
	end

	local template = folder:FindFirstChild(templateName)
	if not template or not template:IsA("Tool") then
		warn(string.format("[ToolService] Tool '%s' não encontrada em ServerStorage.%s", templateName, TOOL_FOLDER))
		return nil
	end

	return template
end

function ToolService:_findTool(player: Player, itemId: string): Tool?
	for _, container in getToolContainers(player) do
		for _, child in container:GetChildren() do
			if child:IsA("Tool") and child:GetAttribute(SOURCE_ATTRIBUTE) == itemId then
				return child
			end
		end
	end
	return nil
end

function ToolService:_findOrCreateTool(player: Player, itemId: string): Tool?
	local existing = self:_findTool(player, itemId)
	if existing then
		return existing
	end

	local backpack = player:FindFirstChildOfClass("Backpack")
	if not backpack then
		return nil
	end

	local template = self:_getTemplate(itemId)
	if not template then
		return nil
	end

	local tool = template:Clone()
	tool:SetAttribute(SOURCE_ATTRIBUTE, itemId)
	tool.Parent = backpack

	return tool
end

--- Destrói Tools cujo item saiu da hotbar (gastou, moveu, dropou).
--- Sem isso a arma continuaria equipável depois do item sumir do inventário.
function ToolService:_purgeUnbacked(player: Player)
	local backed = {}

	for i = 1, InventoryModule.HOTBAR_SLOTS do
		local slot = self._inventory:GetSlot(player, i)
		if slot then
			backed[slot.itemId] = true
		end
	end

	for _, container in getToolContainers(player) do
		for _, child in container:GetChildren() do
			local sourceId = child:IsA("Tool") and child:GetAttribute(SOURCE_ATTRIBUTE)
			if sourceId and not backed[sourceId] then
				child:Destroy()
			end
		end
	end
end

-- ═══════════════════════════════════════════════════════════
-- API
-- ═══════════════════════════════════════════════════════════

function ToolService:Unequip(player: Player): number
	local humanoid = getHumanoid(player)
	if humanoid then
		humanoid:UnequipTools()
	end

	self._equipped[player.UserId] = nil
	self.Client.SlotEquipped:Fire(player, 0)

	return 0
end

--- Equipa o item da hotbar naquele slot. Apertar o slot já equipado desequipa.
--- Retorna o slot que ficou equipado (0 = nenhum).
function ToolService:EquipSlot(player: Player, slotIndex: number): number
	if typeof(slotIndex) ~= "number" or slotIndex ~= slotIndex then
		return self:Unequip(player)
	end

	slotIndex = math.floor(slotIndex)

	if slotIndex < 1 or slotIndex > InventoryModule.HOTBAR_SLOTS then
		return self:Unequip(player)
	end

	local humanoid = getHumanoid(player)
	if not humanoid or humanoid.Health <= 0 then
		return self:Unequip(player)
	end

	-- Toggle: apertar de novo a mesma tecla guarda a arma
	if self._equipped[player.UserId] == slotIndex then
		return self:Unequip(player)
	end

	self:_purgeUnbacked(player)

	local slot = self._inventory:GetSlot(player, slotIndex)
	if not slot then
		return self:Unequip(player)
	end

	local tool = self:_findOrCreateTool(player, slot.itemId)
	if not tool then
		-- Item não equipável (minério, poção...): não é erro, só não faz nada
		return self:Unequip(player)
	end

	humanoid:EquipTool(tool)

	self._equipped[player.UserId] = slotIndex
	self.Client.SlotEquipped:Fire(player, slotIndex)

	return slotIndex
end

function ToolService:GetEquippedSlot(player: Player): number
	return self._equipped[player.UserId] or 0
end

-- ═══════════════════════════════════════════════════════════
-- Client
-- ═══════════════════════════════════════════════════════════

function ToolService.Client:EquipSlot(player: Player, slotIndex: number): number
	return self.Server:EquipSlot(player, slotIndex)
end

function ToolService.Client:GetEquippedSlot(player: Player): number
	return self.Server:GetEquippedSlot(player)
end

-- ═══════════════════════════════════════════════════════════
-- Knit Lifecycle
-- ═══════════════════════════════════════════════════════════

function ToolService:KnitInit()
	local function bindPlayer(player: Player)
		-- Morrer destrói a Tool junto com o personagem: o estado tem que zerar,
		-- senão a tecla do slot vira toggle-desequipa numa arma que não existe.
		player.CharacterAdded:Connect(function()
			self._equipped[player.UserId] = nil
			self.Client.SlotEquipped:Fire(player, 0)
		end)
	end

	Players.PlayerAdded:Connect(bindPlayer)
	for _, player in Players:GetPlayers() do
		bindPlayer(player)
	end

	Players.PlayerRemoving:Connect(function(player)
		self._equipped[player.UserId] = nil
	end)
end

function ToolService:KnitStart()
	self._inventory = Knit.GetService("InventoryService")

	if not ServerStorage:FindFirstChild(TOOL_FOLDER) then
		warn(string.format(
			"[ToolService] ServerStorage.%s não existe — nenhum item vai equipar até criar a pasta",
			TOOL_FOLDER
		))
	end
end

return ToolService
