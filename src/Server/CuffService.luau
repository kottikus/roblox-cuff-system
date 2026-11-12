local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Config = require(ReplicatedStorage:WaitForChild("CuffConfig"))

local R6_ROOT_HEIGHT = 3

type Joint = { Motor: Motor6D, Default: CFrame, Posed: CFrame }

type CuffState = {
	Target: Player,
	Arrester: Player,
	TargetCharacter: Model,
	ArresterCharacter: Model,
	TargetHumanoid: Humanoid,
	TargetRoot: BasePart,
	Weld: WeldConstraint,
	Pose: { Joint },
	Connections: { RBXScriptConnection },
	Saved: { WalkSpeed: number, JumpPower: number, JumpHeight: number, AutoRotate: boolean },
}

type ArresterInfo = {
	Targets: { [Player]: boolean },
	Count: number,
	Connections: { RBXScriptConnection },
	Root: BasePart,
}

local cuffs: { [Player]: CuffState } = {}
local arresters: { [Player]: ArresterInfo } = {}
local lastArrestRequest: { [Player]: number } = {}
local lastReleaseRequest: { [Player]: number } = {}
local initialized = false

local cuffedSignal = Instance.new("BindableEvent")
local releasedSignal = Instance.new("BindableEvent")

local CuffService = {}

--- Fires with (target, arrester) after someone gets cuffed.
CuffService.PlayerCuffed = cuffedSignal.Event
--- Fires with (target, arrester, reason) after someone is freed.
CuffService.PlayerReleased = releasedSignal.Event

--- Override for extra arrest rules. Return false to block.
CuffService.CanArrest = function(_arrester: Player, _target: Player): boolean
	return true
end

--- Only asked when an officer frees somebody elses prisoner.
CuffService.CanRelease = function(_officer: Player, _target: Player): boolean
	return true
end

local function debugLog(...)
	if Config.Debug then
		warn("[CuffService]", ...)
	end
end

local function ensureValues(player: Player)
	local isCuffed = player:FindFirstChild("IsCuffed")
	if not (isCuffed and isCuffed:IsA("BoolValue")) then
		if isCuffed then isCuffed:Destroy() end
		isCuffed = Instance.new("BoolValue")
		isCuffed.Name = "IsCuffed"
		isCuffed.Parent = player
	end

	local cuffedBy = player:FindFirstChild("CuffedBy")
	if not (cuffedBy and cuffedBy:IsA("ObjectValue")) then
		if cuffedBy then cuffedBy:Destroy() end
		cuffedBy = Instance.new("ObjectValue")
		cuffedBy.Name = "CuffedBy"
		cuffedBy.Parent = player
	end

	return isCuffed, cuffedBy
end

local function getCharacterParts(player: Player)
	local character = player.Character
	if not character or not character.Parent then return nil end
	local humanoid = character:FindFirstChildOfClass("Humanoid")
	local root = character:FindFirstChild("HumanoidRootPart")
	if not humanoid or not root or not root:IsA("BasePart") or humanoid.Health <= 0 then
		return nil
	end
	return character, humanoid, root
end

local function findEquippedTool(character: Model): Tool?
	for _, child in character:GetChildren() do
		if child:IsA("Tool") and child.Name == Config.ToolName then
			return child
		end
	end
	return nil
end

-- needed so r6/r15/scaled rigs all land on the same floor after the teleport
local function rootHeightAboveFeet(humanoid: Humanoid, root: BasePart): number
	if humanoid.RigType == Enum.HumanoidRigType.R6 then
		return R6_ROOT_HEIGHT
	end
	return humanoid.HipHeight + root.Size.Y / 2
end

-- animations overwrite Transform every frame so we poke C0 instead, that one sticks
-- and replicates by itself. keeping defaultC0.Rotation on top makes r6 + r15 look the same
local function buildPosedC0(defaultC0: CFrame, degrees: Vector3): CFrame
	local x, y, z = math.rad(degrees.X), math.rad(degrees.Y), math.rad(degrees.Z)
	local rotation = if Config.CuffPoseEulerOrder == "YXZ"
		then CFrame.fromOrientation(x, y, z)
		else CFrame.Angles(x, y, z)
	return CFrame.new(defaultC0.Position) * rotation * defaultC0.Rotation
end

local function findMotor(character: Model, names: { string }): Motor6D?
	for _, name in names do
		local motor = character:FindFirstChild(name, true)
		if motor and motor:IsA("Motor6D") then
			return motor
		end
	end
	return nil
end

