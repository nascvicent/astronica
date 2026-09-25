local Knit = require(game:GetService("ReplicatedStorage").Packages.Knit)
local Players = game:GetService("Players")
local DataStoreService = game:GetService("DataStoreService")

local InventoryModule = require(game:GetService("ReplicatedStorage").Shared.InventoryModule)

local DATASTORE_NAME = "PlayerInventory"
local KEY_PREFIX = "inv_v1_"
local AUTO_SAVE_INTERVAL = 300

local inventoryStore = DataStoreService:GetDataStore(DATASTORE_NAME)

local function makeKey(userId: number): string
	return KEY_PREFIX .. tostring(userId)
end

--- Saves antigos foram criados com mais slots do que a mochila dá. Traz o que
--- estava além do limite para espaços livres dentro dele; se não couber tudo,
--- mantém o tamanho antigo em vez de sumir com item do jogador.
local function shrinkToSlots(data, limit: number, playerName: string)
	if data.maxSlots <= limit then
		return
	end

	local overflow = {}
	for index in data.slots do
		local n = tonumber(index)
		if n and n > limit then
			table.insert(overflow, index)
		end
	end
	table.sort(overflow, function(a, b)
		return tonumber(a) < tonumber(b)
	end)

	local free = 1
	for _, index in overflow do
		while free <= limit and data.slots[free] do
			free += 1
		end

		if free > limit then
			warn(string.format(
				"[InventoryService] %s tem itens demais para %d slots — mantendo %d",
				playerName,
				limit,
				data.maxSlots
			))
			return
		end

		data.slots[free] = data.slots[index]
		data.slots[index] = nil
	end

	data.maxSlots = limit
end

local InventoryService = Knit.CreateService({
	Name = "InventoryService",

	Client = {
		InventoryChanged = Knit.CreateSignal(),
		SlotUpdated = Knit.CreateSignal(),
		ToggleHUD = Knit.CreateSignal(), -- (show: boolean)
	},

	-- backpackLevel mora aqui (e não no PlayerDataService) pra andar sempre
	-- junto com o maxSlots que ele define
	_inventoryData = {} :: { [number]: { slots: { [number]: any }, maxSlots: number, backpackLevel: number } },
	_dataLoaded = {} :: { [number]: boolean },

	-- Jogadores cujo GetAsync falhou: têm inventário vazio em memória que NÃO
	-- representa o save real, então gravar por cima apagaria o inventário deles.
	_loadFailed = {} :: { [number]: boolean },
})

-- ============================================================
-- Client methods (RemoteFunctions)
-- ============================================================

function InventoryService.Client:GetInventory(player: Player)
	while not self.Server._dataLoaded[player.UserId] do
		if not player:IsDescendantOf(game) then
			return { slots = {}, maxSlots = InventoryModule.DEFAULT_SLOTS }
		end
		task.wait(0.1)
	end

	return self.Server:GetInventory(player)
end

function InventoryService.Client:MoveItem(player: Player, fromSlot: number, toSlot: number): (boolean, string)
	if typeof(fromSlot) ~= "number" or typeof(toSlot) ~= "number" then
		return false, "Invalid slot index"
	end

	if fromSlot ~= fromSlot or toSlot ~= toSlot then
		return false, "Invalid slot index"
	end

	-- O MoveItem do servidor já valida os limites contra o maxSlots do jogador
	return self.Server:MoveItem(player, math.floor(fromSlot), math.floor(toSlot))
end

function InventoryService.Client:DeleteSlot(player: Player, slotIndex: any): (boolean, string)
	if typeof(slotIndex) ~= "number" or slotIndex ~= slotIndex then
		return false, "Invalid slot index"
	end
	return self.Server:DeleteSlot(player, math.floor(slotIndex))
end

function InventoryService.Client:UpgradeBackpack(player: Player): (boolean, string)
	return self.Server:UpgradeBackpack(player)
end

-- ============================================================
-- Server methods (públicos, usados por outros services)
-- ============================================================

