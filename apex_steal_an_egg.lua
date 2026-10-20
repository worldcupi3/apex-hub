-- Apex Hub | Steal An Egg
-- Target: Luau (Roblox live client), executor environment
-- Standard Roblox APIs everywhere except these executor globals, all guarded:
--   gethui, fireproximityprompt, Drawing, writefile/readfile/isfile, game:HttpGet
-- NOT included: anything that needs the game's own remotes (auto hatch, auto sell,
-- auto buy, etc). Those need remote logs from the game, so none are guessed here.
-- RightShift hides/shows the menu.

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local StarterGui = game:GetService("StarterGui")
local TeleportService = game:GetService("TeleportService")
local VirtualUser = game:GetService("VirtualUser")
local Lighting = game:GetService("Lighting")
local HttpService = game:GetService("HttpService")
local CoreGui = game:GetService("CoreGui")

local lp = Players.LocalPlayer

local CONFIG = {
	-- ASSUMPTION: eggs are Models or Parts whose name contains one of these.
	-- Check the real names in Dex and edit if needed.
	EggNames = { "egg" },
	-- ASSUMPTION: steal/grab prompts have one of these words in ActionText, ObjectText or name.
	-- Empty table = Auto Interact fires every prompt in range.
	PromptKeywords = { "steal", "grab", "take", "collect", "pick" },
	-- ASSUMPTION: zones/biomes are Models, Folders or Parts in Workspace (or one level
	-- inside a Workspace folder) whose name contains one of these. Edit after checking Dex.
	ZoneKeywords = { "zone", "biome", "area", "island", "world" },
	MaxEggESP = 20, -- Roblox only renders a limited number of Highlights at once
	WalkSpeed = 32,
	JumpPower = 60,
	FlySpeed = 70,
	FOV = 90,
	Gravity = 100,
	PromptRange = 30,
	AutoRange = 15,
	ConfigFile = "apex_steal_an_egg.json",
	Version = "1.1.0",
	SelfUrl = "https://raw.githubusercontent.com/worldcupi3/apex-hub/refs/heads/main/apex_steal_an_egg.lua",
	Discord = "https://discord.gg/9KkKHQZdHF", -- never-expiring invite
	-- ASSUMPTION: eggs store rarity as an attribute with this name (Common, Rare, Epic...).
	-- If the game doesn't, eggs just show in yellow. Check the egg's Attributes in Dex.
	RarityAttribute = "Rarity",
	ESPRange = 0, -- player ESP max distance in studs, 0 = unlimited
}
local NUM_KEYS = { "WalkSpeed", "JumpPower", "FlySpeed", "FOV", "Gravity", "PromptRange", "AutoRange", "ESPRange" }

local alive = true
local connections = {}
local function bind(signal, fn)
	local c = signal:Connect(fn)
	table.insert(connections, c)
	return c
end

local function notify(text)
	pcall(function()
		StarterGui:SetCore("SendNotification", { Title = "Apex Hub", Text = text, Duration = 3 })
	end)
end

local function getChar()
	return lp.Character
end
local function getRoot()
	local c = lp.Character
	return c and c:FindFirstChild("HumanoidRootPart")
end
local function getHum()
	local c = lp.Character
	return c and c:FindFirstChildOfClass("Humanoid")
end

-- feature registry --------------------------------------------------------

local features = {}
local byName = {}

local function feature(name, onFn, offFn)
	local f = { name = name, enabled = false, on = onFn, off = offFn }
	table.insert(features, f)
	byName[name] = f
	return f
end

local function setFeature(f, value)
	if f.enabled == value then
		return
	end
	f.enabled = value
	local fn = value and f.on or f.off
	if fn then
		local ok, err = pcall(fn)
		if not ok then
			warn("[Apex] " .. f.name .. ": " .. tostring(err))
		end
	end
	if f.refresh then
		f.refresh()
	end
end

-- state used by features --------------------------------------------------

local orig = {
	gravity = workspace.Gravity,
	maxZoom = lp.CameraMaxZoomDistance,
}
local savedCF = nil
local lastSafeCF = nil
local flyBV, flyBG = nil, nil
local antiRagHum = nil
local playerESP = {} -- [Player] = { char = Model, items = {Instance}, label = TextLabel }
local eggs = {} -- [Instance] = true
local eggESP = {} -- [Instance] = { items = {Instance}, label = TextLabel }
local tracerLines = {} -- [Player] = Drawing line
local prompts = setmetatable({}, { __mode = "k" }) -- [ProximityPrompt] = original values
local lastFire = setmetatable({}, { __mode = "k" })
local fullbrightOrig = nil

-- eggs and prompts tracking -----------------------------------------------

local function isEggName(inst)
	local name = inst.Name:lower()
	for _, key in ipairs(CONFIG.EggNames) do
		if name:find(key, 1, true) then
			return true
		end
	end
	return false
end

local function trackInstance(inst)
	if inst:IsA("ProximityPrompt") then
		prompts[inst] = prompts[inst] or { hold = inst.HoldDuration, dist = inst.MaxActivationDistance, los = inst.RequiresLineOfSight }
		return
	end
	if (inst:IsA("Model") or inst:IsA("BasePart")) and isEggName(inst) then
		local p = inst.Parent
		while p and p ~= workspace do
			if eggs[p] then
				return -- already covered by a tracked parent egg
			end
			p = p.Parent
		end
		eggs[inst] = true
	end
end

local function clearEggESP(inst)
	local o = eggESP[inst]
	if o then
		for _, i in ipairs(o.items) do
			pcall(function()
				i:Destroy()
			end)
		end
		eggESP[inst] = nil
	end
end

for _, inst in ipairs(workspace:GetDescendants()) do
	trackInstance(inst)
end
bind(workspace.DescendantAdded, trackInstance)
bind(workspace.DescendantRemoving, function(inst)
	eggs[inst] = nil
	clearEggESP(inst)
end)

local function eggPosition(inst)
	if inst:IsA("Model") then
		return inst:GetPivot().Position
	end
	return inst.Position
end

local function nearestEgg()
	local root = getRoot()
	if not root then
		return nil
	end
	local best, bestDist = nil, math.huge
	for inst in pairs(eggs) do
		if inst.Parent then
			local d = (eggPosition(inst) - root.Position).Magnitude
			if d < bestDist then
				best, bestDist = inst, d
			end
		end
	end
	return best
end

-- prompt features ---------------------------------------------------------

