--[[
	ItemModels
	Modelos 3D dos itens, usados nos ViewportFrames do inventário.

	Ordem de busca:
	  1. ReplicatedStorage.ItemModels.<itemId>  (Model ou BasePart feito no Studio)
	  2. builder procedural definido aqui       (fallback: sempre existe algo pra mostrar)

	Pra usar um modelo "de verdade" num item, basta criar a pasta ItemModels em
	ReplicatedStorage e pôr lá dentro um Model com o nome do itemId. Nada aqui
	precisa mudar.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local ItemModels = {}

-- Câmera do viewport: FOV fechado dá menos distorção de perspectiva
local VIEW_FOV = 24
local VIEW_DIR = Vector3.new(0.55, 0.42, 1).Unit  -- ângulo 3/4, levemente de cima
local VIEW_PADDING = 1.05                          -- folga entre o item e a borda
-- Mira um pouco acima do centro do item: assim ele assenta na metade de baixo
-- do slot em vez de ficar colado no topo. Em fração do raio do item.
local VIEW_LOOK_LIFT = 0.08

-- ═══════════════════════════════════════════════════════════
-- Helpers de construção
-- ═══════════════════════════════════════════════════════════

local function newPart(model: Model, size: Vector3, cf: CFrame, color: Color3, shape: Enum.PartType?)
	local part = Instance.new("Part")
	part.Shape = shape or Enum.PartType.Block
	part.Size = size
	part.CFrame = cf
	part.Color = color
	part.Material = Enum.Material.SmoothPlastic
	part.Anchored = true
	part.CanCollide = false
	part.CanQuery = false
	part.CanTouch = false
	part.CastShadow = false
	part.TopSurface = Enum.SurfaceType.Smooth
	part.BottomSurface = Enum.SurfaceType.Smooth
	part.Parent = model
	return part
end

--- Part com SpecialMesh (Prism/Pyramid/Sphere/Wedge...) pra formas que Part.Shape não cobre.
local function newMeshPart(model: Model, size: Vector3, cf: CFrame, color: Color3, meshType: Enum.MeshType)
	local part = newPart(model, size, cf, color)
	local mesh = Instance.new("SpecialMesh")
	mesh.MeshType = meshType
	mesh.Parent = part
	return part
end

local function rad(x: number)
	return math.rad(x)
end

-- Pose dos modelos importados de ReplicatedStorage.ItemModels.
-- Modelo feito no Studio chega na orientação em que foi construído — a pistola,
-- por exemplo, vem em pé, apontando pra cima. Aqui você deita/gira só pro ícone,
-- sem mexer no modelo original. Angles(pitch, yaw, roll) em graus.
-- Não vale para os builders abaixo: esses já nascem posados.
local IMPORT_POSE: { [string]: CFrame } = {
	-- roll -40 inclina o cano em diagonal: -90 deitava a arma no chão, e como o
	-- giro do ícone é no eixo Y ela ficava rodando feito hélice
	laser_pickaxe = CFrame.Angles(0, math.rad(-20), math.rad(-40)),
}

-- ═══════════════════════════════════════════════════════════
-- Builders procedurais por item
-- ═══════════════════════════════════════════════════════════

local GRAY_DARK = Color3.fromRGB(96, 100, 108)
local GRAY = Color3.fromRGB(140, 146, 156)
local GRAY_LIGHT = Color3.fromRGB(196, 202, 212)

local BUILDERS: { [string]: (Model) -> () } = {}

-- Minério: aglomerado de blocos tortos com veios claros
BUILDERS.iron_ore = function(model)
	newPart(model, Vector3.new(1.1, 0.85, 1.0), CFrame.new(0, 0, 0) * CFrame.Angles(rad(12), rad(20), rad(8)), GRAY)
	newPart(model, Vector3.new(0.7, 0.6, 0.7), CFrame.new(0.5, 0.3, -0.2) * CFrame.Angles(rad(-25), rad(40), rad(15)), GRAY_DARK)
	newPart(model, Vector3.new(0.55, 0.5, 0.6), CFrame.new(-0.45, 0.22, 0.25) * CFrame.Angles(rad(30), rad(-15), rad(-20)), GRAY_DARK)
	newPart(model, Vector3.new(0.3, 0.28, 0.3), CFrame.new(0.1, 0.55, 0.3) * CFrame.Angles(rad(20), rad(35), rad(10)), GRAY_LIGHT)
end

-- Cristal: prisma alto com duas lascas menores na base
BUILDERS.crystal_shard = function(model)
	newMeshPart(model, Vector3.new(0.55, 1.5, 0.55), CFrame.new(0, 0.15, 0) * CFrame.Angles(0, rad(20), rad(-6)), GRAY_LIGHT, Enum.MeshType.Prism)
	newMeshPart(model, Vector3.new(0.32, 0.85, 0.32), CFrame.new(0.42, -0.2, 0.12) * CFrame.Angles(0, rad(-30), rad(22)), GRAY, Enum.MeshType.Prism)
	newMeshPart(model, Vector3.new(0.26, 0.65, 0.26), CFrame.new(-0.38, -0.3, -0.1) * CFrame.Angles(0, rad(45), rad(-18)), GRAY, Enum.MeshType.Prism)
end

-- Poção: frasco (esfera) + gargalo + rolha
-- Part.Shape Cylinder tem o eixo em X: Size = (altura, diâmetro, diâmetro),
-- e o Angles(0, 0, 90) deita esse eixo pra vertical.
BUILDERS.health_potion = function(model)
	newPart(model, Vector3.new(1.0, 1.0, 1.0), CFrame.new(0, -0.2, 0), GRAY_LIGHT, Enum.PartType.Ball)
	newPart(model, Vector3.new(0.4, 0.3, 0.3), CFrame.new(0, 0.48, 0) * CFrame.Angles(0, 0, rad(90)), GRAY, Enum.PartType.Cylinder)
	newPart(model, Vector3.new(0.18, 0.38, 0.38), CFrame.new(0, 0.76, 0) * CFrame.Angles(0, 0, rad(90)), GRAY_DARK, Enum.PartType.Cylinder)
end

-- Picareta laser: corpo + cano + empunhadura
BUILDERS.laser_pickaxe = function(model)
	newPart(model, Vector3.new(1.0, 0.42, 0.34), CFrame.new(0, 0.15, 0), GRAY, Enum.PartType.Block)
	newPart(model, Vector3.new(0.7, 0.2, 0.2), CFrame.new(0.72, 0.18, 0), GRAY_LIGHT, Enum.PartType.Cylinder)
	newPart(model, Vector3.new(0.3, 0.65, 0.3), CFrame.new(-0.3, -0.3, 0) * CFrame.Angles(rad(0), 0, rad(-12)), GRAY_DARK)
	newPart(model, Vector3.new(0.16, 0.16, 0.16), CFrame.new(0.2, 0.4, 0), GRAY_LIGHT, Enum.PartType.Ball)
end

-- Mapa estelar: planeta com anel inclinado
BUILDERS.star_map = function(model)
	newPart(model, Vector3.new(0.9, 0.9, 0.9), CFrame.new(0, 0, 0), GRAY, Enum.PartType.Ball)
	newPart(model, Vector3.new(0.06, 1.7, 1.7), CFrame.Angles(rad(12), 0, 0) * CFrame.Angles(0, 0, rad(70)), GRAY_LIGHT, Enum.PartType.Cylinder)
	newPart(model, Vector3.new(0.2, 0.2, 0.2), CFrame.new(0.75, 0.55, 0.2), GRAY_LIGHT, Enum.PartType.Ball)
end

-- Item sem builder próprio: caixa genérica com faixa
local function buildDefault(model: Model)
	newPart(model, Vector3.new(0.95, 0.95, 0.95), CFrame.new(0, 0, 0) * CFrame.Angles(0, rad(15), 0), GRAY)
	newPart(model, Vector3.new(1.0, 0.18, 1.0), CFrame.new(0, 0.1, 0) * CFrame.Angles(0, rad(15), 0), GRAY_LIGHT)
end

-- ═══════════════════════════════════════════════════════════
-- Criação
-- ═══════════════════════════════════════════════════════════

--- Torna a peça acinzentada mantendo o contraste original (para o HUD monocromático).
local function desaturate(model: Model)
	for _, inst in model:GetDescendants() do
		if inst:IsA("BasePart") then
			local c = inst.Color
			local lum = 0.299 * c.R + 0.587 * c.G + 0.114 * c.B
			inst.Color = Color3.new(lum, lum, lum)
		end
	end
end

local function prepareClone(source: Instance): Model?
	local clone = source:Clone()

	local model: Model
	if clone:IsA("Model") then
		model = clone
	elseif clone:IsA("BasePart") then
		model = Instance.new("Model")
		clone.Parent = model
	elseif clone:IsA("Tool") or clone:IsA("Folder") then
		-- Tool copiada direto de ServerStorage.Tools: aproveita o conteúdo
		model = Instance.new("Model")
		for _, child in clone:GetChildren() do
			child.Parent = model
		end
		clone:Destroy()
	else
		clone:Destroy()
		return nil
	end

	for _, inst in model:GetDescendants() do
		if inst:IsA("BasePart") then
			inst.Anchored = true
			inst.CanCollide = false
			inst.CanQuery = false
			inst.CanTouch = false
			inst.CastShadow = false
		elseif inst:IsA("Script") or inst:IsA("LocalScript") then
			inst:Destroy()
		end
	end

	return model
end

--- Caixa que envolve só o que aparece na tela.
--- Model:GetBoundingBox() conta part invisível também, e modelo importado costuma
--- trazer hitbox/handle transparente que empurra o centro e encolhe o item no slot.
local function visibleBounds(model: Model): (Vector3, Vector3)
	local min: Vector3? = nil
	local max: Vector3? = nil

	for _, inst in model:GetDescendants() do
		if inst:IsA("BasePart") and inst.Transparency < 1 then
			local cf = inst.CFrame
			local size = inst.Size / 2
			-- Extensão da part já rotacionada, projetada nos eixos do mundo
			local ext = Vector3.new(
				math.abs(cf.RightVector.X) * size.X + math.abs(cf.UpVector.X) * size.Y + math.abs(cf.LookVector.X) * size.Z,
				math.abs(cf.RightVector.Y) * size.X + math.abs(cf.UpVector.Y) * size.Y + math.abs(cf.LookVector.Y) * size.Z,
				math.abs(cf.RightVector.Z) * size.X + math.abs(cf.UpVector.Z) * size.Y + math.abs(cf.LookVector.Z) * size.Z
			)
			local lo, hi = cf.Position - ext, cf.Position + ext
			min = if min then (min :: Vector3):Min(lo) else lo
			max = if max then (max :: Vector3):Max(hi) else hi
		end
	end

	if not min or not max then
		-- Modelo todo invisível: cai no cálculo padrão
		local cf, size = model:GetBoundingBox()
		return cf.Position, size
	end

	local lo, hi = min :: Vector3, max :: Vector3
	return (lo + hi) / 2, hi - lo
end

--- Modelo 3D do item, pronto pra ser posto num ViewportFrame (pivô na origem).
function ItemModels.Create(itemId: string, monochrome: boolean?): Model?
	local model: Model? = nil

	local folder = ReplicatedStorage:FindFirstChild("ItemModels")
	local source = folder and folder:FindFirstChild(itemId)
	if source then
		model = prepareClone(source)
	end
	local imported = model ~= nil

	if not model then
		local built = Instance.new("Model")
		built.Name = itemId
		local builder = BUILDERS[itemId] or buildDefault
		builder(built)
		model = built
	end

	local m = model :: Model
	if #m:GetChildren() == 0 then
		m:Destroy()
		return nil
	end

	m.Name = itemId

	-- Sem PrimaryPart o pivô do Model é o WorldPivot, que a gente controla.
	-- Com PrimaryPart, o pivô seria o CFrame dela — e o giro do HUD arrancaria
	-- o modelo do centro do slot, jogando o resto das peças pra fora do quadro.
	m.PrimaryPart = nil

	-- Centraliza pelo volume visível: o spin e o enquadramento contam com o
	-- item em (0,0,0) e com o pivô alinhado ao eixo.
	local center = visibleBounds(m)
	m.WorldPivot = CFrame.new(center)
	m:PivotTo(CFrame.new())

	local pose = imported and IMPORT_POSE[itemId]
	if pose then
		m:PivotTo(pose)          -- gira em torno da origem
		m.WorldPivot = CFrame.new()  -- pose fica nas peças; pivô volta pro eixo
	end

	if monochrome then
		desaturate(m)
	end

	return m
end

-- ═══════════════════════════════════════════════════════════
-- Viewport
-- ═══════════════════════════════════════════════════════════

--- Põe o modelo do item dentro do ViewportFrame e enquadra a câmera.
--- Devolve o Model (pra girar depois) ou nil se o item não tiver modelo.
function ItemModels.Mount(viewport: ViewportFrame, itemId: string, monochrome: boolean?): Model?
	ItemModels.Clear(viewport)

	local model = ItemModels.Create(itemId, monochrome)
	if not model then
		return nil
	end
	model.Parent = viewport

	-- Raio da esfera que envolve o item: serve pra qualquer ângulo do giro
	local _, size = visibleBounds(model)
	local radius = size.Magnitude / 2
	local distance = (radius / math.tan(math.rad(VIEW_FOV / 2))) * VIEW_PADDING

	local focus = Vector3.new(0, radius * VIEW_LOOK_LIFT, 0)

	local cam = Instance.new("Camera")
	cam.FieldOfView = VIEW_FOV
	cam.CFrame = CFrame.lookAt(focus + VIEW_DIR * distance, focus)
	cam.Parent = viewport
	viewport.CurrentCamera = cam

	return model
end

--- Esvazia o viewport (modelo + câmera).
function ItemModels.Clear(viewport: ViewportFrame)
	viewport.CurrentCamera = nil
	for _, child in viewport:GetChildren() do
		if child:IsA("Model") or child:IsA("BasePart") or child:IsA("Camera") then
			child:Destroy()
		end
	end
end

--- Iluminação padrão do viewport, no tom do HUD.
function ItemModels.StyleViewport(viewport: ViewportFrame)
	viewport.BackgroundTransparency = 1
	viewport.Ambient = Color3.fromRGB(150, 152, 158)
	viewport.LightColor = Color3.fromRGB(255, 255, 255)
	viewport.LightDirection = Vector3.new(-0.4, -1, -0.6)
end

return ItemModels
