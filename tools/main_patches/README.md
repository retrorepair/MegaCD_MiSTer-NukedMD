# Main_MiSTer patches (not part of the core)

Patches against https://github.com/MiSTer-devel/Main_MiSTer for behaviour that lives on the
Linux side (the CD drive model). They are **untested**: this repository has no ARM toolchain,
so they have to be applied and built with Main's own build setup.

## megacdd_seek_latency.patch — Thunder Storm FX (Wolf Team) drive latency

`support/megacd/megacdd.cpp`, `cdd_t::SeekToLBA`. Main answers a Play after 11 CDD
interrupts and a Seek immediately (0), plus a seek-distance term. Genesis Plus GX (the model
Main's drive code derives from) gives both at least 12 interrupts unless a previous latency is
still running, with a comment listing the Wolf Team titles (Annet Futatabi, Aisle Lord, Cobra
Command, Earnest Evans, Road Avenger, Thunder Storm FX, Time Gal) that need at least 12, and
Space Adventure Cobra that needs 13 including seek time. The patch adopts the GPGX rule for
the MegaCD core only (`is_megacd()`), leaving the Neo Geo CD path unchanged.

Not ported: GPGX also defers the start of a Play/Seek by one CDD interrupt through its
`pending` flag. Main executes the command when the core raises it and reports status on the
next 75 Hz poll before decrementing the latency, which is roughly the same phase.

Test with `/media/fat/_Console/MegaCD_tsfx_jp.mgl` (Thunder Storm FX, Japan) once a patched
Main is on the card; also re-check Final Fight CD (intro seek), Sonic CD (track 26) and
Radical Rex, which GPGX's comments name as sensitive to this timing.

## Findings from the jgenesis issue tracker to fold into the drive model

- **#178 Thunder Storm FX (Japan) freezes on the Sega logo**: a very short seek (00:32:38 to
  00:32:22) that completes too quickly desynchronises the two 68000s into a livelock where
  each waits for the other's flag in $A1200E / $FF800F (the same state observed here with
  Cobra Command on the MiSTer). jsgroth's fix: every seek takes at least 6-7 CDD cycles at
  75 Hz. The patch above uses the GPGX rule (12 cycles unless a latency is still running, plus
  the distance term) for Play and Seek, which covers this; a minimum of 6-7 on the Seek path
  alone would be the smaller change if the 12 proves too slow elsewhere.
- **#100 Radical Rex (USA) crashes in the intro (also GPGX issue 290)**: if a Read/Play
  command arrives while the drive is already playing, the drive reads one more sector from the
  current position before it starts seeking. Main's CommandExec seeks immediately. Radical Rex
  boots by issuing a Read for 00:02:61 right after the sector at 00:03:48 and depends on
  00:03:49 being delivered first. Not yet in the patch.
- **#624 The Smurfs (Europe)**: an EU-only game whose header auto-detects as US; needs PAL
  timings. Region detection is Main/BIOS side on the MiSTer as well.
