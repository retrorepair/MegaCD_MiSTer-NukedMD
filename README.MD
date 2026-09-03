# [Sega MegaCD](https://en.wikipedia.org/wiki/Sega_CD) for [MiSTer Platform](https://github.com/MiSTer-devel/Main_MiSTer/wiki)

Mega Drive side: [NukedMD-FPGA](https://github.com/nukeykt/Nuked-MD-FPGA) (cycle-accurate
FC1004 / 68000 / Z80 / YM3438 from die shots) through the MiSTer HAL, with the FC1004
expansion connector driving the Mega CD gate array. The Mega CD side (gate array, sub 68000,
CDC, PCM, CDDA) is unchanged.

# Installation
Place BIOS to MegaCD folder with name boot.rom

# Features
About 150 games tested without long playing, US/EU regions only.

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
- The PCM wave RAM lives in SDRAM (the Cyclone V does not have enough block RAM for both
  chipsets). It is transparent to the software.
- fpgagen-only options (sprite limit, HiFi PCM, layer toggles, adaptive blend) are gone;
  keyboard, SNAC port select, OSD pause and stereo mix are new.
