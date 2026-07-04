# VolumeKey

**Your Mac's volume keys, for everything.**

macOS disables the keyboard volume keys when audio goes out over HDMI or DisplayPort, and they've never worked for network speakers. VolumeKey is a tiny menu-bar app that fixes that: press your normal volume/mute keys and control whatever you're actually listening through — the TV, a monitor, your Sonos system — with an on-screen volume HUD.

No drivers, no kernel extensions, no accounts, no telemetry. One small native app.

## What it controls

| Device | Protocol | Notes |
|---|---|---|
| **Sonos** | UPnP (native) | Zones, stereo pairs, home-theater satellites, grouping, per-speaker mixer |
| **LG TVs** (webOS) | Network API | Real TV volume; one-time pairing prompt on the TV |
| **Samsung, Sony, Philips, Panasonic TVs; network AVRs & soundbars** (Denon, Yamaha, Onkyo…) | DLNA/UPnP RenderingControl | Auto-detected; only devices that accept volume commands are listed |
| **Roku TVs** (TCL, Hisense, Sharp, onn.) | Roku ECP | Relative volume (Roku has no readback) |
| **Monitors with speakers** (Dell, BenQ, ASUS, LG…) | DDC/CI | Over the display cable itself; Apple Silicon |

Everything is discovered automatically on your local network. Pick a target from the menu-bar menu once — done.

## Features

- **Volume / mute keys** control the selected device, with a clean on-screen HUD
- **Headphones auto-switch** — when AirPods or any Bluetooth headphones connect, the keys control *them* (normal macOS behavior); disconnect, and the keys go back to your TV. Automatic, based on the Mac's default audio output
- **Mic mute: ⌥ + mute key** — mutes your microphone at the OS level (every app hears silence), works with any input device, stays muted even if your default mic changes
- **Sonos extras** — group/ungroup rooms from the menu, per-speaker sliders (including subs and surrounds), a mixer window (⌘M)
- **Adjustable step size** per key press

## Install

Download the latest notarized DMG from [Releases](../../releases), drag VolumeKey to Applications, and launch.

Two one-time permissions:

1. **Accessibility** (System Settings → Privacy & Security → Accessibility) — required to intercept the volume keys
2. **Local Network** — required to discover and control your devices

For LG TVs: select the TV in the menu, then accept the pairing prompt that appears on the TV screen. Once.

## Build from source

```bash
git clone https://github.com/faridsformula/VolumeKey.git
cd VolumeKey
./build.sh --no-refresh
```

Requires Xcode command-line tools. The build is a single `swiftc` invocation — no package manager, no dependencies.

## Troubleshooting

- The app logs to `/tmp/volumekey.log` — check there first.
- **Devices stop being discovered after you rebuild from source:** macOS silently invalidates the Local Network permission whenever an app's binary changes. Toggle VolumeKey off and on in System Settings → Privacy & Security → Local Network (or run `./refresh-permission.sh`).
- **Samsung TVs:** need "network standby" / IP control enabled (usually on by default on recent models).
- **Roku:** requires "Control by mobile apps" (Settings → System → Advanced system settings), on by default.
- **DDC monitors:** Apple Silicon Macs only; the display must be connected directly (some hubs/KVMs block DDC).

## Platform

macOS 12+ (Apple Silicon and Intel; DDC monitor control is Apple Silicon only). A Windows companion is under consideration — the device protocols are portable.

## License

MIT — see [LICENSE](LICENSE).
