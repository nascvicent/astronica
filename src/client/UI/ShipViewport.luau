--[[
	ShipViewport
	Modelo da nave dentro de ViewportFrame (cards do hangar, menu, inventário)
	e cópia estática no pedestal do hangar.

	O modelo sai sempre de ReplicatedStorage/Assets/ShipModels/<modelName>,
	pelo ShipData — nunca por caminho fixo na UI.

	Local: src/client/UI/ShipViewport.luau
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local ShipData = require(ReplicatedStorage.Shared.ShipData)

local ShipViewport = {}

local VIEW_FOV = 30
local VIEW_DIR = Vector3.new(0.75, 0.45, -1).Unit -- 3/4 de frente, de cima
local VIEW_PADDING = 1.08

local function getTemplate(shipId: string): Model?
	local def = ShipData.GetShip(shipId)
	local assets = ReplicatedStorage:FindFirstChild(ShipData.ASSETS_FOLDER)
	local folder = assets and assets:FindFirstChild(ShipData.MODELS_FOLDER)
	if not def or not folder then
		return nil
	end

	local template = folder:FindFirstChild(def.modelName)
	if not template then
		-- Mesmo fallback do servidor: nave padrão e, se nem ela, qualquer modelo
		local default = ShipData.GetShip(ShipData.DEFAULT_SHIP)
		template = default and folder:FindFirstChild(default.modelName)
		if not (template and template:IsA("Model")) then
			template = folder:FindFirstChildWhichIsA("Model")
		end
	end
	return if template and template:IsA("Model") then template else nil
end

--- Cópia inerte: sem scripts, prompts, som, física nem colisão.
function ShipViewport.CreateModel(shipId: string): Model?
	local template = getTemplate(shipId)
	if not template then
		return nil
	end

	local model = template:Clone()
	for _, inst in model:GetDescendants() do
		if inst:IsA("BasePart") then
			inst.Anchored = true
			inst.CanCollide = false
			inst.CanQuery = false
			inst.CanTouch = false
			inst.CastShadow = false
			if inst:IsA("Seat") or inst:IsA("VehicleSeat") then
				inst.Disabled = true
			end
		elseif inst:IsA("LuaSourceContainer") or inst:IsA("ProximityPrompt") or inst:IsA("Sound")
			or inst:IsA("ParticleEmitter") or inst:IsA("BillboardGui") or inst:IsA("SurfaceGui")
			or inst:IsA("Constraint") or inst:IsA("JointInstance") or inst:IsA("BodyMover")
		then
			inst:Destroy()
		end
	end

	model.Name = "Preview_" .. shipId
	return model
end

--- Nave centralizada na origem dentro do viewport, câmera enquadrando.
--- Retorna o Model (pra girar com PivotTo) ou nil.
function ShipViewport.Mount(viewport: ViewportFrame, shipId: string): Model?
	ShipViewport.Clear(viewport)

	local model = ShipViewport.CreateModel(shipId)
	if not model then
		return nil
	end

	local boxCf, size = model:GetBoundingBox()
	model.PrimaryPart = nil
	model.WorldPivot = CFrame.new(boxCf.Position)
	model:PivotTo(CFrame.new())
	model.Parent = viewport

	-- Gira em Y: enquadra o cilindro varrido pelo giro
	local radius = math.max(math.sqrt(size.X * size.X + size.Z * size.Z) / 2, size.Y / 2)
	local distance = radius / math.tan(math.rad(VIEW_FOV / 2)) * VIEW_PADDING

	local cam = Instance.new("Camera")
	cam.FieldOfView = VIEW_FOV
	cam.CFrame = CFrame.lookAt(VIEW_DIR * distance, Vector3.zero)
	cam.Parent = viewport
	viewport.CurrentCamera = cam

	return model
end

function ShipViewport.Clear(viewport: ViewportFrame)
	viewport.CurrentCamera = nil
	for _, child in viewport:GetChildren() do
		if child:IsA("Model") or child:IsA("BasePart") or child:IsA("Camera") then
			child:Destroy()
		end
	end
end

function ShipViewport.Style(viewport: ViewportFrame)
	viewport.BackgroundTransparency = 1
	viewport.Ambient = Color3.fromRGB(150, 152, 158)
	viewport.LightColor = Color3.fromRGB(255, 255, 255)
	viewport.LightDirection = Vector3.new(-0.4, -1, -0.6)
end

return ShipViewport