function InventoryService:AddItem(player: Player, itemId: string, quantity: number, metadata: { [string]: any }?): (boolean, string)
	assert(quantity > 0, "AddItem quantity must be positive")

	if not InventoryModule.IsValidItem(itemId) then
		return false, "Invalid item: " .. itemId
	end

	local userId = player.UserId
	local data = self._inventoryData[userId]
	if not data then
		return false, "Player data not loaded"
	end

	local meta = metadata or {}
	local maxStack = InventoryModule.GetMaxStack(itemId)
	local remaining = quantity

	-- Fase 1: empilhar em slots existentes com mesmo itemId + metadata
	for slotIndex, slot in data.slots do
		if remaining <= 0 then
			break
		end

		if slot.itemId == itemId and InventoryModule.MetadataMatch(slot.metadata, meta) then
			local space = maxStack - slot.quantity
			if space > 0 then
				local toAdd = math.min(remaining, space)
				slot.quantity += toAdd
				remaining -= toAdd
				self.Client.SlotUpdated:Fire(player, slotIndex, slot)
			end
		end
	end

	-- Fase 2: usar slots vazios
	if remaining > 0 then
		for slotIndex = 1, data.maxSlots do
			if remaining <= 0 then
				break
			end

			if not data.slots[slotIndex] then
				local toAdd = math.min(remaining, maxStack)
				data.slots[slotIndex] = InventoryModule.CreateSlot(itemId, toAdd, meta)
				remaining -= toAdd
				self.Client.SlotUpdated:Fire(player, slotIndex, data.slots[slotIndex])
			end
		end
	end

	if remaining > 0 then
		return false, string.format("Inventory full — %d items could not be added", remaining)
	end

	return true, "OK"
end

--- Quantas unidades do item ainda cabem (pilhas incompletas + slots vazios).
--- Serve pra entregar só o que cabe, em vez de o AddItem entregar parte e
--- responder falha.
function InventoryService:GetSpaceFor(player: Player, itemId: string, metadata: { [string]: any }?): number
	local data = self._inventoryData[player.UserId]
	if not data or not InventoryModule.IsValidItem(itemId) then
		return 0
	end

	local meta = metadata or {}
	local maxStack = InventoryModule.GetMaxStack(itemId)
	local space = 0
	for slotIndex = 1, data.maxSlots do
		local slot = data.slots[slotIndex]
		if not slot then
			space += maxStack
		elseif slot.itemId == itemId and InventoryModule.MetadataMatch(slot.metadata, meta) then
			space += math.max(maxStack - slot.quantity, 0)
		end
	end
	return space
end

function InventoryService:RemoveItem(player: Player, slotIndex: number, quantity: number): (boolean, string)
	assert(quantity > 0, "RemoveItem quantity must be positive")

	local userId = player.UserId
	local data = self._inventoryData[userId]
	if not data then
		return false, "Player data not loaded"
	end

	local slot = data.slots[slotIndex]
	if not slot then
		return false, "Slot is empty"
	end

	if slot.quantity < quantity then
		return false, string.format("Not enough items (has %d, tried to remove %d)", slot.quantity, quantity)
	end

	slot.quantity -= quantity

	if slot.quantity <= 0 then
		data.slots[slotIndex] = nil
		self.Client.SlotUpdated:Fire(player, slotIndex, nil)
	else
		self.Client.SlotUpdated:Fire(player, slotIndex, slot)
	end

	return true, "OK"
end

function InventoryService:GetInventory(player: Player)
	local data = self._inventoryData[player.UserId]
	if not data then
		return { slots = {}, maxSlots = InventoryModule.DEFAULT_SLOTS, backpackLevel = 1 }
	end
	return { slots = data.slots, maxSlots = data.maxSlots, backpackLevel = data.backpackLevel }
end

--- Descarta a pilha inteira de um slot.
function InventoryService:DeleteSlot(player: Player, slotIndex: number): (boolean, string)
	local data = self._inventoryData[player.UserId]
	if not data then
		return false, "Inventário ainda carregando"
	end

	local slot = data.slots[slotIndex]
	if not slot then
		return false, "Slot vazio"
	end
	if not InventoryModule.CanDelete(slot.itemId) then
		return false, "Este item não pode ser descartado"
	end

	data.slots[slotIndex] = nil
	self.Client.SlotUpdated:Fire(player, slotIndex, nil)

	-- Item da hotbar equipado: a Tool não pode continuar na mão
	Knit.GetService("ToolService"):OnSlotCleared(player, slotIndex)

	return true, "OK"
