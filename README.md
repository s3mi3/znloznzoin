# znloznzoin

## Shot Detector

`scripts/shot_detector.lua` is a Vector Lua Engine script for whitelisted shot
detection. It supports:

- Normal shot triggers from `GunFiring`, ammo changes, or both.
- Optional player raycast confirmation before firing.
- Optional live hitbox scanning/raycast confirmation before firing.
- Hitbox scan drawing for Head, Torso, Arms, and Legs groups.

Load the script in Vector, whitelist players from the overlay, hold XBUTTON2 to
arm detection, and choose the trigger/method from the `Shot Detect` menu.
