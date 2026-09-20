--[[
	PlayerDataService
	Dono único do save do jogador: uma chave por jogador (PlayerData_v1_{userId}).

	Por que não um DataStore por sistema: vários SetAsync concorrentes no
	PlayerRemoving, sem ordem garantida. Aqui é um documento só.

	Session lock: o jogo teleporta entre Places (Hub ↔ planeta). Sem trava, o
	Place de destino lê o save antes do Place de origem terminar de gravar, e
	o upgrade feito segundos antes some. O load marca o documento com o JobId
	deste servidor e espera a trava do outro ser liberada (ou expirar, se o
	servidor caiu). O save só grava se a trava ainda for nossa.

	Hoje guarda naves e trajes. Inventário e Lúmens ainda têm DataStore
	próprio; migrar os dois pra cá é o passo seguinte natural.

	Local: src/server/Services/PlayerDataService.luau
]]

local Knit = require(game:GetService("ReplicatedStorage").Packages.Knit)
local Players = game:GetService("Players")
local DataStoreService = game:GetService("DataStoreService")
local HttpService = game:GetService("HttpService")

local ShipData = require(game:GetService("ReplicatedStorage").Shared.ShipData)

local DATASTORE_NAME = "PlayerData"
local KEY_PREFIX = "PlayerData_v1_"
local AUTO_SAVE_INTERVAL = 60

-- Trava sem renovação há mais que isso é de servidor morto e pode ser tomada.
-- Precisa ser bem maior que AUTO_SAVE_INTERVAL, que é quem renova.
local LOCK_EXPIRY = 180
local LOCK_RETRY_DELAY = 4
local LOAD_RETRIES = 3

local SCHEMA_VERSION = 1

-- id antigo → id atual
-- Sempre pro id ATUAL, nunca em cadeia: a ordem de um dicionário não é
-- garantida e a migração poderia parar no meio do caminho
local RENAMED_SHIPS = {
	pod = "dispatcher",
}

-- JobId é vazio no Studio: um id por servidor evita que duas sessões de teste
-- se considerem a mesma
local SESSION_ID = if game.JobId ~= "" then game.JobId else "studio_" .. HttpService:GenerateGUID(false)

local store = DataStoreService:GetDataStore(DATASTORE_NAME)

local function makeKey(userId: number): string
	return KEY_PREFIX .. tostring(userId)
end

local PlayerDataService = Knit.CreateService({
	Name = "PlayerDataService",
	Client = {},

	_profiles = {} :: { [number]: any },
	_loaded = {} :: { [number]: boolean },
	-- Load falhou: o perfil em memória é padrão, não o save real. Nunca gravar.
	_loadFailed = {} :: { [number]: boolean },
	-- Lista simples em vez de BindableEvent: o Fire dele copia tabelas, e quem
	-- recebesse o perfil estaria alterando uma cópia que nunca é salva
	_loadedCallbacks = {} :: { (Player, any) -> () },
})

-- ═══════════════════════════════════════════════════════════
-- Schema + migração
-- ═══════════════════════════════════════════════════════════

local function defaultProfile()
	return {
		version = SCHEMA_VERSION,
		ships = {
			equipped = ShipData.DEFAULT_SHIP,
			owned = {
				[ShipData.DEFAULT_SHIP] = ShipData.DefaultModuleLevels(ShipData.DEFAULT_SHIP),
			},
		},
		suits = {
			equipped = "pathfinder",
			owned = { "pathfinder" },
		},
	}
end

--- Leva qualquer formato antigo pro schema atual. Nunca falha: campo estranho
--- vira padrão em vez de derrubar o load.
local function migrate(data: any)
	if typeof(data) ~= "table" then
		return defaultProfile()
	end

	local defaults = defaultProfile()

	-- Schema antigo: ship = { model, engine, tank }. tank sai, engine fica.
	if typeof(data.ship) == "table" then
		local old = data.ship
		data.ships = data.ships or { owned = {} }
		data.ships.owned = data.ships.owned or {}

		local shipId = if ShipData.IsValidShip(old.model) then old.model else ShipData.DEFAULT_SHIP
		local levels = data.ships.owned[shipId] or ShipData.DefaultModuleLevels(shipId)
		if typeof(old.engine) == "number" then
			levels.engine = old.engine
		end
		data.ships.owned[shipId] = levels
		data.ships.equipped = data.ships.equipped or shipId
	end
	data.ship = nil

	-- Fuel foi removido do jogo
	data.fuel = nil

	if typeof(data.ships) ~= "table" then
		data.ships = defaults.ships
	end
	if typeof(data.ships.owned) ~= "table" then
		data.ships.owned = {}
	end
	if typeof(data.suits) ~= "table" then
		data.suits = defaults.suits
	end

	for _, entry in data.ships.owned do
		if typeof(entry) == "table" then
			entry.fuel = nil
			entry.tank = nil
		end
	end

	-- Ids renomeados: o progresso acompanha a nave
	for oldId, newId in RENAMED_SHIPS do
		local owned = data.ships.owned
		if typeof(owned[oldId]) == "table" and owned[newId] == nil then
			owned[newId] = owned[oldId]
		end
		owned[oldId] = nil
		if data.ships.equipped == oldId then
			data.ships.equipped = newId
		end
	end

	data.version = SCHEMA_VERSION
	return data
