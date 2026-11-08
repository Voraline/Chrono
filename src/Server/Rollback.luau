--!native
const RunService: RunService = game:GetService("RunService")
const CollectionService: CollectionService = game:GetService("CollectionService")

const Shared = script.Parent.Parent.Shared
const Config = require(Shared.Config)
const Entity = require(Shared.Entity)
const Holder = require(Shared.Holder)
const Signal = require(Shared.Signal)
const Types = require(Shared.Types)
const Warn = require(Shared.Warn)

type Entity = Types.Entity

type Override = {
	GraceUntil: number,
	Bonus: number,
	BonusUntil: number,
	MaxSpeed: number?,
}

type State = {
	Time: number,
	Position: Vector3,
	SweepFrom: Vector3,
	Safe: CFrame,
	SafeTime: number,
	SetStamp: number?,
	Humanoid: Humanoid?,
	Params: RaycastParams?,
	Horizontal: number,
	Vertical: number,
	SpeedPeak: number,
	Idle: number,
	AirTime: number,
	GroundY: number,
	Lift: number,
	Floor: BasePart?,
	FloorOffset: Vector3?,
	Pending: CFrame?,
	PendingUntil: number,
	Reapply: boolean,
	Attempts: number,
	Desynced: boolean,
}

type ClipCache = {
	Params: RaycastParams,
	Model: (Model | BasePart)?,
	Group: string,
	Base: { Instance },
	Extents: Vector3?,
	Margin: number,
	Size: Vector3,
}

const STEP_INTERVAL: number = 1 / 20
const IDLE_EPSILON_SQ: number = 0.01 * 0.01
const JUMP_POWER_SCALE: number = 1.06
const JUMP_VELOCITY_TOLERANCE: number = 1.25
const GROUND_EXTRA_DISTANCE: number = 2
const MIN_HIP_HEIGHT: number = 2
const ACCEPT_RADIUS: number = 8
const REAPPLY_INTERVAL: number = 0.75
const TELEPORT_WINDOW: number = 1.5
const MAX_REAPPLY_ATTEMPTS: number = 4
const SPEED_DECAY: number = 1
const MAX_BONUS: number = 500
const NoclipIgnoreTag: string = "ChronoNoclipIgnore"
const NoclipMinTravel: number = 0.05
const NoclipMinTravelSq: number = NoclipMinTravel * NoclipMinTravel
const NoclipMaxTravel: number = 1024
const NoclipMinExtent: number = 0.05
const NoclipTouchEpsilon: number = 0.001
const NoclipMaxCasts: number = 4

const States: { [Entity]: State } = setmetatable({}, { __mode = "k" }) :: any
const Overrides: { [Entity]: Override } = setmetatable({}, { __mode = "k" }) :: any
const ClipCaches: { [Entity]: ClipCache } = setmetatable({}, { __mode = "k" }) :: any
const ModelKinds: { [Instance]: number } = setmetatable({}, { __mode = "k" }) :: any

const ViolatedSignal =
	Signal.new() :: Types.Signal<(Player: Player, Target: Entity, Kind: string, Excess: number) -> (), Player, Entity, string, number>

local MODE: string = "NONE"
local SPEED_TOLERANCE: number = 1.5
local BANK_TIME: number = 3
local MIN_BANK: number = 12
local AIR_MARGIN: number = 4
local NoclipEnabled: boolean = true
local NoclipMargin: number = 0.3
local LastStep: number = 0

const Rollback = {}

const function ResolveRoot(Target: Entity): BasePart?
	const Model: (Model | BasePart)? = Target.model
	if not Model then
		return nil
	end
	local Kind: number? = ModelKinds[Model]
	if not Kind then
		Kind = if Model:IsA("BasePart") then 1 elseif Model:IsA("Model") then 2 else 0
		ModelKinds[Model] = Kind
	end
	if Kind == 1 then
		return Model :: BasePart
	end
	if Kind == 2 then
		if Target._chronoPrimary then
			return Entity.GetPrimaryPart(Target)
		end
		return (Model :: Model).PrimaryPart
	end
	return nil
end

const function Observe(Target: Entity): (CFrame?, BasePart?, boolean)
	if Target.modelReplicationMode == "NATIVE" and not Target._lockedCFReplication then
		const Part: BasePart? = ResolveRoot(Target)
		if Part then
			return Part.CFrame, Part, true
		end
		return Target.latestCFrame, nil, true
	end
	return Target.latestCFrame, nil, false
