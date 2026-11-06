--!native

const Players = game:GetService("Players")
const RunService = game:GetService("RunService")

const Shared = script.Parent.Parent.Shared
const Entity = require(Shared.Entity)
const Signal = require(Shared.Signal)
const Types = require(Shared.Types)

type Entity = Types.Entity
type Target = Entity | BasePart | Model
type TouchEvent = Types.Event<(Part: BasePart) -> (), BasePart>
type PlayerEvent = Types.Event<(Player: Player, Part: BasePart) -> (), Player, BasePart>

export type Options = {
	Size: Vector3?,
	Offset: CFrame?,
	Interval: number?,
	CollisionGroup: string?,
	Ignore: { Instance }?,
	MaxParts: number?,
}

export type Tracker = {
	Target: Target,
	Touched: TouchEvent,
	TouchEnded: TouchEvent,
	PlayerTouched: PlayerEvent,
	PlayerTouchEnded: PlayerEvent,
	IsTouching: (self: Tracker, Part: BasePart) -> boolean,
	GetTouching: (self: Tracker) -> { BasePart },
	Destroy: (self: Tracker) -> (),
}

type Impl = Tracker & {
	_Touched: any,
	_Ended: any,
	_PlayerTouched: any,
	_PlayerEnded: any,
	_PlayerParts: { [BasePart]: Player },
	_PlayerCounts: { [Player]: number },
	_Params: OverlapParams,
	_Filter: { Instance },
	_Model: Instance?,
	_Offset: CFrame,
	_UserOffset: CFrame,
	_Size: Vector3,
	_FixedSize: boolean,
	_LiveSize: boolean,
	_Interval: number,
	_NextTime: number,
	_Stamp: number,
	_Overlapping: { [BasePart]: number },
	_Destroyed: boolean,
	_DestroyConnection: Types.Connection?,
}

const IsServer = RunService:IsServer()
const DefaultInterval = 1 / 20

local Budget = 0.0005
local Cursor = 1
local Dirty = false
local Heartbeat: RBXScriptConnection? = nil
const Active: { Impl } = {}

const Tracker = {}
Tracker.__index = Tracker

const function Resolve(Target: Target): (Instance?, BasePart?)
	if typeof(Target) == "Instance" then
		const Item = Target :: Instance
		if Item:IsA("Model") then
			return Item, Item.PrimaryPart or Item:FindFirstChildWhichIsA("BasePart", true)
		end
		return Item, Item :: BasePart
	end
	return (Target :: any).model, Entity.GetPrimaryPart(Target :: Entity)
end

const function Measure(self: Impl, Model: Instance, Part: BasePart?)
	self._Model = Model
	self._Filter[1] = Model
	self._Params.FilterDescendantsInstances = self._Filter
	self._LiveSize = false
	if self._FixedSize then
		self._Offset = self._UserOffset
	elseif Model:IsA("Model") then
		const BoxCFrame, BoxSize = Model:GetBoundingBox()
		self._Size = BoxSize
		self._Offset = (if Part then Part.CFrame:ToObjectSpace(BoxCFrame) else CFrame.identity) * self._UserOffset
	elseif Model:IsA("BasePart") then
		self._LiveSize = true
		self._Offset = self._UserOffset
	end
end

const function PartEntered(self: Impl, Part: BasePart)
	self._Touched:Fire(Part)
	if self._PlayerTouched:HasListeners() or self._PlayerEnded:HasListeners() then
		const Character = Part:FindFirstAncestorOfClass("Model")
		const Player = if Character then Players:GetPlayerFromCharacter(Character) else nil
		if Player then
			self._PlayerParts[Part] = Player
			const Count = (self._PlayerCounts[Player] or 0) + 1
			self._PlayerCounts[Player] = Count
			if Count == 1 then
				self._PlayerTouched:Fire(Player, Part)
			end
		end
	end
end

const function PartLeft(self: Impl, Part: BasePart)
	self._Ended:Fire(Part)
	const Player = self._PlayerParts[Part]
	if Player then
		self._PlayerParts[Part] = nil
		const Count = (self._PlayerCounts[Player] or 1) - 1
		if Count <= 0 then
			self._PlayerCounts[Player] = nil
			self._PlayerEnded:Fire(Player, Part)
		else
			self._PlayerCounts[Player] = Count
		end
	end
end

const function Update(self: Impl)
	const Overlapping = self._Overlapping

	if
		not (
			self._Touched:HasListeners()
			or self._Ended:HasListeners()
			or self._PlayerTouched:HasListeners()
			or self._PlayerEnded:HasListeners()
		)
	then
		if next(Overlapping) ~= nil then
			table.clear(Overlapping)
			table.clear(self._PlayerParts)
			table.clear(self._PlayerCounts)
		end
		return
	end

	const Model, Part = Resolve(self.Target)
	if not Model or not Part then
		return
	end
	if Model ~= self._Model then
		Measure(self, Model, Part)
	end

	const Stamp = self._Stamp + 1
	self._Stamp = Stamp

	const Size = if self._LiveSize then Part.Size else self._Size
	const Results = workspace:GetPartBoundsInBox(Part.CFrame * self._Offset, Size, self._Params)
	for Index = 1, #Results do
		const Other = Results[Index]
		if Overlapping[Other] then
			Overlapping[Other] = Stamp
		elseif Other.CanTouch then
			Overlapping[Other] = Stamp
			PartEntered(self, Other)
		end
	end

	for Other, Seen in Overlapping do
		if Seen ~= Stamp then
			Overlapping[Other] = nil
			PartLeft(self, Other)
		end
	end
