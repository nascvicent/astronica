--[[
	MapConfig
	O que aparece no mapa do sistema (MapHUD) e como.

	O mapa se monta sozinho a partir da cena: todo Part em
	workspace.WarpDestinations vira um ponto, mesmo sem entrada aqui (nome =
	id, tipo DEFAULT_KIND). A tabela BODIES só enfeita e completa:

	  chave            id do corpo. Se existir um marcador de warp com esse
	                   nome (maiúsculas não importam), a posição vem dele e o
	                   corpo é destino de warp
	  aliases          outros nomes de marcador aceitos ({ "citadel" })
	  pattern          padrão Lua (em minúsculas) pra uma entrada valer pra
	                   vários marcadores: "^lua" pega Lua1, Lua2, LuaNorte...
	                   Cada um aparece com o próprio nome
	  displayName      nome na tela (padrão: o id)
	  kind             chave de KINDS (padrão: DEFAULT_KIND)
	  description      texto do painel de informação
	  color            força a cor da esfera e do ícone. Sem ela a cor vem da
	                   cena (ver ColorOf): visual → anchor → o próprio marcador
	                   de warp (se visível) → a cor do tipo
	  size             multiplica o tamanho do tipo no mapa (padrão: 1)
	  anchor           caminho no workspace ("Planets/Ignis") pra ler a posição
	                   quando o corpo não é marcador de warp
	  position         Vector3 fixo, último recurso de posição
	  visual           caminho no workspace do modelo cujo visual é copiado pro
	                   mapa. Sem ele (ou com peças demais) vira uma esfera
	  orbit            false = sem anel (estrela e o CENTER nunca têm) · string =
	                   chave do corpo em volta do qual
	                   o anel é desenhado (lua em volta do planeta)
	  hidden           true = não aparece no mapa
	  warp             false = só aparece no mapa: não dá pra warpar pra ele
	                   mesmo tendo marcador (o servidor recusa e a mira ignora)

	Corpo sem posição resolvível (sem marcador, anchor não carregou por
	streaming e sem position) não aparece, e o Output avisa uma vez com os
	nomes dos marcadores que existem.

	Local: src/shared/MapConfig.luau
]]

local WarpModule = require(script.Parent.WarpModule)

local MapConfig = {}

MapConfig.SYSTEM_NAME = "Sistema Astronica"

-- Centro do sistema, em volta do qual os anéis de órbita são desenhados: id de
-- um corpo de BODIES ou um Vector3
MapConfig.CENTER = "solara" :: Vector3 | string

--[[
	Escala do mapa. As distâncias reais variam muito (um marcador a 200 studs e
	outro a 3500), então o raio é comprimido: raio_mapa ∝ (d / d_max)^EXPONENT.
	1 = linear · 0.5 = raiz (aproxima os de longe, afasta os de perto).
	A altura é achatada por HEIGHT_SCALE pra o mapa ficar legível de cima; a
	linha vertical de cada ponto mostra quanto ele está acima ou abaixo.
]]
MapConfig.SCALE_EXPONENT = 0.55
MapConfig.HEIGHT_SCALE = 0.35

-- Mais peças que isso no `visual` e o mapa usa a esfera
MapConfig.MAX_VISUAL_PARTS = 150

MapConfig.KINDS = {
	star = { label = "Estrela", color = Color3.fromHex("#FFC857"), size = 10 },
	planet = { label = "Planeta", color = Color3.fromHex("#C9825B"), size = 7 },
	moon = { label = "Lua", color = Color3.fromHex("#B8BCC6"), size = 4 },
	station = { label = "Estação", color = Color3.fromHex("#45C7FF"), size = 3.5 },
	poi = { label = "Ponto de interesse", color = Color3.fromHex("#8CE0A8"), size = 2.5 },
}
MapConfig.DEFAULT_KIND = "poi"

