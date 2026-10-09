-------------------------------------------------------------------------------------------------------------
--
-- File: npu_datapath.vhd
-- 
-- ██████╗  █████╗ ████████╗ █████╗ ██████╗  █████╗ ████████╗██╗  ██╗
-- ██╔══██╗██╔══██╗╚══██╔══╝██╔══██╗██╔══██╗██╔══██╗╚══██╔══╝██║  ██║
-- ██║  ██║███████║   ██║   ███████║██████╔╝███████║   ██║   ███████║
-- ██║  ██║██╔══██║   ██║   ██╔══██║██╔═══╝ ██╔══██║   ██║   ██╔══██║
-- ██████╔╝██║  ██║   ██║   ██║  ██║██║     ██║  ██║   ██║   ██║  ██║
-- ╚═════╝ ╚═╝  ╚═╝   ╚═╝   ╚═╝  ╚═╝╚═╝     ╚═╝  ╚═╝   ╚═╝   ╚═╝  ╚═╝                                                               
--
-- Descrição: NPU - Datapath (RAMs, Core, PPU, FIFO)
--            [ATUALIZADO: Remoção do offset de escrita para True Burst Alignment]
--
-- Autor    : [André Maiolini]
-- Data     : [21/01/2026]
--
-------------------------------------------------------------------------------------------------------------

library ieee;
use ieee.std_logic_1164.all;                                     
use ieee.numeric_std.all;                                        
use work.npu_pkg.all;                                            

-------------------------------------------------------------------------------------------------------------
-- ENTIDADE: Definição da interface do caminho de dados
-------------------------------------------------------------------------------------------------------------

entity npu_datapath is

    generic (
        ROWS           : integer := 4;
        COLS           : integer := 4;
        ACC_W          : integer := 32;
        DATA_W         : integer := 8;
        QUANT_W        : integer := 32;
        FIFO_DEPTH     : integer := 2048;
        DOUBLE_BUFFER  : boolean := false;    -- Retrocompatível: false = 1 banco (RTL/recursos idênticos ao legado)
        IM2COL         : boolean := true      -- false = sem hardware de im2col (IM2COL_EN passa a ser ignorado)
    );
    port (
        clk                 : in  std_logic;
        rst_n               : in  std_logic;
        soc_en_i            : in  std_logic := '1';              -- default '1': habilitado se não conectado

        -- Controle de Memória (Escrita - MMIO Fast Path)
        wgt_we              : in  std_logic;
        inp_we              : in  std_logic;
        w_data              : in  std_logic_vector(31 downto 0);
        wgt_wr_ptr          : in  unsigned(31 downto 0);
        inp_wr_ptr          : in  unsigned(31 downto 0);
        inp_base            : in  unsigned(31 downto 0) := (others => '0');  -- Destino da fusão de camadas

        -- Controle de Memória (Leitura - Controller)
        wgt_rd_ptr          : in  unsigned(31 downto 0);
        inp_rd_ptr          : in  unsigned(31 downto 0);

        -- Double Buffering (Ping-Pong): ignorado quando DOUBLE_BUFFER = false
        wr_bank             : in  std_logic := '0';
        rd_bank             : in  std_logic := '0';

        -- im2col em hardware (Inputs gerados a partir da imagem crua)
        img_we              : in  std_logic := '0';
        img_wr_ptr          : in  unsigned(31 downto 0) := (others => '0');
        cfg_im2col_en       : in  std_logic := '0';
        cfg_im_in_w         : in  unsigned(7 downto 0) := (others => '0');
        cfg_im_out_w        : in  unsigned(7 downto 0) := (others => '0');
        cfg_im_stride       : in  unsigned(3 downto 0) := (others => '0');
        cfg_im_kw           : in  unsigned(3 downto 0) := (others => '0');
        cfg_im_nwin         : in  unsigned(15 downto 0) := (others => '0');
        cfg_run_size        : in  unsigned(31 downto 0) := (others => '0');
        ctl_start           : in  std_logic := '0';
        ctl_rst_i           : in  std_logic := '0';

        -- Controle do Core
        ctl_acc_clear       : in  std_logic;
        ctl_acc_dump        : in  std_logic;
        ctl_valid_in        : in  std_logic;
        ctl_last            : in  std_logic := '0';              -- Última entrada do tile (alinhada a ctl_valid_in)
        ctl_issue           : in  std_logic := '0';              -- Leitura emitida (avança o im2col)
        im2col_ready_o      : out std_logic;                     -- Streaming: pixels do tap corrente já escritos
        cfg_overlap         : in  std_logic := '0';              -- Tiles encadeados (acumuladores sombra)
        cfg_out_loop        : in  std_logic := '0';              -- Saída vai para a RAM de Inputs (fusão de camadas)

        -- Configurações PPU
        cfg_relu            : in  std_logic;
        cfg_quant_sh        : in  std_logic_vector(4 downto 0);
        cfg_quant_zo        : in  std_logic_vector(DATA_W-1 downto 0);
        cfg_quant_mul       : in  std_logic_vector(QUANT_W-1 downto 0);
        cfg_bias_vec        : in  std_logic_vector((BIAS_TILES*COLS*ACC_W)-1 downto 0);  -- Banco: um vetor por tile
        cfg_bias_per_tile   : in  std_logic := '0';                  -- 1 = tile t usa o vetor t do banco
        cfg_bias_base       : in  unsigned(2 downto 0) := (others => '0'); -- Banco do primeiro tile
        cfg_gemv            : in  std_logic := '0';                  -- Modo GEMV (camada densa com lote 1)

        -- Saída FIFO
        fifo_pop            : in  std_logic;
        fifo_r_valid        : out std_logic;
        fifo_r_data         : out std_logic_vector(31 downto 0);
        cfg_out_order       : in  std_logic := '0';
        cfg_out_unpack      : in  std_logic := '0';
        out_space_ok        : out std_logic;                     -- Saída comporta o drain de um tile inteiro
        out_busy            : out std_logic                      -- Formatador ainda emitindo resultados
    );
