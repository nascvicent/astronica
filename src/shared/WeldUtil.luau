--[[
	WeldUtil
	Solda todas as BaseParts de um Model/Tool numa parte raiz (Handle).

	Local: src/shared/WeldUtil.luau

	USO EM RUNTIME (server):
		local WeldUtil = require(ReplicatedStorage.Shared.WeldUtil)
		WeldUtil.WeldTo(tool, tool.Handle)

	USO NO STUDIO (command bar — recomendado, solda uma vez e salva):
		Selecione a Tool/Model e rode:

		local m = game.Selection:Get()[1]
		local handle = m:FindFirstChild("Handle")
		for _, p in m:GetDescendants() do
			if p:IsA("BasePart") and p ~= handle then
				p.Anchored, p.CanCollide, p.Massless = false, false, true
				local w = Instance.new("WeldConstraint")
				w.Part0, w.Part1, w.Parent = handle, p, handle
			end
		end
		handle.Anchored, handle.CanCollide = false, false

	IMPORTANTE: o WeldConstraint congela o offset que as partes têm NO MOMENTO
	em que ficam ativas. Posicione tudo certinho ANTES de soldar.
]]

local LaserConfig = require(script.Parent.LaserConfig)

local WeldUtil = {}

local WELD_NAME = "AutoWeld"

--- Solda todas as BaseParts descendentes de `container` em `root`.
--- Retorna a quantidade de welds criados.
function WeldUtil.WeldTo(container: Instance, root: BasePart): number
	assert(root and root:IsA("BasePart"), "WeldUtil.WeldTo: root inválido")

	root.Anchored = false
	root.CanCollide = false

	local count = 0

	for _, part in container:GetDescendants() do
		if part:IsA("BasePart") and part ~= root then
			part.Anchored = false
			part.CanCollide = false
			part.CanQuery = false
			part.Massless = true

			-- Evita weld duplicado se rodar duas vezes
			local existing = part:FindFirstChild(WELD_NAME)
			if existing then
				existing:Destroy()
			end

			local weld = Instance.new("WeldConstraint")
			weld.Name = WELD_NAME
			weld.Part0 = root
			weld.Part1 = part
			weld.Parent = part

			count += 1
		end
	end

	return count
end

--- Garante que a Tool está pronta pra uso: Handle correto, tudo soldado,
--- attribute de identificação e Attachment de muzzle.
--- @param muzzleOffset CFrame relativo ao Handle onde o feixe nasce (ponta do cano)
function WeldUtil.PrepareTool(tool: Tool, muzzleOffset: CFrame?)
	local handle = tool:FindFirstChild("Handle")
	assert(handle and handle:IsA("BasePart"), "A Tool precisa de uma BasePart chamada 'Handle' como filha direta")

	tool.RequiresHandle = true
	tool.CanBeDropped = false

	WeldUtil.WeldTo(tool, handle)

	-- O Muzzle pode estar em qualquer BasePart da Tool, não só no Handle.
	local muzzle = LaserConfig.FindMuzzle(tool)
	if not muzzle then
		muzzle = Instance.new("Attachment")
		muzzle.Name = LaserConfig.MUZZLE_NAME
		muzzle.CFrame = muzzleOffset or CFrame.new(0, 0, -handle.Size.Z / 2)
		muzzle.Parent = handle
	end

	return handle, muzzle
end

return WeldUtil
