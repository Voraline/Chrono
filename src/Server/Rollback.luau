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
	graceUntil: number,
	bonus: number,
	bonusUntil: number,
	maxSpeed: number?,
}

type State = {
	time: number,
	position: Vector3,
	sweepFrom: Vector3,
	safe: CFrame,
	safeTime: number,
	setStamp: number?,
	humanoid: Humanoid?,
	params: RaycastParams?,
	horizontal: number,
	vertical: number,
	speedPeak: number,
	idle: number,
	airTime: number,
	groundY: number,
	lift: number,
	floor: BasePart?,
	floorOffset: Vector3?,
	pending: CFrame?,
	pendingUntil: number,
	reapply: boolean,
	attempts: number,
	desynced: boolean,
}

type ClipCache = {
	Params: RaycastParams,
	Model: (Model | BasePart)?,
	Group: string,
	Base: { Instance },
}

const STEP_INTERVAL: number = 1 / 20
const IDLE_EPSILON: number = 0.01
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
const NoclipMaxTravel: number = 1024
const NoclipMinExtent: number = 0.05
const NoclipTouchEpsilon: number = 0.001
const NoclipMaxCasts: number = 4

const States: { [Entity]: State } = setmetatable({}, { __mode = "k" }) :: any
const Overrides: { [Entity]: Override } = setmetatable({}, { __mode = "k" }) :: any
const ClipCaches: { [Entity]: ClipCache } = setmetatable({}, { __mode = "k" }) :: any

const ViolatedSignal =
	Signal.new() :: Types.Signal<(player: Player, entity: Entity, kind: string, excess: number) -> (), Player, Entity, string, number>

local MODE: string = "NONE"
local SPEED_TOLERANCE: number = 1.5
local BANK_TIME: number = 3
local MIN_BANK: number = 12
local AIR_MARGIN: number = 4
local NoclipEnabled: boolean = true
local NoclipMargin: number = 0.3
local lastStep: number = 0

const Rollback = {}

const function Observe(entity: Entity): CFrame?
	if entity.modelReplicationMode == "NATIVE" and not entity._lockedCFReplication then
		const part: BasePart? = Entity.GetPrimaryPart(entity)
		if part then
			return part.CFrame
		end
	end
	return entity.latestCFrame
end

const function GetHumanoid(entity: Entity, state: State): Humanoid?
	const cached: Humanoid? = state.humanoid
	if cached and cached.Parent then
		return cached
	end
	const model: (Model | BasePart)? = entity.model
	local humanoid: Humanoid? = nil
	if model and model:IsA("Model") then
		humanoid = model:FindFirstChildWhichIsA("Humanoid")
	end
	state.humanoid = humanoid
	state.params = nil
	return humanoid
end

const function GetParams(entity: Entity, state: State): RaycastParams
	const existing: RaycastParams? = state.params
	if existing then
		return existing
	end
	const params: RaycastParams = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	params.FilterDescendantsInstances = if entity.model then { entity.model } else {}
	state.params = params
	return params
end

const function GetSupport(entity: Entity, state: State, humanoid: Humanoid, position: Vector3): BasePart?
	const root: BasePart? = Entity.GetPrimaryPart(entity)
	const rootHalf: number = if root then root.Size.Y / 2 else 1
	const distance: number = math.max(humanoid.HipHeight, MIN_HIP_HEIGHT) + rootHalf + GROUND_EXTRA_DISTANCE
	const result: RaycastResult? = workspace:Raycast(position, Vector3.new(0, -distance, 0), GetParams(entity, state))
	return if result then result.Instance :: BasePart else nil
end

const function GetJumpVelocity(humanoid: Humanoid): number
	if humanoid.UseJumpPower then
		return humanoid.JumpPower * JUMP_POWER_SCALE
	end
	return math.sqrt(2 * workspace.Gravity * humanoid.JumpHeight)
end

const function IsExempt(entity: Entity, humanoid: Humanoid?): boolean
	if entity.mountParentId then
		return true
	end
	if humanoid then
		return humanoid.Health <= 0 or humanoid.SeatPart ~= nil or humanoid.PlatformStand
	end
	return false
end

