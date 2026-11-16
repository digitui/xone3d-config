#!/usr/bin/env python3
"""
xone3d.py - Native control panel for the Allen & Heath / Ploytec Xone:3D
=========================================================================

A ground-up reimplementation of the original 2006 "Xone3D.app" control panel,
written so it runs *natively* on Apple Silicon (M1/M2/M3) macOS, as well as
Linux and Intel macOS.

WHY THIS EXISTS
---------------
The original Xone3D.app is a Mach-O universal binary containing ONLY
PowerPC and 32-bit Intel (i386) code. Apple Silicon cannot run either:
  * Rosetta 2 translates x86_64 only - not i386, not PowerPC.
  * 32-bit Intel support was removed from macOS in 10.15 Catalina (2019).
  * PowerPC support ended in 10.7 Lion (2011).
So the old app literally cannot launch on an M1. The device protocol, however,
is tiny and fully recovered by reverse engineering (see the accompanying
report), so the app can simply be rewritten against libusb, which runs natively
on arm64.

The USB protocol below was recovered from the i386 slice of the original
binary (USBBridge.m / XoneControl.m). The control-transfer opcodes are
certain. The human-readable decode of the 16-bit "routing" word is a best-effort
reconstruction and is clearly marked where it should be verified against
hardware.

REQUIREMENTS (on Apple Silicon macOS)
-------------------------------------
    brew install libusb
    python3 -m pip install pyusb
    python3 xone3d.py info

If macOS has grabbed the device as a USB-audio interface, a plain user-space
libusb open may fail with "Access denied / resource busy". See the report's
"Running on M1" section for how to handle that.

Author: reconstructed from the original Ploytec binary.
License: do what you like with it.
"""

import argparse
import sys
import time

try:
    import usb.core
    import usb.util
except ImportError:
    sys.stderr.write(
        "ERROR: pyusb is not installed.\n"
        "  brew install libusb        # provides the native backend\n"
        "  python3 -m pip install pyusb\n"
    )
    sys.exit(1)

# ---------------------------------------------------------------------------
# Device identity  (recovered from -[USBBridge installUSBAddNotification])
# ---------------------------------------------------------------------------
VENDOR_ID = 0x0A4A       # Ploytec GmbH
PRODUCT_ID = 0xFF00      # Xone:3D

# ---------------------------------------------------------------------------
# Control-transfer protocol
# (recovered from the -[USBBridge ...] methods; each wraps a single
#  IOUSBDeviceInterface::DeviceRequest / libusb control transfer)
#
#   bmRequestType 0xC2 = IN  | Vendor | Recipient=Endpoint(2)
#   bmRequestType 0x42 = OUT | Vendor | Recipient=Endpoint(2)
#   wValue  = 0x0100  (constant for every request)
#   wIndex  = 0x0001  (constant for every request)
#
#   op             bRequest  dir  wLength   meaning
#   getVersion       0x00    IN     16      firmware/version string (16 bytes)
#   readRouting      0x01    IN      2      current routing word (uint16 LE)
#   sendRouting      0x02    OUT     2      set routing word (uint16 LE)
#   startFirmware    0x05    OUT     0      boot/commit newly written firmware
#   readFirmware     0x06    IN      n      read n bytes of firmware image
#   writeFirmware    0x07    OUT     n      write n bytes of firmware image
# ---------------------------------------------------------------------------
BM_IN = 0xC2
BM_OUT = 0x42
WVALUE = 0x0100
WINDEX = 0x0001

REQ_GET_VERSION = 0x00
REQ_READ_ROUTING = 0x01
REQ_SEND_ROUTING = 0x02
REQ_START_FIRMWARE = 0x05
REQ_READ_FIRMWARE = 0x06
REQ_WRITE_FIRMWARE = 0x07

TIMEOUT_MS = 2000


class Xone3D:
    def __init__(self, dev):
        self.dev = dev

    # -- connection ---------------------------------------------------------
    @classmethod
    def open(cls):
        dev = usb.core.find(idVendor=VENDOR_ID, idProduct=PRODUCT_ID)
        if dev is None:
            raise RuntimeError(
                "Xone:3D not found (VID 0x%04X PID 0x%04X). "
                "Is it plugged in and powered on?" % (VENDOR_ID, PRODUCT_ID)
            )
        # We only issue control transfers on endpoint 0, so we do not need to
        # claim a data interface. On Linux, detaching a kernel driver may be
        # required; on macOS the audio driver can hold the device (see report).
        try:
            if hasattr(dev, "is_kernel_driver_active"):
                for cfg in dev:
                    for intf in cfg:
                        n = intf.bInterfaceNumber
                        try:
                            if dev.is_kernel_driver_active(n):
                                dev.detach_kernel_driver(n)
                        except (usb.core.USBError, NotImplementedError):
                            pass
        except usb.core.USBError:
            pass
        return cls(dev)

    # -- low-level primitives ----------------------------------------------
    def _in(self, bRequest, length):
        return bytes(self.dev.ctrl_transfer(
            BM_IN, bRequest, WVALUE, WINDEX, length, TIMEOUT_MS))

    def _out(self, bRequest, data=b""):
        return self.dev.ctrl_transfer(
            BM_OUT, bRequest, WVALUE, WINDEX, data, TIMEOUT_MS)

    # -- high-level operations ---------------------------------------------
    def get_version(self):
        """Return the raw 16-byte version blob and a cleaned ASCII string."""
        raw = self._in(REQ_GET_VERSION, 16)
        text = raw.split(b"\x00", 1)[0].decode("ascii", "replace").strip()
        return raw, text

    def read_routing(self):
        """Return the current 16-bit routing word."""
        raw = self._in(REQ_READ_ROUTING, 2)
        return int.from_bytes(raw[:2], "little")

    def send_routing(self, word):
        """Write a 16-bit routing word."""
        word &= 0xFFFF
        self._out(REQ_SEND_ROUTING, word.to_bytes(2, "little"))
        return word

    def read_firmware(self, length):
        """Read `length` bytes of firmware (safe, read-only)."""
        return self._in(REQ_READ_FIRMWARE, length)

    # NOTE: writeFirmware / startFirmware are implemented as primitives but
    # intentionally NOT wrapped in an automated flashing routine. Flashing is
    # the one operation that can brick the hardware, and the exact firmware
    # record framing could not be verified against a physical device. Use the
    # original tooling / a verified image if you must reflash. See the report.
    def _write_firmware_chunk(self, data):
        return self._out(REQ_WRITE_FIRMWARE, data)

    def _start_firmware(self):
        return self._out(REQ_START_FIRMWARE, b"")