end

--- Sobe a mochila um nível: mais slots, paga em Lúmens.
function InventoryService:UpgradeBackpack(player: Player): (boolean, string)
	local data = self._inventoryData[player.UserId]
	if not data or self._loadFailed[player.UserId] then
		return false, "Inventário ainda carregando"
	end

	local nextLevel = data.backpackLevel + 1
	local def = InventoryModule.BackpackLevels[nextLevel]
	if not def then
		return false, "Mochila já está no nível máximo"
	end

	local lumens = Knit.GetService("LumenService")
	if lumens:GetLumens(player) < def.price then
		return false, "Lúmens insuficientes"
	end
	lumens:RemoveLumens(player, def.price)

	data.backpackLevel = nextLevel
	data.maxSlots = math.max(data.maxSlots, def.slots)
	player:SetAttribute(InventoryModule.BACKPACK_ATTRIBUTE, nextLevel)
	self.Client.InventoryChanged:Fire(player, data)

	print(string.format("[InventoryService] %s subiu a mochila pro nível %d (%d slots)", player.Name, nextLevel, data.maxSlots))
	return true, "OK"
end

function InventoryService:GetSlot(player: Player, slotIndex: number)
	local data = self._inventoryData[player.UserId]
	if not data then
		return nil
	end
	return data.slots[slotIndex]
end

function InventoryService:MoveItem(player: Player, fromSlot: number, toSlot: number): (boolean, string)
	local userId = player.UserId
	local data = self._inventoryData[userId]
	if not data then
		return false, "Player data not loaded"
	end

	if fromSlot == toSlot then
		return true, "OK"
	end

	if fromSlot < 1 or fromSlot > data.maxSlots or toSlot < 1 or toSlot > data.maxSlots then
		return false, "Invalid slot index"
	end

	local slotA = data.slots[fromSlot]
	local slotB = data.slots[toSlot]

	-- Tentar merge se mesmo item + metadata
	if slotA and slotB and slotA.itemId == slotB.itemId and InventoryModule.MetadataMatch(slotA.metadata, slotB.metadata) then
		local maxStack = InventoryModule.GetMaxStack(slotA.itemId)
		local space = maxStack - slotB.quantity
		if space >= slotA.quantity then
			-- Merge completo
			slotB.quantity += slotA.quantity
			data.slots[fromSlot] = nil
			self.Client.SlotUpdated:Fire(player, fromSlot, nil)
			self.Client.SlotUpdated:Fire(player, toSlot, slotB)
		else
			-- Merge parcial
			slotA.quantity -= space
			slotB.quantity = maxStack
			self.Client.SlotUpdated:Fire(player, fromSlot, slotA)
			self.Client.SlotUpdated:Fire(player, toSlot, slotB)
		end
	else
		-- Swap
		data.slots[fromSlot] = slotB
		data.slots[toSlot] = slotA
		self.Client.SlotUpdated:Fire(player, fromSlot, slotB)
		self.Client.SlotUpdated:Fire(player, toSlot, slotA)
	end

	return true, "OK"
end

function InventoryService:ToggleHUD(player: Player, show: boolean)
	self.Client.ToggleHUD:Fire(player, show)
end

-- ============================================================
-- Persistência (mesmo padrão do LumenService)
-- ============================================================

