derive_pll_clocks
derive_clock_uncertainty

set_multicycle_path -to {*Hq2x*} -setup 4
set_multicycle_path -to {*Hq2x*} -hold 3

set_multicycle_path -from [get_clocks { *|pll|pll_inst|altera_pll_i|*[0].*|divclk}] -to {ascal|*} -setup 4
set_multicycle_path -from [get_clocks { *|pll|pll_inst|altera_pll_i|*[0].*|divclk}] -to {ascal|*} -hold 3

# The PSG IIR filter (sys/iir_filter.v) only moves data on its 7.056 MHz clock enable: every
# register in it is written under "if (ce)", so a path from one of its registers to another
# spans at least 7 periods of the 53.69 MHz clock, not one. Without this the fitter reports
# and chases -2.5ns "violations" there that cannot happen.
set_multicycle_path -from {emu|audio_cond|psg_iir|*} -to {emu|audio_cond|psg_iir|*} -setup 4
set_multicycle_path -from {emu|audio_cond|psg_iir|*} -to {emu|audio_cond|psg_iir|*} -hold 3
