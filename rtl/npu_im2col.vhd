-------------------------------------------------------------------------------------------------------------
--
-- File: npu_im2col.vhd
--
-- Descrição: NPU - Gerador de janelas im2col em hardware
--
--            Guarda a imagem crua (1 byte por pixel, 4 pixels por palavra) e monta, a cada leitura do
--            Controller, a palavra de entrada do array: o byte r é o pixel do tap corrente na janela
--            atribuída à linha r. Cada passagem (START) consome um grupo de LANES janelas consecutivas,
--            com K = cfg_run_size taps; ao fim do grupo, cada linha avança LANES janelas.
--
--            Geometria (registradores da NPU):
--              in_w   : largura da imagem (pixels por linha)
--              out_w  : janelas por linha da saída       (deve ser >= LANES)
--              stride : passo da janela
--              kw     : largura do kernel (taps por linha do kernel)
--              nwin   : total de janelas; as excedentes do último grupo leem zero
--
--            A imagem é replicada em LANES RAMs (uma por linha do array), para que cada linha leia o seu
--            pixel no mesmo ciclo. As escritas chegam pela porta IMG (0x1C) e vão para todas as cópias.
--
-------------------------------------------------------------------------------------------------------------

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

-------------------------------------------------------------------------------------------------------------
-- ENTIDADE
-------------------------------------------------------------------------------------------------------------

entity npu_im2col is

    generic (
        LANES       : integer := 4;                              -- Linhas do array (janelas por grupo)
        IMG_WORDS   : integer := 256                             -- Capacidade da imagem (palavras de 4 pixels)
    );

    port (
        clk         : in  std_logic;
        rst_n       : in  std_logic;
        soc_en_i    : in  std_logic := '1';

        -- Escrita da imagem (porta IMG)
        img_we      : in  std_logic;
        img_wr_ptr  : in  unsigned(31 downto 0);
        img_wdata   : in  std_logic_vector(31 downto 0);

        -- Geometria
        cfg_in_w    : in  unsigned(7 downto 0);
        cfg_out_w   : in  unsigned(7 downto 0);
        cfg_stride  : in  unsigned(3 downto 0);
        cfg_kw      : in  unsigned(3 downto 0);
        cfg_nwin    : in  unsigned(15 downto 0);
        cfg_run_size: in  unsigned(31 downto 0);

        -- Sequenciamento (Controller)
        start       : in  std_logic;                             -- Pulso de START (reinicia os taps)
        rst_i       : in  std_logic;                             -- RST_I_RD no START: volta à janela 0
        issue       : in  std_logic;                             -- Leitura emitida pelo Controller (consome um tap)

        -- Streaming: 1 = os pixels do tap corrente (em todas as janelas válidas) já foram escritos
        ready       : out std_logic;

        -- Palavra de entrada do array (1 ciclo depois da leitura, alinhada à RAM de Inputs)
        data_o      : out std_logic_vector(LANES*8-1 downto 0)
    );

end entity npu_im2col;

-------------------------------------------------------------------------------------------------------------
-- ARQUITETURA
-------------------------------------------------------------------------------------------------------------

architecture rtl of npu_im2col is

    type addr_arr_t is array (0 to LANES-1) of unsigned(15 downto 0);
    type col_arr_t  is array (0 to LANES-1) of unsigned(7 downto 0);
    type word_arr_t is array (0 to LANES-1) of std_logic_vector(31 downto 0);
    type sel_arr_t  is array (0 to LANES-1) of unsigned(1 downto 0);

    -- Tap corrente (comum a todas as linhas)
    signal r_tap_off  : unsigned(15 downto 0) := (others => '0');   -- Deslocamento do tap na imagem
    signal r_tap_col  : unsigned(3 downto 0)  := (others => '0');   -- Coluna do tap no kernel
    signal r_tap_cnt  : unsigned(31 downto 0) := (others => '0');   -- Taps consumidos no grupo

    -- Janela corrente de cada linha
    signal r_base     : addr_arr_t := (others => (others => '0'));  -- Pixel do canto da janela
    signal r_col      : col_arr_t  := (others => (others => '0'));  -- Coluna da janela na saída
    signal r_win      : addr_arr_t := (others => (others => '0'));  -- Índice da janela

    -- Passos do avanço de grupo (sem e com quebra de linha da saída)
    signal s_step     : unsigned(15 downto 0);
    signal s_step_wrap: unsigned(15 downto 0);
    signal s_row_jump : unsigned(15 downto 0);

    -- Endereço capturado na emissão (a RAM o lê no ciclo seguinte, junto com a RAM de Inputs)
    signal r_addr     : addr_arr_t := (others => (others => '0'));
    signal r_vld_i    : std_logic_vector(0 to LANES-1) := (others => '0');
    signal s_lane_ok  : std_logic_vector(0 to LANES-1);

    -- Leitura (1 ciclo de latência)
    signal s_rd_word  : word_arr_t;
    signal r_sel      : sel_arr_t := (others => (others => '0'));
    signal r_valid    : std_logic_vector(0 to LANES-1) := (others => '0');

