# [Sega MegaCD](https://en.wikipedia.org/wiki/Sega_CD) for [MiSTer Platform](https://github.com/MiSTer-devel/Main_MiSTer/wiki)

Mega Drive side: [NukedMD-FPGA](https://github.com/nukeykt/Nuked-MD-FPGA) (cycle-accurate
FC1004 / 68000 / Z80 / YM3438 from die shots) through the MiSTer HAL, with the FC1004
expansion connector driving the Mega CD gate array.

Mega CD side: the gate array, CDC, PCM and CDDA are the original core's. **The sub-CPU is
also the Nuked 68000** (the same gate-level `m68kcpu` model that serves as the main CPU),
in place of FX68K, clocked at the Mega CD's 12.5 MHz from the board model's 107.38 MHz
sampling clock.

Resource usage, block RAM map, timing and build history: [STATS.md](STATS.md).

# Installation
- `games/MegaCD/boot.rom` - Mega CD BIOS (loaded at core start).
- `games/MegaCD/boot2.rom` - optional Mega Drive TMSS boot ROM (2 KB, the MegaDrive core's
  `boot.rom`). When present the OSD gains a "TMSS" option; Main only loads boot ROMs from
  the core's own folder, so it has to be a copy here (if a CIFS share holds the MegaCD
  folder, Main uses that folder).

# Features
About 150 games tested without long playing, US/EU regions only.

### Cartridge slot
"Insert Cartridge" in the OSD loads a Mega Drive cartridge (BIN/GEN/MD) into the slot:
/CART goes low, the FC1004 maps the cartridge at 000000 and the Mega CD at 400000 as on
the real machine. Mappers as in the MegaDrive core (SSF2, SRAM, 24Cxx EEPROM, Pier Solar,
Realtec, SF-00x, J-Cart, Sega Channel, per-game lightgun and YM2612 quirks); no SVP.
"Reset & Eject CD" or loading a BIOS returns to Mega CD mode. The file browser opens in
the MegaCD folder (a Main limitation); navigate up to games/MegaDrive once per session.

### Known issues:
- Microcosm & Ultraverse Prime (US) - graphic glitch in game
- Supreme Warrior - Ying Heung (US) - can't select 2 disk

### Supported image formats:
- CUE + single image
- CUE + multiple images (image per track)
- CHD file

### ZIP
ZIP is supported but doesn't work due to long positioning time.
So DON'T zip the images!

### CD BIOS
support BIOS per game. Place cd_bios.rom in game's folder.

### Pier Solar
Place cartridge dump named cart.rom into game's folder

### Notes on the NukedMD version
- The Mega Drive is the real chipset: expansion accesses are acknowledged by the FC1004
  arbiter at the real speed, so the Mega CD answers inside the fixed 68000 cycle.
- Both 68000s are the Nuked gate-level model. The sub-CPU wrapper is `rtl/MCD/MC68K.vhd`.
- The PCM wave RAM lives in SDRAM (the Cyclone V does not have enough block RAM for both
  chipsets). It is transparent to the software.
- fpgagen-only options (sprite limit, HiFi PCM, layer toggles, adaptive blend) are gone;
  keyboard, SNAC port select, OSD pause, stereo mix, TMSS and the cartridge slot are new.
- `nuked-md/` is byte-identical to the MegaDrive core except `md_board.v`, which only adds
  the expansion connector ports and the /CART and DISK pin inputs (marked `// MegaCD`).
