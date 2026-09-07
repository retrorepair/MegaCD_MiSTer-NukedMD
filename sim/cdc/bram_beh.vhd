-- Behavioural stand-ins for the Altera-IP RAM entities in rtl/bram.vhd, so rtl/MCD/MCD.vhd
-- compiles in ModelSim without the altera_mf library. Interfaces match bram.vhd exactly.
-- Covers the widths MCD.vhd uses: spram(16,16) word RAM, dpram_dif(14,8,13,16) CDC buffer.
library IEEE; use IEEE.STD_LOGIC_1164.ALL; use IEEE.NUMERIC_STD.ALL;

entity spram is
   generic ( addr_width : integer := 8; data_width : integer := 8;
             mem_init_file : string := " "; mem_name : string := "MEM" );
   port ( clock   : in  std_logic;
          address : in  std_logic_vector(addr_width-1 downto 0);
          data    : in  std_logic_vector(data_width-1 downto 0) := (others=>'0');
          enable  : in  std_logic := '1';
          wren    : in  std_logic := '0';
          byteena : in  std_logic_vector((data_width/8)-1 downto 0) := (others=>'1');
          q       : out std_logic_vector(data_width-1 downto 0);
          cs      : in  std_logic := '1' );
end spram;
architecture beh of spram is
   type mem_t is array(0 to 2**addr_width-1) of std_logic_vector(data_width-1 downto 0);
   signal mem : mem_t := (others => (others => '0'));
begin
   process(clock) begin
      if rising_edge(clock) then
         if enable = '1' then
            if wren = '1' then
               for i in 0 to (data_width/8)-1 loop
                  if byteena(i) = '1' then
                     mem(to_integer(unsigned(address)))(i*8+7 downto i*8) <= data(i*8+7 downto i*8);
                  end if;
               end loop;
            end if;
            q <= mem(to_integer(unsigned(address)));
         end if;
      end if;
   end process;
end beh;

library IEEE; use IEEE.STD_LOGIC_1164.ALL; use IEEE.NUMERIC_STD.ALL;
-- dpram_dif: port A = byte (data_width_a=8) read/write, port B = word (data_width_b=16) read/write,
-- sharing a 2**addr_width_a-byte memory (matches the CDC decoder buffer 14/8 read, 13/16 write).
entity dpram_dif is
   generic ( addr_width_a : integer := 8; data_width_a : integer := 8;
             addr_width_b : integer := 8; data_width_b : integer := 8;
             mem_init_file : string := " " );
   port ( clock      : in  std_logic;
          address_a  : in  std_logic_vector(addr_width_a-1 downto 0);
          data_a     : in  std_logic_vector(data_width_a-1 downto 0) := (others=>'0');
          enable_a   : in  std_logic := '1';
          wren_a     : in  std_logic := '0';
          byteena_a  : in  std_logic_vector((data_width_a/8)-1 downto 0) := (others=>'1');
          q_a        : out std_logic_vector(data_width_a-1 downto 0);
          cs_a       : in  std_logic := '1';
          address_b  : in  std_logic_vector(addr_width_b-1 downto 0) := (others=>'0');
          data_b     : in  std_logic_vector(data_width_b-1 downto 0) := (others=>'0');
          enable_b   : in  std_logic := '1';
          wren_b     : in  std_logic := '0';
          byteena_b  : in  std_logic_vector((data_width_b/8)-1 downto 0) := (others=>'1');
          q_b        : out std_logic_vector(data_width_b-1 downto 0);
          cs_b       : in  std_logic := '1' );
end dpram_dif;
architecture beh of dpram_dif is
   type mem_t is array(0 to 2**addr_width_a-1) of std_logic_vector(7 downto 0);   -- byte memory
   signal mem : mem_t := (others => (others => '0'));
begin
   process(clock)
      variable ba : integer;
   begin
      if rising_edge(clock) then
         -- port B (word) write
         if enable_b = '1' and wren_b = '1' then
            ba := to_integer(unsigned(address_b)) * 2;
            if byteena_b(0) = '1' then mem(ba)   <= data_b(7 downto 0);  end if;
            if byteena_b(1) = '1' then mem(ba+1) <= data_b(15 downto 8); end if;
         end if;
         -- port A (byte) write
         if enable_a = '1' and wren_a = '1' then
            mem(to_integer(unsigned(address_a))) <= data_a;
         end if;
         -- registered reads
         if enable_a = '1' then q_a <= mem(to_integer(unsigned(address_a))); end if;
         if enable_b = '1' then
            ba := to_integer(unsigned(address_b)) * 2;
            q_b <= mem(ba+1) & mem(ba);
         end if;
      end if;
   end process;
end beh;

library IEEE; use IEEE.STD_LOGIC_1164.ALL; use IEEE.NUMERIC_STD.ALL;
entity dpram is
   generic ( addr_width : integer := 8; data_width : integer := 8; mem_init_file : string := " " );
   port ( clock     : in  std_logic;
          address_a : in  std_logic_vector(addr_width-1 downto 0);
          data_a    : in  std_logic_vector(data_width-1 downto 0) := (others=>'0');
          enable_a  : in  std_logic := '1';
          wren_a    : in  std_logic := '0';
          byteena_a : in  std_logic_vector((data_width/8)-1 downto 0) := (others=>'1');
          q_a       : out std_logic_vector(data_width-1 downto 0);
          cs_a      : in  std_logic := '1';
          address_b : in  std_logic_vector(addr_width-1 downto 0) := (others=>'0');
          data_b    : in  std_logic_vector(data_width-1 downto 0) := (others=>'0');
          enable_b  : in  std_logic := '1';
          wren_b    : in  std_logic := '0';
          byteena_b : in  std_logic_vector((data_width/8)-1 downto 0) := (others=>'1');
          q_b       : out std_logic_vector(data_width-1 downto 0);
          cs_b      : in  std_logic := '1' );
end dpram;
architecture beh of dpram is
   type mem_t is array(0 to 2**addr_width-1) of std_logic_vector(data_width-1 downto 0);
   signal mem : mem_t := (others => (others => '0'));
begin
   process(clock) begin
      if rising_edge(clock) then
         if enable_a = '1' and wren_a = '1' then mem(to_integer(unsigned(address_a))) <= data_a; end if;
         if enable_b = '1' and wren_b = '1' then mem(to_integer(unsigned(address_b))) <= data_b; end if;
         if enable_a = '1' then q_a <= mem(to_integer(unsigned(address_a))); end if;
         if enable_b = '1' then q_b <= mem(to_integer(unsigned(address_b))); end if;
      end if;
   end process;
end beh;