local function applyArmPose(character: Model): { Joint }
	local joints = {}

	local function add(names: { string }, degrees: Vector3)
		local motor = findMotor(character, names)
		if not motor then return end
		local default = motor.C0
		local posed = buildPosedC0(default, degrees)
		motor.C0 = posed
		table.insert(joints, { Motor = motor, Default = default, Posed = posed })
	end

	add({ "LeftShoulder", "Left Shoulder" }, Config.CuffPoseLeftArmDegrees) -- r15 name, then r6
	add({ "RightShoulder", "Right Shoulder" }, Config.CuffPoseRightArmDegrees)
	return joints
end

local function restoreArmPose(joints: { Joint })
	for _, joint in joints do
		if joint.Motor.Parent then
			joint.Motor.C0 = joint.Default
		end
	end
end

local function freeNetworkOwner(part: BasePart?)
	if part and part.Parent then
		pcall(function()
			part:SetNetworkOwnershipAuto()
		end)
	end
end

local function teardownArrester(arrester: Player)
	local info = arresters[arrester]
	if not info then return end
	arresters[arrester] = nil
	for _, conn in info.Connections do
		conn:Disconnect()
	end
	freeNetworkOwner(info.Root)
end

local function release(target: Player, reason: string): boolean
	local state = cuffs[target]
	if not state then return false end
	cuffs[target] = nil -- first, so a double call does nothing

	for _, conn in state.Connections do
		conn:Disconnect()
	end

	state.Weld:Destroy()
	restoreArmPose(state.Pose)

	local hum = state.TargetHumanoid
	if hum.Parent then
		hum.WalkSpeed = state.Saved.WalkSpeed
		hum.JumpPower = state.Saved.JumpPower
		hum.JumpHeight = state.Saved.JumpHeight
		hum.AutoRotate = state.Saved.AutoRotate
	end
	freeNetworkOwner(state.TargetRoot)

	local isCuffed = target:FindFirstChild("IsCuffed")
	if isCuffed and isCuffed:IsA("BoolValue") then
		isCuffed.Value = false
	end
	local cuffedBy = target:FindFirstChild("CuffedBy")
	if cuffedBy and cuffedBy:IsA("ObjectValue") then
		cuffedBy.Value = nil
	end

	local info = arresters[state.Arrester]
	if info then
		info.Targets[target] = nil
		info.Count -= 1
		if info.Count <= 0 then
			teardownArrester(state.Arrester)
		end
	end

	debugLog(target.Name, "released:", reason)
	releasedSignal:Fire(target, state.Arrester, reason)
	return true
end

local function releaseAllFrom(arrester: Player, reason: string)
	local info = arresters[arrester]
	if not info then return end
	-- copy first, release() edits Targets while we loop
	local list = {}
	for target in info.Targets do
		table.insert(list, target)
	end
	for _, target in list do
		release(target, reason)
	end
end

local function validateArrest(arrester: Player, target: Player)
	if arrester == target then return false, "self" end
	if arrester.Parent ~= Players or target.Parent ~= Players then return false, "not in game" end
	if cuffs[arrester] then return false, "arrester is cuffed" end
	if cuffs[target] then return false, "target already cuffed" end

	local aChar, aHum, aRoot = getCharacterParts(arrester)
	if not aChar then return false, "arrester dead/invalid" end
	local tChar, tHum, tRoot = getCharacterParts(target)
	if not tChar then return false, "target dead/invalid" end
	if aHum.Sit or tHum.Sit then return false, "seated" end

	local tool = findEquippedTool(aChar)
	if not tool then return false, "tool not equipped" end

	if (aRoot.Position - tRoot.Position).Magnitude > Config.MaxArrestDistance then
		return false, "too far"
	end

	local info = arresters[arrester]
	if info and info.Count >= Config.MaxCuffedPerArrester then
		return false, "cuff limit reached"
	end

	local ok, allowed = pcall(CuffService.CanArrest, arrester, target)
	if not ok or not allowed then return false, "blocked by CanArrest" end

	return true, {
		aChar = aChar, aHum = aHum, aRoot = aRoot,
		tChar = tChar, tHum = tHum, tRoot = tRoot,
		tool = tool,
	}
end