function InventoryService:_loadPlayerData(player: Player)
	local userId = player.UserId
	local key = makeKey(userId)
	local success, result

	for attempt = 1, 3 do
		success, result = pcall(function()
			return inventoryStore:GetAsync(key)
		end)

		if success then
			break
		end

		warn(string.format("[InventoryService] Load attempt %d failed for %s: %s", attempt, player.Name, tostring(result)))

		if attempt < 3 then
			task.wait(2 ^ attempt)
		end
	end

	if not player:IsDescendantOf(game) then
		return
	end

	local data
	if success and result ~= nil then
		data = result
		-- Garantir que slots e maxSlots existem
		if not data.slots then
			data.slots = {}
		end
		if not data.maxSlots then
			data.maxSlots = InventoryModule.DEFAULT_SLOTS
		end
		data.backpackLevel = InventoryModule.ClampBackpackLevel(data.backpackLevel)
		local slots = InventoryModule.GetBackpackLevel(data.backpackLevel).slots
		-- Mochila maior que o save (nível subiu / tabela mudou): cresce
		data.maxSlots = math.max(data.maxSlots, slots)
		shrinkToSlots(data, slots, player.Name)
	else
		data = {
			slots = {},
			maxSlots = InventoryModule.DEFAULT_SLOTS,
			backpackLevel = 1,
		}
	end
	player:SetAttribute(InventoryModule.BACKPACK_ATTRIBUTE, data.backpackLevel)

	self._inventoryData[userId] = data
	self._dataLoaded[userId] = true

	if not success then
		-- Inventário vazio aqui significa "não consegui ler", não "não tem nada".
		-- O jogo segue jogável, mas esse estado nunca pode virar save.
		self._loadFailed[userId] = true
		warn(string.format(
			"[InventoryService] Load FAILED for %s — inventário desta sessão não será salvo",
			player.Name
		))
	else
		self._loadFailed[userId] = nil
		self:_grantStartingItems(player)
	end

	self.Client.InventoryChanged:Fire(player, data)
	print(string.format("[InventoryService] Loaded inventory for %s (%d slots used)", player.Name, self:_countSlots(userId)))
end

--- Entrega os itens iniciais uma única vez por jogador, marcando no próprio
--- save qual versão da lista ele já recebeu.
function InventoryService:_grantStartingItems(player: Player)
	local data = self._inventoryData[player.UserId]
	if not data then
		return
	end

	if (data.startingItemsVersion or 0) >= InventoryModule.STARTING_ITEMS_VERSION then
		return
	end

	for _, entry in InventoryModule.STARTING_ITEMS do
		local ok, msg = self:AddItem(player, entry.itemId, entry.quantity)
		if not ok then
			warn(string.format(
				"[InventoryService] Starting item %s failed for %s: %s",
				entry.itemId,
				player.Name,
				msg
			))
		end
	end

	data.startingItemsVersion = InventoryModule.STARTING_ITEMS_VERSION

	print(string.format("[InventoryService] Granted starting items to %s", player.Name))
end

function InventoryService:_countSlots(userId: number): number
	local data = self._inventoryData[userId]
	if not data then
		return 0
	end

	local count = 0
	for _ in data.slots do
		count += 1
	end
	return count
end

function InventoryService:_savePlayerData(userId: number)
	if not self._dataLoaded[userId] then
		return
	end

	-- Salvar aqui trocaria o inventário real do jogador por um vazio
	if self._loadFailed[userId] then
		warn(string.format("[InventoryService] Save skipped for userId %d — load had failed", userId))
		return
	end

	local key = makeKey(userId)
	local data = self._inventoryData[userId]

	local success, err = pcall(function()
		inventoryStore:SetAsync(key, data)
	end)

	if not success then
		warn(string.format("[InventoryService] Save failed for userId %d: %s", userId, tostring(err)))
	end
end

function InventoryService:_saveAllData()
	for userId in self._inventoryData do
		self:_savePlayerData(userId)
	end
end

-- ============================================================
-- Knit Lifecycle
-- ============================================================

function InventoryService:KnitInit()
	Players.PlayerAdded:Connect(function(player)
		self:_loadPlayerData(player)
	end)

	Players.PlayerRemoving:Connect(function(player)
		local userId = player.UserId
		self:_savePlayerData(userId)
		self._inventoryData[userId] = nil
		self._dataLoaded[userId] = nil
		self._loadFailed[userId] = nil
	end)

	for _, player in Players:GetPlayers() do
		task.spawn(function()
			self:_loadPlayerData(player)
		end)
	end

	game:BindToClose(function()
		self:_saveAllData()
	end)
end

function InventoryService:KnitStart()
	task.spawn(function()
		while true do
			task.wait(AUTO_SAVE_INTERVAL)
			self:_saveAllData()
		end
	end)
end

return InventoryService