const function Spend(bank: number, bonus: number, amount: number): (boolean, number, number)
	if amount <= bank then
		return true, bank - amount, bonus
	end
	const remaining = amount - bank
	if remaining <= bonus then
		return true, 0, bonus - remaining
	end
	return false, bank, bonus
end

const function Allow(excess: number, bonus: number): (boolean, number)
	if excess <= 0 then
		return true, bonus
	end
	if excess <= bonus then
		return true, bonus - excess
	end
	return false, bonus
end

const function NewState(entity: Entity, cframe: CFrame, now: number): State
	return {
		time = now,
		position = cframe.Position,
		sweepFrom = cframe.Position,
		safe = cframe,
		safeTime = entity.latestTime or now,
		setStamp = entity._setAt,
		horizontal = MIN_BANK,
		vertical = MIN_BANK,
		speedPeak = 0,
		idle = 0,
		airTime = 0,
		groundY = cframe.Position.Y,
		lift = 0,
		pendingUntil = 0,
		reapply = false,
		attempts = 0,
		desynced = false,
	}
end

const function Rebase(state: State, cframe: CFrame, time: number): ()
	state.position = cframe.Position
	state.sweepFrom = cframe.Position
	state.safe = cframe
	state.safeTime = time
	state.pending = nil
	state.reapply = false
	state.attempts = 0
	state.desynced = false
	state.horizontal = MIN_BANK
	state.vertical = MIN_BANK
	state.idle = 0
	state.airTime = 0
	state.groundY = cframe.Position.Y
	state.lift = 0
	state.floor = nil
	state.floorOffset = nil
end

const function Apply(entity: Entity, state: State, target: CFrame): ()
	Entity.SetCFrame(entity, target)
	Entity._SetPartCFrame(entity, target)
	const part: BasePart? = Entity.GetPrimaryPart(entity)
	if part then
		part.AssemblyLinearVelocity = Vector3.zero
	end
	state.setStamp = entity._setAt
end

const function GetDelay(player: Player): number
	return REAPPLY_INTERVAL + math.max(player:GetNetworkPing(), 0) * 2
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
		Cache = { Params = Params, Model = Model, Group = Params.CollisionGroup, Base = Base }
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
	for _, Part in Hit:GetConnectedParts(true) do
		if Part ~= Hit then
			table.insert(Ignored, Part)
		end
	end
	return Ignored
end

const function Sweep(Target: Entity, From: Vector3, To: CFrame, Fallback: Vector3?): number?
	const Root: BasePart? = Entity.GetPrimaryPart(Target)
	if not Root then
		return nil
	end
	local Origin: Vector3 = From
	local Offset: Vector3 = To.Position - Origin
	local Travel: number = Offset.Magnitude
	if Travel < NoclipMinTravel then
		return nil
	end

	const Cache: ClipCache = GetClipCache(Target, Root)
	const Params: RaycastParams = Cache.Params
	const Inset: number = NoclipMargin * 2
	const Extents: Vector3 = Root.Size
	const Size: Vector3 = Vector3.new(
		math.max(Extents.X - Inset, NoclipMinExtent),
		math.max(Extents.Y - Inset, NoclipMinExtent),
		math.max(Extents.Z - Inset, NoclipMinExtent)
	)

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
	return NoclipEnabled and Reapply and Sweep(Target, Pending.Position, Observed, nil) ~= nil
end

const function Violate(
	player: Player,
	entity: Entity,
	state: State,
	cframe: CFrame,
	now: number,
	kind: string,
	excess: number
): ()
	Warn.medium("Rollback:", player.Name, kind, excess)
	ViolatedSignal:Fire(player, entity, kind, excess)
	if MODE ~= "ENFORCE" then
		if kind ~= "INVALID" then
			Rebase(state, cframe, entity.latestTime or state.safeTime)
		end
		return
	end
	const target: CFrame = state.safe
	const safeTime: number = state.safeTime
	const snapshot: Types.Snapshot<CFrame, Vector3>? = entity.snapshot
	if snapshot then
		snapshot:TrimAfter(safeTime)
	end
	entity.latestTime = safeTime
	Apply(entity, state, target)
	Rebase(state, target, safeTime)
	state.pending = target
	state.pendingUntil = now + GetDelay(player)
	state.reapply = true
	state.attempts = 1
