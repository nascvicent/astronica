local Knit = require(game:GetService("ReplicatedStorage").Packages.Knit)

-- Services
require(script.Services.LumenService)

-- Start Knit
Knit.Start():catch(warn):await()
print("[Server] Knit started successfully")