local function refreshPrompts()
	for p, o in pairs(prompts) do
		if p.Parent then
			p.HoldDuration = byName["Instant Prompts"].enabled and 0 or o.hold
			p.MaxActivationDistance = byName["Extended Prompt Range"].enabled and CONFIG.PromptRange or o.dist
			p.RequiresLineOfSight = (not byName["No Line-of-Sight"].enabled) and o.los or false
		end
	end
end

local function promptMatches(p)
	if #CONFIG.PromptKeywords == 0 then
		return true
	end
	local text = (p.ActionText .. " " .. p.ObjectText .. " " .. p.Name):lower()
	for _, key in ipairs(CONFIG.PromptKeywords) do
		if text:find(key, 1, true) then
			return true
		end
	end
	return false
end

local function promptPosition(p)
	local par = p.Parent
	if par and par:IsA("BasePart") then
		return par.Position
	elseif par and par:IsA("Attachment") then
		return par.WorldPosition
	end
	return nil
end

-- esp helpers -------------------------------------------------------------
-- Highlight: https://create.roblox.com/docs/reference/engine/classes/Highlight

local function makeLabel(adornee, color)
	local gui = Instance.new("BillboardGui")
	gui.Adornee = adornee
	gui.AlwaysOnTop = true
	gui.Size = UDim2.fromOffset(160, 24)
	gui.StudsOffset = Vector3.new(0, 3, 0)
	local label = Instance.new("TextLabel")
	label.Size = UDim2.fromScale(1, 1)
	label.BackgroundTransparency = 1
	label.TextColor3 = color
	label.TextStrokeTransparency = 0
	label.Font = Enum.Font.GothamBold
	label.TextSize = 14
	label.Text = ""
	label.Parent = gui
	gui.Parent = adornee
	return gui, label
end

local function makeHighlight(adornee, color)
	local h = Instance.new("Highlight")
	h.Adornee = adornee
	h.FillColor = color
	h.OutlineColor = Color3.new(1, 1, 1)
	h.FillTransparency = 0.5
	h.DepthMode = Enum.HighlightDepthMode.AlwaysOnTop
	h.Parent = adornee
	return h
end

local function clearPlayerESP(plr)
	local o = playerESP[plr]
	if o then
		for _, i in ipairs(o.items) do
			pcall(function()
				i:Destroy()
			end)
		end
		playerESP[plr] = nil
	end
end

local function updatePlayerESP()
	local root = getRoot()
	for _, plr in ipairs(Players:GetPlayers()) do
		if plr ~= lp then
			local char = plr.Character
			local head = char and char:FindFirstChild("Head")
			local inRange = true
			if char and head and root and CONFIG.ESPRange > 0 then
				inRange = (head.Position - root.Position).Magnitude <= CONFIG.ESPRange
			end
			if char and head and inRange then
				local o = playerESP[plr]
				if not o or o.char ~= char then
					clearPlayerESP(plr)
					local h = makeHighlight(char, Color3.fromRGB(255, 70, 70))
					local gui, label = makeLabel(head, Color3.fromRGB(255, 255, 255))
					o = { char = char, items = { h, gui }, label = label }
					playerESP[plr] = o
				end
				local dist = root and math.floor((head.Position - root.Position).Magnitude) or 0
				o.label.Text = plr.DisplayName .. " [" .. dist .. "]"
			else
				clearPlayerESP(plr)
			end
		end
	end
end

local RARITY_COLORS = {
	common = Color3.fromRGB(200, 200, 200),
	uncommon = Color3.fromRGB(80, 200, 90),
	rare = Color3.fromRGB(70, 130, 255),
	epic = Color3.fromRGB(170, 80, 255),
	legendary = Color3.fromRGB(255, 170, 0),
	mythic = Color3.fromRGB(255, 60, 120),
}

local function rarityColor(inst)
	local r = inst:GetAttribute(CONFIG.RarityAttribute)
	if type(r) == "string" then
		local c = RARITY_COLORS[r:lower()]
		if c then
			return c
		end
	end
	return Color3.fromRGB(255, 220, 0)
end

