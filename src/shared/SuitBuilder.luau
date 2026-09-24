--[[
	SuitBuilder
	Monta o personagem de um traje a partir do StarterCharacter do asset,
	com a cabeça e o cabelo de um personagem de origem (o do player).

	Usado pelo SuitService (personagem de verdade) e pela aba Traje do
	inventário (preview de como o player fica com cada traje).

	Local: src/shared/SuitBuilder.luau
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local SuitConfig = require(script.Parent.SuitConfig)

local SuitBuilder = {}

function SuitBuilder.GetTemplate(suitId: string): Model?
	local suit = SuitConfig.Get(suitId)
	if not suit then return nil end

	local assets = ReplicatedStorage:FindFirstChild(SuitConfig.ASSETS_FOLDER)
	local suits = assets and assets:FindFirstChild(SuitConfig.SUITS_FOLDER)
	local folder = suits and suits:FindFirstChild(suit.modelFolder)
	local template = folder and folder:FindFirstChild(suit.character)

	if template and template:IsA("Model") and template:FindFirstChildOfClass("Humanoid") then
		return template
	end
	return nil
end

local function isJoint(inst: Instance): boolean
	return inst:IsA("JointInstance") or inst:IsA("WeldConstraint")
end

--- Troca a Head do traje por uma cópia da cabeça de origem.
--- Juntas e welds que apontavam pra cabeça antiga passam a apontar pra nova.
local function swapHead(character: Model, sourceHead: BasePart)
	local suitHead = character:FindFirstChild("Head")
	if not (suitHead and suitHead:IsA("BasePart")) then
		warn("[SuitBuilder] StarterCharacter do traje sem Head")
		return
	end

	local newHead = sourceHead:Clone()
	-- Juntas da cabeça do avatar (ex: Neck do R15) não servem no rig novo
	for _, d in newHead:GetDescendants() do
		if isJoint(d) then
			d:Destroy()
		end
	end
	newHead.Anchored = false
	newHead.CFrame = suitHead.CFrame

	for _, d in character:GetDescendants() do
		if isJoint(d) then
			local joint = d :: any
			if joint.Part0 == suitHead then joint.Part0 = newHead end
			if joint.Part1 == suitHead then joint.Part1 = newHead end
		end
	end

	-- Juntas que moram dentro da cabeça antiga (ex: Neck no R15) vão pra nova
	for _, child in suitHead:GetChildren() do
		if isJoint(child) then
			child.Parent = newHead
		end
	end

	suitHead:Destroy()
	newHead.Parent = character

	-- BodyColors do traje não pode repintar a cabeça do player
	local bodyColors = character:FindFirstChildOfClass("BodyColors")
	if bodyColors then
		bodyColors.HeadColor3 = sourceHead.Color
	end
end

local function isHair(accessory: Accessory): boolean
	if accessory.AccessoryType == Enum.AccessoryType.Hair then
		return true
	end
	-- Acessórios antigos não têm AccessoryType: identifica pelo attachment
	local handle = accessory:FindFirstChild("Handle")
	return handle ~= nil and handle:FindFirstChild("HairAttachment") ~= nil
end

--- Attachment do corpo (fora de acessórios, pra não encaixar cabelo no capacete).
local function findBodyAttachment(character: Model, name: string): Attachment?
	for _, part in character:GetChildren() do
		if part:IsA("BasePart") then
			local attachment = part:FindFirstChild(name)
			if attachment and attachment:IsA("Attachment") then
				return attachment
			end
		end
	end
	return nil
end

--- Encaixa o acessório no attachment de mesmo nome do personagem, do mesmo
--- jeito que o Humanoid:AddAccessory faz (funciona também no client/viewport).
local function attachAccessory(character: Model, accessory: Accessory)
	local handle = accessory:FindFirstChild("Handle")
	if not (handle and handle:IsA("BasePart")) then
		accessory:Destroy()
		return
	end

	for _, accAttachment in handle:GetChildren() do
		if accAttachment:IsA("Attachment") then
			local charAttachment = findBodyAttachment(character, accAttachment.Name)
			if charAttachment then
				local part0 = charAttachment.Parent :: BasePart
				handle.Anchored = false
				handle.CanCollide = false
				handle.Massless = true
				handle.CFrame = charAttachment.WorldCFrame * accAttachment.CFrame:Inverse()

				local weld = Instance.new("Weld")
				weld.Name = "AccessoryWeld"
				weld.Part0 = part0
				weld.Part1 = handle
				weld.C0 = charAttachment.CFrame
				weld.C1 = accAttachment.CFrame
				weld.Parent = handle

				accessory.Parent = character
				return
			end
		end
	end

	accessory:Destroy()
end

--- Clona o traje com a cabeça e o cabelo de `source`. Não parenta o resultado.
function SuitBuilder.Build(suitId: string, source: Model): Model?
	local template = SuitBuilder.GetTemplate(suitId)
	if not template then
		warn("[SuitBuilder] Personagem do traje não encontrado:", suitId)
		return nil
	end

	local sourceHead = source:FindFirstChild("Head")
	if not (sourceHead and sourceHead:IsA("BasePart")) then
		return nil
	end

	local character = template:Clone()
	swapHead(character, sourceHead)

	for _, child in source:GetChildren() do
		if child:IsA("Accessory") and isHair(child) then
			local copy = child:Clone()
			for _, d in copy:GetDescendants() do
				if isJoint(d) then
					d:Destroy()
				end
			end
			attachAccessory(character, copy)
		end
	end

	return character
end

--- Pinta a Union do visor do capacete. UsePartColor é obrigatório: sem ele a
--- Union mantém as cores originais das peças e ignora Color.
function SuitBuilder.SetVisorColor(character: Model, color: Color3)
	local helmet = character:FindFirstChild(SuitConfig.HELMET_NAME)
	local display = helmet and helmet:FindFirstChild(SuitConfig.DISPLAY_NAME, true)
	if not (display and display:IsA("BasePart")) then return end

	if display:IsA("UnionOperation") then
		display.UsePartColor = true
	end
	display.Color = color
end

--- Liga/desliga as luzes (lanterna do capacete) do personagem do traje.
function SuitBuilder.SetLights(character: Model, on: boolean)
	for _, d in character:GetDescendants() do
		if d:IsA("Light") then
			d.Enabled = on
		end
	end
end

return SuitBuilder
