# OLEDial

*A dial for your LG OLED, right in the macOS menu bar.*

A macOS menu bar app for controlling an LG webOS TV (volume, mute, OLED brightness) over the local network, with a **Liquid Glass** UI and **BetterDisplay-style keyboard control**.

- **Liquid Glass UI** on macOS 26 Tahoe / 27 Golden Gate. It follows the system Liquid Glass appearance slider. On macOS 14–15 it falls back to vibrancy materials.
- **Keyboard media keys:** 🔊 🔉 🔇 and ☀︎ keys control the TV when the pointer is on the TV's screen. You can also set them to *always* or *off*. Hold ⌥⇧ for steps of 1.
- **On-screen HUD:** a glass indicator appears on the TV's screen when you change volume or brightness.
- **Custom global shortcuts:** each action can be re-bound in Settings › Keyboard. Defaults are ⌃⌥⇧ ↑/↓ for volume, ⌃⌥⇧ →/← for brightness and ⌃⌥⇧ M for mute.
- **Connection:** auto-discovers TVs, pairs once, and reconnects automatically, including after the Mac wakes from sleep.

## Download
GitHub Actions builds every push.
- **Releases:** push a tag such as `v1.0.0` and the workflow publishes `OLEDial.zip` on the Releases page.
- **Any commit:** open **Actions**, select the run, and download the `OLEDial-<n>` artifact.

Unzip, move **OLEDial.app** to `/Applications`, then right-click › **Open** the first time. The app is ad-hoc signed, not notarized.

## First run
1. Click the TV icon in the menu bar. Click **Find TVs on network**, or enter the TV's IP address, then click **Pair**. Accept the prompt on the TV.
2. Allow **Local Network** access when macOS asks.
3. For keyboard keys, open Settings › Keyboard › **Grant Access…** and enable *OLEDial* under Privacy & Security › **Accessibility**.
4. If the TV isn't auto-detected as a display, choose it under Settings › General › **TV display**.

> **After installing a new build:** macOS ties the Accessibility permission to the exact binary of an ad-hoc signed app. Remove OLEDial from the Accessibility list, then add it again.

## Build locally
Requires Xcode 26 or newer.
```bash
./build.sh   # → build/OLEDial.app
```

## How it works
- The app talks to the TV over the LG webOS SSAP WebSocket. It uses `wss://<tv>:3001` and falls back to `ws://<tv>:3000`. The TV's self-signed certificate is trusted for that host only.
- **Volume** uses `ssap://audio/setVolume` and `setMute`.
- **Brightness** uses the picture setting `backlight` (OLED Pixel Brightness / OLED Light). The app tries `ssap://settings/setSystemSettings` first. If that fails, it uses the `luna://com.webos.settingsservice/setSystemSettings` alert workaround from bscpylgtv.
- **Media keys** are captured with a `CGEventTap` on `NX_SYSDEFINED` events, the same approach as MonitorControl. A key is swallowed only when the app is going to send it to the TV.
- **Custom shortcuts** use Carbon `RegisterEventHotKey`.

Protocol details were cross-checked against the open-source aiowebostv (Home Assistant) and bscpylgtv libraries.

## Troubleshooting
- **Can't connect while the TV is off:** enable *TV On With Mobile* / *Wake on LAN* (Settings › General › Devices › External Devices; the path varies by model).
- **Brightness slider missing:** some picture modes and Energy Saving settings lock OLED brightness. *Unverified:* this varies by model and firmware.
- **Keys still change the Mac:** check that Accessibility is granted, that the right TV display is selected, and that the pointer is on the TV.
- **Volume does nothing:** if the TV's audio goes to a soundbar over optical, or over ARC without CEC volume control, the TV may not control its volume.

## Publishing to GitHub
This folder is already a git repository with the first commit, so you only need to create the GitHub repo and push.
```bash
gh repo create OLEDial --public --source=. --push   # Actions builds automatically
git tag v1.0.0 && git push --tags                    # publishes a Release with OLEDial.zip
```
Optionally set `LGTVRepositoryURL` in `Info.plist` to your repo URL (shown in Settings › About).
