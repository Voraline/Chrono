--!native

const Players: Players = game:GetService("Players")
const RunService: RunService = game:GetService("RunService")

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
	_Part: BasePart?,
	_Measured: boolean,
	_ModelConnections: { RBXScriptConnection },
	_Offset: CFrame,
	_UserOffset: CFrame,
	_Size: Vector3,
	_FixedSize: boolean,
	_LiveSize: boolean,
	_Interval: number,
	_NextTime: number,
	_HeapIndex: number,
	_Stamp: number,
	_Overlapping: { [BasePart]: number },
	_Destroyed: boolean,
	_DestroyConnection: RBXScriptConnection?,
	_EntityConnection: Types.Connection?,
}

const IsServer: boolean = RunService:IsServer()
const DefaultInterval: number = 1 / 20
const Empty: { BasePart } = table.freeze({} :: { BasePart })

local Budget: number = 0.0005
local Heartbeat: RBXScriptConnection? = nil
const Heap: { Impl } = {}

const Tracker = {}
Tracker.__index = Tracker

const function SiftUp(Start: number): ()
	const Item: Impl = Heap[Start]
	local Index: number = Start
	while Index > 1 do
		const ParentIndex: number = Index // 2
		const Parent: Impl = Heap[ParentIndex]
		if Item._NextTime >= Parent._NextTime then
			break
		end
		Heap[Index] = Parent
		Parent._HeapIndex = Index
		Index = ParentIndex
	end
	Heap[Index] = Item
	Item._HeapIndex = Index
end

const function SiftDown(Start: number): ()
	const Count: number = #Heap
	const Item: Impl = Heap[Start]
	local Index: number = Start
	while true do
		local Child: number = Index * 2
		if Child > Count then
			break
		end
		if Child < Count and Heap[Child + 1]._NextTime < Heap[Child]._NextTime then
			Child += 1
		end
		const Smaller: Impl = Heap[Child]
		if Smaller._NextTime >= Item._NextTime then
			break
		end
		Heap[Index] = Smaller
		Smaller._HeapIndex = Index
		Index = Child
	end
	Heap[Index] = Item
	Item._HeapIndex = Index
end

const function HeapPush(Item: Impl): ()
	const Count: number = #Heap + 1
	Heap[Count] = Item
	Item._HeapIndex = Count
	SiftUp(Count)
end

const function HeapRemove(Item: Impl): ()
	const Index: number = Item._HeapIndex
	if Index == 0 then
		return
	end
	Item._HeapIndex = 0
	const Count: number = #Heap
	const Last: Impl = Heap[Count]
	Heap[Count] = nil :: any
	if Index == Count then
		return
	end
	Heap[Index] = Last
	Last._HeapIndex = Index
	SiftDown(Index)
	SiftUp(Last._HeapIndex)
end

const function HasListeners(self: Impl): boolean
	return self._Touched:HasListeners()
		or self._Ended:HasListeners()
		or self._PlayerTouched:HasListeners()
		or self._PlayerEnded:HasListeners()
end

const function Resolve(Target: Target): (Instance?, BasePart?)
	if typeof(Target) == "Instance" then
		const Item: Instance = (Target :: any) :: Instance
		if Item:IsA("Model") then
			const Primary: BasePart? = Item.PrimaryPart
			if Primary then
				return Item, Primary
			end
			const Found: Instance? = Item:FindFirstChildWhichIsA("BasePart", true)
			if Found and Found:IsA("BasePart") then
				return Item, Found
			end
			return Item, nil
		end
		return Item, Item :: BasePart
	end
	return (Target :: any).model, Entity.GetPrimaryPart(Target :: Entity)
end

const function FindPlayer(Part: BasePart): Player?
	local Current: Instance? = Part.Parent
	while Current and Current ~= workspace do
		if Current:IsA("Model") then
			const Found: Player? = Players:GetPlayerFromCharacter(Current)
			if Found then
				return Found
			end
		end
		Current = Current.Parent
	end
	return nil
end

const function Unwatch(self: Impl): ()
	const Connections: { RBXScriptConnection } = self._ModelConnections
	for Index: number = 1, #Connections do
		Connections[Index]:Disconnect()
	end
	table.clear(Connections)
end