--- Arrests `target` on behalf of `arrester`. Runs every check.
--- @return boolean ok
--- @return string? reason -- only when it fails
function CuffService.Arrest(arrester: Player, target: Player)
	local ok, ctx = validateArrest(arrester, target)
	if not ok then
		debugLog("arrest rejected:", arrester.Name, "->", target.Name, ctx)
		return false, ctx
	end

	-- cuffed guys cant hold prisoners
	releaseAllFrom(target, "Arrested")

	local isCuffed, cuffedBy = ensureValues(target)

	local info = arresters[arrester]
	if not info then
		info = { Targets = {}, Count = 0, Connections = {}, Root = ctx.aRoot }
		arresters[arrester] = info

		local aChar, tool = ctx.aChar, ctx.tool
		table.insert(info.Connections, ctx.aHum.Died:Connect(function()
			releaseAllFrom(arrester, "ArresterDied")
		end))

		if Config.ReleaseOnUnequip then
			table.insert(info.Connections, tool.Unequipped:Connect(function()
				releaseAllFrom(arrester, "ToolUnequipped")
			end))
			-- drop / backpack / destroy all end up here
			table.insert(info.Connections, tool.AncestryChanged:Connect(function()
				if tool.Parent ~= aChar then
					releaseAllFrom(arrester, "ToolLost")
				end
			end))
		end
	end

	-- order matters here: take physics -> teleport -> weld (weld remembers the offset
	-- at creation) -> give the officer ownership of the pair so it doesnt jitter
	local offset = Config.FollowDistance + info.Count * Config.PrisonerSpacing
	local yOffset = rootHeightAboveFeet(ctx.tHum, ctx.tRoot) - rootHeightAboveFeet(ctx.aHum, ctx.aRoot)

	pcall(function()
		ctx.tRoot:SetNetworkOwner(nil)
	end)
	ctx.tChar:PivotTo(ctx.aRoot.CFrame * CFrame.new(0, yOffset, -offset))

	local weld = Instance.new("WeldConstraint")
	weld.Name = "CuffWeld"
	weld.Part0 = ctx.aRoot
	weld.Part1 = ctx.tRoot
	weld.Parent = ctx.tRoot

	pcall(function()
		ctx.aRoot:SetNetworkOwner(arrester)
	end)

	local state: CuffState = {
		Target = target,
		Arrester = arrester,
		TargetCharacter = ctx.tChar,
		ArresterCharacter = ctx.aChar,
		TargetHumanoid = ctx.tHum,
		TargetRoot = ctx.tRoot,
		Weld = weld,
		Pose = {},
		Connections = {},
		Saved = {
			WalkSpeed = ctx.tHum.WalkSpeed,
			JumpPower = ctx.tHum.JumpPower,
			JumpHeight = ctx.tHum.JumpHeight,
			AutoRotate = ctx.tHum.AutoRotate,
		},
	}
	cuffs[target] = state
	info.Targets[target] = true
	info.Count += 1

	ctx.tHum.WalkSpeed = 0
	ctx.tHum.JumpPower = 0
	ctx.tHum.JumpHeight = 0
	ctx.tHum.AutoRotate = false

	table.insert(state.Connections, ctx.tHum.Died:Connect(function()
		release(target, "TargetDied")
	end))
	table.insert(state.Connections, weld.Destroying:Connect(function()
		release(target, "WeldDestroyed")
	end))

	if Config.DisableToolsWhileCuffed then
		ctx.tHum:UnequipTools()
		table.insert(state.Connections, ctx.tChar.ChildAdded:Connect(function(child)
			if child:IsA("Tool") then
				task.defer(function()
					if cuffs[target] == state and ctx.tHum.Parent then
						ctx.tHum:UnequipTools()
					end
				end)
			end
		end))
	end

	isCuffed.Value = true
	cuffedBy.Value = arrester
	state.Pose = applyArmPose(ctx.tChar)

	debugLog(arrester.Name, "arrested", target.Name)
	cuffedSignal:Fire(target, arrester)
	return true
end

--- Frees `target`, no checks at all.
function CuffService.Release(target: Player, reason: string?): boolean
	return release(target, reason or "Manual")
end

--- Frees everyone `arrester` is holding.
function CuffService.ReleaseAllFrom(arrester: Player, reason: string?)
	releaseAllFrom(arrester, reason or "Manual")
end

--- Release with all the checks, this is what the remote uses.
--- @return boolean ok
--- @return string? reason
function CuffService.ReleaseByOfficer(officer: Player, target: Player)
	local state = cuffs[target]
	if not state then return false, "not cuffed" end
	if cuffs[officer] then return false, "officer is cuffed" end

	local oChar, _, oRoot = getCharacterParts(officer)
	if not oChar then return false, "officer dead/invalid" end
	if not findEquippedTool(oChar) then return false, "tool not equipped" end

	if state.Arrester ~= officer then
		if not Config.AllowReleaseOthersPrisoners then
			return false, "not your prisoner"
		end
		local ok, allowed = pcall(CuffService.CanRelease, officer, target)
		if not ok or not allowed then return false, "blocked by CanRelease" end
	end

	local _, _, tRoot = getCharacterParts(target)
	if not tRoot then return false, "target invalid" end
	if (oRoot.Position - tRoot.Position).Magnitude > Config.MaxArrestDistance then
		return false, "too far"
	end

	return release(target, "ReleasedByOfficer"), nil
