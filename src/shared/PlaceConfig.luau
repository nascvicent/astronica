--[[
	PlaceConfig
	Em que tipo de Place o jogo está rodando e onde ficam os objetos de cena
	que o sistema de naves usa.

	Dois tipos de Place:
	  "space"  — Hub e luas. A nave nasce no hangar (LANÇAR) ou na órbita,
	             vinda de um planeta. Pilota-se.
	  "planet" — A nave nasce pousada no LandingPad, ao lado do jogador.
	             Não voa: é a rota de saída (DECOLAR).

	Ordem de decisão do tipo (a primeira que responder vale):
	  1. Atributo PlaceType no Workspace ("planet" | "space"; "hub"/"moon" = space)
	  2. Tabela PLACES abaixo, por PlaceId
	  3. Inferência: existe LandingPad → planet · senão → space

	Objetos de cena (todos opcionais; sem eles o recurso só não existe no Place):
	  Workspace.LandingPad       Part         — planeta: onde a nave pousa
	  Workspace.HangarTerminal   Part/Model   — prompt HANGAR: abre o HUD do hangar
	  Workspace.HangarPads       Folder       — Parts com prompt LANÇAR: nave nasce e senta
	  Workspace.HangarZone       Part(s)      — SÓ ambiência (luz, trilha, câmera) e GUARDAR NAVE.
	                                            Nunca abre menu: o hangar é corredor de passagem
	  Workspace.ShipPedestal     Part         — display local da nave no hangar
	  Workspace.CameraPart       Part         — enquadramento da câmera com o HUD aberto
	  Workspace.WarpDestinations Folder       — marcadores orbitais

	Os prompts HANGAR e LANÇAR podem ser feitos no Studio (ProximityPrompt com
	o nome abaixo dentro do terminal / de cada pad). Se não existirem, o client
	cria um local com as mesmas propriedades.

	Local: src/shared/PlaceConfig.luau
]]

local PlaceConfig = {}

-- Place do Hub, destino da decolagem de planeta. 0 = ainda não publicado
-- (decolar só avisa no output em vez de teleportar).
PlaceConfig.HUB_PLACE_ID = 0

PlaceConfig.PLACES = {
	-- [1234567890] = { type = "planet", planetId = "ignis" },
}

-- Nomes de objeto no Workspace
PlaceConfig.LANDING_PAD = "LandingPad"
PlaceConfig.HANGAR_ZONE = "HangarZone"
PlaceConfig.HANGAR_PADS = "HangarPads"
PlaceConfig.HANGAR_TERMINAL = "HangarTerminal"

-- Prompts do hangar
PlaceConfig.TERMINAL_PROMPT = "HangarPrompt"
PlaceConfig.LAUNCH_PROMPT = "LaunchPrompt"

-- Atributo no pad com o UserId de quem está nele (replica: o client apaga o
-- LANÇAR de pad ocupado)
PlaceConfig.PAD_OCCUPIED_ATTRIBUTE = "OccupiedBy"
PlaceConfig.HANGAR_CAMERA = "CameraPart"
PlaceConfig.SHIP_PEDESTAL = "ShipPedestal"
PlaceConfig.WARP_DESTINATIONS = "WarpDestinations"

-- Chave do TeleportData com o marcador orbital de chegada no Hub
PlaceConfig.ARRIVAL_KEY = "arrivalMarker"

function PlaceConfig.GetPlaceType(): string
	local attr = workspace:GetAttribute("PlaceType")
	if typeof(attr) == "string" and attr ~= "" then
		return if string.lower(attr) == "planet" then "planet" else "space"
	end

	local entry = PlaceConfig.PLACES[game.PlaceId]
	if entry then
		return if entry.type == "planet" then "planet" else "space"
	end

	return if workspace:FindFirstChild(PlaceConfig.LANDING_PAD) then "planet" else "space"
end

function PlaceConfig.IsPlanet(): boolean
	return PlaceConfig.GetPlaceType() == "planet"
end

function PlaceConfig.GetPlanetId(): string?
	local attr = workspace:GetAttribute("PlanetId")
	if typeof(attr) == "string" and attr ~= "" then
		return attr
	end
	local entry = PlaceConfig.PLACES[game.PlaceId]
	return entry and entry.planetId
end

function PlaceConfig.GetLandingPad(): BasePart?
	local pad = workspace:FindFirstChild(PlaceConfig.LANDING_PAD)
	return if pad and pad:IsA("BasePart") then pad else nil
end

-- ═══════════════════════════════════════════════════════════
-- Hangar
-- ═══════════════════════════════════════════════════════════

local function zoneParts(): { BasePart }
	local zone = workspace:FindFirstChild(PlaceConfig.HANGAR_ZONE)
	if not zone then
		return {}
	end
	if zone:IsA("BasePart") then
		return { zone }
	end

	local parts = {}
	for _, child in zone:GetDescendants() do
		if child:IsA("BasePart") then
			table.insert(parts, child)
		end
	end
	return parts
end

function PlaceConfig.HasHangar(): boolean
	return PlaceConfig.GetHangarTerminal() ~= nil or #PlaceConfig.GetHangarPads() > 0
end

--- Part do terminal onde o prompt fica (a própria Part, ou a PrimaryPart /
--- primeira Part de um Model).
function PlaceConfig.GetHangarTerminal(): BasePart?
	local terminal = workspace:FindFirstChild(PlaceConfig.HANGAR_TERMINAL)
	if not terminal then
		return nil
	end
	if terminal:IsA("BasePart") then
		return terminal
	end
	if terminal:IsA("Model") and terminal.PrimaryPart then
		return terminal.PrimaryPart
	end
	return terminal:FindFirstChildWhichIsA("BasePart", true)
end

function PlaceConfig.IsHangarPad(instance: any): boolean
	if typeof(instance) ~= "Instance" or not instance:IsA("BasePart") then
		return false
	end
	local folder = workspace:FindFirstChild(PlaceConfig.HANGAR_PADS)
	return folder ~= nil and instance.Parent == folder
end

--- Ponto dentro do volume do hangar (caixa orientada de qualquer Part da zona).
function PlaceConfig.IsInHangarZone(position: Vector3): boolean
	for _, part in zoneParts() do
		local localPos = part.CFrame:PointToObjectSpace(position)
		local half = part.Size / 2
		if math.abs(localPos.X) <= half.X and math.abs(localPos.Y) <= half.Y and math.abs(localPos.Z) <= half.Z then
			return true
		end
	end
	return false
end

--- Pads de lançamento em ordem de nome (Pad1, Pad2...), pra alocação previsível.
function PlaceConfig.GetHangarPads(): { BasePart }
	local folder = workspace:FindFirstChild(PlaceConfig.HANGAR_PADS)
	local pads = {}
	if not folder then
		return pads
	end
	for _, child in folder:GetChildren() do
		if child:IsA("BasePart") then
			table.insert(pads, child)
		end
	end
	table.sort(pads, function(a, b)
		return a.Name < b.Name
	end)
	return pads
end

return PlaceConfig
