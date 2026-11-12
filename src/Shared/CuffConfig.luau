return {
	ToolName = "Handcuffs",

	-- client prompt
	PromptActionText = "Arrest",
	PromptActionTextRelease = "Release",
	PromptActivationDistance = 7, -- studs
	PromptShowMargin = 4,         -- studs, prompt shows up this much before its reachable
	PromptHoldDuration = 0.35,    -- sec
	PromptOffset = Vector3.new(0, 2.5, 0),
	PromptKeyboardKey = Enum.KeyCode.E,
	PromptGamepadKey = Enum.KeyCode.ButtonX,
	ScanInterval = 0.2,           -- sec
	ClientRequestCooldown = 0.75, -- sec

	-- server rules
	MaxArrestDistance = 12, -- studs, keep above PromptActivationDistance or lag eats arrests
	ArrestCooldown = 1,     -- sec
	ReleaseCooldown = 0.5,  -- sec
	MaxCuffedPerArrester = 1,
	PrisonerSpacing = 2.5,  -- studs between prisoners in the line
	ReleaseOnUnequip = true,
	DisableToolsWhileCuffed = true,

	-- false = only your own prisoners, true = anyone holding the tool
	-- (CuffService.CanRelease still gets a vote)
	AllowReleaseOthersPrisoners = false,

	-- weld / follow
	FollowDistance = 3,           -- studs in front of officer
	IntegrityCheckInterval = 0.5, -- sec
	MaxWeldDrift = 15,            -- studs, further than this = auto release

	-- arm pose, degrees, torso space
	CuffPoseLeftArmDegrees = Vector3.new(0, 25, 30),
	CuffPoseRightArmDegrees = Vector3.new(-25, -35, -25),
	CuffPoseEulerOrder = "XYZ", -- or "YXZ" (matches Part.Orientation)

	Debug = false,
}