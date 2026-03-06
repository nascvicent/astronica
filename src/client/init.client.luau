local Knit = require(game:GetService("ReplicatedStorage").Packages.Knit)

-- Controllers
require(script.Controllers.LumenController)

-- Start Knit
Knit.Start():catch(warn):await()
print("[Client] Knit started successfully")
