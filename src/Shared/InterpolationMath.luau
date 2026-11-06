--!native

const Types = require(script.Parent.Types)
const Config = require(script.Parent.Config)

const function Hermite(p0: Vector3, p1: Vector3, v0: Vector3, v1: Vector3, t: number, dt: number): Vector3
	v0 = v0 or Vector3.zero
	v1 = v1 or Vector3.zero
	const d = p1 - p0
	if not dt or dt == 0 then
		return p0 + d * t
	end

	-- Cap tangent at 3x the segment length to reduce overshoot.
	-- https://en.wikipedia.org/wiki/Monotone_cubic_interpolation

	const maxSq = vector.dot(d :: any, d :: any) * 9
	const dtSq = dt * dt
	const s0 = vector.dot(v0 :: any, v0 :: any) * dtSq
	if s0 > maxSq then
		v0 *= math.sqrt(maxSq / s0)
	end
	const s1 = vector.dot(v1 :: any, v1 :: any) * dtSq
	if s1 > maxSq then
		v1 *= math.sqrt(maxSq / s1)
	end

	const t2 = t * t
	const t3 = t2 * t
	const h10 = (t3 - 2 * t2 + t) * dt
	const h01 = 3 * t2 - 2 * t3
	const h11 = (t3 - t2) * dt

	return p0 + d * h01 + v0 * h10 + v1 * h11
end

const function HermiteCFrame(c0: CFrame, c1: CFrame, v0: Vector3, v1: Vector3, t: number, dt: number): CFrame
	return CFrame.new(Hermite(c0.Position, c1.Position, v0, v1, t, dt)) * c0:Lerp(c1, t).Rotation
end

const function CalculateVelocity(lP: Vector3, lT: number, cP: Vector3, cT: number, tickrate: number?): Vector3
	local rate = tickrate or 1 / 20
	local dt = cT - lT
	if dt <= 1e-6 then
		return Vector3.zero
	elseif dt > rate * 3 and Config.FLAGS.SNAPSHOT_INTERPOLATION_FIX then
		dt = rate
	end
	if Config.FLAGS.VELOCITY_CALC_FIX then
		dt = math.max(dt, rate) -- ensures that velocity is not calculated with a dt that is too small
	end
	return (cP - lP) / dt
end

const function CheckIdle(
	latest: Types.SnapshotData<CFrame, Vector3>,
	t: number,
	position: Vector3,
	tickrate: number,
	peakSpeed: number?
): boolean
	const gap = t - latest.t
	if gap <= tickrate * 3 or not Config.FLAGS.SNAPSHOT_INTERPOLATION_FIX then
		return false
	end
	const velocity = latest.velocity
	const latestSpeed = if velocity then vector.magnitude(velocity :: any) else 0
	const moved = position - latest.value.Position
	const speed = math.max(latestSpeed, peakSpeed or 0)

	const predictedTravel = latestSpeed * gap
	if
		predictedTravel > speed * tickrate * 1.5
		and vector.magnitude((moved - velocity * gap) :: any) < predictedTravel * 0.15
	then
		return false
	end
	if speed < 1e-3 then
		return true
	end

	return vector.magnitude(moved :: any) < speed * (gap + tickrate) * 0.5
end

const function VelocityAt(
	latest: Types.SnapshotData<CFrame, Vector3>?,
	t: number,
	cframe: CFrame,
	tickrate: number?,
	peakSpeed: number?
): Vector3
	if not latest then
		return Vector3.zero
	end
	const rate = tickrate or 1 / 20
	const position = cframe.Position
	if t - latest.t > rate * 3 and not CheckIdle(latest, t, position, rate, peakSpeed) then
		return (position - latest.value.Position) / (t - latest.t)
	end
	return CalculateVelocity(latest.value.Position, latest.t, position, t, rate)
end

return {
	Hermite = Hermite,
	HermiteCFrame = HermiteCFrame,
	VelocityAt = VelocityAt,
	CheckIdle = CheckIdle,
	CalculateVelocity = CalculateVelocity,
}
