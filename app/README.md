# Xone:3D Control — native arm64 macOS app

A ground-up rebuild of the 2006 Ploytec `Xone3D.app` as a **native Apple-Silicon
(arm64) Cocoa app**. The original was PowerPC + 32-bit Intel only and cannot
launch on an M1; this one is pure arm64 and talks to the device using the USB
protocol recovered from the original binary (see `../docs/REVERSE_ENGINEERING_REPORT.md`).

## What it does
- Connects to the Xone:3D (USB VID `0x0A4A` / PID `0xFF00`).
- Shows the firmware/version string.
- Full **Soundcard Operating Modes** panel matching the User Guide (p.12):
  - **Mode 1** (1 Stereo In / 3 Stereo Out) and **Mode 2** (2 Stereo In / 2 Out),
    with the menus relaying out automatically when you switch mode.
  - Soundcard input source(s) — 5 choices incl. SPDIF in; plus the In 1-2 source
    in Mode 2.
  - 3D Digital Out source (4 choices in Mode 1, 2 in Mode 2).
  - A live "Returns" line showing the fixed SC→channel routing for the mode.
  - MIDI channel (1–16) and MIDI mapping (Map 1 / Map 2).
- A **raw routing-word** field (`Send raw`) for exact control / verification.
- Firmware *flashing* is intentionally omitted (it can brick the unit and the
  record framing wasn't verifiable without hardware). Read-only firmware dump
  lives in the companion `xone3d.py` tool.

The menu contents and mode behaviour come straight from the User Guide; the
16-bit routing-word packing behind them is the exact reconstruction recovered
from the original binary (`encodeAndSendRouting`/`readAndDecodeRouting`), which
the guide's option counts corroborate.

## Build it (one command)
Prerequisites on your M1:
```bash
xcode-select --install     # Swift compiler + toolchain
brew install libusb        # native USB backend
```
Then:
```bash
cd Xone3D-Swift
./build.sh
open ./Xone3D.app          # or double-click in Finder
```
`build.sh` runs `swift build -c release --arch arm64`, assembles `Xone3D.app`
(binary + `Info.plist` + `PkgInfo`), and ad-hoc code-signs it so it runs locally.

If Gatekeeper complains the first time: right-click the app → **Open**, or
`xattr -dr com.apple.quarantine ./Xone3D.app`.

## Open it in Xcode instead (optional)
```bash
cd Xone3D-Swift
open Package.swift          # Xcode opens the SwiftPM package
```
Select the `Xone3D` scheme and Run. (Building a signed, notarized, distributable
`.app` for *other* Macs needs your Apple Developer ID; for your own machine the
ad-hoc signing from `build.sh` is enough.)

## Running on an M1 — the one gotcha
On modern macOS the Xone:3D may be grabbed by the system **USB-audio driver**.
When that happens, a user-space libusb open returns *"Access denied"* and the app
says so. Options:
- Try it with the device in its boot/config state (before the audio driver binds).
- Temporarily remove the audio binding for that device.
- If you need it to coexist with audio, the same six control transfers can be
  re-pointed at Apple's `IOUSBHost` API (no libusb) — ask and I'll swap the
  `USBBridge` backend. The protocol is identical; only the plumbing changes.

## Project layout
```
Package.swift                 SwiftPM manifest (links libusb via pkg-config)
Info.plist                    bundle metadata for the assembled .app
build.sh                      build + bundle + ad-hoc sign
Sources/CLibUSB/              system-library shim for <libusb.h>
Sources/Xone3D/
  main.swift                  NSApplication bootstrap (no NIB/storyboard)
  AppDelegate.swift           the window + controls + actions
  USBBridge.swift             the recovered control-transfer protocol
  Routing.swift               16-bit routing word decode/encode
```