end

const function SyncTeleport(entity: Entity, state: State, fallback: CFrame, now: number): ()
	if entity._setAt == state.setStamp then
		return
	end
	state.setStamp = entity._setAt
	state.pending = entity.latestCFrame or fallback
	state.pendingUntil = now + TELEPORT_WINDOW
	state.reapply = false
	state.attempts = 0
end

const function Step(player: Player, entity: Entity, now: number): ()
	const cframe: CFrame? = Observe(entity)
	if not cframe then
		States[entity] = nil
		return
	end
	const state: State? = States[entity]
	if not state then
		States[entity] = NewState(entity, cframe, now)
		return
	end

	const dt: number = now - state.time
	state.time = now
	const position: Vector3 = cframe.Position

	SyncTeleport(entity, state, cframe, now)

	const pending: CFrame? = state.pending
	if pending then
		const distance: number = (position - pending.Position).Magnitude
		if distance <= ACCEPT_RADIUS and not ClipsPending(entity, pending, cframe, state.reapply) then
			Rebase(state, cframe, entity.latestTime or state.safeTime)
		elseif now >= state.pendingUntil then
			if state.reapply then
				state.pendingUntil = now + GetDelay(player)
				if state.attempts < MAX_REAPPLY_ATTEMPTS then
					state.attempts += 1
				elseif not state.desynced then
					state.desynced = true
					ViolatedSignal:Fire(player, entity, "DESYNC", distance)
				end
				Apply(entity, state, pending)
			else
				const grace: Override? = Overrides[entity]
				const exempt: boolean = IsExempt(entity, GetHumanoid(entity, state))
					or (grace ~= nil and now < grace.graceUntil)
				if MODE == "ENFORCE" and not exempt then
					state.reapply = true
					state.attempts = 1
					state.pendingUntil = now + GetDelay(player)
					Apply(entity, state, pending)
				else
					Rebase(state, cframe, entity.latestTime or state.safeTime)
				end
			end
		end
		return
	end

	const override: Override? = Overrides[entity]
	const humanoid: Humanoid? = GetHumanoid(entity, state)
	if (override and now < override.graceUntil) or IsExempt(entity, humanoid) then
		Rebase(state, cframe, entity.latestTime or state.safeTime)
		return
	end

	local speed: number? = override and override.maxSpeed
	if not speed and humanoid then
		speed = humanoid.WalkSpeed
	end
	if not speed then
		Rebase(state, cframe, entity.latestTime or state.safeTime)
		return
	end

	const sum: number = position.X + position.Y + position.Z
	if sum ~= sum or math.abs(sum) == math.huge then
		Violate(player, entity, state, cframe, now, "INVALID", 0)
		return
	end

	state.speedPeak = math.max(speed, state.speedPeak * math.max(0, 1 - SPEED_DECAY * dt))
	const rate: number = state.speedPeak * SPEED_TOLERANCE
	const cap: number = rate * BANK_TIME + MIN_BANK
	const horizontalBank: number = math.min(state.horizontal + rate * dt, cap)
	const verticalBank: number = math.min(state.vertical + rate * dt, cap)

	local floor: BasePart? = nil
	local tethered = false
	if humanoid then
		floor = GetSupport(entity, state, humanoid, position)
		const humanoidState: Enum.HumanoidStateType = humanoid:GetState()
		tethered = humanoidState == Enum.HumanoidStateType.Climbing
			or humanoidState == Enum.HumanoidStateType.Swimming
	end

	local carry: Vector3 = Vector3.zero
	const previousFloor: BasePart? = state.floor
	const floorOffset: Vector3? = state.floorOffset
	if floor and floor == previousFloor and floorOffset then
		carry = floor.CFrame:PointToWorldSpace(floorOffset) - state.position
	end

	const moved: number = (position - state.position).Magnitude
	const delta: Vector3 = position - state.position - carry
	const flat: number = if humanoid then Vector3.new(delta.X, 0, delta.Z).Magnitude else delta.Magnitude
	const bonusActive: boolean = override ~= nil and now < override.bonusUntil
	local bonus: number = if bonusActive and override then override.bonus else 0

	const horizontalOk: boolean, nextHorizontal: number, horizontalBonus: number = Spend(horizontalBank, bonus, flat)
	if not horizontalOk then
		Violate(player, entity, state, cframe, now, "SPEED", flat - horizontalBank - bonus)
		return
	end
	bonus = horizontalBonus

	local nextVertical: number = verticalBank
	const supported: boolean = humanoid == nil or floor ~= nil or tethered

	if humanoid then
		const gravity: number = workspace.Gravity
		const launch: number = GetJumpVelocity(humanoid) * JUMP_VELOCITY_TOLERANCE + state.lift
		const window: number = dt + state.idle
		if tethered then
			const ok: boolean, bank: number, remaining: number = Spend(verticalBank, bonus, math.abs(delta.Y))
			if not ok then
				Violate(player, entity, state, cframe, now, "CLIMB", math.abs(delta.Y) - verticalBank - bonus)
				return
			end
			nextVertical = bank
			bonus = remaining
		else
			const rise: number = launch * window + AIR_MARGIN
			const fall: number = (launch + gravity * state.airTime) * window + 0.5 * gravity * window * window + AIR_MARGIN
			const riseOk: boolean, riseBonus: number = Allow(delta.Y - rise, bonus)
			if not riseOk then
				Violate(player, entity, state, cframe, now, "RISE", delta.Y - rise - bonus)
				return
			end
			const fallOk: boolean, fallBonus: number = Allow(-delta.Y - fall, riseBonus)
			if not fallOk then
				Violate(player, entity, state, cframe, now, "FALL", -delta.Y - fall - riseBonus)
				return
			end
			bonus = fallBonus
			if not supported then
				const airborne: number = state.airTime + dt
				const apex: number = math.max(launch * airborne - 0.5 * gravity * airborne * airborne, 0)
				const ceiling: number = state.groundY + apex + AIR_MARGIN
				const flyOk: boolean, flyBonus: number = Allow(position.Y - ceiling, bonus)
				if not flyOk then
					Violate(player, entity, state, cframe, now, "FLY", position.Y - ceiling - bonus)
					return
				end
				bonus = flyBonus
			end
		end
	end

	if NoclipEnabled and (MODE ~= "ENFORCE" or IsPartDriven(entity)) then
		if (position - state.sweepFrom).Magnitude >= NoclipMinTravel then
			const Penetration: number? = Sweep(entity, state.sweepFrom, cframe, state.safe.Position)
			if Penetration then
				Violate(player, entity, state, cframe, now, "NOCLIP", Penetration)
				return
			end
			state.sweepFrom = position
		end
	end

	if override and bonusActive then
		override.bonus = bonus
	end

	state.horizontal = nextHorizontal
	state.vertical = nextVertical
	state.position = position
	state.floor = floor
	state.floorOffset = if floor then floor.CFrame:PointToObjectSpace(position) else nil
	state.idle = if moved < IDLE_EPSILON then math.min(state.idle + dt, BANK_TIME) else 0

	if supported then
		state.airTime = 0
		state.groundY = position.Y
		state.safe = cframe
		state.safeTime = entity.latestTime or state.safeTime
		state.lift = if floor then math.clamp(carry.Y / math.max(dt, 0.001), 0, rate) else 0
	else
		state.airTime += dt
	end
