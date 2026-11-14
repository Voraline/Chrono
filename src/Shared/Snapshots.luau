--!native

const Types = require(script.Parent.Types)

type SnapshotData<Value, Velocity> = Types.SnapshotData<Value, Velocity>

type Snapshot<Value, Velocity> = Types.Snapshot<Value, Velocity>

const Config = require(script.Parent.Config)
const InterpolationMath = require(script.Parent.InterpolationMath)
const Warn = require(script.Parent.Warn)

local MAX_LENGTH: number
const PEAK_SPEED_DECAY = 0.98

Config._WaitForLock(function()
	MAX_LENGTH = Config._GetConfig("MAX_SNAPSHOT_COUNT")
end)

const function GetBufferIndex(head: number, relativeIndex: number): number
	return (head + relativeIndex - 2) % MAX_LENGTH + 1
end

const function BinarySearchInsertionPoint<Value, Velocity>(self: Snapshot<Value, Velocity>, timeStamp: number): number
	const count: number = self.count
	if count == 0 then
		return 1
	end

	local left: number = 1
	local right: number = count
	const cache: { SnapshotData<Value, Velocity> } = self.cache
	const head: number = self.head

	while left <= right do
		const mid: number = (left + right) // 2
		const bufferIndex: number = GetBufferIndex(head, mid)
		const midTime: number = cache[bufferIndex].t

		if midTime < timeStamp then
			left = mid + 1
		else
			right = mid - 1
		end
	end

	return left
end

const function ShiftElementsRight<Value, Velocity>(self: Snapshot<Value, Velocity>, startPos: number, endPos: number)
	const cache: { SnapshotData<Value, Velocity> } = self.cache
	const head: number = self.head

	for i = endPos, startPos, -1 do
		const fromIndex: number = GetBufferIndex(head, i)
		const toIndex: number = GetBufferIndex(head, i + 1)
		cache[toIndex] = cache[fromIndex]
	end
end

const function GetLatest<Value, Velocity>(self: Snapshot<Value, Velocity>): SnapshotData<Value, Velocity>?
	if self.count == 0 then
		return nil
	end

	const lastIndex: number = GetBufferIndex(self.head, self.count)
	return self.cache[lastIndex]
end

const function Push<Value, Velocity>(self: Snapshot<Value, Velocity>, timeStamp: number, value: Value, velocity: Velocity)
	const cache: { SnapshotData<Value, Velocity> } = self.cache
	const count: number = self.count
	const head: number = self.head

	if count == 0 then
		const slot = cache[head]
		slot.t = timeStamp
		slot.value = value
		slot.velocity = velocity
		self.count = 1
		return
	end

	local insertionPos: number
	if cache[GetBufferIndex(head, count)].t < timeStamp then
		insertionPos = count + 1
	else
		insertionPos = BinarySearchInsertionPoint(self, timeStamp)
	end

	if insertionPos > count then
		if count < MAX_LENGTH then
			const slot = cache[GetBufferIndex(head, count + 1)]
			slot.t = timeStamp
			slot.value = value
			slot.velocity = velocity
			self.count = count + 1
		else
			const slot = cache[head]
			slot.t = timeStamp
			slot.value = value
			slot.velocity = velocity
			self.head = head % MAX_LENGTH + 1
		end
	else
		const newData = { t = timeStamp, value = value, velocity = velocity }
		if count < MAX_LENGTH then
			ShiftElementsRight(self, insertionPos, count)
			cache[GetBufferIndex(head, insertionPos)] = newData
			self.count = count + 1
		else
			if insertionPos == 1 then
				return
			end
			for i = 1, insertionPos - 2 do
				cache[GetBufferIndex(head, i)] = cache[GetBufferIndex(head, i + 1)]
			end
			cache[GetBufferIndex(head, insertionPos - 1)] = newData
		end
	end
end

const function PushWithCheck<Value, Velocity>(
	self: Snapshot<Value, Velocity>,
	timeStamp: number,
	value: Value,
	velocity: Velocity?,
	tickrate: number,
	stopped: boolean?
)
	const latestData = GetLatest(self)
	const isNewest: boolean = not latestData or timeStamp > latestData.t
	if stopped then
		Push(self, timeStamp, value, vector.zero :: any)
		if isNewest then
			self.stoppedAt = timeStamp
		end
		return
	end

	const position = (value :: any).Position
	local teleported: boolean = false
	if latestData and isNewest and latestData.t == self.stoppedAt then
		const moved: number = vector.magnitude(position - (latestData.value :: any).Position)
		const gap: number = timeStamp - latestData.t
		const travelTime: number = if self.peakSpeed > 1e-3 then moved / self.peakSpeed else 0

		teleported = travelTime > tickrate * 5
		const startAt: number = timeStamp - (if teleported then tickrate else math.max(tickrate, travelTime))
		if startAt > latestData.t and gap > tickrate * 1.5 then
			Push(self, startAt, latestData.value, vector.zero :: any)
		end
	elseif
		latestData and InterpolationMath.CheckIdle(latestData :: any, timeStamp, position, tickrate, self.peakSpeed)
	then
		latestData.velocity = vector.zero :: any
		Push(self, timeStamp - tickrate, latestData.value, vector.zero :: any)
	end
	if isNewest then
		self.stoppedAt = nil
	end

	const pushVelocity: Velocity = velocity
		or InterpolationMath.VelocityAt(GetLatest(self) :: any, timeStamp, value :: any, tickrate, self.peakSpeed) :: any

	Push(self, timeStamp, value, pushVelocity)
	if not teleported then
		self.peakSpeed = math.max(vector.magnitude(pushVelocity :: any), self.peakSpeed * PEAK_SPEED_DECAY)
	end
