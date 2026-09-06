# OSD reset / cartridge / disc-eject options

## Done (2026-09-07)
- "Remove Cartridge & Reset" (R[37]): clears the cartridge slot (rom_cart_mode -> 0) and resets
  the core, keeping the mounted CD. So a Mega Drive cartridge loaded via "Insert Cartridge" can be
  removed and the core returns to Mega CD/BIOS mode with the disc still in, without touching Main.
  Wired in MegaCD.sv: `cart_remove = status[37]`, added to `reset` and the rom_cart_mode clear.

## "Eject Disc" as a separate option — needs a decision
The disc eject is a MAIN-side operation: Main's mcd_set_image() calls cdd.Unload() only when the
S0 slot is (re)mounted or emptied from the file browser. The core cannot unmount the CD image on
its own via a status bit; there is no such hook in Main today. So a genuine core "Eject Disc"
menu line requires EITHER:
  (a) use the existing "S0,CUECHD,Insert Disk;" file-browser eject (already available), or
  (b) a small Main patch: watch a dedicated status bit (e.g. status[38]) in mcd_poll and call
      cdd.Unload()/CD_STAT_OPEN when it pulses, then add "R[38],Eject Disc;" to the core.
Option (b) is clean and matches the user's "separate option" request; it is a Main change like the
seek-latency patch (tools/main_patches/). NOT implemented yet — confirm before patching Main.
The current "R[0],Reset & Eject CD;" actually only resets + clears the cartridge (rom_cart_mode),
the disc stays mounted; its label is historically loose. Consider relabeling to "Reset" once (b)
provides a real eject.
