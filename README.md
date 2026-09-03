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

### Native HDMI-CEC probe

Newer Apple-silicon Macs contain a native HDMI-CEC stack, but Apple does not
publish its CEC API. To inspect a Mac without controlling any connected device,
run:

```bash
./Tools/hdmi-cec-probe.sh
```

The standalone probe reports live IOKit CEC services, existing Apple CEC
clients, HDMI port controllers, and the availability of the private CEC API.
It deliberately does **not** transmit CEC frames, open a receive queue, or claim
a CEC logical address. The private API check only loads the system framework and
looks up symbol names.

To explicitly attempt one volume-up action to an HDMI audio receiver (CEC
logical address 5), run:

```bash
./Tools/hdmi-cec-probe.sh --volume-up
```

This sends one `User Control Pressed: Volume Up` frame followed by its required
`User Control Released` frame. Because Apple's `corercd` daemon normally owns
the CEC interface exclusively, the script asks for administrator access to
terminate it once. Launchd automatically restarts the daemon while the sender
briefly retries for the interface. The daemon is never unloaded or disabled.
This uses Apple's private CEC stack and may stop working after a macOS update.

## Troubleshooting

- The app logs to `/tmp/volumekey.log` — check there first.
- **Permissions stop working after you rebuild from source:** an ad-hoc rebuild can invalidate the app's prior privacy identity. Enable VolumeKey manually in the relevant Privacy & Security pane, then relaunch it. VolumeKey checks Accessibility once at launch and never opens, drives, or repeatedly contacts System Settings.
- **Samsung TVs:** need "network standby" / IP control enabled (usually on by default on recent models).
- **Roku:** requires "Control by mobile apps" (Settings → System → Advanced system settings), on by default.
- **DDC monitors:** Apple Silicon Macs only; the display must be connected directly (some hubs/KVMs block DDC).

## Platform

macOS 12+ (Apple Silicon and Intel; DDC monitor control is Apple Silicon only). A Windows companion is under consideration — the device protocols are portable.

## License

MIT — see [LICENSE](LICENSE).