end

const function Update(): ()
	const now: number = os.clock()
	if now - lastStep < STEP_INTERVAL then
		return
	end
	lastStep = now
	for player, owned in Holder._clientOwned do
		if player.Parent == nil then
			continue
		end
		for entity in owned do
			if not entity.destroyed and entity.networkOwner == player then
				Step(player, entity, now)
			end
		end
	end
end

const function GetOverride(entity: Entity): Override
	const existing: Override? = Overrides[entity]
	if existing then
		return existing
	end
	const override: Override = { graceUntil = 0, bonus = 0, bonusUntil = 0 }
	Overrides[entity] = override
	return override
end

function Rollback.Exempt(entity: Entity, seconds: number): ()
	assert(type(seconds) == "number" and seconds >= 0, "Chrono: Rollback.Exempt expected a non-negative number")
	GetOverride(entity).graceUntil = os.clock() + seconds
end

function Rollback.Grant(entity: Entity, studs: number): ()
	assert(type(studs) == "number" and studs >= 0, "Chrono: Rollback.Grant expected a non-negative number")
	const override: Override = GetOverride(entity)
	const now: number = os.clock()
	const current: number = if now < override.bonusUntil then override.bonus else 0
	override.bonus = math.min(current + studs, MAX_BONUS)
	override.bonusUntil = now + BANK_TIME + 1
