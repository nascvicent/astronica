local Knit = require(game:GetService("ReplicatedStorage").Packages.Knit)
local Players = game:GetService("Players")

-- Services
require(script.Services.LumenService)
require(script.Services.InventoryService)
require(script.Services.HealthService)

-- Start Knit
Knit.Start():catch(warn):await()
print("[Server] Knit started successfully")

-- ============================================================
-- TEST: toque na Part "Teste" para adicionar itens + tirar vida
-- ============================================================
task.spawn(function()
	local testPart = workspace:FindFirstChild("Teste")
	if not testPart then return end

	local InventoryService = Knit.GetService("InventoryService")
	local debounce = {}

	testPart.Touched:Connect(function(hit)
		local character = hit:FindFirstAncestorOfClass("Model")
		if not character then return end

		local player = Players:GetPlayerFromCharacter(character)
		if not player then return end

		if debounce[player.UserId] then return end
		debounce[player.UserId] = true

		-- Adiciona 5 iron_ore ao inventário
		local ok, msg = InventoryService:AddItem(player, "iron_ore", 5)
		print(string.format("[TestTouch] %s — AddItem iron_ore x5: %s (%s)", player.Name, tostring(ok), msg))

		-- Tira 20 de vida
		local humanoid = character:FindFirstChildOfClass("Humanoid")
		if humanoid then
			humanoid:TakeDamage(20)
			print(string.format("[TestTouch] %s — HP: %.0f/%.0f", player.Name, humanoid.Health, humanoid.MaxHealth))
		end

		task.wait(3)
		debounce[player.UserId] = nil
	end)

	print("[TestTouch] Pronto — toque na Part 'Teste' para testar")
end)
