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
"Remove Cartridge & Reset" empties the slot and returns to Mega CD mode. A cartridge is
physical: it survives a reset and a disc change, and only that OSD entry removes it. The file
browser opens in the MegaCD folder (a Main limitation); navigate up to games/MegaDrive once
per session.

### Disc handling
"Eject Disc" opens the tray without resetting anything, so the running BIOS or game sees the
disc go away as on hardware. "Reset & Eject CD" does both.

"Disc Insert" chooses what a *new* disc does. Default **Reset**: the machine restarts with
that game's BIOS, save file and cheats, which is what a flat folder of unrelated games wants.
**Keep Running** swaps the disc in the drive with the core still running, for multi-disc games
kept in their own folder. Both need the patched Main (see releases/main_mister); the choice is
read there, in mcd_set_image(), not in the core.

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

# Accuracy

The reference is [mcd-verificator](https://gendev.spritesmind.net/forum/viewtopic.php?t=3166),
krikzz's hardware-validated Mega CD diagnostic, run on a real DE10-Nano.  Build 56, over
12 consecutive runs that came back byte-identical:

| test | result |
|---|---|
| RAM CART, COLOR CALC, VAR TESTS | OK |
| REG X000 / X002 / 2006 / X00C / 8030 | OK |
| PROG RAM, WORD RAM, WRAM PMOD | OK |
| CDC REGS, CDC FLAGS | OK |
| CDC DMA1, DMA2, DMA3 | OK |
| CDC INIT | OK |
| IRQ TEST | ERROR 0A |

CDC INIT used to fail 62% of runs and is now 0 in 34; the CDC frame timer was expiring 27 ns
before each sector arrived, so sync insertion fired on every normal frame and woke the sub CPU
to read a sector header that had not been latched yet.

IRQ TEST 0A is the last one, and it is marginal rather than wrong.  Individual runs do pass it -
builds 51 and 54 each produced a run where every single test was OK.  A 120-offset sweep of the
sub-CPU's interrupt path (sim/cdc/irq) puts the response at 5411/6190/7097 ns against a 6779 ns
deadline, with the gate array contributing nothing measurable: the whole spread is the 68000's
own /VPA-terminated interrupt acknowledge, which takes 13-22 clocks depending on E-clock phase.
That is what the real hardware does - Sega's gate-array pin list, Sega's factory checker and
krikzz's own Mega CD core all say /VPA - so it is not something to shorten.
[HANDOFF.md](HANDOFF.md) has the full analysis.

# Testing a running MiSTer over SSH

`tools/mister/` exists because reproducing hardware behaviour by hand does not scale:

- `uinput_kbd.py` runs on the MiSTer and synthesises keystrokes through `/dev/uinput`; MiSTer's
  inotify watch on `/dev/input` picks the device up with no restart. Start it once with
  `--daemon` and drive it with `--send osd up up enter` - creating the device per keypress
  races MiSTer's device-open path and loses keys.
- `osd.py` holds the OSD selection indices derived from Main's `menu.cpp`. The OSD is
  composited *after* the scaler, so it can never appear in a screenshot and has to be driven
  blind; the selection wraps, so the bottom items are 1-4 UP presses from a freshly-opened menu.
- `verif_loop.sh` runs mcd-verificator N times and md5-groups the result screens, so identical
  outcomes collapse to a single image to read.
- `mcd_telemetry.py` reads a telemetry struct out of the FPGA's DDR3 window from Linux.

# Main_MiSTer

This core expects a patched Main; `releases/main_mister/` has the binary and
[retrorepair/Main_MiSTer](https://github.com/retrorepair/Main_MiSTer) branch `megacd-nukedmd`
has the source. Every patch is `is_megacd()`-guarded:

- CDD seek latency matched to Genesis Plus GX, so Thunder Storm FX and the other Wolf Team
  titles boot instead of freezing on the Sega logo;
- an "Eject Disc" OSD option that opens the tray without resetting;
- "Disc Insert" decides whether a disc change restarts the machine, instead of a
  directory-prefix guess that treats every game in a flat folder as the same game;
- line-buffered stdout, so a redirected log shows what just happened.

`wslbuild.sh` in that fork cross-builds it from WSL with ARM's 10.2 `arm-none-linux-gnueabihf`
toolchain - the one `setup_default_toolchain.sh` fetches.
