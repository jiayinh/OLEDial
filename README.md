<p align="center"><img src="Design/AppIcon-1024.png" width="160" alt="OLEDial icon"></p>

# OLEDial

*A dial for your LG OLED, right in the macOS menu bar.*

A macOS menu bar app for controlling an LG webOS TV (volume, mute, OLED brightness) over the local network, with a **Liquid Glass** UI and **BetterDisplay-style keyboard control**.

- **Liquid Glass UI** on macOS 26 Tahoe / 27 Golden Gate. It follows the system Liquid Glass appearance slider. On macOS 14–15 it falls back to vibrancy materials.
- **Keyboard media keys:** 🔊 🔉 🔇 and ☀︎ keys control the TV when the pointer is on the TV's screen. You can also set them to *always* or *off*. Hold ⌥⇧ for steps of 1.
- **On-screen HUD:** a glass indicator appears on the TV's screen when you change volume or brightness.
- **Custom global shortcuts:** each action can be re-bound in Settings › Keyboard. Defaults are ⌃⌥⇧ ↑/↓ for volume, ⌃⌥⇧ →/← for brightness and ⌃⌥⇧ M for mute.
- **Connection:** auto-discovers TVs, pairs once, and reconnects automatically, including after the Mac wakes from sleep.

## Download
[![Build](https://github.com/jiayinh/OLEDial/actions/workflows/build.yml/badge.svg)](https://github.com/jiayinh/OLEDial/actions/workflows/build.yml)

GitHub Actions builds every push to `main` (workflow: `.github/workflows/build.yml`). The app is a universal binary (Apple Silicon + Intel) and runs on macOS 14 or newer.
- **Releases:** push a tag such as `v1.0.0` and the workflow publishes `OLEDial.zip` on the [Releases](https://github.com/jiayinh/OLEDial/releases) page.
- **Any commit:** open [Actions](https://github.com/jiayinh/OLEDial/actions), select a run, and download the `OLEDial-<n>` artifact. (You must be signed in to GitHub to download artifacts. The artifact is a zip that contains `OLEDial.zip`, so unzip twice.)
- **Manual build:** Actions › **Build** › **Run workflow**.

## Installing (the app is not notarized)
OLEDial is **ad-hoc signed** but not signed with an Apple Developer ID or notarized, so Gatekeeper blocks it the first time. This is expected. Pick one of the options below.

1. Unzip `OLEDial.zip` and move **OLEDial.app** to `/Applications`.
2. Double-click it once. macOS shows *"OLEDial" Not Opened* (or *cannot be opened because Apple cannot check it for malicious software*). Click **Done** / **OK**.

**Option A – System Settings (no Terminal)**

3. Open Apple menu › **System Settings › Privacy & Security**.
4. Scroll to **Security**. Next to *"OLEDial" was blocked to protect your Mac*, click **Open Anyway**, then authenticate.
5. Open OLEDial again and click **Open Anyway** in the dialog. macOS remembers this choice.

> On **macOS 15 Sequoia and newer**, right-click › **Open** no longer bypasses Gatekeeper. Use Option A or B. On macOS 14 Sonoma, right-click › **Open** › **Open** still works.

**Option B – Terminal (remove the quarantine flag)**
```bash
xattr -dr com.apple.quarantine /Applications/OLEDial.app
open /Applications/OLEDial.app
```
Use this if macOS says the app **"is damaged and can't be opened"**, or if *Open Anyway* doesn't appear. Browsers add the quarantine flag to downloaded files, and removing it tells macOS that you trust this copy.

**Still won't launch?** Re-apply the ad-hoc signature, then repeat Option B:
```bash
codesign --force --deep --sign - /Applications/OLEDial.app
```

> **Why is it not notarized?** Notarization needs a paid Apple Developer account. If you prefer not to trust a downloaded binary, [build it yourself](#build-locally). An app you build locally has no quarantine flag, so it opens without any of the steps above.

## First run
1. Click the OLEDial icon (a dial around a small TV) in the menu bar. Click **Find TVs on network**, or enter the TV's IP address, then click **Pair**. Accept the prompt on the TV.
2. Allow **Local Network** access when macOS asks.
3. For keyboard keys, open Settings › Keyboard › **Grant Access…** and enable *OLEDial* under Privacy & Security › **Accessibility**.
4. If the TV isn't auto-detected as a display, choose it under Settings › General › **TV display**.

> **After installing a new build:** macOS ties the Accessibility permission to the exact binary of an ad-hoc signed app, so each update looks like a new app. In Privacy & Security › Accessibility, select OLEDial, click **−** to remove it, then add it again (or turn it on again via Settings › Keyboard › **Grant Access…**). If the media keys stop working after an update, this is the cause. You may also need to repeat the Gatekeeper steps above for a new download.

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
- **"OLEDial" Not Opened / "is damaged":** see [Installing](#installing-the-app-is-not-notarized).
- **Can't connect while the TV is off:** enable *TV On With Mobile* / *Wake on LAN* (Settings › General › Devices › External Devices; the path varies by model).
- **Brightness slider missing:** some picture modes and Energy Saving settings lock OLED brightness. *Unverified:* this varies by model and firmware.
- **Keys still change the Mac:** check that Accessibility is granted, that the right TV display is selected, and that the pointer is on the TV.
- **Volume does nothing:** if the TV's audio goes to a soundbar over optical, or over ARC without CEC volume control, the TV may not control its volume.

## Icon
The icon's glowing ring is both a volume/brightness dial and the "O" of OLEDial, wrapped around a TV with a pure-black (OLED) screen. Sources are in `Design/`. Run `python3 Design/make_icons.py` (needs `rsvg-convert` and Pillow) to regenerate `Resources/AppIcon.icns` and the menu bar glyphs.
