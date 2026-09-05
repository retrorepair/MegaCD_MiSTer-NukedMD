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
