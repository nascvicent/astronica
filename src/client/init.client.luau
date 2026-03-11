local Knit = require(game:GetService("ReplicatedStorage").Packages.Knit)

-- Controllers
require(script.Controllers.LumenController)
require(script.Controllers.InventoryController)

-- Start Knit
Knit.Start():catch(warn):await()
print("[Client] Knit started successfully")