end

const function GetHumanoid(Target: Entity, State: State): Humanoid?
	const Cached: Humanoid? = State.Humanoid
	if Cached and Cached.Parent then
		return Cached
	end
	const Model: (Model | BasePart)? = Target.model
	local Humanoid: Humanoid? = nil
	if Model and Model:IsA("Model") then
		Humanoid = Model:FindFirstChildWhichIsA("Humanoid")
	end
	State.Humanoid = Humanoid
	State.Params = nil
	return Humanoid
end

const function GetParams(Target: Entity, State: State): RaycastParams
	const Existing: RaycastParams? = State.Params
	if Existing then
		return Existing
	end
	const Params: RaycastParams = RaycastParams.new()
	Params.FilterType = Enum.RaycastFilterType.Exclude
	Params.FilterDescendantsInstances = if Target.model then { Target.model } else {}
	State.Params = Params
	return Params
end

const function GetSupport(Target: Entity, State: State, Humanoid: Humanoid, RootSize: Vector3?, Position: Vector3): BasePart?
	const RootHalf: number = if RootSize then RootSize.Y / 2 else 1
	const Distance: number = math.max(Humanoid.HipHeight, MIN_HIP_HEIGHT) + RootHalf + GROUND_EXTRA_DISTANCE
	const Result: RaycastResult? = workspace:Raycast(Position, Vector3.new(0, -Distance, 0), GetParams(Target, State))
	return if Result then Result.Instance :: BasePart else nil
end

const function GetJumpVelocity(Humanoid: Humanoid): number
	if Humanoid.UseJumpPower then
		return Humanoid.JumpPower * JUMP_POWER_SCALE
	end
	return math.sqrt(2 * workspace.Gravity * Humanoid.JumpHeight)
end

const function IsExempt(Target: Entity, Humanoid: Humanoid?): boolean
	if Target.mountParentId then
		return true
	end
	if Humanoid then
		return Humanoid.Health <= 0 or Humanoid.SeatPart ~= nil or Humanoid.PlatformStand
	end
	return false
end

const function NewState(Target: Entity, Frame: CFrame, Now: number): State
	return {
		Time = Now,
		Position = Frame.Position,
		SweepFrom = Frame.Position,
		Safe = Frame,
		SafeTime = Target.latestTime or Now,
		SetStamp = Target._setAt,
		Horizontal = MIN_BANK,
		Vertical = MIN_BANK,
		SpeedPeak = 0,
		Idle = 0,
		AirTime = 0,
		GroundY = Frame.Position.Y,
		Lift = 0,
		PendingUntil = 0,
		Reapply = false,
		Attempts = 0,
		Desynced = false,
	}
end

const function Rebase(State: State, Frame: CFrame, Time: number): ()
	State.Position = Frame.Position
	State.SweepFrom = Frame.Position
	State.Safe = Frame
	State.SafeTime = Time
	State.Pending = nil
	State.Reapply = false
	State.Attempts = 0
	State.Desynced = false
	State.Horizontal = MIN_BANK
	State.Vertical = MIN_BANK
	State.Idle = 0
	State.AirTime = 0
	State.GroundY = Frame.Position.Y
	State.Lift = 0
	State.Floor = nil
	State.FloorOffset = nil
end

const function Apply(Target: Entity, State: State, Goal: CFrame): ()
	Entity.SetCFrame(Target, Goal)
	Entity._SetPartCFrame(Target, Goal)
	const Part: BasePart? = Entity.GetPrimaryPart(Target)
	if Part then
		Part.AssemblyLinearVelocity = Vector3.zero
	end
	State.SetStamp = Target._setAt
end

const function GetDelay(Player: Player): number
	return REAPPLY_INTERVAL + math.max(Player:GetNetworkPing(), 0) * 2
end

const function IsPartDriven(Target: Entity): boolean
	return Target.modelReplicationMode == "NATIVE" and not Target._lockedCFReplication
end

