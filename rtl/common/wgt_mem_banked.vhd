-------------------------------------------------------------------------------------------------------------
--
-- File: wgt_mem_banked.vhd
--
-- Descrição: Memória de Pesos em 4 bancos intercalados (palavra a no banco a mod 4, linha a / 4).
--
--            A escrita continua sendo de uma palavra de 32 bits por vez (porta W_PORT / DMA). A leitura
--            entrega, com latência de 1 ciclo:
--              rd_word : a palavra de 32 bits do endereço rd_addr (modo normal);
--              rd_wide : as 4 palavras consecutivas da linha rd_addr / 4, palavra rd_addr(1:0)=0 nos bits
--                        baixos (modo GEMV: um peso distinto para cada PE do array 4x4 por ciclo).
--
-------------------------------------------------------------------------------------------------------------

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity wgt_mem_banked is

    generic (
        DEPTH   : integer := 2048                                -- Capacidade total em palavras de 32 bits
    );

    port (
        clk     : in  std_logic;

        wr_en   : in  std_logic;
        wr_addr : in  std_logic_vector(31 downto 0);
        wr_data : in  std_logic_vector(31 downto 0);

        rd_addr : in  std_logic_vector(31 downto 0);
        rd_word : out std_logic_vector(31 downto 0);
        rd_wide : out std_logic_vector(127 downto 0)
    );

end entity wgt_mem_banked;

architecture rtl of wgt_mem_banked is

    type word_arr_t is array (0 to 3) of std_logic_vector(31 downto 0);

    signal s_bank_we   : std_logic_vector(0 to 3);
    signal s_wr_row    : std_logic_vector(31 downto 0);
    signal s_rd_row    : std_logic_vector(31 downto 0);
    signal s_rd_data   : word_arr_t;
    signal r_sel       : std_logic_vector(1 downto 0) := (others => '0');

begin

    s_wr_row <= "00" & wr_addr(31 downto 2);
    s_rd_row <= "00" & rd_addr(31 downto 2);

    GEN_BANKS : for b in 0 to 3 generate
        s_bank_we(b) <= wr_en when unsigned(wr_addr(1 downto 0)) = b else '0';

        u_bank : entity work.ram_dual
            generic map (DATA_W => 32, DEPTH => DEPTH / 4)
            port map (
                clk     => clk,
                wr_en   => s_bank_we(b),
                wr_addr => s_wr_row,
                wr_data => wr_data,
                rd_addr => s_rd_row,
                rd_data => s_rd_data(b)
            );

        rd_wide((b+1)*32-1 downto b*32) <= s_rd_data(b);
    end generate GEN_BANKS;

    -- Banco da palavra lida acompanha a latência da RAM
    process(clk)
    begin
        if rising_edge(clk) then
            r_sel <= rd_addr(1 downto 0);
        end if;
    end process;

    with r_sel select rd_word <=
        s_rd_data(0) when "00",
        s_rd_data(1) when "01",
        s_rd_data(2) when "10",
        s_rd_data(3) when others;

end architecture; -- rtl

-------------------------------------------------------------------------------------------------------------
