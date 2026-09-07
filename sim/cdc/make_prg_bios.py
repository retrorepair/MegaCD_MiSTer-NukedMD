#!/usr/bin/env python3
# Extract the verificator's 8KB sub BIOS from mcd-verificator.bin and pack it as
# big-endian 16-bit words (prg_bios.hex) for the MCD.vhd sub-CPU boot bench.
# The blob sits at .bin offset 4768 (its "SEGA MEGADRIVE" header is at 4768+0x100).
# NOTE: prg_bios.hex is a derivative of krikzz's mcd-verificator.bin and is NOT
# committed; generate it locally, pointing SRC at your own copy of the binary.
import sys
SRC = sys.argv[1] if len(sys.argv) > 1 else "mcd-verificator.bin"
blob = open(SRC, "rb").read()[4768:4768+8192]
with open("prg_bios.hex", "w") as f:
    for i in range(0, 8192, 2):
        f.write("%04x\n" % ((blob[i] << 8) | blob[i+1]))
print("wrote prg_bios.hex (%d words); word0-3:" % (8192//2),
      " ".join("%04x" % ((blob[i]<<8)|blob[i+1]) for i in range(0, 8, 2)))
