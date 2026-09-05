library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
library STD;
use IEEE.NUMERIC_STD.ALL;

-- Mega CD sub-CPU: the Nuked-MD gate-level 68000 (m68kcpu, rtl/nuked-md/68k.v), the same
-- model that serves as the main CPU inside the FC1004 board model, in place of FX68K.
--
-- The model samples its CLK pin as a level on MCLK (107.38 MHz, the clock md_board uses for
-- the main CPU). The 12.5 MHz sub-CPU clock is rebuilt from the Mega CD clock generator's
-- rising/falling enables (CLK_12M_R/F in the 53.69 MHz domain, same PLL, exactly 2:1 to
-- MCLK), so every level change lands on an MCLK edge. All other pins keep the real 68000
-- levels (active low as on the package); the FX68K wrapper's port list is unchanged.
entity M68K_WRAP is
	port(
		CLK			: in std_logic;						-- 53.69 MHz Mega CD clock (enables, bus side)
		MCLK			: in std_logic;						-- 107.38 MHz: gate-level model sampling clock
		RST_N			: in std_logic;

		RESET_I_N	: in std_logic;
		CLKEN_P 		: in std_logic;						-- (FX68K legacy, unused here)
		CLKEN_N 		: in std_logic;						-- (FX68K legacy, unused here)
		CLK_LEVEL	: in std_logic;						-- 12.5 MHz CPU clock level from the gate array phase counter
		A   			: out std_logic_vector(23 downto 1);
		DI				: in std_logic_vector(15 downto 0);
		DO				: out std_logic_vector(15 downto 0);
		AS_N			: out std_logic;
		RNW			: out std_logic;
		UDS_N			: out std_logic;
		LDS_N			: out std_logic;
		DTACK_N		: in std_logic;
		IPL_N			: in std_logic_vector(2 downto 0);
		VPA_N			: in std_logic;
		FC				: out std_logic_vector(2 downto 0);
		HALT_I_N		: in std_logic;
		BGACK_N		: in std_logic;
		BG_N			: out std_logic;
		BR_N			: in std_logic;
		VMA_N			: out std_logic;
		E				: out std_logic;
		BERR_N		: in std_logic;
		RESET_O_N	: out std_logic;
		HALT_O_N		: out std_logic
	);
end M68K_WRAP;

architecture rtl of M68K_WRAP is

	component m68kcpu
	port(
		MCLK			: in std_logic;
		CLK			: in std_logic;
		VPA			: in std_logic;
		BR				: in std_logic;
		BGACK			: in std_logic;
		DTACK			: in std_logic;
		IPL			: in std_logic_vector(2 downto 0);
		BERR			: in std_logic;
		RESET_i		: in std_logic;
		RESET_pull	: out std_logic;
		HALT_i		: in std_logic;
		HALT_pull	: out std_logic;
		DATA_i		: in std_logic_vector(15 downto 0);
		DATA_o		: out std_logic_vector(15 downto 0);
		DATA_z		: out std_logic;
		E_CLK			: out std_logic;
		BG				: out std_logic;
		FC				: out std_logic_vector(2 downto 0);
		FC_z			: out std_logic;
		RW				: out std_logic;
		RW_z			: out std_logic;
		ADDRESS		: out std_logic_vector(22 downto 0);
		ADDRESS_z	: out std_logic;
		AS				: out std_logic;
		LDS			: out std_logic;
		UDS			: out std_logic;
		strobe_z		: out std_logic
	);
	end component;

	signal cpu_clk		: std_logic := '0';
	signal cpu_reset_n	: std_logic;
	signal cpu_halt_n	: std_logic;
	signal n_reset_pull	: std_logic;
	signal n_halt_pull	: std_logic;
	signal n_data_o		: std_logic_vector(15 downto 0);
	signal n_fc			: std_logic_vector(2 downto 0);
	signal n_fc_z		: std_logic;
	signal n_rw			: std_logic;
	signal n_rw_z		: std_logic;
	signal n_address	: std_logic_vector(22 downto 0);
	signal n_as			: std_logic;
	signal n_lds		: std_logic;
	signal n_uds		: std_logic;
	signal n_strobe_z	: std_logic;
	signal n_bg			: std_logic;
	-- outputs registered at MCLK (see below)
	signal r_address	: std_logic_vector(22 downto 0) := (others => '0');
	signal r_data_o		: std_logic_vector(15 downto 0) := (others => '0');
	signal r_as_n		: std_logic := '1';
	signal r_uds_n		: std_logic := '1';
	signal r_lds_n		: std_logic := '1';
	signal r_rnw		: std_logic := '1';
	signal r_fc			: std_logic_vector(2 downto 0) := (others => '1');