MapConfig.BODIES = {
	-- Centro do sistema (CENTER): as órbitas giram em volta dela. Sem marcador
	-- de warp: a posição vem de um objeto "Solara" no workspace, se existir,
	-- ou da origem
	solara = {
		displayName = "Solara",
		kind = "star",
		description = "A estrela do sistema.",
		color = Color3.fromHex("#FFC857"),
		anchor = "Solara",
		position = Vector3.zero,
		warp = false,
	},
	verdana = {
		displayName = "Verdana",
		kind = "planet",
		description = "Floresta acolhedora e sem ameaças. Minério bruto e planta medicinal.",
		color = Color3.fromHex("#5FBF5A"),
	},
	ignis = {
		displayName = "Ignis",
		kind = "planet",
		description = "Vulcânico, sob um pôr do sol permanente. Cristal de magma, dano por calor e criaturas hostis.",
		color = Color3.fromHex("#E0643C"),
	},
	glacius = {
		displayName = "Glacius",
		kind = "planet",
		description = "Congelado, com cavernas de cristal e aurora no céu. Cristal de gelo, lentidão e bichos camuflados.",
		color = Color3.fromHex("#8FD3F0"),
	},
	noctis = {
		displayName = "Noctis",
		kind = "planet",
		description = "Escuridão total sob uma nebulosa roxa. Xenolite, criaturas agressivas e o boss. Conteúdo de fim de jogo.",
		color = Color3.fromHex("#7B4FC9"),
	},
	cidadel = {
		displayName = "Cidadel",
		kind = "station",
		aliases = { "citadel", "cidadela", "citadela" },
		description = "Estação do Hub.",
		color = Color3.fromHex("#F2F2F2"),
	},
	-- Ilhas no espaço do Hub: vale pra todo marcador que comece com "lua" ou
	-- "moon" (Lua1, Lua2...). Chega-se voando; sem teleporte de Place.
	luas = {
		kind = "moon",
		pattern = "^lua",
		aliases = { "^moon" },
		description = "Ilha no espaço do Hub. Recursos menores e recarga lenta de combustível.",
		color = Color3.fromHex("#C9CCD4"),
	},
}

export type Body = {
	id: string,
	displayName: string,
	kind: string,
	kindLabel: string,
	description: string?,
	color: Color3,
	size: number,
	position: Vector3,
	isWarp: boolean,
	entry: string?, -- chave em BODIES que descreve o corpo, se houver
	visual: Instance?,
	orbit: (string | boolean)?,
}

--- Instância por caminho "A/B/C" a partir do workspace.
function MapConfig.FindPath(path: string?): Instance?
	if typeof(path) ~= "string" then
		return nil
	end
	local current: Instance? = workspace
	for name in string.gmatch(path, "[^/]+") do
		current = current and current:FindFirstChild(name)
	end
	return current
end

--[[
	Cor de um objeto da cena: Part → a cor dele. Model → a cor do PrimaryPart;
	sem PrimaryPart, a da maior peça (num planeta é a esfera, não um detalhe).
]]
function MapConfig.ColorOf(instance: Instance?): Color3?
	if not instance then
		return nil
	end
	if instance:IsA("BasePart") then
		return instance.Color
	end
	if instance:IsA("Model") then
		if instance.PrimaryPart then
			return instance.PrimaryPart.Color
		end
		local largest, largestVolume = nil, -1
		for _, part in instance:GetDescendants() do
			if part:IsA("BasePart") then
				local volume = part.Size.X * part.Size.Y * part.Size.Z
				if volume > largestVolume then
					largest, largestVolume = part, volume
				end
			end
		end
		return if largest then largest.Color else nil
	end
	return nil
end

local function positionOf(instance: Instance?): Vector3?
	if not instance then
		return nil
	end
	if instance:IsA("BasePart") then
		return instance.Position
	end
	if instance:IsA("Model") then
		local cf = instance:GetBoundingBox()
		return cf.Position
	end
	return nil
end

--- Entrada de BODIES pra um nome de marcador: chave exata, chave sem
--- diferenciar maiúsculas, aliases, e por último pattern. Retorna a chave e
--- se foi por pattern (aí o nome exibido é o do marcador).
local function findEntry(markerName: string): (string?, boolean)
	if MapConfig.BODIES[markerName] then
		return markerName, false
	end
	local lower = string.lower(markerName)
	for key, def in MapConfig.BODIES do
		if string.lower(key) == lower then
			return key, false
		end
		for _, alias in def.aliases or {} do
			local aliasLower = string.lower(alias)
			if string.sub(aliasLower, 1, 1) == "^" then
				if string.find(lower, aliasLower) then
					return key, def.pattern ~= nil
				end
			elseif aliasLower == lower then
				return key, false
			end
		end
	end
	for key, def in MapConfig.BODIES do
		if def.pattern and string.find(lower, string.lower(def.pattern)) then
			return key, true
		end
	end
	return nil, false