end

const function Compact()
	Dirty = false
	const Count = #Active
	local Write = 1
	local NewCursor = 1
	for Read = 1, Count do
		if Read == Cursor then
			NewCursor = Write
		end
		const Item = Active[Read]
		if not Item._Destroyed then
			if Write ~= Read then
				Active[Write] = Item
			end
			Write += 1
		end
	end
	for Index = Count, Write, -1 do
		Active[Index] = nil
	end
	Cursor = if NewCursor > Write - 1 then 1 else NewCursor
end

const function Step()
	if Dirty then
		Compact()
	end
	const Count = #Active
	if Count == 0 then
		if Heartbeat then
			Heartbeat:Disconnect()
			Heartbeat = nil
		end
		return
	end

	const Now = os.clock()
	const Deadline = Now + Budget
	local Index = if Cursor > Count then 1 else Cursor

	for _ = 1, Count do
		const Item = Active[Index]
		Index = if Index == Count then 1 else Index + 1
		Cursor = Index
		if not Item._Destroyed and Now >= Item._NextTime then
			Item._NextTime = Now + Item._Interval
			Update(Item)
			if os.clock() >= Deadline then
				break
			end
		end
	end
end

function Tracker.IsTouching(self: Impl, Part: BasePart): boolean
	return self._Overlapping[Part] ~= nil
end

function Tracker.GetTouching(self: Impl): { BasePart }
	const List: { BasePart } = {}
	local Count = 0
	for Part in self._Overlapping do
		Count += 1
		List[Count] = Part
	end
	return List
end

function Tracker.Destroy(self: Impl)
	if self._Destroyed then
		return
	end
	self._Destroyed = true
	Dirty = true
	self._Touched:DisconnectAll()
	self._Ended:DisconnectAll()
	self._PlayerTouched:DisconnectAll()
	self._PlayerEnded:DisconnectAll()
	const Connection = self._DestroyConnection
	if Connection then
		self._DestroyConnection = nil
		Connection:Disconnect()
	end
end

const Touch = {}

function Touch.Track(Target: Target, Settings: Options?): Tracker
	assert(IsServer, "Chrono.Touch.Track can only be used on the server")
	const IsInstance = typeof(Target) == "Instance"
	assert(
		if IsInstance
			then (Target :: Instance):IsA("BasePart") or (Target :: Instance):IsA("Model")
			else type(Target) == "table" and not (Target :: any).destroyed,
		"Chrono.Touch.Track expects a live entity, a BasePart or a Model"
	)

	const Opts: Options = Settings or {}
	const TickInterval = if IsInstance then DefaultInterval else (Target :: any).entityConfig.TICK_RATE
	const Interval = math.max(Opts.Interval or TickInterval or DefaultInterval, 0)

	const Params = OverlapParams.new()
	Params.FilterType = Enum.RaycastFilterType.Exclude
	Params.MaxParts = Opts.MaxParts or 0
	if Opts.CollisionGroup then
		Params.CollisionGroup = Opts.CollisionGroup
	end

	const Filter: { Instance } = {}
	const Ignore = Opts.Ignore
	if Ignore then
		for Index, Item in Ignore do
			Filter[Index + 1] = Item
		end
	end

	const TouchedSignal = Signal.new()
	const EndedSignal = Signal.new()
	const PlayerTouchedSignal = Signal.new()
	const PlayerEndedSignal = Signal.new()

	const self: Impl = setmetatable({
		Target = Target,
		Touched = TouchedSignal.Event,
		TouchEnded = EndedSignal.Event,
		PlayerTouched = PlayerTouchedSignal.Event,
		PlayerTouchEnded = PlayerEndedSignal.Event,
		_Touched = TouchedSignal,
		_Ended = EndedSignal,
		_PlayerTouched = PlayerTouchedSignal,
		_PlayerEnded = PlayerEndedSignal,
		_PlayerParts = {},
		_PlayerCounts = {},
		_Params = Params,
		_Filter = Filter,
		_Model = nil,
		_Offset = CFrame.identity,
		_UserOffset = Opts.Offset or CFrame.identity,
		_Size = Opts.Size or Vector3.one,
		_FixedSize = Opts.Size ~= nil,
		_LiveSize = false,
		_Interval = Interval,
		_NextTime = os.clock() + math.random() * Interval,
		_Stamp = 0,
		_Overlapping = {},
		_Destroyed = false,
		_DestroyConnection = nil,
	}, Tracker) :: any

	self._DestroyConnection = if IsInstance
		then (Target :: Instance).Destroying:Connect(function()
			self:Destroy()
		end)
		else Entity.GetEvent(Target :: Entity, "Destroying"):Connect(function()
			self:Destroy()
		end)

	table.insert(Active, self)
	if not Heartbeat then
		Heartbeat = RunService.Heartbeat:Connect(Step)
	end

	return self
end

function Touch.SetBudget(Seconds: number)
	assert(type(Seconds) == "number" and Seconds > 0, "Chrono.Touch.SetBudget expects a positive number of seconds")
	Budget = Seconds
end

return Touch
