local Knit = require(game:GetService("ReplicatedStorage").Packages.Knit)

-- Controllers
require(script.Controllers.LumenController)
require(script.Controllers.InventoryController)
require(script.Controllers.HealthController)
require(script.Controllers.LaserToolController)
require(script.Controllers.SprintController)
require(script.Controllers.ShipController)
require(script.Controllers.MapController)
require(script.Controllers.HangarAmbienceController)

-- Start Knit
Knit.Start():catch(warn):await()
print("[Client] Knit started successfully")
