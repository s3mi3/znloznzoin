# Ping Display Spoofer

A small Roblox Lua script that overrides the on-screen ping HUD with a
realistic-looking value. By default it shows **your real ping plus an
offset**, with subtle smooth jitter so the number drifts naturally
instead of sitting on one constant value.

> ⚠️ **Purely cosmetic.** It changes the text on your own screen only.
> Your actual network latency is not modified and other players cannot
> see the fake value.

## Modes

| Mode      | Formula                                  | Use when                                        |
| --------- | ---------------------------------------- | ----------------------------------------------- |
| `"add"`   | `realPing + EXTRA_PING + jitter`         | You want it to *look real* — moves with your connection. **(default)** |
| `"fixed"` | `FAKE_PING + jitter`                     | You want a specific number that wiggles a bit.  |

## Quick start

1. Open `ping_spoof.lua`.
2. (Optional) edit the **CONFIG** block:
   - `MODE` — `"add"` or `"fixed"`.
   - `EXTRA_PING` — ms added to your real ping in `"add"` mode (e.g. `50`, `100`, `200`).
   - `FAKE_PING` — value used in `"fixed"` mode.
   - `JITTER` — how many ms the value wiggles by (set to `0` to lock it).
   - `DRIFT_SPEED` — how fast the wiggle moves (lower = slower drift).
   - `UPDATE_INTERVAL` — refresh rate. Lower = jumpier looking.
3. Run the script in your executor.

## Live control from the console

```lua
_G.PingSpoofMode   = "add"      -- or "fixed"
_G.PingSpoofExtra  = 80         -- show real ping + 80 ms
_G.PingSpoofJitter = 6          -- wiggle by +/- 6 ms
_G.PingSpoofFixed  = 120        -- value used in "fixed" mode
_G.PingSpoofEnabled = false     -- stop the spoof
```

## Troubleshooting — "it's not changing anything"

The script prints `[PingSpoof] Active ... Hooked N label(s).` when it
runs. If `N` is `0`, the label wasn't auto-detected. Run this:

```lua
_G.PingSpoofDump()
```

It will print every `TextLabel`/`TextButton` whose text contains
`"ms"`, with its full path and name. Either:
- Tell me the **Name** and I'll add it to `NAME_KEYWORDS`, or
- Add the name yourself to the `NAME_KEYWORDS` list at the top of the
  script.

## How it works

1. Reads your real ping from `Stats.Network.ServerStatsItem["Data Ping"]`.
2. Adds `EXTRA_PING` plus smooth sine-wave jitter (two out-of-phase
   waves plus a tiny random nudge — looks more natural than pure
   `math.random()`).
3. Walks `PlayerGui` + `CoreGui` looking for `TextLabel`/`TextButton`
   objects whose **Name** contains `ping`/`latency`/`ms`, or whose
   **Text** matches the pattern `<number> ms`.
4. Rewrites `.Text` with the spoofed value.
5. Hooks `GetPropertyChangedSignal("Text")` so the game's update loop
   can't restore the real ping.
6. Watches `DescendantAdded` and re-scans periodically to catch HUDs
   that get rebuilt (e.g. on respawn).
