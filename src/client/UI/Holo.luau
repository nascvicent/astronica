--[[
	Holo
	Placa holográfica presa à câmera — o mesmo sistema do SpeedHUD
	(ShipHudModule), do HealthHUD e da quick bar do InventoryHUD: uma Part
	invisível a DEPTH studs da câmera com uma SurfaceGui AlwaysOnTop.

	O que é holográfico e o que é 2D:
	  Holograma — instrumento e botão fixo da HUD: velocidade, casco/armas,
	              carga do warp, vida, quick bar, botões MAPA e inventário
	  2D        — o que precisa cair num pixel exato ou seguir algo no mundo
	              (miras, marcador de alvo do warp), aviso de tela (flash,
	              toast, mensagem de abate), controle de toque do celular e
	              painel cheio (inventário, hangar, menu da nave, mapa)

	Cor: monocromático do inventário e do HealthHUD — branco sobre placa
	escura, hierarquia por transparência (THEME + T). Cor só com significado:
	vermelho = perigo, verde = zona segura.

	FOV: a câmera de voo abre o FOV com a velocidade. Toda placa usa
	SpeedHUD.GetDepth, que aproxima a placa na mesma proporção: a HUD fica do
	mesmo tamanho na tela enquanto a câmera se afasta.

	Tamanho: `size` é em studs na escala do PC. O conteúdo é desenhado em
	pixels da SurfaceGui (size × 512). No celular a placa cresce SCALE vezes e
	o PPS cai igual: mesmo layout, maior na tela.

	Local: src/client/UI/Holo.luau
]]

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local SpeedHUD = require(ReplicatedStorage.Shared.ShipHudModule)

local player = Players.LocalPlayer
local playerGui = player:WaitForChild("PlayerGui")

local Holo = {}
Holo.__index = Holo

Holo.SCALE = SpeedHUD.SCALE
Holo.BASE_PPS = 512

-- Mesmos valores do HealthHUD / SpeedHUD
Holo.THEME = {
	plate = Color3.fromRGB(10, 11, 14),
	white = Color3.fromRGB(255, 255, 255),
	danger = Color3.fromRGB(220, 60, 60), -- vermelho do HealthHUD com vida baixa
	safe = Color3.fromRGB(90, 220, 130),
}

-- Transparências: é daqui que sai a hierarquia
Holo.T = {
	plate = 0.32,
	line = 0.85,
	lineHover = 0.45,
	title = 0.35, -- rótulo ("CASCO", "CANCELAR")
	value = 0, -- número / texto principal
	track = 0.84, -- trilho vazio da barra
}

local JURA = "rbxasset://fonts/families/Jura.json"
Holo.FONT_TITLE = Font.new(JURA, Enum.FontWeight.Medium, Enum.FontStyle.Normal)
Holo.FONT_VALUE = Font.new(JURA, Enum.FontWeight.Bold, Enum.FontStyle.Normal)

--[[
	CFrame na frente da câmera. screenX/screenY normalizados (-1..1, +Y =
	topo), como no SpeedHUD. rotY inclina a placa (positivo à esquerda da
	tela, negativo à direita). offset em studs, no plano da placa.
]]
function Holo.ScreenCFrame(cam: Camera, screenX: number, screenY: number, rotY: number, offset: Vector3?): CFrame
	local depth = SpeedHUD.GetDepth(cam)
	local halfH = depth * math.tan(math.rad(cam.FieldOfView) / 2)
	local halfW = halfH * (cam.ViewportSize.X / cam.ViewportSize.Y)
	local position = Vector3.new(halfW * screenX, halfH * screenY, -depth) + (offset or Vector3.zero)
	return cam.CFrame * CFrame.new(position) * CFrame.Angles(0, math.rad(rotY), 0)
end