const function Watch(self: Impl, Model: Instance): ()
	Unwatch(self)
	if self._FixedSize or not Model:IsA("Model") then
		return
	end
	const function Invalidate(): ()
		self._Measured = false
	end
	self._ModelConnections[1] = Model.DescendantAdded:Connect(Invalidate)
	self._ModelConnections[2] = Model.DescendantRemoving:Connect(Invalidate)
end

const function Measure(self: Impl, Model: Instance, Part: BasePart): ()
	if Model ~= self._Model then
		self._Model = Model
		self._Filter[1] = Model
		self._Params.FilterDescendantsInstances = self._Filter
		Watch(self, Model)
	end
	self._Part = Part
	self._Measured = true
	self._LiveSize = false
	if self._FixedSize then
		self._Offset = self._UserOffset
	elseif Model:IsA("Model") then
		const BoxCFrame: CFrame, BoxSize: Vector3 = Model:GetBoundingBox()
		self._Size = BoxSize
		self._Offset = Part.CFrame:ToObjectSpace(BoxCFrame) * self._UserOffset
	elseif Model:IsA("BasePart") then
		self._LiveSize = true
		self._Offset = self._UserOffset
	end
end

const function Collect(self: Impl): { BasePart }
	if self._Destroyed then
		return Empty
	end
	const Model: Instance?, Part: BasePart? = Resolve(self.Target)
	if not Model or not Part then
		return Empty
	end
	if not self._Measured or Model ~= self._Model or Part ~= self._Part then
		Measure(self, Model, Part)
	end
	const Size: Vector3 = if self._LiveSize then Part.Size else self._Size
	return workspace:GetPartBoundsInBox(Part.CFrame * self._Offset, Size, self._Params)
end

const function PartEntered(self: Impl, Part: BasePart): ()
	const Player: Player? = FindPlayer(Part)
	local First: boolean = false
	if Player then
		self._PlayerParts[Part] = Player
		const Count: number = (self._PlayerCounts[Player] or 0) + 1
		self._PlayerCounts[Player] = Count
		First = Count == 1
	end
	self._Touched:Fire(Part)
	if First and Player and not self._Destroyed then
		self._PlayerTouched:Fire(Player, Part)
	end
end

const function PartLeft(self: Impl, Part: BasePart): ()
	self._Ended:Fire(Part)
	const Player: Player? = self._PlayerParts[Part]
	if Player then
		self._PlayerParts[Part] = nil
		const Count: number = (self._PlayerCounts[Player] or 1) - 1
		if Count <= 0 then
			self._PlayerCounts[Player] = nil
			self._PlayerEnded:Fire(Player, Part)
		else
			self._PlayerCounts[Player] = Count
		end
	end
end

const function Update(self: Impl): ()
	const Overlapping: { [BasePart]: number } = self._Overlapping

	if not HasListeners(self) then
		if next(Overlapping) ~= nil then
			table.clear(Overlapping)
			table.clear(self._PlayerParts)
			table.clear(self._PlayerCounts)
		end
		return
	end

	const Results: { BasePart } = Collect(self)
	const Stamp: number = self._Stamp + 1
	self._Stamp = Stamp

	for Index: number = 1, #Results do
		const Other: BasePart = Results[Index]
		if Other.CanTouch then
			if Overlapping[Other] then
				Overlapping[Other] = Stamp
			else
				Overlapping[Other] = Stamp
				PartEntered(self, Other)
				if self._Destroyed then
					return
				end
			end
		end
	end

	for Other: BasePart, Seen: number in Overlapping do
		if Seen ~= Stamp then
			Overlapping[Other] = nil
			PartLeft(self, Other)
			if self._Destroyed then
				return
			end
		end
	end
end

const function Step(): ()
	if #Heap == 0 then
		if Heartbeat then
			Heartbeat:Disconnect()
			Heartbeat = nil
		end
		return
	end

	const Now: number = os.clock()
	const Deadline: number = Now + Budget

	while true do
		const Item: Impl? = Heap[1]
		if not Item or Item._NextTime >= Now then
			break
		end
		HeapRemove(Item)
		Item._NextTime = Now + Item._Interval
		Update(Item)
		if not Item._Destroyed then
			HeapPush(Item)
		end
		if os.clock() >= Deadline then
			break
		end
	end
end

function Tracker.IsTouching(self: Impl, Part: BasePart): boolean
	if self._Destroyed then
		return false
	end
	if HasListeners(self) then
		return self._Overlapping[Part] ~= nil
	end
	const Results: { BasePart } = Collect(self)
	for Index: number = 1, #Results do
		if Results[Index] == Part then
			return Part.CanTouch
		end
	end
	return false