end

function Rollback.SetMaxSpeed(entity: Entity, speed: number?): ()
	assert(speed == nil or (type(speed) == "number" and speed >= 0), "Chrono: Rollback.SetMaxSpeed expected a non-negative number")
	GetOverride(entity).maxSpeed = speed
end

const function Gate(player: Player, entity: Entity, state: State, cframe: CFrame, now: number): boolean
	const override: Override? = Overrides[entity]
	if override and now < override.graceUntil then
		return false
	end
	const humanoid: Humanoid? = GetHumanoid(entity, state)
	if IsExempt(entity, humanoid) then
		return false
	end
	local speed: number? = override and override.maxSpeed
	if not speed and humanoid then
		speed = humanoid.WalkSpeed
	end
	if not speed then
		return false
	end

	const dt: number = math.max(now - state.time, 0)
	const peak: number = math.max(speed, state.speedPeak * math.max(0, 1 - SPEED_DECAY * dt))
	const rate: number = peak * SPEED_TOLERANCE
	const cap: number = rate * BANK_TIME + MIN_BANK
	const horizontalBank: number = math.min(state.horizontal + rate * dt, cap)
	const bonus: number = if override and now < override.bonusUntil then override.bonus else 0

	local carry: Vector3 = Vector3.zero
	const floor: BasePart? = state.floor
	const floorOffset: Vector3? = state.floorOffset
	if floor and floorOffset then
		carry = floor.CFrame:PointToWorldSpace(floorOffset) - state.position
	end

	const delta: Vector3 = cframe.Position - state.position - carry
	const flat: number = if humanoid then Vector3.new(delta.X, 0, delta.Z).Magnitude else delta.Magnitude
	if flat > horizontalBank + bonus then
		Violate(player, entity, state, cframe, now, "SPEED", flat - horizontalBank - bonus)
		return true
	end

	if humanoid then
		const verticalBank: number = math.min(state.vertical + rate * dt, cap)
		const gravity: number = workspace.Gravity
		const launch: number = GetJumpVelocity(humanoid) * JUMP_VELOCITY_TOLERANCE + state.lift
		const window: number = dt + state.idle
		const rise: number = launch * window + AIR_MARGIN
		const fall: number = (launch + gravity * state.airTime) * window + 0.5 * gravity * window * window + AIR_MARGIN
		const reach: number = math.max(rise, fall, verticalBank) + bonus
		if math.abs(delta.Y) > reach then
			Violate(
				player,
				entity,
				state,
				cframe,
				now,
				if delta.Y > 0 then "RISE" else "FALL",
				math.abs(delta.Y) - reach
			)
			return true
		end
	end

	if NoclipEnabled and (cframe.Position - state.sweepFrom).Magnitude >= NoclipMinTravel then
		const Penetration: number? = Sweep(entity, state.sweepFrom, cframe, state.safe.Position)
		if Penetration then
			Violate(player, entity, state, cframe, now, "NOCLIP", Penetration)
			return true
		end
		state.sweepFrom = cframe.Position
	end
	return false
end

function Rollback.Filter(player: Player, entity: Entity, cframe: CFrame, now: number): boolean
	if MODE ~= "ENFORCE" then
		return false
	end
	const state: State? = States[entity]
	if not state or entity.mountParentId then
		return false
	end
	SyncTeleport(entity, state, state.safe, now)
	const pending: CFrame? = state.pending
	if pending then
		return (cframe.Position - pending.Position).Magnitude > ACCEPT_RADIUS
			or ClipsPending(entity, pending, cframe, state.reapply)
	end
	return Gate(player, entity, state, cframe, now)
end

function Rollback.Reset(entity: Entity): ()
	States[entity] = nil
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