# ---------------------------------------------------------------------------
# Best-effort decode of the 16-bit routing word.
# Reconstructed from -[XoneControl readAndDecodeRouting] /
# -[XoneControl encodeAndSendRouting]. Bit positions are from the binary;
# the human labels should be confirmed against your hardware before you rely
# on them. Raw read/write (above) is exact regardless.
# ---------------------------------------------------------------------------
def decode_routing(word):
    return {
        "raw": "0x%04X" % word,
        "bit8_mode_select": (word >> 8) & 1,
        "bit9_input1_present": (word >> 9) & 1,
        "bit10_input1_sub": (word >> 10) & 1,
        "bits2_3_input_alt": (word >> 2) & 0x3,
        "bits0_1_input2/digitalout": word & 0x3,
        "bits4_7_midi_channel": (word >> 4) & 0xF,
        "bit14_input3_enable": (word >> 14) & 1,
        "bit15_midi_mapping": (word >> 15) & 1,
    }


# ---------------------------------------------------------------------------
# CLI
# ---------------------------------------------------------------------------
def cmd_info(_args):
    x = Xone3D.open()
    raw, text = x.get_version()
    word = x.read_routing()
    print("Xone:3D connected  (VID 0x%04X  PID 0x%04X)" % (VENDOR_ID, PRODUCT_ID))
    print("  version raw : %s" % raw.hex(" "))
    print("  version text: %r" % text)
    print("  routing word: 0x%04X" % word)
    for k, v in decode_routing(word).items():
        if k != "raw":
            print("    %-26s %s" % (k, v))


def cmd_version(_args):
    raw, text = Xone3D.open().get_version()
    print(text if text else raw.hex(" "))


def cmd_get_routing(_args):
    word = Xone3D.open().read_routing()
    print("0x%04X" % word)
    for k, v in decode_routing(word).items():
        if k != "raw":
            print("  %-26s %s" % (k, v))


def cmd_set_routing(args):
    word = int(args.value, 0) & 0xFFFF
    x = Xone3D.open()
    before = x.read_routing()
    x.send_routing(word)
    after = x.read_routing()
    print("routing: 0x%04X -> requested 0x%04X -> now 0x%04X" % (before, word, after))


def cmd_dump_firmware(args):
    x = Xone3D.open()
    length = int(args.length, 0)
    data = bytearray()
    remaining = length
    while remaining > 0:
        chunk = min(remaining, 64)
        data += x.read_firmware(chunk)
        remaining -= chunk
    with open(args.out, "wb") as f:
        f.write(data)
    print("wrote %d bytes to %s" % (len(data), args.out))


def main():
    p = argparse.ArgumentParser(
        description="Native Xone:3D control panel (M1-compatible replacement "
                    "for the 2006 PPC/i386 app).")
    sub = p.add_subparsers(dest="cmd", required=True)

    sub.add_parser("info", help="show version + routing").set_defaults(func=cmd_info)
    sub.add_parser("version", help="print firmware/version string").set_defaults(func=cmd_version)
    sub.add_parser("get-routing", help="read the routing word").set_defaults(func=cmd_get_routing)

    sp = sub.add_parser("set-routing", help="write a routing word, e.g. 0x0107")
    sp.add_argument("value")
    sp.set_defaults(func=cmd_set_routing)

    sp = sub.add_parser("dump-firmware", help="read firmware to a file (safe)")
    sp.add_argument("--length", default="0x100", help="bytes to read (default 0x100)")
    sp.add_argument("--out", default="xone3d_firmware.bin")
    sp.set_defaults(func=cmd_dump_firmware)

    args = p.parse_args()
    try:
        args.func(args)
    except RuntimeError as e:
        sys.stderr.write("error: %s\n" % e)
        sys.exit(2)
    except usb.core.USBError as e:
        sys.stderr.write(
            "USB error: %s\n"
            "On macOS the device may be claimed by the audio driver; "
            "see the report's 'Running on M1' section.\n" % e)
        sys.exit(3)


if __name__ == "__main__":
    main()