end

const function GetAt<Value, Velocity>(self: Snapshot<Value, Velocity>, at: number, bypassLock: boolean?): Value?
	const count: number = self.count
	if count == 0 then
		return nil
	end

	if count == 1 then
		const index: number = GetBufferIndex(self.head, 1)
		return self.cache[index].value
	end

	if at < 0 then
		const latest = GetLatest(self)
		return latest and latest.value or nil
	end

	const cache: { SnapshotData<Value, Velocity> } = self.cache
	const head: number = self.head
	const lerpFunction = self.Lerp
	const lockedTime: number = self.lockedTime

	if at < lockedTime and not bypassLock then
		at = lockedTime
	end

	local insertionPos: number = 0
	const hint: number = self.hint
	if hint < count then
		if cache[GetBufferIndex(head, hint)].t < at then
			if cache[GetBufferIndex(head, hint + 1)].t >= at then
				insertionPos = hint + 1
			elseif hint + 1 < count and cache[GetBufferIndex(head, hint + 2)].t >= at then
				insertionPos = hint + 2
			end
		end
	end
	if insertionPos == 0 then
		insertionPos = BinarySearchInsertionPoint(self, at)
	end
	if insertionPos > 1 then
		self.hint = insertionPos - 1
	end

	const beforePos: number = insertionPos - 1
	const afterPos: number = insertionPos

	local beforeData: SnapshotData<Value, Velocity>?
	local afterData: SnapshotData<Value, Velocity>?

	if beforePos >= 1 and beforePos <= count then
		const beforeIndex: number = GetBufferIndex(head, beforePos)
		beforeData = cache[beforeIndex]
	end

	if afterPos >= 1 and afterPos <= count then
		const afterIndex: number = GetBufferIndex(head, afterPos)
		afterData = cache[afterIndex]
	end

	if beforeData and afterData then
		const dt: number = afterData.t - beforeData.t
		if dt == 0 then
			return beforeData.value
		end
		const alpha: number = (at - beforeData.t) / dt

		return lerpFunction(beforeData.value, afterData.value, beforeData.velocity, afterData.velocity, alpha, dt)
	elseif beforeData then
		Warn.low("Tried to fetch a time that was ahead of snapshot storage!")
		return beforeData.value
	elseif afterData then
		Warn.low("Tried to fetch a time that was behind snapshot storage!")
		return afterData.value
	end

	return nil
end

const function TrimAfter<Value, Velocity>(self: Snapshot<Value, Velocity>, time: number): ()
	const cache: { SnapshotData<Value, Velocity> } = self.cache
	const head: number = self.head
	local count: number = self.count
	while count > 0 and cache[GetBufferIndex(head, count)].t > time do
		count -= 1
	end
	self.count = count
	const stoppedAt: number? = self.stoppedAt
	if stoppedAt and stoppedAt > time then
		self.stoppedAt = nil
	end
end

const function Clear<Value, Velocity>(self: Snapshot<Value, Velocity>)
	self.head = 1
	self.count = 0
	self.lockedTime = 0
	self.peakSpeed = 0
	self.hint = 1
	self.stoppedAt = nil
end

const function New<Value, Velocity>(lerpFunction: (Value, Value, Velocity, Velocity, number, number) -> Value): Snapshot<Value, Velocity>
	const cache: { SnapshotData<Value, Velocity> } = table.create(MAX_LENGTH) :: any
	for i = 1, MAX_LENGTH do
		cache[i] = { t = 0, value = (nil :: any) :: Value, velocity = (nil :: any) :: Velocity }
	end

	return {
		cache = cache,
		head = 1,
		count = 0,
		lockedTime = 0,
		peakSpeed = 0,
		hint = 1,
		Lerp = lerpFunction,

		Push = Push,
		PushWithCheck = PushWithCheck,
		GetLatest = GetLatest,
		GetAt = GetAt,
		TrimAfter = TrimAfter,
		Clear = Clear,
	}
end

return New