end

--- Regras que dependem do catálogo atual. Rodam em todo load, porque o
--- catálogo muda entre versões do jogo.
--- Id órfão (nave removida/renomeada) fica no save, intocado: se a nave voltar,
--- o progresso volta junto. Só é ignorado em runtime pelo ShipService.
local function reconcile(data)
	local owned = data.ships.owned

	-- Ninguém fica sem nave
	if typeof(owned[ShipData.DEFAULT_SHIP]) ~= "table" then
		owned[ShipData.DEFAULT_SHIP] = ShipData.DefaultModuleLevels(ShipData.DEFAULT_SHIP)
	end

	for shipId, levels in owned do
		if ShipData.IsValidShip(shipId) and typeof(levels) == "table" then
			for _, moduleId in ShipData.MODULE_ORDER do
				levels[moduleId] = ShipData.ClampModuleLevel(shipId, moduleId, levels[moduleId])
			end
			if typeof(levels.skin) ~= "string" then
				levels.skin = "default"
			end
		end
	end

	local equipped = data.ships.equipped
	if not ShipData.IsValidShip(equipped) or typeof(owned[equipped]) ~= "table" then
		data.ships.equipped = ShipData.DEFAULT_SHIP
	end
end

-- ═══════════════════════════════════════════════════════════
-- API pública (server)
-- ═══════════════════════════════════════════════════════════

--- Perfil em memória, ou nil se ainda não carregou. Quem altera o perfil
--- altera direto nesta tabela: o próximo save grava.
function PlayerDataService:GetProfile(player: Player)
	return self._profiles[player.UserId]
end

function PlayerDataService:IsLoaded(player: Player): boolean
	return self._loaded[player.UserId] == true
end

--- Espera o perfil carregar. Retorna nil se o jogador sair antes.
function PlayerDataService:WaitForProfile(player: Player)
	while not self._loaded[player.UserId] do
		if not player:IsDescendantOf(game) then
			return nil
		end
		task.wait(0.1)
	end
	return self._profiles[player.UserId]
end

--- callback(player, profile) — dispara pra cada perfil carregado, inclusive
--- os que já estavam carregados quando alguém se inscreveu.
function PlayerDataService:OnProfileLoaded(callback: (Player, any) -> ())
	for userId, profile in self._profiles do
		local player = Players:GetPlayerByUserId(userId)
		if player and self._loaded[userId] then
			task.spawn(callback, player, profile)
		end
	end
	table.insert(self._loadedCallbacks, callback)
end

-- ═══════════════════════════════════════════════════════════
-- Load / save
-- ═══════════════════════════════════════════════════════════

--- Tenta pegar a trava e ler o documento numa transação só.
--- Retorna ("ok", data) | ("locked", nil) | ("error", err)
local function acquire(key: string)
	local lockedByOther = false

	local ok, result = pcall(function()
		return store:UpdateAsync(key, function(old)
			-- O transform pode rodar mais de uma vez: o resultado é o da última
			lockedByOther = false
			local now = os.time()
			if typeof(old) == "table" and typeof(old.session) == "table" then
				local session = old.session
				local fresh = typeof(session.updatedAt) == "number" and now - session.updatedAt < LOCK_EXPIRY
				if session.id ~= SESSION_ID and fresh then
					lockedByOther = true
					return nil -- cancela a escrita
				end
			end

			local data = if typeof(old) == "table" then old else defaultProfile()
			data.session = { id = SESSION_ID, updatedAt = now }
			return data
		end)
	end)

	if not ok then
		return "error", result
	end
	if lockedByOther then
		return "locked", nil
	end
	return "ok", result
end

