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
		CLKEN_P 		: in std_logic;
		CLKEN_N 		: in std_logic;
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

begin

	-- 12.5 MHz CLK level from the clock generator's edge enables
	process(CLK)
	begin
		if rising_edge(CLK) then
			if CLKEN_P = '1' then
				cpu_clk <= '1';
			elsif CLKEN_N = '1' then
				cpu_clk <= '0';
			end if;
		end if;
	end process;

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

	-- Bus outputs registered in the 53.69 MHz Mega CD domain: the model's pins move on MCLK
	-- edges while the gate array, CDC and PCM decode them combinationally in the CLK domain;
	-- one CLK stage (the bus buffers of the real board) gives that decode a full CLK period.
	-- Released (high-Z) pins read as pulled up, as md_board does for the main CPU.
	process(CLK)
	begin
		if rising_edge(CLK) then
			A     <= n_address;
			DO    <= n_data_o;
			AS_N  <= n_strobe_z or n_as;
			UDS_N <= n_strobe_z or n_uds;
			LDS_N <= n_strobe_z or n_lds;
			RNW   <= n_rw_z or n_rw;
			FC    <= n_fc or (n_fc_z & n_fc_z & n_fc_z);
		end if;
	end process;
	BG_N  <= n_bg;
	VMA_N <= '1';
	RESET_O_N <= not n_reset_pull;
	HALT_O_N  <= not n_halt_pull;

end rtl;
