# Ping Display Spoofer

Roblox Lua scripts that override the on-screen ping HUD with a
realistic-looking value (your real ping plus an offset, with smooth
jitter so it drifts naturally instead of sitting on one number).

> ⚠️ **Purely cosmetic.** Changes only what *you* see on your own screen.
> Your real network latency is unchanged and other players cannot see
> the fake value.

## Files

| File                | What it is                                              |
| ------------------- | ------------------------------------------------------- |
| `ping_spoof_ui.lua` | **Recommended.** Full script with a draggable in-game control panel. |
| `ping_spoof.lua`    | Same engine, no UI — configure via the CONFIG block or `_G.*` globals. |

## Quick start (UI version)

1. Execute `ping_spoof_ui.lua` in your executor.
2. A panel appears on the left of your screen with:
   - **STATUS** — live "Real ping" vs "Shown ping" readout.
   - **MODE** — toggle between `ADD` (real + extra) and `FIXED`.
   - **Extra ping** — ms added to your real ping in ADD mode.
   - **Fixed ping** — value used in FIXED mode.
   - **Jitter** — how much the value wiggles (±ms) for realism.
   - **SPOOF: ENABLED / DISABLED** — big toggle button.
3. Drag the title bar to move the panel.
4. Press **RightShift** to hide / show it. Close with the `×` button.

All changes apply instantly — no need to re-execute.

## Modes

| Mode    | Formula                                  |
| ------- | ---------------------------------------- |
| `add`   | `realPing + EXTRA_PING + jitter` *(default)* |
| `fixed` | `FAKE_PING + jitter`                     |

## Live control from the console (no UI required)

```lua
_G.PingSpoofMode   = "add"      -- or "fixed"
_G.PingSpoofExtra  = 80         -- ms added to real ping
_G.PingSpoofJitter = 6          -- +/- ms wiggle
_G.PingSpoofFixed  = 120        -- value used in FIXED mode
_G.PingSpoofEnabled = false     -- stop the spoof
```

## Troubleshooting — "it's not changing anything"

The script prints `[PingSpoof] ...` lines when it loads. If you don't
see the ping in the HUD change, the label wasn't auto-detected. From
your executor's console run:

```lua
_G.PingSpoofDump()    -- (no-UI script) lists every label whose text contains "ms"
```

Take the **Name** that matches the on-screen ping label and add it to
`NAME_KEYWORDS` at the top of the script.

## How it works

1. Reads your real ping from `Stats.Network.ServerStatsItem["Data Ping"]`.
2. Adds `EXTRA_PING` plus smooth sine-wave jitter (two out-of-phase
   waves + tiny random nudge — natural-looking variation).
3. Walks `PlayerGui` + `CoreGui` for `TextLabel`/`TextButton` objects
   whose **Name** contains `ping`/`latency`/`ms`, or whose **Text**
   matches the pattern `<number> ms`.
4. Rewrites `.Text` with the spoofed value.
5. Hooks `GetPropertyChangedSignal("Text")` so the game's update loop
   can't restore the real ping.
6. Watches `DescendantAdded` and re-scans periodically to catch HUDs
   that get rebuilt (e.g. on respawn).