end entity npu_datapath;

-------------------------------------------------------------------------------------------------------------
-- ARQUITETURA: Implementação estrutural do caminho de dados
-------------------------------------------------------------------------------------------------------------

architecture rtl of npu_datapath is

    -- Controle de Memória 
    signal wgt_ram_rdata    : std_logic_vector(31 downto 0);
    signal inp_ram_rdata    : std_logic_vector(31 downto 0);
    signal im2col_rdata     : std_logic_vector(31 downto 0);
    signal core_acts        : std_logic_vector(31 downto 0);

    -- Estágio registrado na entrada do Core: tira a leitura da BRAM (e o seletor de byte do im2col)
    -- do mesmo ciclo do MAC. O Controller conta este ciclo em C_PIPE_LATENCY.
    signal r_core_acts      : std_logic_vector(31 downto 0) := (others => '0');
    signal r_core_wgts      : std_logic_vector(31 downto 0) := (others => '0');
    signal r_core_wgts_wide : std_logic_vector(127 downto 0) := (others => '0');
    signal wgt_ram_wide     : std_logic_vector(127 downto 0);

    -- GEMV: as ROWS linhas de cada coluna guardam somas parciais (features k = r mod ROWS) e são
    -- somadas antes da PPU, porque a quantização não é linear
    type acc_vec_t is array (0 to COLS-1) of signed(ACC_W-1 downto 0);
    signal r_red_part       : acc_vec_t := (others => (others => '0'));
    signal r_red_sum        : std_logic_vector((COLS*ACC_W)-1 downto 0) := (others => '0');
    signal r_red_valid      : std_logic := '0';
    signal r_red_cnt        : integer range 0 to ROWS-1 := 0;
    signal ppu_in_valid     : std_logic;
    signal ppu_in_accs      : std_logic_vector((COLS*ACC_W)-1 downto 0);

    -- Bias por tile
    signal r_bias_idx       : integer range 0 to BIAS_TILES-1 := 0;
    signal r_bias_rows      : integer range 0 to ROWS-1 := 0;
    signal s_bias_vec       : std_logic_vector((COLS*ACC_W)-1 downto 0);
    signal r_core_valid     : std_logic := '0';
    signal wgt_wr_addr_calc : std_logic_vector(31 downto 0);
    signal wgt_rd_addr_calc : std_logic_vector(31 downto 0);
    signal inp_wr_addr_calc : std_logic_vector(31 downto 0);
    signal inp_rd_addr_calc : std_logic_vector(31 downto 0);

    -- Sinais CORE / PPU 
    signal core_valid_out   : std_logic;
    signal core_accs        : std_logic_vector((COLS*ACC_W)-1 downto 0);
    signal ppu_valid_vec    : std_logic_vector(0 to COLS-1);
    signal ppu_data_vec     : std_logic_vector((COLS*DATA_W)-1 downto 0);

    -- FIFO 
    signal ofifo_w_valid, ofifo_w_ready : std_logic;
    signal ofifo_w_data     : std_logic_vector(31 downto 0);
    signal s_fifo_rst_n     : std_logic;
    signal ofifo_count      : std_logic_vector(31 downto 0);

    -- Formatador de saída: junta as ROWS linhas de um tile e as reemite na ordem das linhas e/ou
    -- com uma ativação por palavra (formato que uma camada densa seguinte lê direto pelo DMA)
    constant C_OFIFO_DEPTH  : integer := 256;
    constant C_TILE_WORDS   : integer := ROWS * COLS;        -- Pior caso de palavras por tile (unpack)
    type out_buf_t is array (0 to ROWS-1) of std_logic_vector(31 downto 0);
    signal r_obuf           : out_buf_t := (others => (others => '0'));
    signal r_ocnt           : integer range 0 to ROWS := 0;  -- Linhas recebidas da PPU
    signal r_emit           : std_logic := '0';               -- Reemitindo o tile
    signal r_erow           : integer range 0 to ROWS-1 := 0;
    signal r_ecol           : integer range 0 to COLS-1 := 0;
    signal s_fmt_en         : std_logic;
    signal s_emit_data      : std_logic_vector(31 downto 0);
    signal s_tile_rows      : integer range 1 to ROWS;
    signal r_core_last      : std_logic := '0';
    signal s_out_ready      : std_logic;                      -- Destino da saída aceita uma palavra

    -- Fusão de camadas: a saída é gravada na RAM de Inputs a partir de I_BASE
    signal r_loop_ptr       : unsigned(31 downto 0) := (others => '0');
    signal s_out_valid      : std_logic;
    signal s_loop_we        : std_logic;
    signal s_inp_we_m       : std_logic;
    signal s_inp_waddr_m    : std_logic_vector(31 downto 0);
    signal s_inp_wdata_m    : std_logic_vector(31 downto 0);

