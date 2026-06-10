# znloznzoin

## Shot Detector

`scripts/shot_detector.lua` is a Vector Lua Engine script for whitelisted shot
detection. It supports:

- Normal shot triggers from `GunFiring`, ammo changes, or both.
- Event-based `Changed` connections for fast response, with polling as backup.
- Continuous autoclicking after a whitelisted shot while XBUTTON2 is held.
- Immediate stop when XBUTTON2 is released or the script is disabled.

Load the script in Vector, whitelist players from the overlay, hold XBUTTON2 to
arm detection, and use the overlay's `Trigger:` button to choose
`GunFiring + Ammo`, `GunFiring only`, or `Ammo only`.

The `Last:` status line shows which source started the click loop. For example,
`Last: GunFiring CLICKING` means GunFiring triggered the autoclicker.
