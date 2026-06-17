# Ping Display Spoofer

A small Roblox Lua script that lets you make the in-game **NetworkPing** HUD
display any number you choose.

> ⚠️ **This is purely cosmetic.** It changes the text on your own screen only.
> Your actual network latency is not modified and other players cannot see
> the fake value. Use this for screenshots, streams, or just for fun — do
> not use it to mislead anyone in a competitive setting.

## Usage

1. Open `ping_spoof.lua`.
2. Edit the **CONFIG** block at the top:
   - `FAKE_PING` — the number shown in the HUD (e.g. `35`, `1`, `999`).
   - `SUFFIX` — text appended after the number (default `" ms"`).
   - `RANDOM_JITTER` — set to e.g. `2` to make the value wiggle by ±2 each
     update for a more realistic look. `0` keeps it locked.
   - `UPDATE_INTERVAL` — how often (seconds) the value is refreshed.
3. Run the script through any Roblox executor that can access `CoreGui`.

## Changing the value at runtime

The script reads `_G.FakePing` every tick, so you can change the value from
your executor's console without re-running:

```lua
_G.FakePing = 1     -- show "1 ms"
_G.FakePing = 420   -- show "420 ms"
```

## Disabling

```lua
_G.PingSpoofEnabled = false
```

## How it works

The performance overlay you see in the screenshot is a `TextLabel` named
`NetworkPing` inside `CoreGui`. The script:

1. Walks `CoreGui` to find every label named `NetworkPing`.
2. Overwrites the label's `Text` with your chosen value.
3. Hooks `GetPropertyChangedSignal("Text")` so the game's normal update
   loop can't put the real ping back.
4. Re-scans periodically in case the HUD is rebuilt.
