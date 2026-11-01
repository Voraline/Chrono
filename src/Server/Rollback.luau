--!native
const RunService: RunService = game:GetService("RunService")

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

const States: { [Entity]: State } = setmetatable({}, { __mode = "k" }) :: any
const Overrides: { [Entity]: Override } = setmetatable({}, { __mode = "k" }) :: any

const ViolatedSignal =
	Signal.new() :: Types.Signal<(player: Player, entity: Entity, kind: string, excess: number) -> (), Player, Entity, string, number>

local MODE: string = "NONE"
local SPEED_TOLERANCE: number = 1.5
local BANK_TIME: number = 3
local MIN_BANK: number = 12
local AIR_MARGIN: number = 4
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

	if entity._setAt ~= state.setStamp then
		state.setStamp = entity._setAt
		state.pending = entity.latestCFrame or cframe
		state.pendingUntil = now + TELEPORT_WINDOW
		state.reapply = false
		state.attempts = 0
	end

	const pending: CFrame? = state.pending
	if pending then
		const distance: number = (position - pending.Position).Magnitude
		if distance <= ACCEPT_RADIUS then
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

function Rollback.Filter(entity: Entity, cframe: CFrame): boolean
	if MODE ~= "ENFORCE" then
		return false
	end
	const state: State? = States[entity]
	if not state then
		return false
	end
	const pending: CFrame? = state.pending
	if not pending or entity.mountParentId then
		return false
	end
	return (cframe.Position - pending.Position).Magnitude > ACCEPT_RADIUS
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
	RunService.PostSimulation:Connect(Update)
end)

return Rollback
