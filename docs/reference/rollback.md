# Server.Rollback
Validates client owned entities on the server and rolls them back to their last valid position when they move faster, higher or longer than the server allows, or pass through solid geometry.

## Configuration
```lua
Config.SetConfig("ROLLBACK_MODE", "LOG")
Config.SetConfig("ROLLBACK_SPEED_TOLERANCE", 1.5)
Config.SetConfig("ROLLBACK_BANK_TIME", 3)
Config.SetConfig("ROLLBACK_MIN_BANK", 12)
Config.SetConfig("ROLLBACK_AIR_MARGIN", 4)
Config.SetConfig("ROLLBACK_NOCLIP", true)
Config.SetConfig("ROLLBACK_NOCLIP_MARGIN", 0.3)
```

- `ROLLBACK_MODE` - `"NONE"` disables it, `"LOG"` only fires `Violated`, `"ENFORCE"` also rolls the entity back.
- `ROLLBACK_SPEED_TOLERANCE` - Multiplier applied to the entity's `WalkSpeed`.
- `ROLLBACK_BANK_TIME` - Seconds of unused movement an entity can bank to absorb lag spikes.
- `ROLLBACK_MIN_BANK` - Studs always available regardless of speed.
- `ROLLBACK_AIR_MARGIN` - Studs of vertical slack above the jump arc.
- `ROLLBACK_NOCLIP` - Enables the noclip check.
- `ROLLBACK_NOCLIP_MARGIN` - Studs the entity's collision box is shrunk on every side before it is swept. Higher values tolerate more legitimate overlap, lower values catch shallower clips.

## Noclip
Every validated move sweeps the primary part's box from the last accepted position to the new one. Anything solid in between is a `"NOCLIP"` violation. The sweep respects `CanCollide` and the entity's collision group, and ignores water.

The sweep never counts:
- Parts inside a model that has a `Humanoid`.
- Parts that are not anchored, including everything welded to them.
- Parts, or any ancestor of parts, tagged `ChronoNoclipIgnore`. Tag doors, lifts and other moving geometry, since the sweep tests against where it is now rather than where it was.

```lua
CollectionService:AddTag(workspace.SlidingDoor, "ChronoNoclipIgnore")
```

## Functions

### `Exempt(entity: Entity, seconds: number) -> ()`
Suspends validation for the entity and rebases it on its current position afterwards.

### `Grant(entity: Entity, studs: number) -> ()`
Adds one-off movement allowance for knockbacks, dashes and launch pads.

### `SetMaxSpeed(entity: Entity, speed: number?) -> ()`
Overrides the horizontal speed limit. Required for entities without a `Humanoid`.

### `Reset(entity: Entity) -> ()`
Clears the stored state for the entity.

## Events

### `Violated(player: Player, entity: Entity, kind: string, excess: number)`
`kind` is `"SPEED"`, `"RISE"`, `"FALL"`, `"FLY"`, `"CLIMB"`, `"NOCLIP"`, `"INVALID"` or `"DESYNC"`. For `"NOCLIP"`, `excess` is how many studs of the move were past the first solid.

```lua
chrono.Rollback.Violated:Connect(function(player, entity, kind, excess)
    print(player.Name, kind, excess)
end)
```
