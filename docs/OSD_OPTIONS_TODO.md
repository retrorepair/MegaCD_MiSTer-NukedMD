# OSD reset / cartridge / disc-eject options

## Done (2026-09-07)
- "Remove Cartridge & Reset" (R[37]): clears the cartridge slot (rom_cart_mode -> 0) and resets
  the core, keeping the mounted CD. A Mega Drive cartridge loaded via "Insert Cartridge" can be
  removed and the core returns to Mega CD/BIOS mode with the disc still in, without touching Main.
  Wired in MegaCD.sv: cart_remove = status[37], added to `reset` and the rom_cart_mode clear.
- "Eject Disc" (R[38]): a separate eject that does NOT reset. Main patch
  (tools/main_patches/megacd_eject_disc.patch): mcd_eject() = cdd.Unload() + CD_STAT_OPEN, called
  from the menu R/T handler on bit 38. Opens the tray so the running BIOS/game sees the disc gone,
  as on hardware; re-insert via the OSD file browser. Core adds "R[38],Eject Disc;" and wires no
  reset to status[38]. Built into releases/main_mister/MiSTer (md5 f7fa87d4); hardware check
  pending. Splits the eject out of "Reset & Eject CD" (R[0], which ejects + resets).

## How R[0] "Reset & Eject CD" works (for reference)
Main's menu handler calls mcd_set_image(0, "") when the status bit is 0: that unloads the disc
(CD_STAT_OPEN) AND, because the filename is empty (not same_game), pulses status[0] and reloads
the BIOS -- i.e. it ejects AND resets. R[38] is the eject-only half.