begin

    ---------------------------------------------------------------------------------------------------------
    -- Memórias (Weights & Inputs)
    ---------------------------------------------------------------------------------------------------------
    
    -- CORREÇÃO: Remoção do "- 1" nos write pointers, pois o write enable agora é 0-latency.
    wgt_wr_addr_calc <= std_logic_vector(wgt_wr_ptr);
    inp_wr_addr_calc <= std_logic_vector(inp_wr_ptr);

    -- Os Read Pointers mantêm o "- 1" pois o npu_controller pré-incrementa síncronamente na FSM.
    -- No GEMV o Controller avança 4 palavras (uma linha da memória em bancos) por leitura
    wgt_rd_addr_calc <= std_logic_vector(wgt_rd_ptr - 4) when cfg_gemv = '1' else std_logic_vector(wgt_rd_ptr - 1);
    inp_rd_addr_calc <= std_logic_vector(inp_rd_ptr - 1);

    -- CASO 1: Buffer Único (Comportamento Legado) -----------------------------------------------------------
    -- Retrocompatível: quando DOUBLE_BUFFER = false (default), esta é a MESMA estrutura de sempre,
    -- sem qualquer mux ou recurso extra de BRAM.
    GEN_SINGLE_BUF : if not DOUBLE_BUFFER generate
    begin

        u_ram_w : entity work.wgt_mem_banked
            generic map (DEPTH => FIFO_DEPTH)
            port map (
                clk     => clk,
                wr_en   => wgt_we,
                wr_addr => wgt_wr_addr_calc,
                wr_data => w_data,
                rd_addr => wgt_rd_addr_calc,
                rd_word => wgt_ram_rdata,
                rd_wide => wgt_ram_wide
            );

        u_ram_i : entity work.ram_dual
            generic map (DATA_W => 32, DEPTH => FIFO_DEPTH)
            port map (
                clk     => clk,
                wr_en   => s_inp_we_m,
                wr_addr => s_inp_waddr_m,
                wr_data => s_inp_wdata_m,
                rd_addr => inp_rd_addr_calc,
                rd_data => inp_ram_rdata
            );

    end generate GEN_SINGLE_BUF;

    -- CASO 2: Double Buffering (Ping-Pong) -------------------------------------------------------------------
    -- Dois bancos físicos por stream (A/B). O host escreve o próximo tile no banco "wr_bank" via
    -- MMIO enquanto o Core lê o tile corrente do banco "rd_bank" — a movimentação de dados do
    -- próximo tile fica sobreposta (overlap) com a computação/drain do tile atual, em vez de ficar
    -- em série como no modo de buffer único.
    GEN_DOUBLE_BUF : if DOUBLE_BUFFER generate

        signal wgt_rdata_a, wgt_rdata_b : std_logic_vector(31 downto 0);
        signal wgt_wide_a, wgt_wide_b   : std_logic_vector(127 downto 0);
        signal inp_rdata_a, inp_rdata_b : std_logic_vector(31 downto 0);

        -- Write-enables qualificados por banco (sinais próprios: mantém os port maps abaixo como
        -- simples nomes estáticos, evitando restrições de expressão em port map dentro de generate)
        signal s_wgt_we_a, s_wgt_we_b : std_logic;
        signal s_inp_we_a, s_inp_we_b : std_logic;

    begin

        s_wgt_we_a <= wgt_we and (not wr_bank);
        s_wgt_we_b <= wgt_we and wr_bank;
        s_inp_we_a <= s_inp_we_m and (not wr_bank);
        s_inp_we_b <= s_inp_we_m and wr_bank;

        u_ram_w_a : entity work.wgt_mem_banked
            generic map (DEPTH => FIFO_DEPTH)
            port map (
                clk     => clk,
                wr_en   => s_wgt_we_a,
                wr_addr => wgt_wr_addr_calc,
                wr_data => w_data,
                rd_addr => wgt_rd_addr_calc,
                rd_word => wgt_rdata_a,
                rd_wide => wgt_wide_a
            );

        u_ram_w_b : entity work.wgt_mem_banked
            generic map (DEPTH => FIFO_DEPTH)
            port map (
                clk     => clk,
                wr_en   => s_wgt_we_b,
                wr_addr => wgt_wr_addr_calc,
                wr_data => w_data,
                rd_addr => wgt_rd_addr_calc,
                rd_word => wgt_rdata_b,
                rd_wide => wgt_wide_b
            );

        u_ram_i_a : entity work.ram_dual
            generic map (DATA_W => 32, DEPTH => FIFO_DEPTH)
            port map (
                clk     => clk,
                wr_en   => s_inp_we_a,
                wr_addr => s_inp_waddr_m,
                wr_data => s_inp_wdata_m,
                rd_addr => inp_rd_addr_calc,
                rd_data => inp_rdata_a
            );

        u_ram_i_b : entity work.ram_dual
            generic map (DATA_W => 32, DEPTH => FIFO_DEPTH)
            port map (
                clk     => clk,
                wr_en   => s_inp_we_b,
                wr_addr => s_inp_waddr_m,
                wr_data => s_inp_wdata_m,
                rd_addr => inp_rd_addr_calc,
                rd_data => inp_rdata_b
            );

        -- Mux de leitura: o Core sempre enxerga o banco "rd_bank" corrente (registrado dentro da RAM,
        -- então o mux não acrescenta latência: continua sendo 1 ciclo endereço -> dado, como no legado)
        wgt_ram_rdata <= wgt_rdata_b when rd_bank = '1' else wgt_rdata_a;
        wgt_ram_wide  <= wgt_wide_b  when rd_bank = '1' else wgt_wide_a;
        inp_ram_rdata <= inp_rdata_b when rd_bank = '1' else inp_rdata_a;

    end generate GEN_DOUBLE_BUF;

    ---------------------------------------------------------------------------------------------------------
    -- im2col em hardware: com cfg_im2col_en = 1, as janelas saem da imagem crua em vez da RAM de Inputs
    ---------------------------------------------------------------------------------------------------------

    GEN_IM2COL : if IM2COL generate
    u_im2col : entity work.npu_im2col
        generic map (LANES => ROWS)
        port map (
            clk          => clk,
            rst_n        => rst_n,
            soc_en_i     => soc_en_i,
            img_we       => img_we,
            img_wr_ptr   => img_wr_ptr,
            img_wdata    => w_data,
            cfg_in_w     => cfg_im_in_w,
            cfg_out_w    => cfg_im_out_w,
            cfg_stride   => cfg_im_stride,
            cfg_kw       => cfg_im_kw,
            cfg_nwin     => cfg_im_nwin,
            cfg_run_size => cfg_run_size,
            start        => ctl_start,
            rst_i        => ctl_rst_i,
            issue        => ctl_issue,
            ready        => im2col_ready_o,
            data_o       => im2col_rdata
        );
    end generate GEN_IM2COL;

    GEN_NO_IM2COL : if not IM2COL generate
        im2col_rdata   <= (others => '0');
        im2col_ready_o <= '1';
    end generate GEN_NO_IM2COL;

    core_acts <= im2col_rdata when (IM2COL and cfg_im2col_en = '1') else inp_ram_rdata;

    process(clk)
    begin
        if rising_edge(clk) then
            if rst_n = '0' then
                r_core_valid <= '0';
                r_core_last  <= '0';
            elsif soc_en_i = '1' then
                r_core_acts  <= core_acts;
                r_core_wgts  <= wgt_ram_rdata;
                r_core_wgts_wide <= wgt_ram_wide;
                r_core_valid <= ctl_valid_in;
                r_core_last  <= ctl_last;
            end if;
        end if;
    end process;

    ---------------------------------------------------------------------------------------------------------
    -- Core Sistólico
    ---------------------------------------------------------------------------------------------------------

    u_core : entity work.npu_core
        generic map (ROWS => ROWS, COLS => COLS, DATA_W => DATA_W, ACC_W => ACC_W)
        port map (
            clk           => clk,
            rst_n         => rst_n, 
            soc_en_i      => soc_en_i,
            acc_clear     => ctl_acc_clear,
            acc_dump      => ctl_acc_dump,
            valid_in      => r_core_valid,
            ovl_en        => cfg_overlap,
            last_in       => r_core_last,
            input_weights => r_core_wgts,
            input_acts    => r_core_acts,
            gemv_en       => cfg_gemv,
            gemv_weights  => r_core_wgts_wide,
            output_accs   => core_accs,
            valid_out     => core_valid_out
        );

    ---------------------------------------------------------------------------------------------------------
    -- GEMV: redução das ROWS linhas de cada coluna (somas parciais) num único vetor antes da PPU
    ---------------------------------------------------------------------------------------------------------

    process(clk)
        variable v_sum : signed(ACC_W-1 downto 0);
    begin
        if rising_edge(clk) then
            if s_fifo_rst_n = '0' then
                r_red_cnt   <= 0;
                r_red_valid <= '0';
            elsif soc_en_i = '1' then
                r_red_valid <= '0';
                if cfg_gemv = '1' and core_valid_out = '1' then
                    for c in 0 to COLS-1 loop
                        if r_red_cnt = 0 then
                            v_sum := signed(core_accs((c+1)*ACC_W-1 downto c*ACC_W));
                        else
                            v_sum := r_red_part(c) + signed(core_accs((c+1)*ACC_W-1 downto c*ACC_W));
                        end if;
                        r_red_part(c) <= v_sum;
                        r_red_sum((c+1)*ACC_W-1 downto c*ACC_W) <= std_logic_vector(v_sum);
                    end loop;
                    if r_red_cnt = ROWS - 1 then
                        r_red_cnt   <= 0;
                        r_red_valid <= '1';
                    else
                        r_red_cnt   <= r_red_cnt + 1;
                    end if;
                end if;
            end if;
        end if;
    end process;

    ppu_in_valid <= r_red_valid when cfg_gemv = '1' else core_valid_out;
    ppu_in_accs  <= r_red_sum   when cfg_gemv = '1' else core_accs;

    ---------------------------------------------------------------------------------------------------------
    -- Bias por tile: o tile t de uma sequência usa o vetor t do banco (BIAS_PER_TILE); sem a opção,
    -- vale sempre o vetor 0 (registradores 0x80..0x8C, comportamento original)
    ---------------------------------------------------------------------------------------------------------

    process(clk)
    begin
        if rising_edge(clk) then
            if rst_n = '0' then
                r_bias_idx  <= 0;
                r_bias_rows <= 0;
            elsif ctl_start = '1' then
                -- Cada camada começa no seu banco: os biases de várias camadas ficam residentes
                r_bias_idx  <= to_integer(cfg_bias_base);
                r_bias_rows <= 0;
            elsif soc_en_i = '1' and cfg_bias_per_tile = '1' then
                -- Um tile termina de entrar na PPU no último dump (normal) ou na saída da redução (GEMV)
                if cfg_gemv = '1' then
                    if r_red_valid = '1' then
                        r_bias_idx <= (r_bias_idx + 1) mod BIAS_TILES;
                    end if;
                elsif core_valid_out = '1' then
                    if r_bias_rows = ROWS - 1 then
                        r_bias_rows <= 0;
                        r_bias_idx  <= (r_bias_idx + 1) mod BIAS_TILES;
                    else
                        r_bias_rows <= r_bias_rows + 1;
                    end if;
                end if;
            end if;
        end if;
    end process;

    s_bias_vec <= cfg_bias_vec((r_bias_idx+1)*COLS*ACC_W-1 downto r_bias_idx*COLS*ACC_W);

    ---------------------------------------------------------------------------------------------------------
    -- Post Processing Units (PPU)
    ---------------------------------------------------------------------------------------------------------

    GEN_PPU : for i in 0 to COLS-1 generate
        u_ppu : entity work.post_process
            port map (
                clk         => clk,
                rst_n       => rst_n,
                soc_en_i    => soc_en_i,
                valid_in    => ppu_in_valid,
                acc_in      => ppu_in_accs((i+1)*ACC_W-1 downto i*ACC_W),
                bias_in     => s_bias_vec((i+1)*ACC_W-1 downto i*ACC_W),
                quant_mult  => cfg_quant_mul,
                quant_shift => cfg_quant_sh,
                zero_point  => cfg_quant_zo,
                en_relu     => cfg_relu,
                valid_out   => ppu_valid_vec(i),
                data_out    => ppu_data_vec((i+1)*DATA_W-1 downto i*DATA_W)
            );
    end generate;

    ---------------------------------------------------------------------------------------------------------
    -- Output FIFO
    ---------------------------------------------------------------------------------------------------------

    -- No modo encadeado as linhas já saem do array na ordem 0..ROWS-1 e o formatador fica de
    -- fora (UNPACK não é suportado nesse modo)
    s_fmt_en    <= (cfg_out_order or cfg_out_unpack) and not cfg_overlap;
    s_tile_rows <= 1 when cfg_gemv = '1' else ROWS;           -- Palavras que a PPU entrega por tile

    -- Palavra reemitida: a linha inteira, ou um byte dela estendido com zeros
    process(r_obuf, r_erow, r_ecol, cfg_out_unpack)
        variable v_word : unsigned(31 downto 0);
    begin
        v_word := shift_right(unsigned(r_obuf(r_erow)), 8 * r_ecol);
        if cfg_out_unpack = '1' then
            s_emit_data <= x"000000" & std_logic_vector(v_word(7 downto 0));
        else
            s_emit_data <= r_obuf(r_erow);
        end if;
    end process;

    process(clk)
        variable v_slot : integer range 0 to ROWS-1;
    begin
        if rising_edge(clk) then
            if s_fifo_rst_n = '0' or s_fmt_en = '0' then
                r_ocnt <= 0;
                r_emit <= '0';
                r_erow <= 0;
                r_ecol <= 0;
            elsif soc_en_i = '1' then

                if r_emit = '0' then
                    -- Coleta: a PPU entrega a última linha primeiro (no GEMV, uma palavra por tile)
                    if ppu_valid_vec(0) = '1' then
                        if cfg_gemv = '1' then
                            v_slot := 0;
                        elsif cfg_out_order = '1' then
                            v_slot := ROWS - 1 - r_ocnt;
                        else
                            v_slot := r_ocnt;
                        end if;
                        r_obuf(v_slot) <= std_logic_vector(resize(unsigned(ppu_data_vec), 32));
                        if r_ocnt = s_tile_rows - 1 then
                            r_ocnt <= 0;
                            r_emit <= '1';
                        else
                            r_ocnt <= r_ocnt + 1;
                        end if;
                    end if;

                elsif s_out_ready = '1' then
                    -- Reemissão: uma palavra por ciclo, enquanto a FIFO aceitar
                    if cfg_out_unpack = '1' and r_ecol /= COLS - 1 then
                        r_ecol <= r_ecol + 1;
                    else
                        r_ecol <= 0;
                        if r_erow = s_tile_rows - 1 then
                            r_erow <= 0;
                            r_emit <= '0';
                        else
                            r_erow <= r_erow + 1;
                        end if;
                    end if;
                end if;

            end if;
        end if;
    end process;

    s_out_valid   <= r_emit when s_fmt_en = '1' else ppu_valid_vec(0);
    ofifo_w_data  <= s_emit_data when s_fmt_en = '1' else std_logic_vector(resize(unsigned(ppu_data_vec), 32));

    -- Destino da saída: FIFO (O_DATA) ou, na fusão de camadas, a RAM de Inputs
    ofifo_w_valid <= s_out_valid and not cfg_out_loop;
    s_out_ready   <= '1' when cfg_out_loop = '1' else ofifo_w_ready;
    s_loop_we     <= s_out_valid and cfg_out_loop;

    process(clk)
    begin
        if rising_edge(clk) then
            if rst_n = '0' or ctl_start = '1' then
                r_loop_ptr <= inp_base;
            elsif s_loop_we = '1' and soc_en_i = '1' then
                r_loop_ptr <= r_loop_ptr + 1;
            end if;
        end if;
    end process;

    s_inp_we_m    <= inp_we or s_loop_we;
    s_inp_waddr_m <= std_logic_vector(r_loop_ptr) when s_loop_we = '1' else inp_wr_addr_calc;
    s_inp_wdata_m <= ofifo_w_data when s_loop_we = '1' else w_data;

    -- Backpressure: o Controller só esvazia um tile quando ele cabe inteiro na FIFO. Encadeado,
    -- até 3 tiles podem estar a caminho da saída quando um novo tile começa.
    out_space_ok <= '1' when r_emit = '0' and
                             (cfg_out_loop = '1' or
                              (cfg_overlap = '0' and unsigned(ofifo_count) <= C_OFIFO_DEPTH - C_TILE_WORDS - 8) or
                              (cfg_overlap = '1' and unsigned(ofifo_count) <= C_OFIFO_DEPTH - 3*C_TILE_WORDS - 8))
                    else '0';
    out_busy     <= r_emit;

    -- Reset da FIFO
    s_fifo_rst_n  <= rst_n and not ctl_acc_clear;

    u_ofifo : entity work.fifo_sync
        generic map (DATA_W => 32, DEPTH => C_OFIFO_DEPTH) 
        port map (
            clk     => clk, 
            rst_n   => s_fifo_rst_n,
            w_valid => ofifo_w_valid, 
            w_ready => ofifo_w_ready, 
            w_data  => ofifo_w_data,
            r_valid => fifo_r_valid, 
            r_ready => fifo_pop, 
            r_data  => fifo_r_data,
            count   => ofifo_count
        );

end architecture;