local function updateEggESP()
	local root = getRoot()
	local list = {}
	for inst in pairs(eggs) do
		if inst.Parent then
			local d = root and (eggPosition(inst) - root.Position).Magnitude or 0
			table.insert(list, { inst = inst, dist = d })
		end
	end
	table.sort(list, function(a, b)
		return a.dist < b.dist
	end)
	local keep = {}
	for i = 1, math.min(CONFIG.MaxEggESP, #list) do
		local inst = list[i].inst
		keep[inst] = true
		local o = eggESP[inst]
		if not o then
			local part = inst:IsA("BasePart") and inst or inst:FindFirstChildWhichIsA("BasePart", true)
			if part then
				local color = rarityColor(inst)
				local h = makeHighlight(inst, color)
				local gui, label = makeLabel(part, color)
				o = { items = { h, gui }, label = label }
				eggESP[inst] = o
			end
		end
		if o then
			o.label.Text = inst.Name .. " [" .. math.floor(list[i].dist) .. "]"
		end
	end
	for inst in pairs(eggESP) do
		if not keep[inst] then
			clearEggESP(inst)
		end
	end
end

local function clearTracers()
	for plr, line in pairs(tracerLines) do
		pcall(function()
			line:Remove()
		end)
		tracerLines[plr] = nil
	end
end

local hasDrawing = typeof(Drawing) == "table" or typeof(Drawing) == "userdata"
	or (type(Drawing) == "table")

-- fly ---------------------------------------------------------------------

local function stopFly()
	if flyBV then
		flyBV:Destroy()
		flyBV = nil
	end
	if flyBG then
		flyBG:Destroy()
		flyBG = nil
	end
	local hum = getHum()
	if hum then
		hum.PlatformStand = false
	end
end

local function startFly()
	local root, hum = getRoot(), getHum()
	if not root then
		return
	end
	flyBV = Instance.new("BodyVelocity")
	flyBV.MaxForce = Vector3.one * 1e9
	flyBV.Velocity = Vector3.zero
	flyBV.Parent = root
	flyBG = Instance.new("BodyGyro")
	flyBG.MaxTorque = Vector3.one * 1e9
	flyBG.P = 1e4
	flyBG.CFrame = root.CFrame
	flyBG.Parent = root
	if hum then
		hum.PlatformStand = true
	end
end

-- features ----------------------------------------------------------------

local origSpeed, origJump, origUseJump

local F = {}

F.speed = feature("Speed Boost", function()
	local h = getHum()
	origSpeed = h and h.WalkSpeed
end, function()
	local h = getHum()
	if h and origSpeed then
		h.WalkSpeed = origSpeed
	end
end)

F.jump = feature("Jump Boost", function()
	local h = getHum()
	if h then
		origJump, origUseJump = h.JumpPower, h.UseJumpPower
	end
end, function()
	local h = getHum()
	if h and origJump then
		h.UseJumpPower = origUseJump
		h.JumpPower = origJump
	end
end)

F.infJump = feature("Infinite Jump")
bind(UserInputService.JumpRequest, function()
	if F.infJump.enabled then
		local h = getHum()
		if h then
			h:ChangeState(Enum.HumanoidStateType.Jumping)
		end
	end
end)

F.fly = feature("Fly", startFly, stopFly)
F.noclip = feature("Noclip")
F.clickTp = feature("Click Teleport (Ctrl+Click)")
F.antiVoid = feature("Anti-Void")

F.antiRag = feature("Anti-Ragdoll", nil, function()
	local h = getHum()
	if h then
		h:SetStateEnabled(Enum.HumanoidStateType.Ragdoll, true)
		h:SetStateEnabled(Enum.HumanoidStateType.FallingDown, true)
	end
	antiRagHum = nil
end)

F.playerEsp = feature("Player ESP", nil, function()
	for plr in pairs(playerESP) do
		clearPlayerESP(plr)
	end
end)

F.eggEsp = feature("Egg ESP", nil, function()
	for inst in pairs(eggESP) do
		clearEggESP(inst)
	end
end)

F.tracers = feature("Player Tracers", function()
	if not hasDrawing then
		notify("Tracers need the Drawing API (not on your executor)")
	end
end, clearTracers)

F.instant = feature("Instant Prompts", refreshPrompts, refreshPrompts)
F.range = feature("Extended Prompt Range", refreshPrompts, refreshPrompts)
F.noLos = feature("No Line-of-Sight", refreshPrompts, refreshPrompts)
F.autoInteract = feature("Auto Interact", function()
	if typeof(fireproximityprompt) ~= "function" then
		notify("Auto Interact needs fireproximityprompt (not on your executor)")
	end
end)

F.antiAfk = feature("Anti-AFK")
bind(lp.Idled, function()
	if F.antiAfk.enabled then
		VirtualUser:CaptureController()
		VirtualUser:ClickButton2(Vector2.new())
	end
end)

F.autoRejoin = feature("Auto Rejoin on Kick")
do
	local ok = pcall(function()
		local overlay = CoreGui:WaitForChild("RobloxPromptGui", 5):WaitForChild("promptOverlay", 5)
		bind(overlay.ChildAdded, function(child)
			if F.autoRejoin.enabled and child.Name == "ErrorPrompt" then
				task.wait(2)
				TeleportService:Teleport(game.PlaceId, lp)
			end
		end)
	end)
	if not ok then
		warn("[Apex] Auto Rejoin hook unavailable on this executor")
	end
end

F.hideTag = feature("Hide Name Tag", nil, function()
	local h = getHum()
	if h then
		h.DisplayDistanceType = Enum.HumanoidDisplayDistanceType.Viewer
	end
end)

F.fullbright = feature("Fullbright", function()
	fullbrightOrig = {
		Brightness = Lighting.Brightness,
		ClockTime = Lighting.ClockTime,
		FogEnd = Lighting.FogEnd,
		GlobalShadows = Lighting.GlobalShadows,
		Ambient = Lighting.Ambient,
	}
	Lighting.Brightness = 2
	Lighting.ClockTime = 14
	Lighting.FogEnd = 1e6
	Lighting.GlobalShadows = false
	Lighting.Ambient = Color3.fromRGB(180, 180, 180)
end, function()
	if fullbrightOrig then
		for k, v in pairs(fullbrightOrig) do
			Lighting[k] = v
		end
	end
end)

F.fov = feature("FOV Changer")
F.gravity = feature("Gravity Changer", nil, function()
	workspace.Gravity = orig.gravity
end)
F.zoom = feature("Max Zoom", function()
	lp.CameraMaxZoomDistance = 1000
end, function()
	lp.CameraMaxZoomDistance = orig.maxZoom
end)

-- actions (buttons) ---------------------------------------------------------

local actions = {}

local function action(name, fn)
	table.insert(actions, { name = name, fn = fn })
end

action("Teleport to Nearest Egg", function()
	local root, egg = getRoot(), nearestEgg()
	if root and egg then
		root.CFrame = CFrame.new(eggPosition(egg) + Vector3.new(0, 4, 0))
	else
		notify("No egg found (check CONFIG.EggNames)")
	end
end)

action("Teleport to Nearest Player", function()
	local root = getRoot()
	if not root then
		return
	end
	local best, bestDist = nil, math.huge
	for _, plr in ipairs(Players:GetPlayers()) do
		local r = plr ~= lp and plr.Character and plr.Character:FindFirstChild("HumanoidRootPart")
		if r then
			local d = (r.Position - root.Position).Magnitude
			if d < bestDist then
				best, bestDist = r, d
			end
		end
	end
	if best then
		root.CFrame = best.CFrame * CFrame.new(0, 0, 4)
	end
end)

action("Save Position", function()
	local root = getRoot()
	if root then
		savedCF = root.CFrame
		notify("Position saved")
	end
end)

action("Return to Saved Position", function()
	local root = getRoot()
	if root and savedCF then
		root.CFrame = savedCF
	else
		notify("No saved position")
	end
end)

action("Rejoin Server", function()
	TeleportService:TeleportToPlaceInstance(game.PlaceId, game.JobId, lp)
end)

action("Server Hop (Low Population)", function()
	notify("Looking for a server...")
	task.spawn(function()
		local ok, res = pcall(function()
			local url = ("https://games.roblox.com/v1/games/%d/servers/Public?sortOrder=Asc&limit=100"):format(game.PlaceId)
			return HttpService:JSONDecode(game:HttpGet(url))
		end)
		if not ok or type(res) ~= "table" or type(res.data) ~= "table" then
			notify("Server list request failed")
			return
		end
		local best
		for _, s in ipairs(res.data) do
			if s.id ~= game.JobId and s.playing and s.maxPlayers and s.playing < s.maxPlayers then
				if not best or s.playing < best.playing then
					best = s
				end
			end
		end
		if best then
			TeleportService:TeleportToPlaceInstance(game.PlaceId, best.id, lp)
		else
			notify("No other server found")
		end
	end)
end)

action("FPS Boost (one-way)", function()
	Lighting.GlobalShadows = false
	pcall(function()
		settings().Rendering.QualityLevel = Enum.QualityLevel.Level01
	end)
	for _, inst in ipairs(workspace:GetDescendants()) do
		if inst:IsA("ParticleEmitter") or inst:IsA("Trail") or inst:IsA("Smoke") or inst:IsA("Fire") then
			inst.Enabled = false
		end
	end
	for _, inst in ipairs(Lighting:GetChildren()) do
		if inst:IsA("BloomEffect") or inst:IsA("BlurEffect") or inst:IsA("SunRaysEffect") or inst:IsA("DepthOfFieldEffect") then
			inst.Enabled = false
		end
	end
	notify("FPS boost applied")
end)

-- unload / config (forward-declared so the UI can use them) --------------------

local gui
local steppers = {}

-- extra features (v1.1.0) -----------------------------------------------------

local function nearestPlayerRoot()
	local root = getRoot()
	if not root then
		return nil
	end
	local best, bestDist = nil, math.huge
	for _, plr in ipairs(Players:GetPlayers()) do
		local r = plr ~= lp and plr.Character and plr.Character:FindFirstChild("HumanoidRootPart")
		if r then
			local d = (r.Position - root.Position).Magnitude
			if d < bestDist then
				best, bestDist = r, d
			end
		end
	end
	return best
end

F.follow = feature("Follow Nearest Player")
F.bhop = feature("Bunny Hop")

-- prompt esp: labels every proximity prompt (nearest 25) through walls
local promptESP = {}

local function clearPromptESP(p)
	local o = promptESP[p]
	if o then
		pcall(function()
			o.gui:Destroy()
		end)
		promptESP[p] = nil
	end
end

local function updatePromptESP()
	local root = getRoot()
	local list = {}
	for p in pairs(prompts) do
		if p.Parent and p.Enabled then
			local pos = promptPosition(p)
			if pos then
				table.insert(list, { p = p, dist = root and (pos - root.Position).Magnitude or 0 })
			end
		end
	end
	table.sort(list, function(a, b)
		return a.dist < b.dist
	end)
	local keep = {}
	for i = 1, math.min(25, #list) do
		local p = list[i].p
		keep[p] = true
		local o = promptESP[p]
		if not o then
			local adornee = p.Parent:IsA("Attachment") and p.Parent.Parent or p.Parent
			if adornee and adornee:IsA("BasePart") then
				local g, label = makeLabel(adornee, Color3.fromRGB(120, 220, 255))
				o = { gui = g, label = label }
				promptESP[p] = o
			end
		end
		if o then
			local name = p.ActionText ~= "" and p.ActionText or p.Name
			o.label.Text = name .. " [" .. math.floor(list[i].dist) .. "]"
		end
	end
	for p in pairs(promptESP) do
		if not keep[p] then
			clearPromptESP(p)
		end
	end
end

F.promptEsp = feature("Prompt ESP", nil, function()
	for p in pairs(promptESP) do
		clearPromptESP(p)
	end
end)

-- remove fog
local fogOrig
F.noFog = feature("Remove Fog", function()
	fogOrig = { FogEnd = Lighting.FogEnd, FogStart = Lighting.FogStart, atmosphere = {} }
	Lighting.FogStart = 0
	Lighting.FogEnd = 1e6
	for _, a in ipairs(Lighting:GetChildren()) do
		if a:IsA("Atmosphere") then
			fogOrig.atmosphere[a] = a.Density
			a.Density = 0
		end
	end
end, function()
	if fogOrig then
		Lighting.FogEnd = fogOrig.FogEnd
		Lighting.FogStart = fogOrig.FogStart
		for a, density in pairs(fogOrig.atmosphere) do
			if a.Parent then
				a.Density = density
			end
		end
	end
end)

-- fps / ping counter
local hudLabel
local fpsAcc, fpsFrames = 0, 0
F.hud = feature("FPS / Ping Counter", function()
	hudLabel = Instance.new("TextLabel")
	hudLabel.Size = UDim2.fromOffset(170, 22)
	hudLabel.Position = UDim2.new(1, -180, 0, 6)
	hudLabel.BackgroundColor3 = Color3.fromRGB(20, 20, 26)
	hudLabel.BackgroundTransparency = 0.3
	hudLabel.BorderSizePixel = 0
	hudLabel.TextColor3 = Color3.new(1, 1, 1)
	hudLabel.Font = Enum.Font.GothamBold
	hudLabel.TextSize = 13
	hudLabel.Text = ""
	hudLabel.Parent = gui
end, function()
	if hudLabel then
		hudLabel:Destroy()
		hudLabel = nil
	end
end)
bind(RunService.RenderStepped, function(dt)
	if hudLabel then
		fpsAcc += dt
		fpsFrames += 1
		if fpsAcc >= 0.5 then
			local ping = math.floor(lp:GetNetworkPing() * 1000)
			hudLabel.Text = ("FPS %d | Ping %dms"):format(math.floor(fpsFrames / fpsAcc), ping)
			fpsAcc, fpsFrames = 0, 0
		end
	end
end)

-- arrow pointing at the nearest egg
local arrowLabel
F.arrow = feature("Arrow to Nearest Egg", function()
	arrowLabel = Instance.new("TextLabel")
	arrowLabel.AnchorPoint = Vector2.new(0.5, 0.5)
	arrowLabel.Size = UDim2.fromOffset(32, 32)
	arrowLabel.BackgroundTransparency = 1
	arrowLabel.Text = "▲"
	arrowLabel.TextSize = 28
	arrowLabel.Font = Enum.Font.GothamBold
	arrowLabel.TextColor3 = Color3.fromRGB(255, 220, 0)
	arrowLabel.TextStrokeTransparency = 0
	arrowLabel.Visible = false
	arrowLabel.Parent = gui
end, function()
	if arrowLabel then
		arrowLabel:Destroy()
		arrowLabel = nil
	end
end)
bind(RunService.RenderStepped, function()
	if not arrowLabel then
		return
	end
	local cam = workspace.CurrentCamera
	local egg = nearestEgg()
	if not egg or not cam then
		arrowLabel.Visible = false
		return
	end
	local v = cam:WorldToViewportPoint(eggPosition(egg))
	local center = cam.ViewportSize / 2
	local dir = Vector2.new(v.X, v.Y) - center
	if v.Z < 0 then
		dir = -dir
	end
	if dir.Magnitude < 1 then
		dir = Vector2.new(0, -1)
	end
	local unit = dir.Unit
	local p = center + unit * math.min(dir.Magnitude, 180)
	arrowLabel.Visible = true
	arrowLabel.Position = UDim2.fromOffset(p.X, p.Y)
	arrowLabel.Rotation = math.deg(math.atan2(unit.Y, unit.X)) + 90
end)

-- spectate
local spectateIndex = 0

local function stopSpectate()
	local cam, hum = workspace.CurrentCamera, getHum()
	if cam and hum then
		cam.CameraSubject = hum
	end
end

local function spectatePlayer(plr)
	local hum = plr.Character and plr.Character:FindFirstChildOfClass("Humanoid")
	if hum then
		workspace.CurrentCamera.CameraSubject = hum
		notify("Spectating " .. plr.DisplayName)
	else
		notify("That player has no character right now")
	end
end

action("Spectate Next Player", function()
	local others = {}
	for _, plr in ipairs(Players:GetPlayers()) do
		if plr ~= lp then
			table.insert(others, plr)
		end
	end
	if #others == 0 then
		notify("No other players")
		return
	end
	spectateIndex = spectateIndex % #others + 1
	spectatePlayer(others[spectateIndex])
end)
action("Stop Spectating", stopSpectate)

-- update checker
local function checkUpdate(silent)
	task.spawn(function()
		local ok, src = pcall(game.HttpGet, game, CONFIG.SelfUrl)
		if not ok or type(src) ~= "string" then
			if not silent then
				notify("Update check failed")
			end
			return
		end
		local remote = src:match('Version = "([%d%.]+)"')
		if remote and remote ~= CONFIG.Version then
			notify("Update available: v" .. remote .. " (you have v" .. CONFIG.Version .. ")")
		elseif not silent then
			notify("You're on the latest version (v" .. CONFIG.Version .. ")")
		end
	end)
end
action("Check for Updates", function()
	checkUpdate(false)
end)

action("Copy Discord Invite", function()
	if typeof(setclipboard) == "function" then
		setclipboard(CONFIG.Discord)
		notify("Discord invite copied")
	else
		notify(CONFIG.Discord)
	end
end)

local function unload()
	alive = false
	for _, f in ipairs(features) do
		setFeature(f, false)
	end
	clearTracers()
	for inst in pairs(eggESP) do
		clearEggESP(inst)
	end
	for plr in pairs(playerESP) do
		clearPlayerESP(plr)
	end
	for _, c in ipairs(connections) do
		c:Disconnect()
	end
	table.clear(connections)
	if gui then
		gui:Destroy()
	end
	notify("Unloaded")
end

local function saveConfig()
	if typeof(writefile) ~= "function" then
		notify("Config needs writefile (not on your executor)")
		return
	end
	local data = { nums = {}, toggles = {} }
	for _, k in ipairs(NUM_KEYS) do
		data.nums[k] = CONFIG[k]
	end
	for _, f in ipairs(features) do
		data.toggles[f.name] = f.enabled
	end
	writefile(CONFIG.ConfigFile, HttpService:JSONEncode(data))
	notify("Config saved")
end

local function loadConfig(silent)
	if typeof(isfile) ~= "function" or typeof(readfile) ~= "function" or not isfile(CONFIG.ConfigFile) then
		if not silent then
			notify("No saved config found")
		end
		return
	end
	local ok, data = pcall(function()
		return HttpService:JSONDecode(readfile(CONFIG.ConfigFile))
	end)
	if not ok or type(data) ~= "table" then
		notify("Config file is corrupted")
		return
	end
	for k, v in pairs(data.nums or {}) do
		if type(v) == "number" and table.find(NUM_KEYS, k) then
			CONFIG[k] = v
		end
	end
	for _, refresh in ipairs(steppers) do
		refresh()
	end
	for name, value in pairs(data.toggles or {}) do
		local f = byName[name]
		if f then
			setFeature(f, value == true)
		end
	end
	if not silent then
		notify("Config loaded")
	end
end

action("Save Config", saveConfig)
action("Load Config", loadConfig)
action("Unload Script", unload)

-- main loops ----------------------------------------------------------------

local slowTimer, promptTimer = 0, 0

bind(RunService.Heartbeat, function(dt)
	local hum, root = getHum(), getRoot()
	if not hum or not root then
		return
	end

	if F.speed.enabled then
		hum.WalkSpeed = CONFIG.WalkSpeed
	end
	if F.jump.enabled then
		hum.UseJumpPower = true
		hum.JumpPower = CONFIG.JumpPower
	end
	if F.gravity.enabled then
		workspace.Gravity = CONFIG.Gravity
	end
	if F.hideTag.enabled then
		hum.DisplayDistanceType = Enum.HumanoidDisplayDistanceType.None
	end
	if F.follow.enabled then
		local target = nearestPlayerRoot()
		if target then
			hum:MoveTo(target.Position)
		end
	end
	if F.bhop.enabled and hum.FloorMaterial ~= Enum.Material.Air and hum.MoveDirection.Magnitude > 0 then
		hum.Jump = true
	end
	if F.antiRag.enabled and hum ~= antiRagHum then
		hum:SetStateEnabled(Enum.HumanoidStateType.Ragdoll, false)
		hum:SetStateEnabled(Enum.HumanoidStateType.FallingDown, false)
		antiRagHum = hum
	end

	do
		-- always records a safe spot so Anti-Void has somewhere to return you when toggled on
		local floor = workspace.FallenPartsDestroyHeight + 80
		if hum.FloorMaterial ~= Enum.Material.Air and root.Position.Y > floor then
			lastSafeCF = root.CFrame
		elseif F.antiVoid.enabled and root.Position.Y < floor and lastSafeCF then
			root.AssemblyLinearVelocity = Vector3.zero
			root.CFrame = lastSafeCF
		end
	end

	if F.fly.enabled then
		if not flyBV or flyBV.Parent ~= root then
			stopFly()
			startFly()
		end
		if flyBV and flyBG then
			local cf = workspace.CurrentCamera.CFrame
			local dir = Vector3.zero
			if UserInputService:IsKeyDown(Enum.KeyCode.W) then
				dir += cf.LookVector
			end
			if UserInputService:IsKeyDown(Enum.KeyCode.S) then
				dir -= cf.LookVector
			end
			if UserInputService:IsKeyDown(Enum.KeyCode.D) then
				dir += cf.RightVector
			end
			if UserInputService:IsKeyDown(Enum.KeyCode.A) then
				dir -= cf.RightVector
			end
			if UserInputService:IsKeyDown(Enum.KeyCode.Space) then
				dir += Vector3.yAxis
			end
			if UserInputService:IsKeyDown(Enum.KeyCode.LeftShift) then
				dir -= Vector3.yAxis
			end
			flyBV.Velocity = dir.Magnitude > 0 and dir.Unit * CONFIG.FlySpeed or Vector3.zero
			flyBG.CFrame = cf
		end
	end

	slowTimer += dt
	if slowTimer >= 0.2 then
		slowTimer = 0
		if F.playerEsp.enabled then
			updatePlayerESP()
		end
		if F.eggEsp.enabled then
			updateEggESP()
		end
		if F.promptEsp.enabled then
			updatePromptESP()
		end
	end

	promptTimer += dt
	if promptTimer >= 0.25 then
		promptTimer = 0
		if F.instant.enabled or F.range.enabled or F.noLos.enabled then
			refreshPrompts()
		end
		if F.autoInteract.enabled and typeof(fireproximityprompt) == "function" then
			local now = os.clock()
			for p in pairs(prompts) do
				if p.Parent and p.Enabled and promptMatches(p) and (lastFire[p] or 0) + 1 < now then
					local pos = promptPosition(p)
					if pos and (pos - root.Position).Magnitude <= CONFIG.AutoRange then
						lastFire[p] = now
						fireproximityprompt(p)
					end
				end
			end
		end
	end
end)

-- noclip runs on Stepped so it applies before physics each frame
bind(RunService.Stepped, function()
	if F.noclip.enabled then
		local char = getChar()
		if char then
			for _, part in ipairs(char:GetDescendants()) do
				if part:IsA("BasePart") then
					part.CanCollide = false
				end
			end
		end
	end
end)

bind(RunService.RenderStepped, function()
	local cam = workspace.CurrentCamera
	if F.fov.enabled and cam then
		cam.FieldOfView = CONFIG.FOV
	end
	if F.tracers.enabled and hasDrawing and cam then
		local from = Vector2.new(cam.ViewportSize.X / 2, cam.ViewportSize.Y)
		for _, plr in ipairs(Players:GetPlayers()) do
			if plr ~= lp then
				local r = plr.Character and plr.Character:FindFirstChild("HumanoidRootPart")
				local line = tracerLines[plr]
				if r then
					local pos, onScreen = cam:WorldToViewportPoint(r.Position)
					if not line then
						line = Drawing.new("Line")
						line.Thickness = 1.5
						line.Color = Color3.fromRGB(255, 70, 70)
						tracerLines[plr] = line
					end
					line.From = from
					line.To = Vector2.new(pos.X, pos.Y)
					line.Visible = onScreen
				elseif line then
					line.Visible = false
				end
			end
		end
	end
end)

bind(Players.PlayerRemoving, function(plr)
	clearPlayerESP(plr)
	local line = tracerLines[plr]
	if line then
		pcall(function()
			line:Remove()
		end)
		tracerLines[plr] = nil
	end
end)

-- click teleport
bind(UserInputService.InputBegan, function(input, processed)
	if processed or not F.clickTp.enabled then
		return
	end
	if input.UserInputType == Enum.UserInputType.MouseButton1 and UserInputService:IsKeyDown(Enum.KeyCode.LeftControl) then
		local root = getRoot()
		if root then
			root.CFrame = CFrame.new(lp:GetMouse().Hit.Position + Vector3.new(0, 4, 0))
		end
	end
end)

-- ui --------------------------------------------------------------------------

gui = Instance.new("ScreenGui")
gui.Name = "ApexHub"
gui.ResetOnSpawn = false
gui.IgnoreGuiInset = true
local parented = pcall(function()
	gui.Parent = (typeof(gethui) == "function" and gethui()) or CoreGui
end)
if not parented or not gui.Parent then
	gui.Parent = lp:WaitForChild("PlayerGui")
end

local main = Instance.new("Frame")
main.Size = UDim2.fromOffset(290, 420)
main.Position = UDim2.new(0, 20, 0.5, -210)
main.BackgroundColor3 = Color3.fromRGB(20, 20, 26)
main.BorderSizePixel = 0
main.Parent = gui
Instance.new("UICorner", main).CornerRadius = UDim.new(0, 8)

local title = Instance.new("TextLabel")
title.Size = UDim2.new(1, 0, 0, 30)
title.BackgroundColor3 = Color3.fromRGB(255, 170, 0)
title.BorderSizePixel = 0
title.Font = Enum.Font.GothamBold
title.TextSize = 14
title.TextColor3 = Color3.fromRGB(20, 20, 26)
title.Text = "Apex Hub | Steal An Egg"
title.Parent = main
Instance.new("UICorner", title).CornerRadius = UDim.new(0, 8)

local scroll = Instance.new("ScrollingFrame")
scroll.Position = UDim2.fromOffset(0, 34)
scroll.Size = UDim2.new(1, 0, 1, -38)
scroll.BackgroundTransparency = 1
scroll.BorderSizePixel = 0
scroll.ScrollBarThickness = 4
scroll.CanvasSize = UDim2.new()
scroll.AutomaticCanvasSize = Enum.AutomaticSize.Y
scroll.Parent = main
local layout = Instance.new("UIListLayout", scroll)
layout.SortOrder = Enum.SortOrder.LayoutOrder
layout.Padding = UDim.new(0, 4)
layout.HorizontalAlignment = Enum.HorizontalAlignment.Center
local pad = Instance.new("UIPadding", scroll)
pad.PaddingTop = UDim.new(0, 2)
pad.PaddingBottom = UDim.new(0, 6)

-- drag
do
	local dragging, dragStart, startPos
	bind(title.InputBegan, function(input)
		if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
			dragging, dragStart, startPos = true, input.Position, main.Position
		end
	end)
	bind(UserInputService.InputChanged, function(input)
		if dragging and (input.UserInputType == Enum.UserInputType.MouseMovement or input.UserInputType == Enum.UserInputType.Touch) then
			local d = input.Position - dragStart
			main.Position = UDim2.new(startPos.X.Scale, startPos.X.Offset + d.X, startPos.Y.Scale, startPos.Y.Offset + d.Y)
		end
	end)
	bind(UserInputService.InputEnded, function(input)
		if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
			dragging = false
		end
	end)
end

local accentLabels = {}
local function header(text)
	local l = Instance.new("TextLabel")
	l.Size = UDim2.new(1, -16, 0, 20)
	l.BackgroundTransparency = 1
	l.Font = Enum.Font.GothamBold
	l.TextSize = 12
	l.TextColor3 = Color3.fromRGB(255, 170, 0)
	l.TextXAlignment = Enum.TextXAlignment.Left
	l.Text = text
	l.Parent = scroll
	table.insert(accentLabels, l)
end

local function styleButton(b)
	b.Size = UDim2.new(1, -16, 0, 26)
	b.BorderSizePixel = 0
	b.Font = Enum.Font.Gotham
	b.TextSize = 13
	b.TextColor3 = Color3.new(1, 1, 1)
	Instance.new("UICorner", b).CornerRadius = UDim.new(0, 5)
end

local function toggleRow(f)
	local b = Instance.new("TextButton")
	styleButton(b)
	f.refresh = function()
		b.Text = f.name .. ": " .. (f.enabled and "ON" or "OFF")
		b.BackgroundColor3 = f.enabled and Color3.fromRGB(40, 140, 70) or Color3.fromRGB(45, 45, 56)
	end
	f.refresh()
	bind(b.MouseButton1Click, function()
		setFeature(f, not f.enabled)
	end)
	b.Parent = scroll
end

local function stepperRow(label, key, step, minV, maxV)
	local row = Instance.new("Frame")
	row.Size = UDim2.new(1, -16, 0, 26)
	row.BackgroundColor3 = Color3.fromRGB(32, 32, 42)
	row.BorderSizePixel = 0
	Instance.new("UICorner", row).CornerRadius = UDim.new(0, 5)
	row.Parent = scroll

	local text = Instance.new("TextLabel")
	text.Size = UDim2.new(1, -60, 1, 0)
	text.Position = UDim2.fromOffset(8, 0)
	text.BackgroundTransparency = 1
	text.Font = Enum.Font.Gotham
	text.TextSize = 13
	text.TextColor3 = Color3.new(1, 1, 1)
	text.TextXAlignment = Enum.TextXAlignment.Left
	text.Parent = row

	local function refresh()
		text.Text = label .. ": " .. tostring(CONFIG[key])
	end
	refresh()
	table.insert(steppers, refresh)

	local function mini(txt, xOffset, delta)
		local b = Instance.new("TextButton")
		b.Size = UDim2.fromOffset(24, 20)
		b.Position = UDim2.new(1, xOffset, 0, 3)
		b.BackgroundColor3 = Color3.fromRGB(55, 55, 70)
		b.BorderSizePixel = 0
		b.Font = Enum.Font.GothamBold
		b.TextSize = 14
		b.TextColor3 = Color3.new(1, 1, 1)
		b.Text = txt
		b.Parent = row
		bind(b.MouseButton1Click, function()
			CONFIG[key] = math.clamp(CONFIG[key] + delta, minV, maxV)
			refresh()
		end)
	end
	mini("-", -54, -step)
	mini("+", -28, step)
end

local function actionRow(a)
	local b = Instance.new("TextButton")
	styleButton(b)
	b.BackgroundColor3 = Color3.fromRGB(60, 60, 110)
	b.Text = a.name
	bind(b.MouseButton1Click, a.fn)
	b.Parent = scroll
end

header("MOVEMENT")
toggleRow(F.speed)
stepperRow("Walk Speed", "WalkSpeed", 4, 16, 200)
toggleRow(F.jump)
stepperRow("Jump Power", "JumpPower", 5, 50, 300)
toggleRow(F.infJump)
toggleRow(F.fly)
stepperRow("Fly Speed", "FlySpeed", 10, 20, 300)
toggleRow(F.noclip)
toggleRow(F.clickTp)
toggleRow(F.antiVoid)
toggleRow(F.antiRag)
toggleRow(F.follow)
toggleRow(F.bhop)

header("VISUALS")
toggleRow(F.playerEsp)
toggleRow(F.eggEsp)
toggleRow(F.tracers)
stepperRow("ESP Range (0 = any)", "ESPRange", 100, 0, 3000)
toggleRow(F.fullbright)
toggleRow(F.fov)
stepperRow("FOV", "FOV", 5, 40, 120)
toggleRow(F.gravity)
stepperRow("Gravity", "Gravity", 20, 0, 400)
toggleRow(F.zoom)
toggleRow(F.hideTag)
toggleRow(F.promptEsp)
toggleRow(F.arrow)
toggleRow(F.noFog)
toggleRow(F.hud)

header("PROMPTS AND EGGS")
toggleRow(F.instant)
toggleRow(F.range)
stepperRow("Prompt Range", "PromptRange", 5, 10, 100)
toggleRow(F.noLos)
toggleRow(F.autoInteract)
stepperRow("Auto Range", "AutoRange", 3, 5, 60)

header("UTILITY")
toggleRow(F.antiAfk)
toggleRow(F.autoRejoin)

header("ACTIONS")
for _, a in ipairs(actions) do
	actionRow(a)
end

bind(UserInputService.InputBegan, function(input, processed)
	if not processed and input.KeyCode == Enum.KeyCode.RightShift then
		main.Visible = not main.Visible
	end
end)

-- zones -----------------------------------------------------------------------
-- Scans Workspace (and one level inside Workspace folders) for names matching
-- CONFIG.ZoneKeywords and makes a teleport button for each match.

header("ZONES")

local zoneButtons = {}
local zoneBox

local function zoneMatches(inst)
	local name = inst.Name:lower()
	for _, key in ipairs(CONFIG.ZoneKeywords) do
		if name:find(key, 1, true) then
			return true
		end
	end
	return false
end

local function zonePosition(inst)
	if inst:IsA("Model") then
		return inst:GetPivot().Position
	elseif inst:IsA("BasePart") then
		return inst.Position
	elseif inst:IsA("Folder") then
		local part = inst:FindFirstChildWhichIsA("BasePart", true)
		return part and part.Position
	end
	return nil
end

local function scanZones()
	for _, b in ipairs(zoneButtons) do
		b:Destroy()
	end
	table.clear(zoneButtons)

	local found = {}
	local function consider(inst)
		if inst ~= workspace.Terrain and inst ~= workspace.CurrentCamera and zoneMatches(inst) and zonePosition(inst) then
			table.insert(found, inst)
		end
	end
	for _, child in ipairs(workspace:GetChildren()) do
		consider(child)
		if child:IsA("Folder") or child:IsA("Model") then
			for _, sub in ipairs(child:GetChildren()) do
				consider(sub)
			end
		end
	end

	table.sort(found, function(a, b)
		return a.Name < b.Name
	end)
	for i = 1, math.min(30, #found) do
		local zone = found[i]
		local b = Instance.new("TextButton")
		styleButton(b)
		b.BackgroundColor3 = Color3.fromRGB(70, 60, 40)
		b.Text = "TP: " .. zone.Name
		bind(b.MouseButton1Click, function()
			local root = getRoot()
			local pos = zone.Parent and zonePosition(zone)
			if root and pos then
				root.CFrame = CFrame.new(pos + Vector3.new(0, 5, 0))
			else
				notify("That zone is gone, rescan")
			end
		end)
		b.Size = UDim2.new(1, 0, 0, 26)
		b.Parent = zoneBox
		table.insert(zoneButtons, b)
	end
	notify(#found .. " zone(s) found")
end

local scanBtn = Instance.new("TextButton")
styleButton(scanBtn)
scanBtn.BackgroundColor3 = Color3.fromRGB(60, 60, 110)
scanBtn.Text = "Scan Zones"
bind(scanBtn.MouseButton1Click, scanZones)
scanBtn.Parent = scroll

local function makeBox()
	local box = Instance.new("Frame")
	box.Size = UDim2.new(1, -16, 0, 0)
	box.AutomaticSize = Enum.AutomaticSize.Y
	box.BackgroundTransparency = 1
	local l = Instance.new("UIListLayout", box)
	l.Padding = UDim.new(0, 4)
	box.Parent = scroll
	return box
end

local function smallButton(text, color, parent, fn)
	local b = Instance.new("TextButton")
	styleButton(b)
	b.Size = UDim2.new(1, 0, 0, 26)
	b.BackgroundColor3 = color
	b.Text = text
	bind(b.MouseButton1Click, fn)
	b.Parent = parent
	return b
end

zoneBox = makeBox()

-- waypoints: save your current spot, get a teleport button for it -------------

header("WAYPOINTS")
local wpBox
local wpCount = 0
smallButton("Save Waypoint Here", Color3.fromRGB(60, 60, 110), scroll, function()
	local root = getRoot()
	if not root then
		return
	end
	wpCount += 1
	local cf = root.CFrame
	local n = wpCount
	smallButton("TP: Waypoint " .. n, Color3.fromRGB(40, 90, 90), wpBox, function()
		local r = getRoot()
		if r then
			r.CFrame = cf
		end
	end)
	notify("Waypoint " .. n .. " saved")
end)
smallButton("Clear Waypoints", Color3.fromRGB(110, 50, 50), scroll, function()
	for _, c in ipairs(wpBox:GetChildren()) do
		if c:IsA("TextButton") then
			c:Destroy()
		end
	end
	wpCount = 0
end)
wpBox = makeBox()

-- player list: tp and spectate per player -------------------------------------

header("PLAYERS")
local playerBox
smallButton("Refresh Player List", Color3.fromRGB(60, 60, 110), scroll, function()
	for _, c in ipairs(playerBox:GetChildren()) do
		if c:IsA("TextButton") then
			c:Destroy()
		end
	end
	for _, plr in ipairs(Players:GetPlayers()) do
		if plr ~= lp then
			smallButton("TP: " .. plr.DisplayName, Color3.fromRGB(70, 60, 40), playerBox, function()
				local root = getRoot()
				local r = plr.Character and plr.Character:FindFirstChild("HumanoidRootPart")
				if root and r then
					root.CFrame = r.CFrame * CFrame.new(0, 0, 4)
				end
			end)
			smallButton("Spectate: " .. plr.DisplayName, Color3.fromRGB(50, 70, 50), playerBox, function()
				spectatePlayer(plr)
			end)
		end
	end
end)
playerBox = makeBox()

-- themes and minimize ---------------------------------------------------------

local THEMES = {
	Color3.fromRGB(255, 170, 0),
	Color3.fromRGB(80, 160, 255),
	Color3.fromRGB(80, 210, 120),
	Color3.fromRGB(255, 90, 160),
}
local themeIndex = 1
header("MENU")
smallButton("Cycle Theme", Color3.fromRGB(60, 60, 110), scroll, function()
	themeIndex = themeIndex % #THEMES + 1
	title.BackgroundColor3 = THEMES[themeIndex]
	for _, l in ipairs(accentLabels) do
		l.TextColor3 = THEMES[themeIndex]
	end
end)

do
	local minBtn = Instance.new("TextButton")
	minBtn.Size = UDim2.fromOffset(28, 26)
	minBtn.Position = UDim2.new(1, -32, 0, 2)
	minBtn.BackgroundTransparency = 1
	minBtn.Font = Enum.Font.GothamBold
	minBtn.TextSize = 18
	minBtn.TextColor3 = Color3.fromRGB(20, 20, 26)
	minBtn.Text = "-"
	minBtn.Parent = title
	local minimized = false
	bind(minBtn.MouseButton1Click, function()
		minimized = not minimized
		scroll.Visible = not minimized
		main.Size = minimized and UDim2.fromOffset(290, 30) or UDim2.fromOffset(290, 420)
		minBtn.Text = minimized and "+" or "-"
	end)
end

-- mobile: floating button to show/hide the menu
if UserInputService.TouchEnabled then
	local toggle = Instance.new("TextButton")
	toggle.Size = UDim2.fromOffset(46, 46)
	toggle.Position = UDim2.new(1, -56, 0.5, -23)
	toggle.BackgroundColor3 = Color3.fromRGB(255, 170, 0)
	toggle.BorderSizePixel = 0
	toggle.Font = Enum.Font.GothamBold
	toggle.TextSize = 13
	toggle.TextColor3 = Color3.fromRGB(20, 20, 26)
	toggle.Text = "Apex"
	Instance.new("UICorner", toggle).CornerRadius = UDim.new(1, 0)
	toggle.Parent = gui
	bind(toggle.MouseButton1Click, function()
		main.Visible = not main.Visible
	end)
end

-- keep rows in build order
for i, child in ipairs(scroll:GetChildren()) do
	if child:IsA("GuiObject") then
		child.LayoutOrder = i
	end
end

-- fly speed hotkeys: ] faster, [ slower
bind(UserInputService.InputBegan, function(input, processed)
	if processed then
		return
	end
	if input.KeyCode == Enum.KeyCode.RightBracket then
		CONFIG.FlySpeed = math.clamp(CONFIG.FlySpeed + 10, 20, 300)
	elseif input.KeyCode == Enum.KeyCode.LeftBracket then
		CONFIG.FlySpeed = math.clamp(CONFIG.FlySpeed - 10, 20, 300)
	else
		return
	end
	for _, refresh in ipairs(steppers) do
		refresh()
	end
	notify("Fly speed: " .. CONFIG.FlySpeed)
end)

-- startup: restore saved config, then check for a newer version
loadConfig(true)
checkUpdate(true)

notify("Apex Hub v" .. CONFIG.Version .. " loaded | RightShift hides the menu")
