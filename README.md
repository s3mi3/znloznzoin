# Shot Detector — Vector Lua Engine

A Lua script for the [Vector Lua Engine](https://project-vector-1.gitbook.io/vector-lua-engine)
that detects when a whitelisted enemy fires their weapon (by watching the
`GunFiring` body effect and the `Ammo` value) and responds with a configurable
click burst.

## Features

- **Whitelist UI** — an in-game panel to pick which players the detector reacts to.
- **Event-driven detection** — hooks the `Changed` event of `GunFiring`/`Ammo`
  refs so the burst fires on the same game step the value changes, with a
  polling fallback.
- **Raycast shot detection** — optionally gate the burst on a clear line of
  sight to the target, using the engine's [Raycast API](https://project-vector-1.gitbook.io/vector-lua-engine/api/raycast-api.md):
  - *Player (cached)* — `raycast.is_player_visible(char.address)`, essentially
    free, reads the worker thread's visibility buffer.
  - *Hitbox scan (live)* — `raycast.is_visible(camera, bone_position)` per
    hitbox bone, true line-of-sight against the world obstacle cache.
  - Fails open (treats the target as visible) while the obstacle cache is still
    building, matching the engine's raycast semantics.
- **Hitbox scanning** — walks each enabled hitbox bone of a target, reads its
  world position, tests visibility, projects it to screen with
  `utility.world_to_screen`, and highlights the best exposed hitpoint
  (closest visible bone to the crosshair). Works for both R6 and R15 rigs.

## Usage

Load `shot_detector.lua` in the engine. Open the **Shot Detect** tab:

- **Settings → Enable** — master toggle.
- **Raycast / Hitbox**
  - *Only fire with line of sight* — enable the raycast gate.
  - *LOS check* — choose the cached player check or the live hitbox scan.
  - *Draw hitbox scan* — overlay per-bone visibility dots (green = visible,
    red = occluded) and a yellow ring on the best hitpoint.
  - *Scan hitboxes* — which hitbox groups (Head / Torso / Arms / Legs) to scan.
  - *Scan range* — only scan/draw targets within this many studs.

Hold **XBUTTON2** (mouse 4) to arm the detector. Left-click a player row in the
panel to select, then click the button to whitelist/remove them. The dot next
to a whitelisted player is bright green when they currently have line of sight,
orange when occluded.

### Tuning

Edit the constants at the top of `shot_detector.lua`:

| Constant         | Meaning                                   |
| ---------------- | ----------------------------------------- |
| `XBUTTON2`       | Arm key (VK code)                         |
| `GUN_NAME`       | Tool name searched in Backpack/Character  |
| `AMMO_NAME`      | Ammo value name inside the tool           |
| `BURST`          | Number of clicks per detected shot        |
| `BURST_INTERVAL` | Milliseconds between clicks               |
| `HITGROUPS`      | Bone names scanned for each hitbox group  |
