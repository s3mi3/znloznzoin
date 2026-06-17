# Ping Display Spoofer

A small Roblox Lua script that lets you make the in-game ping HUD display
any number you choose.

> ⚠️ **Purely cosmetic.** It changes the text on your own screen only.
> Your actual network latency is not modified and other players cannot
> see the fake value.

## Usage

1. Open `ping_spoof.lua`.
2. Edit `FAKE_PING` at the top.
3. Run the script in your executor.

The script automatically scans both `CoreGui` **and** `PlayerGui`, so it
works for the built-in Performance Stats overlay as well as custom in-game
HUDs (like the one in the screenshot showing `NetworkPing` / `35 ms`).

## Live control from the console

```lua
_G.FakePing = 12              -- change displayed value on the fly
_G.PingSpoofEnabled = false   -- stop the spoof
_G.PingSpoofDebug = true      -- verbose logging (on by default)
```

## Troubleshooting — "it's not changing anything"

The script prints `[PingSpoof] Active — ... Hooked N label(s).` when it
runs. If `N` is `0`, it didn't recognise the label. Run this in your
executor's console:

```lua
_G.PingSpoofDump()
```

It will print every `TextLabel`/`TextButton` whose text contains `"ms"`,
along with its full path and name. Copy the **Name** of the one that
shows your ping and add it to `NAME_KEYWORDS` at the top of the script,
then re-run.

Other things to check:
- Make sure your executor has CoreGui access (most modern ones do).
- Some games rebuild the HUD on respawn — the script auto-rescans every
  second, so just wait a moment.
- If the value flickers back briefly, lower `UPDATE_INTERVAL` (e.g. `0.05`).

## How it works

1. Walks `PlayerGui` + `CoreGui` looking for `TextLabel`/`TextButton`
   objects whose **Name** contains `ping`/`latency`/`ms`, or whose
   **Text** matches the pattern `<number> ms`.
2. Rewrites `.Text` with your chosen value.
3. Hooks `GetPropertyChangedSignal("Text")` so the game's update loop
   can't restore the real ping.
4. Watches `DescendantAdded` and re-scans periodically to catch HUDs
   that get rebuilt (e.g. on respawn).
