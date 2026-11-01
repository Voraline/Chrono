--!native
const RunService = game:GetService("RunService")

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
}

const STEP_INTERVAL = 1 / 20
const IDLE_EPSILON = 0.01
const JUMP_POWER_SCALE = 1.06
const JUMP_VELOCITY_TOLERANCE = 1.25
const GROUND_EXTRA_DISTANCE = 2
const MIN_HIP_HEIGHT = 2
const ACCEPT_RADIUS = 8
const REAPPLY_INTERVAL = 0.75
const TELEPORT_WINDOW = 1.5
const MAX_REAPPLY_ATTEMPTS = 4
const SPEED_DECAY = 1
const MAX_BONUS = 500

const States: { [Entity]: State } = setmetatable({}, { __mode = "k" }) :: any
const Overrides: { [Entity]: Override } = setmetatable({}, { __mode = "k" }) :: any

const ViolatedSignal =
	Signal.new() :: Types.Signal<(player: Player, entity: Entity, kind: string, excess: number) -> (), Player, Entity, string, number>

local MODE: string = "NONE"
local SPEED_TOLERANCE = 1.5
local BANK_TIME = 3
local MIN_BANK = 12
local AIR_MARGIN = 4
local lastStep = 0

const Rollback = {}

const function Observe(entity: Entity): CFrame?
	if entity.modelReplicationMode == "NATIVE" and not entity._lockedCFReplication then
		const part = Entity.GetPrimaryPart(entity)
		if part then
			return part.CFrame
		end
	end
	return entity.latestCFrame
end

const function GetHumanoid(entity: Entity, state: State): Humanoid?
	const cached = state.humanoid
	if cached and cached.Parent then
		return cached
	end
	const model = entity.model
	local humanoid: Humanoid? = nil
	if model and model:IsA("Model") then
		humanoid = model:FindFirstChildWhichIsA("Humanoid")
	end
	state.humanoid = humanoid
	state.params = nil
	return humanoid
end

const function GetParams(entity: Entity, state: State): RaycastParams
	local params = state.params
	if not params then
		params = RaycastParams.new()
		params.FilterType = Enum.RaycastFilterType.Exclude
		params.FilterDescendantsInstances = if entity.model then { entity.model } else {}
		state.params = params
	end
	return params :: RaycastParams
end

const function GetSupport(entity: Entity, state: State, humanoid: Humanoid, position: Vector3): BasePart?
	const root = Entity.GetPrimaryPart(entity)
	const rootHalf = if root then root.Size.Y / 2 else 1
	const distance = math.max(humanoid.HipHeight, MIN_HIP_HEIGHT) + rootHalf + GROUND_EXTRA_DISTANCE
	const result = workspace:Raycast(position, Vector3.new(0, -distance, 0), GetParams(entity, state))
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
	}
end

const function Rebase(state: State, cframe: CFrame)
	state.position = cframe.Position
	state.safe = cframe
	state.pending = nil
	state.reapply = false
	state.attempts = 0
	state.horizontal = MIN_BANK
	state.vertical = MIN_BANK
	state.idle = 0
	state.airTime = 0
	state.groundY = cframe.Position.Y
	state.lift = 0
	state.floor = nil
	state.floorOffset = nil
end

const function Apply(entity: Entity, state: State, target: CFrame)
	Entity.SetCFrame(entity, target)
	Entity._SetPartCFrame(entity, target)
	const part = Entity.GetPrimaryPart(entity)
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
)
	Warn.medium("Rollback:", player.Name, kind, excess)
	ViolatedSignal:Fire(player, entity, kind, excess)
	if MODE ~= "ENFORCE" then
		if kind ~= "INVALID" then
			Rebase(state, cframe)
		end
		return
	end
	const target = state.safe
	Apply(entity, state, target)
	Rebase(state, target)
	state.pending = target
	state.pendingUntil = now + GetDelay(player)
	state.reapply = true
	state.attempts = 1
end