begin

	-- 12.5 MHz CLK level straight from the gate array's phase counter (high during the same
	-- CLK cycles in which FX68K ran its PHI1 actions). Rebuilding it from the edge enables
	-- would put every CPU clock edge one CLK (18.6 ns) late against the gate array's own
	-- enable-timed DTACK and strobe sampling.
	cpu_clk <= CLK_LEVEL;

	-- A 68000 only resets with /RESET and /HALT low together; the board's sub-CPU reset
	-- (gate array SRES) drives both lines. FX68K did this internally (extReset).
	cpu_reset_n <= RESET_I_N and RST_N;
	cpu_halt_n  <= HALT_I_N and cpu_reset_n;

	P68K : m68kcpu
	port map(
		MCLK			=> MCLK,
		CLK			=> cpu_clk,
		VPA			=> VPA_N,
		BR				=> BR_N,
		BGACK			=> BGACK_N,
		DTACK			=> DTACK_N,
		IPL			=> IPL_N,
		BERR			=> BERR_N,
		RESET_i		=> cpu_reset_n,
		RESET_pull	=> n_reset_pull,
		HALT_i		=> cpu_halt_n,
		HALT_pull	=> n_halt_pull,
		DATA_i		=> DI,
		DATA_o		=> n_data_o,
		DATA_z		=> open,
		E_CLK			=> E,
		BG				=> n_bg,
		FC				=> n_fc,
		FC_z			=> n_fc_z,
		RW				=> n_rw,
		RW_z			=> n_rw_z,
		ADDRESS		=> n_address,
		ADDRESS_z	=> open,
		AS				=> n_as,
		LDS			=> n_lds,
		UDS			=> n_uds,
		strobe_z		=> n_strobe_z
	);

	-- Bus outputs go to the gate array directly. A register stage here (tried in build 15 for
	-- timing) delays /AS by one CLK (18.6 ns) against the gate array's enable-timed DTACK and
	-- closes the CPU's DTACK acceptance window one clock early: the sub-CPU then takes one
	-- more wait state than FX68K on every late-acknowledged access (mcd-verificator IRQ and
	-- VAR tests). There is no buffer between the sub-CPU and the gate array on the real board.
	-- Released (high-Z) pins read as pulled up, as md_board does for the main CPU.
	-- The gate-level model's bus outputs are combinational functions of latches that settle after
	-- every MCLK (107 MHz) edge, while the gate array samples them in the 53.7 MHz domain. Handing
	-- them over combinationally (builds 18-28) left long 107 -> 53.7 MHz paths whose slack varied
	-- from fit to fit and was 1% tighter in NTSC than in PAL; the symptoms were fit-dependent PCM
	-- pops and BIOS hangs in NTSC. Registering the outputs at MCLK adds 9.3 ns (a ninth of a CPU
	-- clock), which lands in the same CE_F sample of the gate array as the direct outputs did, so
	-- the bus-cycle timing verified on the bench (DTACK windows at 4/8/12 CLK) is unchanged.
	process( MCLK )
	begin
		if rising_edge(MCLK) then
			r_address <= n_address;
			r_data_o  <= n_data_o;
			r_as_n    <= n_strobe_z or n_as;
			r_uds_n   <= n_strobe_z or n_uds;
			r_lds_n   <= n_strobe_z or n_lds;
			r_rnw     <= n_rw_z or n_rw;
			r_fc      <= n_fc or (n_fc_z & n_fc_z & n_fc_z);
		end if;
	end process;
	A     <= r_address;
	DO    <= r_data_o;
	AS_N  <= r_as_n;
	UDS_N <= r_uds_n;
	LDS_N <= r_lds_n;
	RNW   <= r_rnw;
	FC    <= r_fc;
	BG_N  <= n_bg;
	VMA_N <= '1';
	RESET_O_N <= not n_reset_pull;
	HALT_O_N  <= not n_halt_pull;

end rtl;