end

--- Nome de exibição de um marcador de warp (o mesmo que o mapa usa).
function MapConfig.GetDisplayName(markerName: string): string
	local key, byPattern = findEntry(markerName)
	local def = key and MapConfig.BODIES[key]
	if def and not byPattern and def.displayName then
		return def.displayName
	end
	return markerName
end

--- Dá pra warpar pra esse marcador? Só não dá se a entrada dele tiver
--- warp = false. Usado pelo servidor (validação) e pela mira.
function MapConfig.IsWarpable(markerName: string): boolean
	local key = findEntry(markerName)
	local def = key and MapConfig.BODIES[key]
	return not (def and def.warp == false)
end

-- Avisa só uma vez por entrada que não achou lugar no mapa
local warned = {}

--- Todos os corpos visíveis com posição resolvida, ordenados por id.
function MapConfig.GetBodies(): { Body }
	local list = {}
	local seen = {}

	local function add(id: string, def, marker: BasePart?, entry: string?)
		def = def or {}
		if def.hidden then
			return
		end
		local anchor = MapConfig.FindPath(def.anchor)
		local visual = MapConfig.FindPath(def.visual)
		local warpPosition = if marker then marker.Position else nil
		local position = warpPosition or positionOf(anchor) or def.position
		if typeof(position) ~= "Vector3" then
			return
		end

		local kindId = if MapConfig.KINDS[def.kind] then def.kind else MapConfig.DEFAULT_KIND
		local kind = MapConfig.KINDS[kindId]
		-- Marcador invisível (o normal pra um ponto orbital) não tem cor que
		-- signifique algo
		local markerColor = if marker and marker.Transparency < 1 then marker.Color else nil
		local color = def.color or MapConfig.ColorOf(visual) or MapConfig.ColorOf(anchor) or markerColor or kind.color
		table.insert(list, {
			id = id,
			displayName = def.displayName or id,
			kind = kindId,
			kindLabel = kind.label,
			description = def.description,
			color = color,
			size = kind.size * (def.size or 1),
			position = position,
			isWarp = warpPosition ~= nil and def.warp ~= false,
			entry = entry,
			visual = visual,
			orbit = def.orbit,
		})
	end

	local destinations = WarpModule.GetDestinations()
	for _, dest in destinations do
		local key, byPattern = findEntry(dest.id)
		local def = key and MapConfig.BODIES[key]
		if key then
			seen[key] = true
		end
		if def and byPattern then
			-- Entrada de grupo: cada marcador com o próprio nome
			def = table.clone(def)
			def.displayName = dest.id
		end
		add(dest.id, def, dest.part, key)
	end

	local count = #list
	for id, def in MapConfig.BODIES do
		if not seen[id] then
			add(id, def, nil, id)
			if #list == count and not def.pattern and not def.hidden and not warned[id] then
				warned[id] = true
				local names = {}
				for _, dest in destinations do
					table.insert(names, dest.id)
				end
				warn(string.format(
					"[MapConfig] '%s' não aparece no mapa: nenhum marcador com esse nome em workspace.%s "
						.. "(e sem anchor/position). Marcadores existentes: %s",
					id,
					"WarpDestinations",
					if #names > 0 then table.concat(names, ", ") else "nenhum"
				))
			end
			count = #list
		end
	end

	table.sort(list, function(a, b)
		return a.id < b.id
	end)
	return list
end

--- O corpo é o CENTER? Compara pela chave de BODIES e pelo nome do
--- marcador sem diferenciar maiúsculas ("solara" pega o marcador "Solara").
function MapConfig.IsCenter(body: Body): boolean
	local center = MapConfig.CENTER
	if typeof(center) ~= "string" then
		return false
	end
	local lower = string.lower(center)
	return (body.entry ~= nil and string.lower(body.entry) == lower) or string.lower(body.id) == lower
end

--- Posição real do centro do sistema.
function MapConfig.GetCenter(bodies: { Body }): Vector3
	local center = MapConfig.CENTER
	if typeof(center) == "string" then
		for _, body in bodies do
			if MapConfig.IsCenter(body) then
				return body.position
			end
		end
		return Vector3.zero
	end
	return center :: Vector3
end

return MapConfig
