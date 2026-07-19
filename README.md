# Ping Display Spoofer

Scripts that override the on-screen ping HUD with a realistic-looking
value. Comes in two flavors:

- **Roblox executor** (Synapse / Wave / Fluxus / any executor with
  CoreGui access) — `ping_spoof.lua` and `ping_spoof_ui.lua`.
- **Vector Lua Engine** (external overlay/cheat engine) —
  `ping_spoof_vector.lua`.

> ⚠️ **Purely cosmetic.** Changes only what *you* see on your screen.
> Real network latency is unchanged and other players cannot see the
> fake value.

## Files

| File                     | Use with                    | Description |
| ------------------------ | --------------------------- | ----------- |
| `ping_spoof_ui.lua`      | Roblox executor             | Draggable in-game control panel (recommended for executors). |
| `ping_spoof.lua`         | Roblox executor             | Same engine, no UI — configure via CONFIG block. |
| `ping_spoof_vector.lua`  | Vector Lua Engine           | Overlay-menu UI + GC-API patching. See below. |

---

## Vector Lua Engine version

The Vector engine is an external overlay — it has no `Instance.new`, no
`RunService`, no `Stats` service, and `GuiObject.Text` is read-only via
its Game API. So instead of overwriting the label directly, this script
uses the **GC API** to patch the plain-Lua variable that populates the
label each frame.

### Load

Drop `ping_spoof_vector.lua` into the engine's scripts folder (or run
it via `utility.load_url`). A new **"Ping Spoof"** tab appears in the
menu.

### Menu

| Section  | Element                | What it does |
| -------- | ---------------------- | ------------ |
| Spoof    | Enable Spoof           | Starts/stops the background patch worker. |
| Spoof    | Mode                   | `Add to real` or `Fixed value`. |
| Spoof    | Patch interval         | How often (ms) to re-apply the patch. Default 100 ms. |
| Values   | Extra ping             | ms added to your real ping in ADD mode. |
| Values   | Fixed ping             | Value written in FIXED mode. |
| Values   | Jitter                 | ± ms wiggle, resampled per patch. |
| Keys     | Ping key names         | Comma-separated Lua variable names to patch. Defaults cover common conventions (`Ping`, `NetworkPing`, `Latency`, ...). |
| Keys     | Dump GC to file        | Writes every string-keyed Lua entry in the process to `C:/vector_gc_dump.txt` — use this if the default key names don't match your game. |
| Keys     | Warm key cache         | Prewarm the internal GC cache for the currently configured keys. |
| Status   | Show on-screen readout | Small overlay in the bottom-left showing real / shown ping and patch count. |

### If nothing changes when you enable

The default key names cover common HUD conventions but every game names
its variables differently. To find your game's ping key:

1. Click **"Dump GC to file"**.
2. Open `C:/vector_gc_dump.txt` and search for `ping`, `ms`, `latency`,
   or a number matching what the HUD currently shows.
3. Paste the exact key name(s) into **"Ping key names"** (comma-
   separated, case-sensitive).
4. Click **"Warm key cache"**, then re-toggle "Enable Spoof".

### How it works (Vector version)

1. `refreshgc()` runs at script load.
2. When enabled, a background thread (`thread.create`) calls `applygc`
   every N ms with the configured key names, writing the computed
   spoofed value into every matching node across every Lua VM.
3. `on_frame` samples the visible ping label's `.Text` (read-only in
   this API) as best-effort "real ping" for the status readout and
   for ADD-mode base value.
4. Because `Text` can only be read (not written) through the Game API,
   the actual change comes from the GC patch — most custom Roblox HUDs
   cache their ping in a Lua variable each frame *before* writing it
   into the label, so patching that variable changes the display.
5. Games overwrite the value on their own ticks, so we keep re-applying
   at 50–200 ms intervals. This is exactly the pattern the Vector docs
   recommend for weapon-stat / config patching.

### Caveats specific to Vector

- If the game reads ping directly from `Stats` and writes to the label
  *without* passing through a plain Lua number (e.g. the built-in Roblox
  Performance Stats overlay), the GC API can't touch it. Use one of the
  Roblox-executor scripts instead in that case.
- `applygc` patches every matching key across every VM at once. If your
  game happens to also use `"Ping"` elsewhere (unlikely but possible),
  it'll also be overwritten. Pick more specific key names when possible.

---

## Roblox executor versions

### Quick start (UI)

1. Execute `ping_spoof_ui.lua`.
2. A draggable dark panel appears with:
   - **STATUS** — live Real / Shown readout.
   - **MODE** — `ADD` (real + extra) or `FIXED`.
   - **Extra ping** / **Fixed ping** / **Jitter** — text inputs.
   - Big **SPOOF: ENABLED/DISABLED** toggle.
3. Press **RightShift** to hide/show, drag the title bar to move.

### Live control from the console

```lua
_G.PingSpoofMode    = "add"      -- or "fixed"
_G.PingSpoofExtra   = 80
_G.PingSpoofJitter  = 6
_G.PingSpoofFixed   = 120
_G.PingSpoofEnabled = false
```

### Modes

| Mode    | Formula                                  |
| ------- | ---------------------------------------- |
| `add`   | `realPing + EXTRA_PING + jitter` *(default)* |
| `fixed` | `FAKE_PING + jitter`                     |

The displayed value only recomputes when real ping (or config) actually
changes, so the HUD updates at the same cadence as your real
connection (≈1 Hz) — no fake-looking frame-by-frame wiggling.

### Troubleshooting (executor)

If the ping in the HUD doesn't change, run this in your executor
console:

```lua
_G.PingSpoofDump()
```

Copy the **Name** of the label matching your ping and add it to
`NAME_KEYWORDS` at the top of the script.

---

## How the spoofing engine works (shared design)

1. Reads real ping from `Stats.Network.ServerStatsItem["Data Ping"]`
   (executor version) or samples the visible label text (Vector version).
2. Adds `EXTRA_PING` plus a jitter offset resampled once per real-ping
   change — so the value never wiggles faster than your connection would.
3. Executor version overwrites `.Text` on every matched label and hooks
   `GetPropertyChangedSignal("Text")` so the game can't restore the real
   value. Vector version patches the underlying Lua variable via
   `applygc` on a background `thread.create` loop.
4. Both versions rescan periodically to catch HUDs rebuilt on respawn.
