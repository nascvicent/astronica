local Knit = require(game:GetService("ReplicatedStorage").Packages.Knit)
local Players = game:GetService("Players")
local DataStoreService = game:GetService("DataStoreService")

local DATASTORE_NAME = "PlayerLumens"
local KEY_PREFIX = "lumens_v1_"
local DEFAULT_LUMENS = 0
local AUTO_SAVE_INTERVAL = 300

-- Jogador que recebe 5000 LUM ao entrar (teste)
local TEST_PLAYER = "einsteinburro"
local TEST_GRANT = 1

local lumenStore = DataStoreService:GetDataStore(DATASTORE_NAME)

local function makeKey(userId: number): string
	return KEY_PREFIX .. tostring(userId)
end

local LumenService = Knit.CreateService({
	Name = "LumenService",

	Client = {
		LumensChanged = Knit.CreateSignal(),
	},

	_lumenData = {} :: { [number]: number },
	_dataLoaded = {} :: { [number]: boolean },
})

function LumenService:AddLumens(player: Player, amount: number): number
    assert(amount >= 0, "AddLumens amount must be non-negative")
    local userId = player.UserId
    local current = self._lumenData[userId] or 0
    local newAmount = current + amount
    
    self._lumenData[userId] = newAmount
    self.Client.LumensChanged:Fire(player, newAmount)
    self:_updateLeaderstats(player, newAmount) -- <--- ADICIONE AQUI
    
    return newAmount
end

function LumenService:RemoveLumens(player: Player, amount: number): number
    assert(amount >= 0, "RemoveLumens amount must be non-negative")
    local userId = player.UserId
    local current = self._lumenData[userId] or 0
    local newAmount = math.max(0, current - amount)
    
    self._lumenData[userId] = newAmount
    self.Client.LumensChanged:Fire(player, newAmount)
    self:_updateLeaderstats(player, newAmount) -- <--- ADICIONE AQUI
    
    return newAmount
end

function LumenService:GetLumens(player: Player): number
	return self._lumenData[player.UserId] or 0
end

function LumenService.Client:GetLumens(player: Player): number
    -- Espera os dados do jogador carregarem antes de responder ao cliente
    while not self.Server._dataLoaded[player.UserId] do
        -- Se o jogador sair do jogo enquanto carrega, cancela e retorna 0
        if not player:IsDescendantOf(game) then return 0 end
        task.wait(0.1)
    end
    
    return self.Server:GetLumens(player)
end

function LumenService:_loadPlayerData(player: Player)
	local userId = player.UserId
	local key = makeKey(userId)
	local success, result

	for attempt = 1, 3 do
		success, result = pcall(function()
			return lumenStore:GetAsync(key)
		end)

		if success then
			break
		end

		warn(string.format("[LumenService] Load attempt %d failed for %s: %s", attempt, player.Name, tostring(result)))

		if attempt < 3 then
			task.wait(2 ^ attempt)
		end
	end

	if not player:IsDescendantOf(game) then
		return
	end

	local lumens = if success and result ~= nil then result else DEFAULT_LUMENS
	self._lumenData[userId] = lumens
	self._dataLoaded[userId] = true

	local leaderstats = Instance.new("Folder")
    leaderstats.Name = "leaderstats" -- O nome TEM que ser esse, em minúsculo
    leaderstats.Parent = player

    local lumensValue = Instance.new("IntValue")
    lumensValue.Name = "LUM" -- Este é o nome que vai aparecer na tabela no topo da tela
    lumensValue.Value = lumens
    lumensValue.Parent = leaderstats
    -- ==========================================

    self.Client.LumensChanged:Fire(player, lumens)

    -- Grant de teste para o dono
    if player.Name == TEST_PLAYER then
        self:AddLumens(player, TEST_GRANT)
        print(string.format("[LumenService] Granted %d LUM to %s (test)", TEST_GRANT, player.Name))
    end
end

function LumenService:_savePlayerData(userId: number)
	if not self._dataLoaded[userId] then
		return
	end

	local key = makeKey(userId)
	local lumens = self._lumenData[userId]

	local success, err = pcall(function()
		lumenStore:SetAsync(key, lumens)
	end)

	if not success then
		warn(string.format("[LumenService] Save failed for userId %d: %s", userId, tostring(err)))
	end
end

function LumenService:_saveAllData()
	for userId in self._lumenData do
		self:_savePlayerData(userId)
	end
end


function LumenService:_updateLeaderstats(player: Player, amount: number)
    local leaderstats = player:FindFirstChild("leaderstats")
    if leaderstats then
        local lumensValue = leaderstats:FindFirstChild("LUM")
        if lumensValue then
            lumensValue.Value = amount
        end
    end
end

function LumenService:KnitInit()
	Players.PlayerAdded:Connect(function(player)
		self:_loadPlayerData(player)
	end)

	Players.PlayerRemoving:Connect(function(player)
		local userId = player.UserId
		self:_savePlayerData(userId)
		self._lumenData[userId] = nil
		self._dataLoaded[userId] = nil
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

function LumenService:KnitStart()
	task.spawn(function()
		while true do
			task.wait(AUTO_SAVE_INTERVAL)
			self:_saveAllData()
		end
	end)
end

return LumenService