--- Placa nova, escondida. place(cam) devolve o CFrame a cada frame visível.
--- scale aumenta a placa inteira (conteúdo junto, layout igual), por cima do
--- aumento do celular.
function Holo.new(name: string, size: Vector2, place: (Camera) -> CFrame, scale: number?)
	local self = setmetatable({}, Holo)
	self._place = place
	self._visible = false

	-- Tamanho real (escalado) — quem empilha placas usa este
	local factor = Holo.SCALE * (scale or 1)
	self.size = size * factor

	local folder = Instance.new("Folder")
	folder.Name = name
	self._folder = folder

	local part = Instance.new("Part")
	part.Name = name .. "_Part"
	part.Size = Vector3.new(self.size.X, self.size.Y, 0.01)
	part.Anchored = true
	part.CanCollide = false
	part.CanQuery = false
	part.CanTouch = false
	part.CastShadow = false
	part.Transparency = 1
	part.Parent = folder
	self.part = part

	local gui = Instance.new("SurfaceGui")
	gui.Name = name .. "_SGui"
	gui.Adornee = part
	gui.Face = Enum.NormalId.Back
	gui.AlwaysOnTop = true
	gui.PixelsPerStud = Holo.BASE_PPS / factor
	gui.SizingMode = Enum.SurfaceGuiSizingMode.PixelsPerStud
	gui.LightInfluence = 0
	gui.ResetOnSpawn = false
	gui.Enabled = false
	gui.Parent = playerGui
	self.gui = gui

	return self
end

--- Fundo padrão: placa escura translúcida, cantos e borda branca fina.
--- Devolve o container e a borda (pra quem pinta a borda por estado).
function Holo:Plate(): (Frame, UIStroke)
	local theme = Holo.THEME
	local container = Instance.new("Frame")
	container.Name = "Container"
	container.Size = UDim2.fromScale(1, 1)
	container.BackgroundColor3 = theme.plate
	container.BackgroundTransparency = Holo.T.plate
	container.BorderSizePixel = 0
	container.Parent = self.gui

	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, 8)
	corner.Parent = container

	local stroke = Instance.new("UIStroke")
	stroke.Color = theme.white
	stroke.Thickness = 2
	stroke.Transparency = Holo.T.line
	stroke.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
	stroke.Parent = container

	return container, stroke
end

--- Texto branco; `transparency` dá o nível (Holo.T.title, Holo.T.value).
--- Com `fit`, encolhe pra caber mas nunca passa de textSize.
function Holo.Label(parent: Instance, name: string, textSize: number, font: Font, transparency: number, fit: boolean?): TextLabel
	local label = Instance.new("TextLabel")
	label.Name = name
	label.BackgroundTransparency = 1
	label.Text = ""
	label.TextColor3 = Holo.THEME.white
	label.TextTransparency = transparency
	label.TextSize = textSize
	label.FontFace = font
	label.TextXAlignment = Enum.TextXAlignment.Left
	label.Parent = parent
	if fit then
		label.TextScaled = true
		local constraint = Instance.new("UITextSizeConstraint")
		constraint.MaxTextSize = textSize
		constraint.Parent = label
	end
	return label
end

--- Barra horizontal (trilho + preenchimento). Devolve o preenchimento.
function Holo.Bar(parent: Instance, name: string, y: number, height: number): Frame
	local theme = Holo.THEME
	local track = Instance.new("Frame")
	track.Name = name .. "Track"
	track.Position = UDim2.fromOffset(0, y)
	track.Size = UDim2.new(1, 0, 0, height)
	track.BackgroundColor3 = theme.white
	track.BackgroundTransparency = Holo.T.track
	track.BorderSizePixel = 0
	track.Parent = parent
	local trackCorner = Instance.new("UICorner")
	trackCorner.CornerRadius = UDim.new(0, 4)
	trackCorner.Parent = track

	local fill = Instance.new("Frame")
	fill.Name = "Fill"
	fill.Size = UDim2.fromScale(1, 1)
	fill.BackgroundColor3 = theme.white
	fill.BorderSizePixel = 0
	fill.Parent = track
	local fillCorner = Instance.new("UICorner")
	fillCorner.CornerRadius = UDim.new(0, 4)
	fillCorner.Parent = fill
	return fill
end

--- Escondida, a placa sai do workspace e para de seguir a câmera.
function Holo:SetVisible(visible: boolean)
	if self._visible == visible then
		return
	end
	self._visible = visible
	self.gui.Enabled = visible
	self._folder.Parent = if visible then workspace else nil

	if visible then
		local function follow()
			local cam = workspace.CurrentCamera
			if cam then
				self.part.CFrame = self._place(cam)
			end
		end
		follow()
		self._followConn = RunService.RenderStepped:Connect(follow)
	elseif self._followConn then
		self._followConn:Disconnect()
		self._followConn = nil
	end
end

function Holo:IsVisible(): boolean
	return self._visible
end

return Holo