const function GetClipCache(Target: Entity, Root: BasePart): ClipCache
	const Model: (Model | BasePart)? = Target.model
	const Existing: ClipCache? = ClipCaches[Target]
	local Cache: ClipCache
	if Existing and Existing.Model == Model then
		Cache = Existing
	else
		const Params: RaycastParams = RaycastParams.new()
		Params.FilterType = Enum.RaycastFilterType.Exclude
		Params.RespectCanCollide = true
		Params.IgnoreWater = true
		const Base: { Instance } = if Model then { Model } else { Root }
		Params.FilterDescendantsInstances = Base
		Cache = {
				Params = Params,
				Model = Model,
				Group = Params.CollisionGroup,
				Base = Base,
				Extents = nil,
				Margin = 0,
				Size = Vector3.zero,
			}
		ClipCaches[Target] = Cache
	end
	const Group: string = Root.CollisionGroup
	if Cache.Group ~= Group then
		Cache.Params.CollisionGroup = Group
		Cache.Group = Group
	end
	return Cache
end

const function GetIgnored(Hit: BasePart): { Instance }?
	local Node: Instance? = Hit
	while Node and Node ~= workspace do
		if
			CollectionService:HasTag(Node, NoclipIgnoreTag)
			or (Node:IsA("Model") and Node:FindFirstChildWhichIsA("Humanoid") ~= nil)
		then
			const Found: { Instance } = { Node }
			return Found
		end
		Node = Node.Parent
	end
	if Hit.Anchored or Hit.AssemblyRootPart.Anchored then
		return nil
	end
	const Ignored: { Instance } = { Hit }
	for _, Part: BasePart in Hit:GetConnectedParts(true) do
		if Part ~= Hit then
			table.insert(Ignored, Part)
		end
	end
	return Ignored
end

