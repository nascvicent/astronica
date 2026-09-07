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

local InventoryService = Knit.CreateService({
	Name = "InventoryService",

	Client = {
		InventoryChanged = Knit.CreateSignal(),
		SlotUpdated = Knit.CreateSignal(),
		ToggleHUD = Knit.CreateSignal(), -- (show: boolean)
	},

	_inventoryData = {} :: { [number]: { slots: { [number]: any }, maxSlots: number } },
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
		return { slots = {}, maxSlots = InventoryModule.DEFAULT_SLOTS }
	end
	return { slots = data.slots, maxSlots = data.maxSlots }
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
	else
		data = {
			slots = {},
			maxSlots = InventoryModule.DEFAULT_SLOTS,
		}
	end

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