end

function Tracker.GetTouching(self: Impl): { BasePart }
	const List: { BasePart } = {}
	if self._Destroyed then
		return List
	end
	local Count: number = 0
	if HasListeners(self) then
		for Part: BasePart in self._Overlapping do
			Count += 1
			List[Count] = Part
		end
	else
		const Results: { BasePart } = Collect(self)
		for Index: number = 1, #Results do
			const Part: BasePart = Results[Index]
			if Part.CanTouch then
				Count += 1
				List[Count] = Part
			end
		end
	end
	return List
end

function Tracker.Destroy(self: Impl): ()
	if self._Destroyed then
		return
	end
	self._Destroyed = true
	HeapRemove(self)

	const Connection: RBXScriptConnection? = self._DestroyConnection
	if Connection then
		self._DestroyConnection = nil
		Connection:Disconnect()
	end
	const EntityConnection: Types.Connection? = self._EntityConnection
	if EntityConnection then
		self._EntityConnection = nil
		EntityConnection:Disconnect()
	end
	Unwatch(self)

	const Remaining: { BasePart } = {}
	local Count: number = 0
	for Part: BasePart in self._Overlapping do
		Count += 1
		Remaining[Count] = Part
	end
	table.clear(self._Overlapping)
	for Index: number = 1, Count do
		PartLeft(self, Remaining[Index])
	end

	table.clear(self._PlayerParts)
	table.clear(self._PlayerCounts)
	self._Touched:DisconnectAll()
	self._Ended:DisconnectAll()
	self._PlayerTouched:DisconnectAll()
	self._PlayerEnded:DisconnectAll()
end

const Touch = {}

function Touch.Track(Target: Target, Settings: Options?): Tracker
	assert(IsServer, "Chrono.Touch.Track can only be used on the server")
	const IsInstance: boolean = typeof(Target) == "Instance"
	assert(
		if IsInstance
			then ((Target :: any) :: Instance):IsA("BasePart") or ((Target :: any) :: Instance):IsA("Model")
			else type(Target) == "table" and not (Target :: any).destroyed,
		"Chrono.Touch.Track expects a live entity, a BasePart or a Model"
	)

	const Opts: Options = Settings or {}
	const TickInterval: number? = if IsInstance then DefaultInterval else (Target :: any).entityConfig.TICK_RATE
	const Interval: number = math.max(Opts.Interval or TickInterval or DefaultInterval, 0)

	const Params: OverlapParams = OverlapParams.new()
	Params.FilterType = Enum.RaycastFilterType.Exclude
	Params.MaxParts = Opts.MaxParts or 0
	if Opts.CollisionGroup then
		Params.CollisionGroup = Opts.CollisionGroup
	end

	const Filter: { Instance } = {}
	const Ignore: { Instance }? = Opts.Ignore
	if Ignore then
		for Index: number, Item: Instance in Ignore do
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
		_Part = nil,
		_Measured = false,
		_ModelConnections = {},
		_Offset = CFrame.identity,
		_UserOffset = Opts.Offset or CFrame.identity,
		_Size = Opts.Size or Vector3.one,
		_FixedSize = Opts.Size ~= nil,
		_LiveSize = false,
		_Interval = Interval,
		_NextTime = os.clock() + math.random() * Interval,
		_HeapIndex = 0,
		_Stamp = 0,
		_Overlapping = {},
		_Destroyed = false,
		_DestroyConnection = nil,
		_EntityConnection = nil,
	}, Tracker) :: any

	if IsInstance then
		self._DestroyConnection = ((Target :: any) :: Instance).Destroying:Connect(function(): ()
			self:Destroy()
		end)
	else
		self._EntityConnection = Entity.GetEvent((Target :: any) :: Entity, "Destroying"):Connect(function(): ()
			self:Destroy()
		end)
	end

	HeapPush(self)
	if not Heartbeat then
		Heartbeat = RunService.Heartbeat:Connect(Step)
	end

	return self
end

function Touch.SetBudget(Seconds: number): ()
	assert(type(Seconds) == "number" and Seconds > 0, "Chrono.Touch.SetBudget expects a positive number of seconds")
	Budget = Seconds
end

return Touch
