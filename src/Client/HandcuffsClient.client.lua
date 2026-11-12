local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Config = require(ReplicatedStorage:WaitForChild("CuffConfig"))
local Remotes = ReplicatedStorage:WaitForChild("CuffRemotes")
local ArrestRequest = Remotes:WaitForChild("ArrestRequest")
local ReleaseRequest = Remotes:WaitForChild("ReleaseRequest")

local tool = script.Parent
local localPlayer = Players.LocalPlayer

type PromptEntry = {
	Prompt: ProximityPrompt,
	Attachment: Attachment,
	Connection: RBXScriptConnection,
	Root: BasePart,
	Mode: string,
}

local prompts: { [Player]: PromptEntry } = {}
local scanThread: thread? = nil
local lastFire = 0

local function getRoot(player: Player)
	local character = player.Character
	if not character then return nil end
	local humanoid = character:FindFirstChildOfClass("Humanoid")
	local root = character:FindFirstChild("HumanoidRootPart")
	if humanoid and root and root:IsA("BasePart") and humanoid.Health > 0 then
		return root, humanoid
	end
	return nil
end

local function isCuffed(player: Player): boolean
	local value = player:FindFirstChild("IsCuffed")
	return value ~= nil and value:IsA("BoolValue") and value.Value
end

-- nil = no prompt for this guy
local function getMode(other: Player): string?
	if not isCuffed(other) then
		return "Arrest"
	end
	local cuffedBy = other:FindFirstChild("CuffedBy")
	local officer = if cuffedBy and cuffedBy:IsA("ObjectValue") then cuffedBy.Value else nil
	if officer == localPlayer then
		return "Release"
	end
	if Config.AllowReleaseOthersPrisoners and officer ~= nil then
		return "Release"
	end
	return nil
end

local function actionText(mode: string): string
	return if mode == "Release" then Config.PromptActionTextRelease else Config.PromptActionText
end

local function removePrompt(player: Player)
	local entry = prompts[player]
	if not entry then return end
	prompts[player] = nil
	entry.Connection:Disconnect()
	entry.Attachment:Destroy() -- prompt dies with it
end

local function clearAllPrompts()
	for player in prompts do
		removePrompt(player)
	end
end

local function createPrompt(target: Player, root: BasePart, mode: string)
	-- all local, nobody else sees it
	local attachment = Instance.new("Attachment")
	attachment.Name = "CuffPromptAnchor"
	attachment.Position = Config.PromptOffset
	attachment.Parent = root

	local prompt = Instance.new("ProximityPrompt")
	prompt.Name = "CuffPrompt"
	prompt.ActionText = actionText(mode)
	prompt.ObjectText = target.DisplayName
	prompt.KeyboardKeyCode = Config.PromptKeyboardKey
	prompt.GamepadKeyCode = Config.PromptGamepadKey
	prompt.HoldDuration = Config.PromptHoldDuration
	prompt.MaxActivationDistance = Config.PromptActivationDistance
	prompt.RequiresLineOfSight = false
	prompt.Exclusivity = Enum.ProximityPromptExclusivity.OnePerButton
	prompt.Parent = attachment

	local entry = { Prompt = prompt, Attachment = attachment, Root = root, Mode = mode }
	entry.Connection = prompt.Triggered:Connect(function()
		local now = os.clock()
		if now - lastFire < Config.ClientRequestCooldown then return end
		lastFire = now
		if entry.Mode == "Release" then
			ReleaseRequest:FireServer(target)
		else
			ArrestRequest:FireServer(target)
		end
	end)
	prompts[target] = entry
end

local function scan()
	local myRoot = getRoot(localPlayer)
	if not myRoot or isCuffed(localPlayer) then
		clearAllPrompts()
		return
	end

	local showDistance = Config.PromptActivationDistance + Config.PromptShowMargin
	for _, other in Players:GetPlayers() do
		if other == localPlayer then continue end

		local root, humanoid = getRoot(other)
		local mode = nil
		if root and humanoid and not humanoid.Sit and (root.Position - myRoot.Position).Magnitude <= showDistance then
			mode = getMode(other)
		end

		local entry = prompts[other]
		if mode and root then
			if entry and entry.Root ~= root then -- respawned, old one is stale
				removePrompt(other)
				entry = nil
			end
			if not entry then
				createPrompt(other, root, mode)
			elseif entry.Mode ~= mode then
				entry.Mode = mode
				entry.Prompt.ActionText = actionText(mode)
			end
		elseif entry then
			removePrompt(other)
		end
	end
end

local function stopScanning()
	if scanThread then
		task.cancel(scanThread)
		scanThread = nil
	end
	clearAllPrompts()
end

local function startScanning()
	stopScanning()
	scanThread = task.spawn(function()
		while true do
			scan()
			task.wait(Config.ScanInterval)
		end
	end)
end

tool.Equipped:Connect(startScanning)
tool.Unequipped:Connect(stopScanning)
script.Destroying:Connect(stopScanning)
localPlayer.CharacterRemoving:Connect(stopScanning)
Players.PlayerRemoving:Connect(removePrompt)

-- tool might already be equipped when we load
if tool.Parent == localPlayer.Character then
	startScanning()
end