const function Step(player: Player, entity: Entity, now: number)
	const cframe = Observe(entity)
	if not cframe then
		States[entity] = nil
		return
	end
	const state = States[entity]
	if not state then
		States[entity] = NewState(entity, cframe, now)
		return
	end

	const dt = now - state.time
	state.time = now
	const position = cframe.Position

	if entity._setAt ~= state.setStamp then
		state.setStamp = entity._setAt
		state.pending = entity.latestCFrame or cframe
		state.pendingUntil = now + TELEPORT_WINDOW
		state.reapply = false
		state.attempts = 0
	end

	const pending = state.pending
	if pending then
		const distance = (position - pending.Position).Magnitude
		if distance <= ACCEPT_RADIUS then
			Rebase(state, cframe)
		elseif now >= state.pendingUntil then
			if state.reapply and state.attempts < MAX_REAPPLY_ATTEMPTS then
				state.attempts += 1
				state.pendingUntil = now + GetDelay(player)
				Apply(entity, state, pending)
			else
				const wasRollback = state.reapply
				Rebase(state, cframe)
				if wasRollback then
					ViolatedSignal:Fire(player, entity, "DESYNC", distance)
				end
			end
		end
		return
	end

	const override = Overrides[entity]
	const humanoid = GetHumanoid(entity, state)
	if (override and now < override.graceUntil) or IsExempt(entity, humanoid) then
		Rebase(state, cframe)
		return
	end

	local speed = override and override.maxSpeed
	if not speed and humanoid then
		speed = humanoid.WalkSpeed
	end
	if not speed then
		Rebase(state, cframe)
		return
	end

	const sum = position.X + position.Y + position.Z
	if sum ~= sum or math.abs(sum) == math.huge then
		Violate(player, entity, state, cframe, now, "INVALID", 0)
		return
	end

	state.speedPeak = math.max(speed, state.speedPeak * math.max(0, 1 - SPEED_DECAY * dt))
	const rate = state.speedPeak * SPEED_TOLERANCE
	const cap = rate * BANK_TIME + MIN_BANK
	const horizontalBank = math.min(state.horizontal + rate * dt, cap)
	const verticalBank = math.min(state.vertical + rate * dt, cap)

	local floor: BasePart? = nil
	local tethered = false
	if humanoid then
		floor = GetSupport(entity, state, humanoid, position)
		const humanoidState = humanoid:GetState()
		tethered = humanoidState == Enum.HumanoidStateType.Climbing
			or humanoidState == Enum.HumanoidStateType.Swimming
	end

	local carry = Vector3.zero
	const previousFloor = state.floor
	const floorOffset = state.floorOffset
	if floor and floor == previousFloor and floorOffset then
		carry = floor.CFrame:PointToWorldSpace(floorOffset) - state.position
	end

	const moved = (position - state.position).Magnitude
	const delta = position - state.position - carry
	const flat = if humanoid then Vector3.new(delta.X, 0, delta.Z).Magnitude else delta.Magnitude
	const bonusActive = override ~= nil and now < override.bonusUntil
	local bonus = if bonusActive and override then override.bonus else 0

	const horizontalOk, nextHorizontal, horizontalBonus = Spend(horizontalBank, bonus, flat)
	if not horizontalOk then
		Violate(player, entity, state, cframe, now, "SPEED", flat - horizontalBank - bonus)
		return
	end
	bonus = horizontalBonus

	local nextVertical = verticalBank
	const supported = humanoid == nil or floor ~= nil or tethered

	if humanoid then
		const gravity = workspace.Gravity
		const launch = GetJumpVelocity(humanoid) * JUMP_VELOCITY_TOLERANCE + state.lift
		const window = dt + state.idle
		if tethered then
			const ok, bank, remaining = Spend(verticalBank, bonus, math.abs(delta.Y))
			if not ok then
				Violate(player, entity, state, cframe, now, "CLIMB", math.abs(delta.Y) - verticalBank - bonus)
				return
			end
			nextVertical = bank
			bonus = remaining
		else
			const rise = launch * window + AIR_MARGIN
			const fall = (launch + gravity * state.airTime) * window + 0.5 * gravity * window * window + AIR_MARGIN
			const riseOk, riseBonus = Allow(delta.Y - rise, bonus)
			if not riseOk then
				Violate(player, entity, state, cframe, now, "RISE", delta.Y - rise - bonus)
				return
			end
			const fallOk, fallBonus = Allow(-delta.Y - fall, riseBonus)
			if not fallOk then
				Violate(player, entity, state, cframe, now, "FALL", -delta.Y - fall - riseBonus)
				return
			end
			bonus = fallBonus
			if not supported then
				const airborne = state.airTime + dt
				const apex = math.max(launch * airborne - 0.5 * gravity * airborne * airborne, 0)
				const ceiling = state.groundY + apex + AIR_MARGIN
				const flyOk, flyBonus = Allow(position.Y - ceiling, bonus)
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
		state.lift = if floor then math.clamp(carry.Y / math.max(dt, 0.001), 0, rate) else 0
	else
		state.airTime += dt
	end
end

const function Update()
	const now = os.clock()
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
	local override = Overrides[entity]
	if not override then
		override = { graceUntil = 0, bonus = 0, bonusUntil = 0 }
		Overrides[entity] = override
	end
	return override :: Override
end

function Rollback.Exempt(entity: Entity, seconds: number)
	assert(type(seconds) == "number" and seconds >= 0, "Chrono: Rollback.Exempt expected a non-negative number")
	GetOverride(entity).graceUntil = os.clock() + seconds
end

function Rollback.Grant(entity: Entity, studs: number)
	assert(type(studs) == "number" and studs >= 0, "Chrono: Rollback.Grant expected a non-negative number")
	const override = GetOverride(entity)
	const now = os.clock()
	const current = if now < override.bonusUntil then override.bonus else 0
	override.bonus = math.min(current + studs, MAX_BONUS)
	override.bonusUntil = now + BANK_TIME + 1
end

function Rollback.SetMaxSpeed(entity: Entity, speed: number?)
	assert(speed == nil or (type(speed) == "number" and speed >= 0), "Chrono: Rollback.SetMaxSpeed expected a non-negative number")
	GetOverride(entity).maxSpeed = speed
end

function Rollback.Reset(entity: Entity)
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
