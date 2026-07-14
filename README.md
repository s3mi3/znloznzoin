# znloznzoin

## Shot Detector

`scripts/shot_detector.lua` is a Vector Lua Engine script for whitelisted shot
detection. It supports:

- Normal shot triggers from `GunFiring`, ammo changes, or both.
- Event-based `Changed` connections for fast response, with polling as backup.
- Continuous autoclicking after a whitelisted shot while XBUTTON2 is held.
- Immediate stop when XBUTTON2 is released or the script is disabled.
- Configurable first-click delay, defaulting to `0ms` for instant response.

Load the script in Vector, whitelist players from the overlay, hold XBUTTON2 to
arm detection, and use the overlay's `Trigger:` button to choose
`GunFiring + Ammo`, `GunFiring only`, or `Ammo only`.

Use the overlay's `First delay:` slider near the top of the panel to delay the
first click after a shot is detected. Leave it at `0ms` for instant clicking.

Press F8 to hide or show the overlay. Shot detection and clicking keep running
while the overlay is hidden.

The `Last:` status line shows which source started the click loop. For example,
`Last: GunFiring CLICKING` means GunFiring triggered the autoclicker.
