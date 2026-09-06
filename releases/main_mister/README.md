# Patched Main_MiSTer binary (Mega CD seek-latency fix)

`MiSTer` here is a build of MiSTer-devel/Main_MiSTer (master, commit 915ca33) with
`tools/main_patches/megacdd_seek_latency.patch` applied — the Genesis Plus GX drive-latency
floor for Play/Seek (at least 12 CDD interrupts), which lets Thunder Storm FX (and the other
Wolf Team titles) boot instead of freezing on the Sega logo when a short seek finishes too fast.

- md5: 475ac9e6 (162,116 bytes). Confirmed on hardware: Thunder Storm FX boots, FM/CD audio OK.
- Built with the Arm GNU 10.2 arm-none-linux-gnueabihf toolchain (Main's Makefile toolchain).

Install: back up the original first, then copy over it and reboot:
    cp /media/fat/MiSTer /media/fat/MiSTer.orig
    cp MiSTer /media/fat/MiSTer && sync && reboot
The patch is MegaCD-only (`is_megacd()` guard); other cores' CD drive timing is unchanged.
This is a core-side deliverable's companion; upstream the patch to Main_MiSTer for a permanent fix.