function PlayerDataService:_load(player: Player)
	local userId = player.UserId
	local key = makeKey(userId)

	local data = nil
	local failed = false
	local errors = 0
	local lockWaitStart = os.clock()

	while player:IsDescendantOf(game) do
		local status, result = acquire(key)

		if status == "ok" then
			data = result
			break
		elseif status == "locked" then
			-- Outro servidor ainda está gravando (teleporte) ou caiu. Espera
			-- até a trava expirar, que é o pior caso.
			if os.clock() - lockWaitStart > LOCK_EXPIRY + 10 then
				warn(string.format("[PlayerDataService] Trava de %s não liberou — sessão sem save", player.Name))
				failed = true
				break
			end
			task.wait(LOCK_RETRY_DELAY)
		else
			errors += 1
			warn(string.format("[PlayerDataService] Load attempt %d failed for %s: %s", errors, player.Name, tostring(result)))
			if errors >= LOAD_RETRIES then
				failed = true
				break
			end
			task.wait(2 ^ errors)
		end
	end

	if not player:IsDescendantOf(game) then
		-- Saiu no meio do load: se pegamos a trava, solta
		if data then
			self:_release(userId)
		end
		return
	end

	if failed or not data then
		data = defaultProfile()
		self._loadFailed[userId] = true
		warn(string.format("[PlayerDataService] Load FAILED for %s — perfil desta sessão não será salvo", player.Name))
	end

	data = migrate(data)
	reconcile(data)

	self._profiles[userId] = data
	self._loaded[userId] = true
	for _, callback in self._loadedCallbacks do
		task.spawn(callback, player, data)
	end

	print(string.format("[PlayerDataService] Loaded %s (nave: %s)", player.Name, tostring(data.ships.equipped)))
end

--- Grava o perfil se a trava ainda for nossa. release = true solta a trava.
function PlayerDataService:_save(userId: number, release: boolean): boolean
	if not self._loaded[userId] or self._loadFailed[userId] then
		return false
	end

	local profile = self._profiles[userId]
	if not profile then
		return false
	end

	local lost = false
	local ok, err = pcall(function()
		store:UpdateAsync(makeKey(userId), function(old)
			lost = false
			if typeof(old) == "table" and typeof(old.session) == "table" and old.session.id ~= SESSION_ID then
				-- Outro servidor tomou a trava (a nossa expirou): gravar por cima
				-- apagaria o progresso feito lá
				lost = true
				return nil
			end

			profile.session = if release then nil else { id = SESSION_ID, updatedAt = os.time() }
			return profile
		end)
	end)

	if not ok then
		warn(string.format("[PlayerDataService] Save failed for userId %d: %s", userId, tostring(err)))
		return false
	end
	if lost then
		warn(string.format("[PlayerDataService] Save skipped for userId %d — trava pertence a outro servidor", userId))
		return false
	end
	return true
end

--- Solta a trava sem mexer no conteúdo (jogador saiu antes do load terminar).
function PlayerDataService:_release(userId: number)
	pcall(function()
		store:UpdateAsync(makeKey(userId), function(old)
			if typeof(old) == "table" and typeof(old.session) == "table" and old.session.id == SESSION_ID then
				old.session = nil
				return old
			end
			return nil
		end)
	end)
end

function PlayerDataService:_unload(player: Player)
	local userId = player.UserId
	self:_save(userId, true)
	self._profiles[userId] = nil
	self._loaded[userId] = nil
	self._loadFailed[userId] = nil
end

-- ═══════════════════════════════════════════════════════════
-- Knit Lifecycle
-- ═══════════════════════════════════════════════════════════

function PlayerDataService:KnitInit()
	Players.PlayerAdded:Connect(function(player)
		self:_load(player)
	end)

	Players.PlayerRemoving:Connect(function(player)
		self:_unload(player)
	end)

	for _, player in Players:GetPlayers() do
		task.spawn(function()
			self:_load(player)
		end)
	end

	game:BindToClose(function()
		local pending = 0
		for _, player in Players:GetPlayers() do
			pending += 1
			task.spawn(function()
				self:_unload(player)
				pending -= 1
			end)
		end
		local deadline = os.clock() + 25
		while pending > 0 and os.clock() < deadline do
			task.wait(0.1)
		end
	end)
end

function PlayerDataService:KnitStart()
	task.spawn(function()
		while true do
			task.wait(AUTO_SAVE_INTERVAL)
			for userId in self._profiles do
				task.spawn(function()
					self:_save(userId, false)
				end)
			end
		end
	end)
end

return PlayerDataService