end

function CuffService.IsCuffed(player: Player): boolean
	return cuffs[player] ~= nil
end

local function integrityStep()
	if next(cuffs) == nil then return end

	local snapshot = {}
	for _, state in cuffs do
		table.insert(snapshot, state)
	end

	for _, state in snapshot do
		local target, arrester, weld = state.Target, state.Arrester, state.Weld
		if cuffs[target] ~= state then continue end

		if target.Character ~= state.TargetCharacter or arrester.Character ~= state.ArresterCharacter then
			release(target, "CharacterChanged")
			continue
		end

		local aChar, _, aRoot = getCharacterParts(arrester)
		local tChar, tHum, tRoot = getCharacterParts(target)
		if not aChar or not tChar then
			release(target, "InvalidCharacter")
		elseif Config.ReleaseOnUnequip and not findEquippedTool(aChar) then
			releaseAllFrom(arrester, "ToolMissing")
		elseif weld.Parent ~= tRoot or not weld.Enabled or weld.Part0 ~= aRoot or weld.Part1 ~= tRoot then
			release(target, "WeldBroken")
		elseif (aRoot.Position - tRoot.Position).Magnitude > Config.MaxWeldDrift then
			release(target, "WeldDrift")
		else
			-- other scripts love touching these, put them back
			if tHum.WalkSpeed ~= 0 then tHum.WalkSpeed = 0 end
			if tHum.JumpPower ~= 0 then tHum.JumpPower = 0 end
			if tHum.JumpHeight ~= 0 then tHum.JumpHeight = 0 end
			if tHum.AutoRotate then tHum.AutoRotate = false end
			for _, joint in state.Pose do
				if joint.Motor.Parent and joint.Motor.C0 ~= joint.Posed then
					joint.Motor.C0 = joint.Posed
				end
			end
		end
	end
end

local function setupPlayer(player: Player)
	ensureValues(player)
	player.CharacterRemoving:Connect(function()
		releaseAllFrom(player, "CharacterRemoving")
		release(player, "CharacterRemoving")
	end)
end

--- Creates the remotes and starts everything. Safe to call twice.
function CuffService.Init()
	if initialized then return end
	initialized = true

	-- parent the folder last so clients never see a half built one
	local folder = Instance.new("Folder")
	folder.Name = "CuffRemotes"
	local arrestRequest = Instance.new("RemoteEvent")
	arrestRequest.Name = "ArrestRequest"
	arrestRequest.Parent = folder
	local releaseRequest = Instance.new("RemoteEvent")
	releaseRequest.Name = "ReleaseRequest"
	releaseRequest.Parent = folder
	folder.Parent = ReplicatedStorage

	arrestRequest.OnServerEvent:Connect(function(player, target)
		if typeof(target) ~= "Instance" or not target:IsA("Player") then return end
		local now = os.clock()
		if now - (lastArrestRequest[player] or 0) < Config.ArrestCooldown then return end
		lastArrestRequest[player] = now
		CuffService.Arrest(player, target)
	end)

	releaseRequest.OnServerEvent:Connect(function(player, target)
		if typeof(target) ~= "Instance" or not target:IsA("Player") then return end
		local now = os.clock()
		if now - (lastReleaseRequest[player] or 0) < Config.ReleaseCooldown then return end
		lastReleaseRequest[player] = now
		local ok, reason = CuffService.ReleaseByOfficer(player, target)
		if not ok then
			debugLog("release rejected:", player.Name, "->", target.Name, reason)
		end
	end)

	for _, player in Players:GetPlayers() do
		setupPlayer(player)
	end
	Players.PlayerAdded:Connect(setupPlayer)

	Players.PlayerRemoving:Connect(function(player)
		releaseAllFrom(player, "ArresterLeft")
		release(player, "TargetLeft")
		lastArrestRequest[player] = nil
		lastReleaseRequest[player] = nil
	end)

	local acc = 0
	RunService.Heartbeat:Connect(function(dt)
		acc += dt
		if acc >= Config.IntegrityCheckInterval then
			acc = 0
			integrityStep()
		end
	end)
end

return CuffService