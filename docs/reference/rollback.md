# Server.Rollback
Validates client owned entities on the server and rolls them back to their last valid position when they move faster, higher or longer than the server allows.

## Configuration
```lua
Config.SetConfig("ROLLBACK_MODE", "LOG")
Config.SetConfig("ROLLBACK_SPEED_TOLERANCE", 1.5)
Config.SetConfig("ROLLBACK_BANK_TIME", 3)
Config.SetConfig("ROLLBACK_MIN_BANK", 12)
Config.SetConfig("ROLLBACK_AIR_MARGIN", 4)
```

- `ROLLBACK_MODE` - `"NONE"` disables it, `"LOG"` only fires `Violated`, `"ENFORCE"` also rolls the entity back.
- `ROLLBACK_SPEED_TOLERANCE` - Multiplier applied to the entity's `WalkSpeed`.
- `ROLLBACK_BANK_TIME` - Seconds of unused movement an entity can bank to absorb lag spikes.
- `ROLLBACK_MIN_BANK` - Studs always available regardless of speed.
- `ROLLBACK_AIR_MARGIN` - Studs of vertical slack above the jump arc.

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
`kind` is `"SPEED"`, `"RISE"`, `"FALL"`, `"FLY"`, `"CLIMB"`, `"INVALID"` or `"DESYNC"`.

```lua
chrono.Rollback.Violated:Connect(function(player, entity, kind, excess)
    print(player.Name, kind, excess)
end)
```
