local Knit = require(game:GetService("ReplicatedStorage").Packages.Knit)

-- Services
require(script.Services.LumenService)
require(script.Services.InventoryService)

-- Start Knit
Knit.Start():catch(warn):await()
print("[Server] Knit started successfully")
