# Patched Main_MiSTer binary (Mega CD: seek-latency fix + Eject Disc)

`MiSTer` here is a build of MiSTer-devel/Main_MiSTer (master, commit 915ca33) with two
MegaCD-only patches from `tools/main_patches/` applied:

1. `megacdd_seek_latency.patch` — the Genesis Plus GX drive-latency floor for Play/Seek (at
   least 12 CDD interrupts), which lets Thunder Storm FX (and the other Wolf Team titles) boot
   instead of freezing on the Sega logo when a short seek finishes too fast.
2. `megacd_eject_disc.patch` — adds `mcd_eject()` and wires it to the new OSD option
   **"Eject Disc" (R[38])**: it opens the tray (CDD reports CD_STAT_OPEN) WITHOUT resetting
   either 68000 or reloading the BIOS, so the running BIOS/game sees the disc removed as on
   hardware. This is the eject half of "Reset & Eject CD" (R[0]) split out on its own, per the
   request for a separate eject. Re-insert via the OSD file browser as usual. The core ignores
   status[38] (no reset is wired to it), so the option is inert without this patched Main.

- md5: f7fa87d4 (1,162,116 bytes). The seek-latency fix is confirmed on hardware; the eject
  option is built and needs a hardware check (select it with a disc mounted and a BIOS running).
- Built with the Arm GNU 10.2 arm-none-linux-gnueabihf toolchain (Main's Makefile toolchain).

Install: back up the original first, then copy over it and reboot:
    cp /media/fat/MiSTer /media/fat/MiSTer.orig
    cp MiSTer /media/fat/MiSTer && sync && reboot
Both patches are MegaCD-only (`is_megacd()` guard); other cores are unchanged. Upstream the
patches to Main_MiSTer for a permanent fix.
