# Patched Main_MiSTer binary (Mega CD)

`MiSTer` here is MiSTer-devel/Main_MiSTer with five MegaCD patches, all guarded by
`is_megacd()` except the last, which is core-independent. Source:
[retrorepair/Main_MiSTer](https://github.com/retrorepair/Main_MiSTer), branch `megacd-nukedmd`.

1. **CDD seek latency** — the Genesis Plus GX drive-latency floor for Play/Seek (at least 12 CDD
   interrupts). Thunder Storm FX and the other Wolf Team titles boot instead of freezing on the
   Sega logo when a short seek finishes too fast. Confirmed on hardware.
2. **"Eject Disc" (OSD `R[38]`)** — `mcd_eject()` opens the tray (the drive reports
   `CD_STAT_OPEN`) **without** resetting either 68000 or reloading the BIOS, so the running
   BIOS or game sees the disc removed as on hardware. This is the eject half of "Reset & Eject
   CD" (`R[0]`) on its own. Confirmed on hardware: selecting it logs
   `MCD: eject - tray open, core left running` and the core keeps running.
3. **"Disc Insert" decides whether a disc change resets** — `mcd_set_image()` decided "same
   game" by directory prefix, which is right for a multi-disc game in its own folder and wrong
   for the usual flat folder of unrelated titles, where every game matches every other:
   inserting a different game hot-swapped it into the previous game's BIOS and save file, which
   from the outside looks like nothing happened. The test is now gated on the core's
   `status[36]`, so the default restarts on every disc change and "Keep Running" is opt-in for
   multi-disc swapping. Cores that do not define bit 36 read 0 and get the restart behaviour.
4. **The eject is logged**, so it can be told apart from a keypress that never arrived.
5. **`setvbuf(stdout, NULL, _IOLBF, 0)`** — stdout is block-buffered when redirected, so
   `MiSTer > /tmp/mister.log` kept the last few kilobytes in libc's buffer and an action's log
   line stayed invisible until unrelated output pushed it out. Line-buffered now. This one is
   not MegaCD-specific and costs nothing.

- md5 **561f3ede** (1,162,116 bytes).
- Built with ARM's GNU 10.2 `arm-none-linux-gnueabihf` toolchain — the one Main's own
  `setup_default_toolchain.sh` fetches. `wslbuild.sh` in the fork cross-builds it from WSL.

Install: back up the original first, then copy over it and reboot:

    cp /media/fat/MiSTer /media/fat/MiSTer.orig
    cp MiSTer /media/fat/MiSTer && sync && reboot

The core ignores `status[38]`, so "Eject Disc" is inert without this Main. Upstream these to
Main_MiSTer for a permanent fix.
