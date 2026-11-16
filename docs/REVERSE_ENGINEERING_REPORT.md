# Xone3D.app — Reverse Engineering Report & M1 Port

## 1. What this app is

`Xone3D.app` is the 2006 control-panel / firmware-updater utility for the
**Allen & Heath Xone:3D** DJ mixer + USB soundcard, written by Ploytec GmbH
(the OEM that makes the device's USB audio engine). It is a thin Cocoa app:

- A UI controller class **`XoneControl`** — the window with the Sound Card Mode,
  Sound Input 1/2/3, Digital Output, MIDI Channel and MIDI Mapping menus, an
  "Update" (firmware) button, a progress bar and a version field.
- A hardware class **`USBBridge`** — talks to the device over USB via IOKit.

Recovered source paths (left in the binary's debug symbols):
```
/Users/eric/Developpements/Ploytec/Xone3D/Xone3D_Panel_1.00/XoneControl.m
/Users/eric/Developpements/Ploytec/Xone3D_Threaded/USBBridge.m
```

Linked frameworks: `Cocoa`, `IOKit` (USB), `libSystem`, `libgcc`.

## 2. Why it will not run on an M1 (the core problem)

The executable is a Mach-O **universal binary with exactly two slices**:

| Slice | CPU type | Can an M1 run it? |
|-------|----------|-------------------|
| `ppc`  | PowerPC (cputype 18) | No — PPC support ended in macOS 10.7 (2011) |
| `i386` | 32-bit Intel          | No — 32-bit support removed in macOS 10.15 (2019) |

There is **no `arm64` slice and no `x86_64` slice**. This matters because:

- **Rosetta 2** (the Apple-Silicon translator) only handles **x86_64**. It does
  **not** translate i386 or PowerPC.
- 32-bit Intel binaries won't load on any macOS since Catalina, on any Mac.

So the file cannot be "patched" into running — there is no 64-bit machine code
to run. Making it work on an M1 fundamentally means **producing new 64-bit code**.
The good news: the app's real logic is tiny (a handful of USB control transfers),
and it has been fully recovered below.

## 3. Recovered hardware protocol

### 3.1 Device identity
From `-[USBBridge installUSBAddNotification]`:
```
idVendor  = 0x0A4A   (Ploytec GmbH)
idProduct = 0xFF00   (Xone:3D)
```
Matched with `IOServiceMatching("IOUSBDevice")` + an `IOServiceAddMatchingNotification`
first-match notification; the device interface used is `IOUSBDeviceInterface187`.

### 3.2 Control-transfer table
Every operation is a single USB **control transfer on endpoint 0**, wrapped by
`-[USBBridge USBDeviceRequestWithbRequest:bmRequestType:wValue:wIndex:wLength:pData:]`.
Constants for every request: **`wValue = 0x0100`**, **`wIndex = 0x0001`**.

| Operation      | `bRequest` | `bmRequestType` | Dir | `wLength` | Data |
|----------------|:--------:|:-------------:|:---:|:--------:|------|
| getVersion     | `0x00` | `0xC2` | IN  | 16 | 16-byte version blob |
| readRouting    | `0x01` | `0xC2` | IN  | 2  | `uint16` routing word (LE) |
| sendRouting    | `0x02` | `0x42` | OUT | 2  | `uint16` routing word (LE) |
| startFirmware  | `0x05` | `0x42` | OUT | 0  | none (boot new firmware) |
| readFirmware   | `0x06` | `0xC2` | IN  | n  | firmware bytes |
| writeFirmware  | `0x07` | `0x42` | OUT | n  | firmware bytes |

`bmRequestType` decode: `0xC2` = IN | Vendor | recipient Endpoint(2);
`0x42` = OUT | Vendor | recipient Endpoint(2). These opcodes are **certain** —
they are hard-coded immediates in the disassembly.

### 3.3 The 16-bit routing word (best-effort decode)
`readRouting`/`sendRouting` exchange a single 16-bit word that encodes the whole
panel state. Reconstructed bit layout from `readAndDecodeRouting` /
`encodeAndSendRouting` (**verify against hardware before depending on labels**;
the raw read/write is exact either way):

| Bits | Meaning (reconstructed) |
|------|--------------------------|
| 0–1  | Sound Input 2 / Digital Output low selector |
| 2–3  | Alternate input selector (used when input-1 index > 1) |
| 4–7  | MIDI channel (0–15) |
| 8    | Sound Card Mode select (0 vs 1 layout) |
| 9    | Sound Input 1 present |
| 10   | Sound Input 1 sub-selection |
| 14   | Sound Input 3 enable |
| 15   | MIDI mapping select |

The exact menu *labels* for each index live in `MainMenu.nib`
(`keyedobjects.nib`) and in `-[XoneControl changeLayout:]`; they aren't needed to
read/write the word, so they are left as a follow-up if you want a pixel-faithful
UI.

### 3.4 Firmware update flow (documented, not automated)
`-[XoneControl executeUpdateFirmware:]` reads a firmware file as records, writes
them with `writeFirmware` (`0x07`), reads them back with `readFirmware` (`0x06`)
to verify/echo the address, retries on mismatch (up to ~0x31 times with `usleep`
pacing), and finally calls `startFirmware` (`0x05`). On success it prints
*"Firmware update complete. Please REBOOT the Xone:3D (Power Off, Power On)."*

⚠️ **Flashing is the one operation that can brick the device.** The exact record
framing was not verifiable without the physical unit, so the port deliberately
does **not** ship an automated flasher. The opcodes are documented so a verified
image + known-good tooling can drive them if ever needed.

## 4. Making it work on an M1 — your options

**Option A — Native replacement (recommended, included).**
`xone3d.py` reimplements the protocol against **libusb**, which runs natively on
arm64 macOS. It gives you the useful, safe functions — read version, read/set the
routing configuration, and dump firmware — with no emulation and no 32-bit code.
```
brew install libusb
python3 -m pip install pyusb
python3 xone3d.py info
```
If macOS has already bound the Xone:3D as a USB-audio device, a user-space open
can report "busy/denied". Workarounds: unload the audio binding, or run the tool
with the device in its boot/config state, or build the same calls as a tiny
`IOUSBHost` Swift helper that coexists with the audio driver. (The control
transfers are identical regardless of language.)

**Option B — Rebuild the original UI as a native Swift/Cocoa app.**
Because the logic is so small, the whole panel can be rebuilt as an arm64 app:
the six USB calls above + eight menus bound to the routing word. This is the path
if you want the original window back, notarized and double-clickable. I can
scaffold that Xcode project on request.

**Option C — Emulation (faithful but impractical for hardware).**
Run the *original* binary inside an emulated old macOS:
- the **i386** slice needs macOS 10.6–10.14 — on an M1 that only exists under
  full x86 emulation (e.g. QEMU/UTM in TCG mode), which is slow and makes USB
  passthrough to the real Xone:3D fragile;
- the **ppc** slice needs Mac OS X 10.4/10.5 PPC under QEMU-system-ppc.
Fine for *looking at* the app; poor for actually driving the device.

**Option D — Use an older Mac.** Any Intel Mac on macOS ≤ 10.14 Mojave runs the
i386 slice directly. Simplest if you have one; not an M1, obviously.

## 5. Files in this delivery
- `xone3d.py` — native, M1-compatible control tool (Option A).
- `REVERSE_ENGINEERING_REPORT.md` — this document.
- `protocol.json` — the recovered protocol as machine-readable data.