begin

    -- s_step      = LANES * stride
    -- s_step_wrap = LANES * stride + stride * (in_w - out_w)   (desce uma linha de janelas)
    -- s_row_jump  = in_w - (kw - 1)                             (próxima linha do kernel)
    s_step      <= resize(to_unsigned(LANES, 8) * cfg_stride, 16);
    s_step_wrap <= s_step + resize(cfg_stride * (cfg_in_w - cfg_out_w), 16);
    s_row_jump  <= resize(cfg_in_w - resize(cfg_kw - 1, 8), 16);

    ---------------------------------------------------------------------------------------------------------
    -- Cópias da imagem: uma RAM por linha, todas escritas juntas
    ---------------------------------------------------------------------------------------------------------

    GEN_LANES : for r in 0 to LANES-1 generate
        signal s_addr    : unsigned(15 downto 0);
        signal s_rd_addr : std_logic_vector(31 downto 0);
        signal s_wr_addr : std_logic_vector(31 downto 0);
    begin
        s_addr    <= r_base(r) + r_tap_off;                      -- Tap corrente (ainda não emitido)
        s_rd_addr <= std_logic_vector(resize(r_addr(r)(15 downto 2), 32));

        -- Streaming: o pixel do tap corrente já chegou (ou a janela é de preenchimento)
        s_lane_ok(r) <= '1' when r_win(r) >= cfg_nwin or resize(s_addr(15 downto 2), 32) < img_wr_ptr else '0';
        s_wr_addr <= std_logic_vector(img_wr_ptr);

        u_img : entity work.ram_dual
            generic map (DATA_W => 32, DEPTH => IMG_WORDS)
            port map (
                clk     => clk,
                wr_en   => img_we,
                wr_addr => s_wr_addr,
                wr_data => img_wdata,
                rd_addr => s_rd_addr,
                rd_data => s_rd_word(r)
            );

        -- Byte e validade acompanham a latência da RAM
        process(clk)
        begin
            if rising_edge(clk) then
                r_sel(r)   <= r_addr(r)(1 downto 0);
                r_valid(r) <= r_vld_i(r);
            end if;
        end process;

        -- Seleção do pixel dentro da palavra (little-endian: pixel 4w+b no byte b)
        process(s_rd_word, r_sel, r_valid)
        begin
            if r_valid(r) = '0' then
                data_o(r*8+7 downto r*8) <= (others => '0');
            else
                case r_sel(r) is
                    when "00"   => data_o(r*8+7 downto r*8) <= s_rd_word(r)(7 downto 0);
                    when "01"   => data_o(r*8+7 downto r*8) <= s_rd_word(r)(15 downto 8);
                    when "10"   => data_o(r*8+7 downto r*8) <= s_rd_word(r)(23 downto 16);
                    when others => data_o(r*8+7 downto r*8) <= s_rd_word(r)(31 downto 24);
                end case;
            end if;
        end process;
    end generate GEN_LANES;

    ready <= '1' when s_lane_ok = (s_lane_ok'range => '1') else '0';

    ---------------------------------------------------------------------------------------------------------
    -- Sequenciamento de taps e janelas
    ---------------------------------------------------------------------------------------------------------

    process(clk)
    begin
        if rising_edge(clk) then
            if rst_n = '0' then
                r_tap_off <= (others => '0');
                r_tap_col <= (others => '0');
                r_tap_cnt <= (others => '0');
                for r in 0 to LANES-1 loop
                    r_base(r) <= resize(to_unsigned(r, 8) * cfg_stride, 16);
                    r_col(r)  <= to_unsigned(r, 8);
                    r_win(r)  <= to_unsigned(r, 16);
                end loop;

            elsif soc_en_i = '1' then

                if start = '1' then
                    r_tap_off <= (others => '0');
                    r_tap_col <= (others => '0');
                    r_tap_cnt <= (others => '0');

                    if rst_i = '1' then
                        for r in 0 to LANES-1 loop
                            r_base(r) <= resize(to_unsigned(r, 8) * cfg_stride, 16);
                            r_col(r)  <= to_unsigned(r, 8);
                            r_win(r)  <= to_unsigned(r, 16);
                        end loop;
                    end if;

                elsif issue = '1' then

                    -- Captura o endereço e a validade do tap emitido (lidos no ciclo seguinte)
                    for r in 0 to LANES-1 loop
                        r_addr(r) <= r_base(r) + r_tap_off;
                        if r_win(r) < cfg_nwin then r_vld_i(r) <= '1'; else r_vld_i(r) <= '0'; end if;
                    end loop;

                    if r_tap_cnt = cfg_run_size - 1 then
                        -- Fim do grupo: volta ao primeiro tap e avança LANES janelas em cada linha
                        r_tap_off <= (others => '0');
                        r_tap_col <= (others => '0');
                        r_tap_cnt <= (others => '0');

                        for r in 0 to LANES-1 loop
                            r_win(r) <= r_win(r) + LANES;
                            if r_col(r) + LANES >= cfg_out_w then
                                r_col(r)  <= r_col(r) + LANES - cfg_out_w;
                                r_base(r) <= r_base(r) + s_step_wrap;
                            else
                                r_col(r)  <= r_col(r) + LANES;
                                r_base(r) <= r_base(r) + s_step;
                            end if;
                        end loop;

                    else
                        r_tap_cnt <= r_tap_cnt + 1;
                        if r_tap_col = cfg_kw - 1 then
                            r_tap_col <= (others => '0');
                            r_tap_off <= r_tap_off + s_row_jump;
                        else
                            r_tap_col <= r_tap_col + 1;
                            r_tap_off <= r_tap_off + 1;
                        end if;
                    end if;

                end if;
            end if;
        end if;
    end process;

end architecture; -- rtl

-------------------------------------------------------------------------------------------------------------
