# FakeDeafen (BetterDiscord)

A [BetterDiscord](https://betterdiscord.app/) port of the Vencord **FakeDeafen** plugin.

While enabled, other people in a voice channel see you as **deafened** (and/or **muted**),
but you can still hear and talk normally.

> This works by intercepting the gateway voice-state update (opcode `4`) and rewriting the
> `self_deaf` / `self_mute` flags before they leave your client.

## Features

- **Fake Deafen** – appear deafened to others while you keep hearing.
- **Fake Mute** – appear muted to others while you keep talking.
- **Account-panel button** – a toggle button next to the mic/deafen buttons (bottom-left).
- **Keybind** – toggle with `Ctrl+Shift+Q`.
- **Persistent settings** stored via BetterDiscord's data API.

## Installation

1. Make sure [BetterDiscord](https://betterdiscord.app/) is installed.
2. Download `FakeDeafen.plugin.js`.
3. Move it into your BetterDiscord plugins folder:
   - **Windows:** `%appdata%\BetterDiscord\plugins`
   - **macOS:** `~/Library/Application Support/BetterDiscord/plugins`
   - **Linux:** `~/.config/BetterDiscord/plugins`
   - (or open Discord → **Settings → Plugins → Open Plugins Folder**)
4. Enable **FakeDeafen** in **Settings → Plugins**.

## Usage

- Click the FakeDeafen button in the account panel (bottom-left), **or** press `Ctrl+Shift+Q`.
- When enabled, the button icon turns red and others see you as deafened/muted.
- Configure behavior in **Settings → Plugins → FakeDeafen → settings gear**:
  - **Fake Deafen** / **Fake Mute** – choose what to fake.
  - **Show Panel Button** – show/hide the toolbar button.
  - **Enable Keybind** – enable/disable the `Ctrl+Shift+Q` shortcut.

## Notes

- The gateway interception (the actual fake deafen/mute) is robust and is the core of the
  plugin. The account-panel button placement depends on Discord's internal component layout;
  if Discord changes its internals and the button can't be placed, the plugin still works
  fully via the keybind and settings, and a warning is logged to the console.
- Using client modifications is against Discord's Terms of Service. Use at your own risk.

## Credits

- Original Vencord plugin by **hyyven**.
- Ported to BetterDiscord using only the modern `BdApi` (no external library required).