const function Sweep(Target: Entity, Root: BasePart, Extents: Vector3, From: Vector3, To: CFrame, Fallback: Vector3?): number?
	local Origin: Vector3 = From
	local Offset: Vector3 = To.Position - Origin
	local Travel: number = Offset.Magnitude
	if Travel < NoclipMinTravel then
		return nil
	end

	const Cache: ClipCache = GetClipCache(Target, Root)
	const Params: RaycastParams = Cache.Params
	local Size: Vector3 = Cache.Size
	if Cache.Extents ~= Extents or Cache.Margin ~= NoclipMargin then
		const Inset: number = NoclipMargin * 2
		Size = Vector3.new(
			math.max(Extents.X - Inset, NoclipMinExtent),
			math.max(Extents.Y - Inset, NoclipMinExtent),
			math.max(Extents.Z - Inset, NoclipMinExtent)
		)
		Cache.Extents = Extents
		Cache.Margin = NoclipMargin
		Cache.Size = Size
	end

	local Excluded: { Instance } = Cache.Base
	local Dirty: boolean = false
	local Restarted: boolean = false
	local Contact: number? = nil
	local Casts: number = 0
	while Casts < NoclipMaxCasts do
		Casts += 1
		const Direction: Vector3 = if Travel > NoclipMaxTravel then Offset.Unit * NoclipMaxTravel else Offset
		const Result: RaycastResult? = workspace:Blockcast(To.Rotation + Origin, Size, Direction, Params)
		if not Result then
			break
		end
		const Hit: BasePart = Result.Instance :: BasePart
		local Ignored: { Instance }? = GetIgnored(Hit)
		if Result.Distance <= NoclipTouchEpsilon then
			if not Ignored and Fallback and not Restarted then
				Restarted = true
				Origin = Fallback
				Offset = To.Position - Origin
				Travel = Offset.Magnitude
				if Travel < NoclipMinTravel then
					break
				end
				continue
			end
			if not Ignored then
				const Touching: { Instance } = { Hit }
				Ignored = Touching
			end
		end
		if not Ignored then
			Contact = Result.Distance
			break
		end
		if not Dirty then
			Excluded = table.clone(Cache.Base)
			Dirty = true
		end
		table.move(Ignored, 1, #Ignored, #Excluded + 1, Excluded)
		Params.FilterDescendantsInstances = Excluded
	end
	if Dirty then
		Params.FilterDescendantsInstances = Cache.Base
	end

	if Contact and Contact < Travel then
		return Travel - Contact
	end
	return nil
end

const function ClipsPending(Target: Entity, Pending: CFrame, Observed: CFrame, Reapply: boolean): boolean
	if not (NoclipEnabled and Reapply) then
		return false
	end
	const Root: BasePart? = ResolveRoot(Target)
	if not Root then
		return false
	end
	return Sweep(Target, Root, Root.Size, Pending.Position, Observed, nil) ~= nil
end

const function Violate(
	Player: Player,
	Target: Entity,
	State: State,
	Frame: CFrame,
	Now: number,
	Kind: string,
	Excess: number
): ()
	Warn.medium("Rollback:", Player.Name, Kind, Excess)
	ViolatedSignal:Fire(Player, Target, Kind, Excess)
	if MODE ~= "ENFORCE" then
		if Kind ~= "INVALID" then
			Rebase(State, Frame, Target.latestTime or State.SafeTime)
		end
		return
	end
	const Goal: CFrame = State.Safe
	const SafeTime: number = State.SafeTime
	const Snapshot: Types.Snapshot<CFrame, Vector3>? = Target.snapshot
	if Snapshot then
		Snapshot:TrimAfter(SafeTime)
	end
	Target.latestTime = SafeTime
	Apply(Target, State, Goal)
	Rebase(State, Goal, SafeTime)
	State.Pending = Goal
	State.PendingUntil = Now + GetDelay(Player)
	State.Reapply = true
	State.Attempts = 1
end

const function SyncTeleport(Target: Entity, State: State, Fallback: CFrame, Now: number): ()
	if Target._setAt == State.SetStamp then
		return
	end
	State.SetStamp = Target._setAt
	State.Pending = Target.latestCFrame or Fallback
	State.PendingUntil = Now + TELEPORT_WINDOW
	State.Reapply = false
	State.Attempts = 0
end

const function Step(Player: Player, Target: Entity, Now: number): ()
	const Frame: CFrame?, ObservedRoot: BasePart?, RootResolved: boolean = Observe(Target)
	if not Frame then
		States[Target] = nil
		return
	end
	const State: State? = States[Target]
	if not State then
		States[Target] = NewState(Target, Frame, Now)
		return
	end

	const DeltaTime: number = Now - State.Time
	State.Time = Now
	const Position: Vector3 = Frame.Position

	SyncTeleport(Target, State, Frame, Now)

	const Pending: CFrame? = State.Pending
	if Pending then
		const Distance: number = (Position - Pending.Position).Magnitude
		if Distance <= ACCEPT_RADIUS and not ClipsPending(Target, Pending, Frame, State.Reapply) then
			Rebase(State, Frame, Target.latestTime or State.SafeTime)
		elseif Now >= State.PendingUntil then
			if State.Reapply then
				State.PendingUntil = Now + GetDelay(Player)
				if State.Attempts < MAX_REAPPLY_ATTEMPTS then
					State.Attempts += 1
				elseif not State.Desynced then
					State.Desynced = true
					ViolatedSignal:Fire(Player, Target, "DESYNC", Distance)
				end
				Apply(Target, State, Pending)
			else
				const Grace: Override? = Overrides[Target]
				const Exempt: boolean = IsExempt(Target, GetHumanoid(Target, State))
					or (Grace ~= nil and Now < Grace.GraceUntil)
				if MODE == "ENFORCE" and not Exempt then
					State.Reapply = true
					State.Attempts = 1
					State.PendingUntil = Now + GetDelay(Player)
					Apply(Target, State, Pending)
				else
					Rebase(State, Frame, Target.latestTime or State.SafeTime)
				end
			end
		end
		return
	end

	const Override: Override? = Overrides[Target]
	const Humanoid: Humanoid? = GetHumanoid(Target, State)
	if (Override and Now < Override.GraceUntil) or IsExempt(Target, Humanoid) then
		Rebase(State, Frame, Target.latestTime or State.SafeTime)
		return
	end

	local Speed: number? = Override and Override.MaxSpeed
	if not Speed and Humanoid then
		Speed = Humanoid.WalkSpeed
	end
	if not Speed then
		Rebase(State, Frame, Target.latestTime or State.SafeTime)
		return
	end

	const Px: number, Py: number, Pz: number = Position.X, Position.Y, Position.Z
	const Sum: number = Px + Py + Pz
	if Sum ~= Sum or math.abs(Sum) == math.huge then
		Violate(Player, Target, State, Frame, Now, "INVALID", 0)
		return
	end

	const SpeedPeak: number = math.max(Speed, State.SpeedPeak * math.max(0, 1 - SPEED_DECAY * DeltaTime))
	State.SpeedPeak = SpeedPeak
	const Rate: number = SpeedPeak * SPEED_TOLERANCE
	const Cap: number = Rate * BANK_TIME + MIN_BANK
	const HorizontalBank: number = math.min(State.Horizontal + Rate * DeltaTime, Cap)
	const VerticalBank: number = math.min(State.Vertical + Rate * DeltaTime, Cap)

	const SweepEnabled: boolean = NoclipEnabled and (MODE ~= "ENFORCE" or IsPartDriven(Target))
	local Root: BasePart? = ObservedRoot
	if not RootResolved and (Humanoid ~= nil or SweepEnabled) then
		Root = ResolveRoot(Target)
	end
	const RootSize: Vector3? = if Root then Root.Size else nil

	local Floor: BasePart? = nil
	local Tethered: boolean = false
	if Humanoid then
		Floor = GetSupport(Target, State, Humanoid, RootSize, Position)
		const HumanoidState: Enum.HumanoidStateType = Humanoid:GetState()
		Tethered = HumanoidState == Enum.HumanoidStateType.Climbing
			or HumanoidState == Enum.HumanoidStateType.Swimming
	end

	const Previous: Vector3 = State.Position
	const Sx: number, Sy: number, Sz: number = Previous.X, Previous.Y, Previous.Z
	const Ux: number, Uy: number, Uz: number = Px - Sx, Py - Sy, Pz - Sz
	local Cx: number, Cy: number, Cz: number = 0, 0, 0
	const FloorCFrame: CFrame? = if Floor then Floor.CFrame else nil
	const PreviousFloor: BasePart? = State.Floor
	const FloorOffset: Vector3? = State.FloorOffset
	if FloorCFrame and Floor == PreviousFloor and FloorOffset then
		const World: Vector3 = FloorCFrame:PointToWorldSpace(FloorOffset)
		Cx, Cy, Cz = World.X - Sx, World.Y - Sy, World.Z - Sz
	end

	const Dx: number, Dy: number, Dz: number = Ux - Cx, Uy - Cy, Uz - Cz
	const Flat: number = if Humanoid then math.sqrt(Dx * Dx + Dz * Dz) else math.sqrt(Dx * Dx + Dy * Dy + Dz * Dz)
	const BonusActive: boolean = Override ~= nil and Now < Override.BonusUntil
	local Bonus: number = if BonusActive and Override then Override.Bonus else 0

	local NextHorizontal: number
	if Flat <= HorizontalBank then
		NextHorizontal = HorizontalBank - Flat
	else
		const Remaining: number = Flat - HorizontalBank
		if Remaining <= Bonus then
			NextHorizontal = 0
			Bonus -= Remaining
		else
			Violate(Player, Target, State, Frame, Now, "SPEED", Flat - HorizontalBank - Bonus)
			return
		end
	end

	local NextVertical: number = VerticalBank
	const Supported: boolean = Humanoid == nil or Floor ~= nil or Tethered

	if Humanoid then
		const Gravity: number = workspace.Gravity
		const Launch: number = GetJumpVelocity(Humanoid) * JUMP_VELOCITY_TOLERANCE + State.Lift
		const Window: number = DeltaTime + State.Idle
		if Tethered then
			const Amount: number = math.abs(Dy)
			if Amount <= VerticalBank then
				NextVertical = VerticalBank - Amount
			else
				const Remaining: number = Amount - VerticalBank
				if Remaining <= Bonus then
					NextVertical = 0
					Bonus -= Remaining
				else
					Violate(Player, Target, State, Frame, Now, "CLIMB", Amount - VerticalBank - Bonus)
					return
				end
			end
		else
			const Rise: number = Launch * Window + AIR_MARGIN
			const RiseExcess: number = Dy - Rise
			if RiseExcess <= 0 then
			elseif RiseExcess <= Bonus then
				Bonus -= RiseExcess
			else
				Violate(Player, Target, State, Frame, Now, "RISE", RiseExcess - Bonus)
				return
			end
			const Fall: number = (Launch + Gravity * State.AirTime) * Window + 0.5 * Gravity * Window * Window + AIR_MARGIN
			const FallExcess: number = -Dy - Fall
			if FallExcess <= 0 then
			elseif FallExcess <= Bonus then
				Bonus -= FallExcess
			else
				Violate(Player, Target, State, Frame, Now, "FALL", FallExcess - Bonus)
				return
			end
			if not Supported then
				const Airborne: number = State.AirTime + DeltaTime
				const Apex: number = math.max(Launch * Airborne - 0.5 * Gravity * Airborne * Airborne, 0)
				const FlyExcess: number = Py - (State.GroundY + Apex + AIR_MARGIN)
				if FlyExcess <= 0 then
				elseif FlyExcess <= Bonus then
					Bonus -= FlyExcess
				else
					Violate(Player, Target, State, Frame, Now, "FLY", FlyExcess - Bonus)
					return
				end
			end
		end
	end

	if SweepEnabled then
		const Anchor: Vector3 = State.SweepFrom
		const Wx: number, Wy: number, Wz: number = Px - Anchor.X, Py - Anchor.Y, Pz - Anchor.Z
		if Wx * Wx + Wy * Wy + Wz * Wz >= NoclipMinTravelSq then
			const Penetration: number? = if Root and RootSize
				then Sweep(Target, Root, RootSize, Anchor, Frame, State.Safe.Position)
				else nil
			if Penetration then
				Violate(Player, Target, State, Frame, Now, "NOCLIP", Penetration)
				return
			end
			State.SweepFrom = Position
		end
	end

	if Override and BonusActive then
		Override.Bonus = Bonus
	end

	State.Horizontal = NextHorizontal
	State.Vertical = NextVertical
	State.Position = Position
	State.Floor = Floor
	State.FloorOffset = if FloorCFrame then FloorCFrame:PointToObjectSpace(Position) else nil
	State.Idle = if Ux * Ux + Uy * Uy + Uz * Uz < IDLE_EPSILON_SQ then math.min(State.Idle + DeltaTime, BANK_TIME) else 0

	if Supported then
		State.AirTime = 0
		State.GroundY = Py
		State.Safe = Frame
		State.SafeTime = Target.latestTime or State.SafeTime
		State.Lift = if Floor then math.clamp(Cy / math.max(DeltaTime, 0.001), 0, Rate) else 0
	else
		State.AirTime += DeltaTime
	end
end

const function Update(): ()
	const Now: number = os.clock()
	if Now - LastStep < STEP_INTERVAL then
		return
	end
	LastStep = Now
	for Player: Player, Owned: { [Entity]: true } in Holder._clientOwned do
		if Player.Parent == nil then
			continue
		end
		for Target: Entity in Owned do
			if not Target.destroyed and Target.networkOwner == Player then
				Step(Player, Target, Now)
			end
		end
	end
end

const function GetOverride(Target: Entity): Override
	const Existing: Override? = Overrides[Target]
	if Existing then
		return Existing
	end
	const Override: Override = { GraceUntil = 0, Bonus = 0, BonusUntil = 0 }
	Overrides[Target] = Override
	return Override
end

function Rollback.Exempt(Target: Entity, Seconds: number): ()
	assert(type(Seconds) == "number" and Seconds >= 0, "Chrono: Rollback.Exempt expected a non-negative number")
	GetOverride(Target).GraceUntil = os.clock() + Seconds
end

function Rollback.Grant(Target: Entity, Studs: number): ()
	assert(type(Studs) == "number" and Studs >= 0, "Chrono: Rollback.Grant expected a non-negative number")
	const Override: Override = GetOverride(Target)
	const Now: number = os.clock()
	const Current: number = if Now < Override.BonusUntil then Override.Bonus else 0
	Override.Bonus = math.min(Current + Studs, MAX_BONUS)
	Override.BonusUntil = Now + BANK_TIME + 1
end

function Rollback.SetMaxSpeed(Target: Entity, Speed: number?): ()
	assert(Speed == nil or (type(Speed) == "number" and Speed >= 0), "Chrono: Rollback.SetMaxSpeed expected a non-negative number")
	GetOverride(Target).MaxSpeed = Speed
end

const function Gate(Player: Player, Target: Entity, State: State, Frame: CFrame, Now: number): boolean
	const Override: Override? = Overrides[Target]
	if Override and Now < Override.GraceUntil then
		return false
	end
	const Humanoid: Humanoid? = GetHumanoid(Target, State)
	if IsExempt(Target, Humanoid) then
		return false
	end
	local Speed: number? = Override and Override.MaxSpeed
	if not Speed and Humanoid then
		Speed = Humanoid.WalkSpeed
	end
	if not Speed then
		return false
	end

	const DeltaTime: number = math.max(Now - State.Time, 0)
	const Peak: number = math.max(Speed, State.SpeedPeak * math.max(0, 1 - SPEED_DECAY * DeltaTime))
	const Rate: number = Peak * SPEED_TOLERANCE
	const Cap: number = Rate * BANK_TIME + MIN_BANK
	const HorizontalBank: number = math.min(State.Horizontal + Rate * DeltaTime, Cap)
	const Bonus: number = if Override and Now < Override.BonusUntil then Override.Bonus else 0

	const Position: Vector3 = Frame.Position
	const Px: number, Py: number, Pz: number = Position.X, Position.Y, Position.Z
	const Previous: Vector3 = State.Position
	const Sx: number, Sy: number, Sz: number = Previous.X, Previous.Y, Previous.Z
	local Cx: number, Cy: number, Cz: number = 0, 0, 0
	const Floor: BasePart? = State.Floor
	const FloorOffset: Vector3? = State.FloorOffset
	if Floor and FloorOffset then
		const World: Vector3 = Floor.CFrame:PointToWorldSpace(FloorOffset)
		Cx, Cy, Cz = World.X - Sx, World.Y - Sy, World.Z - Sz
	end

	const Dx: number, Dy: number, Dz: number = Px - Sx - Cx, Py - Sy - Cy, Pz - Sz - Cz
	const Flat: number = if Humanoid then math.sqrt(Dx * Dx + Dz * Dz) else math.sqrt(Dx * Dx + Dy * Dy + Dz * Dz)
	if Flat > HorizontalBank + Bonus then
		Violate(Player, Target, State, Frame, Now, "SPEED", Flat - HorizontalBank - Bonus)
		return true
	end

	if Humanoid then
		const VerticalBank: number = math.min(State.Vertical + Rate * DeltaTime, Cap)
		const Gravity: number = workspace.Gravity
		const Launch: number = GetJumpVelocity(Humanoid) * JUMP_VELOCITY_TOLERANCE + State.Lift
		const Window: number = DeltaTime + State.Idle
		const Rise: number = Launch * Window + AIR_MARGIN
		const Fall: number = (Launch + Gravity * State.AirTime) * Window + 0.5 * Gravity * Window * Window + AIR_MARGIN
		const Reach: number = math.max(Rise, Fall, VerticalBank) + Bonus
		const AbsDy: number = math.abs(Dy)
		if AbsDy > Reach then
			Violate(Player, Target, State, Frame, Now, if Dy > 0 then "RISE" else "FALL", AbsDy - Reach)
			return true
		end
	end

	if NoclipEnabled then
		const Anchor: Vector3 = State.SweepFrom
		const Wx: number, Wy: number, Wz: number = Px - Anchor.X, Py - Anchor.Y, Pz - Anchor.Z
		if Wx * Wx + Wy * Wy + Wz * Wz >= NoclipMinTravelSq then
			const Root: BasePart? = ResolveRoot(Target)
			const Penetration: number? = if Root then Sweep(Target, Root, Root.Size, Anchor, Frame, State.Safe.Position) else nil
			if Penetration then
				Violate(Player, Target, State, Frame, Now, "NOCLIP", Penetration)
				return true
			end
			State.SweepFrom = Position
		end
	end
	return false
end

function Rollback.Filter(Player: Player, Target: Entity, Frame: CFrame, Now: number): boolean
	if MODE ~= "ENFORCE" then
		return false
	end
	const State: State? = States[Target]
	if not State or Target.mountParentId then
		return false
	end
	SyncTeleport(Target, State, State.Safe, Now)
	const Pending: CFrame? = State.Pending
	if Pending then
		return (Frame.Position - Pending.Position).Magnitude > ACCEPT_RADIUS
			or ClipsPending(Target, Pending, Frame, State.Reapply)
	end
	return Gate(Player, Target, State, Frame, Now)
end

function Rollback.Reset(Target: Entity): ()
	States[Target] = nil
end

Rollback.Violated = ViolatedSignal.Event

Config._WaitForLock(function()
	if not RunService:IsServer() then
		return
	end
	MODE = Config._GetConfig("ROLLBACK_MODE")
	if MODE == "NONE" then
		return
	end
	SPEED_TOLERANCE = Config._GetConfig("ROLLBACK_SPEED_TOLERANCE")
	BANK_TIME = Config._GetConfig("ROLLBACK_BANK_TIME")
	MIN_BANK = Config._GetConfig("ROLLBACK_MIN_BANK")
	AIR_MARGIN = Config._GetConfig("ROLLBACK_AIR_MARGIN")
	NoclipEnabled = Config._GetConfig("ROLLBACK_NOCLIP")
	NoclipMargin = Config._GetConfig("ROLLBACK_NOCLIP_MARGIN")
	RunService.PostSimulation:Connect(Update)
end)

return Rollback
