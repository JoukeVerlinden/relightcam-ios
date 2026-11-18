#!/usr/bin/env python3
"""Add an optional USB MIDI interface to the Arduino UNO R4 WiFi core (arduino:renesas_uno).

The UNO R4 core ships TinyUSB with its MIDI class switched off and a fixed USB descriptor, so out of the box an
R4 can be a USB keyboard but not a USB MIDI device. This patch:
  1. switches TinyUSB's MIDI class on for the UNO R4 WiFi (variants/UNOWIFIR4/tusb_config.h), and
  2. adds a MIDI interface to the USB configuration descriptor (cores/arduino/usb/USB.cpp), but only for sketches
     that define `void __USBInstallMIDI() {}` (USB.h already declares that hook). Other sketches are unchanged.
Then a sketch that calls __USBStart() appears on a Mac or an iPhone as a class-compliant USB MIDI device and reads
packets with TinyUSB's tud_midi_packet_read(). See ../relightcam_dome_usb.

Usage:  python3 patch_core.py            apply (idempotent; keeps *.orig backups)
        python3 patch_core.py --revert   restore the original files
        python3 patch_core.py --check    report whether the installed core(s) are patched
Re-run it after updating the "Arduino UNO R4 Boards" package.
"""
import glob
import os
import shutil
import sys

MARK = "relightCam USB MIDI patch"

TUSB_OLD = "#define CFG_TUD_MIDI             0\n"
TUSB_NEW = (f"// {MARK}: MIDI class on (the interface is only added for sketches that define __USBInstallMIDI)\n"
            "#define CFG_TUD_MIDI             1\n"
            "#define CFG_TUD_MIDI_RX_BUFSIZE  64\n"
            "#define CFG_TUD_MIDI_TX_BUFSIZE  64\n"
            "#define CFG_TUD_MIDI_EP_BUFSIZE  64\n")

USB_EDITS = [
    # endpoint addresses
    ("#define USBD_MSD_IN_OUT_SIZE (512)\n",
     "#define USBD_MSD_IN_OUT_SIZE (512)\n\n"
     f"// {MARK}\n"
     "#ifndef USBD_MIDI_EP_OUT\n#define USBD_MIDI_EP_OUT (0x05)\n#endif\n"
     "#ifndef USBD_MIDI_EP_IN\n#define USBD_MIDI_EP_IN (0x85)\n#endif\n"),
    # the MIDI interface descriptor, after the mass storage one
    ("        // Create configuration descriptor\n",
     f"        /*\n         * -----    MIDI ({MARK})\n         */\n"
     "        bool install_MIDI = false;\n"
     "#if CFG_TUD_MIDI\n"
     "        install_MIDI = __USBInstallMIDI;\n"
     "        uint8_t midi_desc[TUD_MIDI_DESC_LEN] = {\n"
     "            // Interface number, string index, EP Out & EP In address, EP size\n"
     "            TUD_MIDI_DESCRIPTOR(interface_count, 0, USBD_MIDI_EP_OUT, USBD_MIDI_EP_IN, 64)\n"
     "        };\n"
     "        interface_count += (install_MIDI ? 2 : 0);\n"
     "#else\n"
     "        uint8_t midi_desc[0] = {};\n"
     "#endif\n\n"
     "        // Create configuration descriptor\n"),
    # its length
    ("            + (install_MSD ? sizeof(msd_desc) : 0);\n",
     "            + (install_MSD ? sizeof(msd_desc) : 0)\n"
     "            + (install_MIDI ? sizeof(midi_desc) : 0);\n"),
    # and copy it into the combined descriptor
    ("            if (install_MSD) {\n"
     "                memcpy(ptr, msd_desc, sizeof(msd_desc));\n"
     "                ptr += sizeof(msd_desc);\n"
     "            }\n",
     "            if (install_MSD) {\n"
     "                memcpy(ptr, msd_desc, sizeof(msd_desc));\n"
     "                ptr += sizeof(msd_desc);\n"
     "            }\n"
     "            if (install_MIDI) {\n"
     "                memcpy(ptr, midi_desc, sizeof(midi_desc));\n"
     "                ptr += sizeof(midi_desc);\n"
     "            }\n"),
]


def cores():
    roots = [os.path.expanduser("~/Library/Arduino15"),       # macOS
             os.path.expanduser("~/.arduino15"),              # Linux
             os.path.expandvars(r"%LOCALAPPDATA%\Arduino15")]  # Windows
    found = []
    for r in roots:
        found += sorted(glob.glob(os.path.join(r, "packages", "arduino", "hardware", "renesas_uno", "*")))
    return [c for c in found if os.path.isfile(os.path.join(c, "cores", "arduino", "usb", "USB.cpp"))]


def files(core):
    return (os.path.join(core, "variants", "UNOWIFIR4", "tusb_config.h"),
            os.path.join(core, "cores", "arduino", "usb", "USB.cpp"))


def patched(path):
    return MARK in open(path, encoding="utf-8").read()


def apply(core):
    tusb, usb = files(core)
    for path in (tusb, usb):
        if not os.path.exists(path + ".orig"):
            shutil.copy2(path, path + ".orig")
    s = open(tusb, encoding="utf-8").read()
    if MARK not in s:
        if TUSB_OLD not in s:
            sys.exit(f"{tusb}: unexpected contents, not patched")
        open(tusb, "w", encoding="utf-8").write(s.replace(TUSB_OLD, TUSB_NEW, 1))
    s = open(usb, encoding="utf-8").read()
    if MARK not in s:
        for old, new in USB_EDITS:
            if s.count(old) != 1:
                sys.exit(f"{usb}: unexpected contents ({old.strip()[:40]}…), not patched")
            s = s.replace(old, new, 1)
        open(usb, "w", encoding="utf-8").write(s)
    print(f"patched {core}")


def revert(core):
    for path in files(core):
        if os.path.exists(path + ".orig"):
            shutil.copy2(path + ".orig", path)
            os.remove(path + ".orig")
    print(f"restored {core}")


def main():
    cs = cores()
    if not cs:
        sys.exit("No Arduino UNO R4 core found. Install 'Arduino UNO R4 Boards' in the Boards Manager first.")
    for c in cs:
        if "--revert" in sys.argv:
            revert(c)
        elif "--check" in sys.argv:
            print(c, "patched" if all(patched(p) for p in files(c)) else "NOT patched")
        else:
            apply(c)


if __name__ == "__main__":
    main()
