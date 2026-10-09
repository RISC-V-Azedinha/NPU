-------------------------------------------------------------------------------------------------------------
--
-- File: npu_controller.vhd
-- 
--  ██████╗ ██████╗ ███╗   ██╗████████╗██████╗  ██████╗ ██╗     ██╗     ███████╗██████╗ 
-- ██╔════╝██╔═══██╗████╗  ██║╚══██╔══╝██╔══██╗██╔═══██╗██║     ██║     ██╔════╝██╔══██╗
-- ██║     ██║   ██║██╔██╗ ██║   ██║   ██████╔╝██║   ██║██║     ██║     █████╗  ██████╔╝
-- ██║     ██║   ██║██║╚██╗██║   ██║   ██╔══██╗██║   ██║██║     ██║     ██╔══╝  ██╔══██╗
-- ╚██████╗╚██████╔╝██║ ╚████║   ██║   ██║  ██║╚██████╔╝███████╗███████╗███████╗██║  ██║
--  ╚═════╝ ╚═════╝ ╚═╝  ╚═══╝   ╚═╝   ╚═╝  ╚═╝ ╚═════╝ ╚══════╝╚══════╝╚══════╝╚═╝  ╚═╝                                                                                  
--
-- Descrição: NPU - Micro-Sequencer Controller (FSM)
--
-- Autor    : [André Maiolini]
-- Data     : [21/01/2026]
--
-------------------------------------------------------------------------------------------------------------

library ieee;                                                    -- Biblioteca padrão IEEE
use ieee.std_logic_1164.all;                                     -- Tipos de lógica digital
use ieee.numeric_std.all;                                        -- Tipos numéricos (signed, unsigned)
use work.npu_pkg.all;                                            -- Pacote de definições do NPU

-------------------------------------------------------------------------------------------------------------
-- ENTIDADE: Definição da interface do controlador (FSM)
-------------------------------------------------------------------------------------------------------------

entity npu_controller is

    generic (
    
        ROWS          : integer := 4;                            -- Quantidade de Linhas do Array Sistólico
        COLS          : integer := 4                             -- Quantidade de Colunas do Array Sistólico
    
    );

    port (

        -----------------------------------------------------------------------------------------------------
        -- Sinais de Controle e Sincronização
        -----------------------------------------------------------------------------------------------------

        clk           : in  std_logic;
        rst_n         : in  std_logic;
        soc_en_i      : in  std_logic := '1';                    -- Default '1': testbenches que não conectam este pino continuam habilitadas (retrocompatível com npu_fpga_top, que já amarra em '1')

        -----------------------------------------------------------------------------------------------------
        -- Interface Register File
        -----------------------------------------------------------------------------------------------------

        cmd_start     : in  std_logic;
        cmd_no_drain  : in  std_logic;
        cmd_rst_w     : in  std_logic;                           -- Reset Wgt Ptr
        cmd_rst_i     : in  std_logic;                           -- Reset Inp Ptr
        cmd_dbuf_en   : in  std_logic := '0';                    -- Double Buffering neste START (Ping-Pong)
        cfg_run_size  : in  unsigned(31 downto 0);
        wgt_base      : in  unsigned(31 downto 0) := (others => '0'); -- Destino de RST_W_RD
        inp_base      : in  unsigned(31 downto 0) := (others => '0'); -- Destino de RST_I_RD

        -- Sequenciador de tiles: um START executa cfg_tiles tiles (0/1 = um tile, legado)
        cfg_tiles     : in  unsigned(15 downto 0) := (others => '0');
        cfg_tile_rw_w : in  std_logic := '0';                    -- A cada tile, Pesos voltam a wgt_base
        cfg_tile_rw_i : in  std_logic := '0';                    -- A cada tile, Inputs voltam a inp_base
        cfg_gemv      : in  std_logic := '0';                    -- GEMV: Pesos avançam 4 palavras por leitura

        -- Streaming: uma leitura só é emitida quando o dado já chegou (a carga por DMA pode
        -- acontecer depois do START, em paralelo com o cômputo)
        cfg_stream_i  : in  std_logic := '0';                    -- Espera os Inputs (RAM ou imagem do im2col)
        cfg_stream_w  : in  std_logic := '0';                    -- Espera os Pesos
        inp_wr_ptr    : in  unsigned(31 downto 0) := (others => '0');
        wgt_wr_ptr    : in  unsigned(31 downto 0) := (others => '0');
        cfg_im2col_en : in  std_logic := '0';
        im2col_ready  : in  std_logic := '1';                    -- Pixels do tap corrente já escritos

        -- Tiles encadeados: os tiles seguem sem pausa e o array entrega cada tile sozinho
        -- (acumuladores sombra nos PEs); exige CONFIG >= COLS + 1
        cfg_overlap   : in  std_logic := '0';
        ctl_issue     : out std_logic;                           -- Leitura emitida neste ciclo (combinacional)
        ctl_core_last : out std_logic;                           -- Última leitura do tile (alinhada a ctl_core_vld)

        -----------------------------------------------------------------------------------------------------
        -- Sinais de Saída (Status e Controle)
        -----------------------------------------------------------------------------------------------------

        sts_busy      : out std_logic;
        sts_done      : out std_logic;
        
        -----------------------------------------------------------------------------------------------------
        -- Controle do Pipeline
        -----------------------------------------------------------------------------------------------------

        wgt_rd_ptr    : out unsigned(31 downto 0);
        inp_rd_ptr    : out unsigned(31 downto 0);

        ctl_ram_re    : out std_logic;                           -- Read Enable
        ctl_core_vld  : out std_logic;                           -- Valid In (Delayed)
        ctl_acc_dump  : out std_logic;

        -- Double Buffering: banco lido pelo Core / banco liberado para escrita (MMIO)
        rd_bank_o     : out std_logic;
        wr_bank_o     : out std_logic;

        -----------------------------------------------------------------------------------------------------
        -- Backpressure
        -----------------------------------------------------------------------------------------------------

        out_space_ok  : in  std_logic;                           -- 1 = Saída comporta o drain de um tile inteiro
        out_busy      : in  std_logic := '0'                     -- 1 = Ainda há resultados a caminho da FIFO

        -----------------------------------------------------------------------------------------------------

    );

end entity npu_controller;

-------------------------------------------------------------------------------------------------------------
-- ARQUITETURA: Implementação comportamental do controlador (FSM)
-------------------------------------------------------------------------------------------------------------

architecture rtl of npu_controller is

    -- Constantes de Latência -------------------------------------------------------------------------------

    constant C_PIPE_LATENCY : integer := 1 + 1 + 1 + (ROWS + COLS);   -- BRAM + registro de entrada do Core + skew
    constant C_FLUSH_LATENCY: integer := 8;                           -- Redução GEMV + PPU (4 estágios) + FIFO

    -- Estados da FSM ---------------------------------------------------------------------------------------

    type state_t is (IDLE, COMPUTE, DRAIN, FLUSH);

    signal s_in_ok      : std_logic;
    signal s_w_ok       : std_logic;
    signal s_issue      : std_logic;
    signal s_wgt_step   : unsigned(31 downto 0);
    signal s_tile_end   : boolean;                                -- Esta leitura fecha o tile
    signal r_last       : std_logic := '0';
    signal r_ovl        : std_logic := '0';                        -- Tiles encadeados nesta execução

    -- Volta à base pendente: o datapath lê o endereço (ponteiro - passo) no ciclo seguinte à
    -- emissão, então a última leitura de um tile encadeado avança normalmente e a volta à base
    -- é aplicada na primeira leitura do tile seguinte
    signal r_pend_rw_w  : std_logic := '0';
    signal r_pend_rw_i  : std_logic := '0';
    signal s_wgt_from   : unsigned(31 downto 0);
    signal s_inp_from   : unsigned(31 downto 0);
    signal state : state_t := IDLE;

    signal r_cycle_cnt  : unsigned(31 downto 0) := (others => '0');
    signal s_ram_read_en: std_logic := '0';
    
    -- Ponteiros internos -----------------------------------------------------------------------------------

    signal r_wgt_rd_ptr : unsigned(31 downto 0) := (others => '0');
    signal r_inp_rd_ptr : unsigned(31 downto 0) := (others => '0');

    -- Shadow Registers -------------------------------------------------------------------------------------

    signal r_no_drain   : std_logic := '0';
    signal r_tiles_left : unsigned(15 downto 0) := (others => '0');
    signal r_rw_w       : std_logic := '0';
    signal r_rw_i       : std_logic := '0';

    -- Double Buffering (Ping-Pong) ---------------------------------------------------------------------------
    -- r_wr_bank: banco atualmente aberto para escrita via MMIO (W_PORT/I_PORT).
    -- r_rd_bank: banco que o Core está consumindo na COMPUTE/DRAIN corrente.
    -- Quando cmd_dbuf_en = '0' em um START, ambos são forçados a '0' (banco único),
    -- reproduzindo exatamente o endereçamento legado (retrocompatível).

    signal r_wr_bank    : std_logic := '0';
    signal r_rd_bank    : std_logic := '0';

    ---------------------------------------------------------------------------------------------------------

begin

    -- Emissão de leitura: dados disponíveis (streaming) e, no início de um tile encadeado,
    -- espaço garantido na saída para ele
    s_wgt_step <= to_unsigned(4, 32) when cfg_gemv = '1' else to_unsigned(1, 32);

    s_in_ok <= '1' when cfg_stream_i = '0' else
               im2col_ready when cfg_im2col_en = '1' else
               '1' when s_inp_from < inp_wr_ptr else '0';

    s_w_ok  <= '1' when cfg_stream_w = '0' or (s_wgt_from + s_wgt_step) <= wgt_wr_ptr else '0';

    s_issue <= '1' when state = COMPUTE and r_cycle_cnt < cfg_run_size and s_in_ok = '1' and s_w_ok = '1' and
                        (r_ovl = '0' or r_cycle_cnt /= 0 or out_space_ok = '1') else '0';

    s_tile_end <= r_cycle_cnt = cfg_run_size - 1;

    s_wgt_from <= wgt_base when r_pend_rw_w = '1' else r_wgt_rd_ptr;
    s_inp_from <= inp_base when r_pend_rw_i = '1' else r_inp_rd_ptr;

    ctl_issue <= s_issue;

    wgt_rd_ptr <= r_wgt_rd_ptr;
    inp_rd_ptr <= r_inp_rd_ptr;
    ctl_ram_re <= s_ram_read_en;
    rd_bank_o  <= r_rd_bank;
    wr_bank_o  <= r_wr_bank;

    process(clk)
    begin
        if rising_edge(clk) then
            if rst_n = '0' then
                state <= IDLE;
                r_wgt_rd_ptr <= (others => '0');
                r_inp_rd_ptr <= (others => '0');
                r_cycle_cnt <= (others => '0');
                s_ram_read_en <= '0';
                ctl_core_vld  <= '0';
                ctl_core_last <= '0';
                r_last        <= '0';
                r_ovl         <= '0';
                ctl_acc_dump  <= '0';
                sts_busy <= '0';
                sts_done <= '0';
                r_no_drain <= '0';
                r_wr_bank <= '0';
                r_rd_bank <= '0';

            elsif soc_en_i = '1' then

                -- Pipeline do Valid (Acompanha latência de 1 ciclo da BRAM)
                ctl_core_vld  <= s_ram_read_en;
                ctl_core_last <= r_last;

                case state is
                    when IDLE =>
                        sts_busy <= '0';
                        s_ram_read_en <= '0';
                        ctl_acc_dump <= '0';
                        
                        -- Start Check
                        if cmd_start = '1' then
                            state <= COMPUTE;
                            sts_busy <= '1';
                            sts_done <= '0';
                            r_cycle_cnt <= (others => '0');
                            
                            -- Capture configs
                            r_no_drain <= cmd_no_drain;
                            r_rw_w     <= cfg_tile_rw_w;
                            r_rw_i     <= cfg_tile_rw_i;
                            if cfg_overlap = '1' and cmd_no_drain = '0' and cfg_run_size > COLS then
                                r_ovl <= '1';
                            else
                                r_ovl <= '0';
                            end if;
                            if cfg_tiles = 0 then
                                r_tiles_left <= to_unsigned(1, 16);
                            else
                                r_tiles_left <= cfg_tiles;
                            end if;

                            -- Double Buffering: troca de bancos no instante do START.
                            -- Habilitado (cmd_dbuf_en=1): passa a ler o banco que acabou de ser
                            -- preenchido (r_wr_bank) e libera o outro banco para a próxima escrita.
                            -- Desabilitado: força banco único (0), idêntico ao comportamento legado.
                            if cmd_dbuf_en = '1' then
                                r_rd_bank <= r_wr_bank;
                                r_wr_bank <= not r_wr_bank;
                            else
                                r_rd_bank <= '0';
                                r_wr_bank <= '0';
                            end if;

                            -- Reset Pointers caso requisitado
                            r_pend_rw_w <= '0';
                            r_pend_rw_i <= '0';
                            if cmd_rst_w = '1' then r_wgt_rd_ptr <= wgt_base; end if;
                            if cmd_rst_i = '1' then r_inp_rd_ptr <= inp_base; end if;
                        end if;

                    when COMPUTE =>
                        sts_busy <= '1';

                        -- Fase 1: emissão das leituras (o contador só avança quando a leitura sai)
                        if s_issue = '1' then
                            s_ram_read_en <= '1';
                            if s_tile_end then r_last <= '1'; else r_last <= '0'; end if;

                            r_wgt_rd_ptr <= s_wgt_from + s_wgt_step;
                            r_inp_rd_ptr <= s_inp_from + 1;
                            r_pend_rw_w  <= '0';
                            r_pend_rw_i  <= '0';

                            if r_ovl = '1' and s_tile_end and r_tiles_left > 1 then
                                -- Tile encadeado: o próximo começa no ciclo seguinte, sem esvaziar o array
                                r_tiles_left <= r_tiles_left - 1;
                                r_cycle_cnt  <= (others => '0');
                                r_pend_rw_w  <= r_rw_w;
                                r_pend_rw_i  <= r_rw_i;
                            else
                                r_cycle_cnt  <= r_cycle_cnt + 1;
                            end if;
                        else
                            s_ram_read_en <= '0';
                            r_last        <= '0';
                        end if;

                        -- Fase 2: todas as leituras emitidas; espera o array
                        if r_cycle_cnt >= cfg_run_size then
                            if r_ovl = '1' then
                                -- Encadeado: o último tile sai sozinho do array; FLUSH espera a latência
                                state       <= FLUSH;
                                r_cycle_cnt <= (others => '0');
                            elsif r_cycle_cnt < (cfg_run_size + C_PIPE_LATENCY) then
                                r_cycle_cnt <= r_cycle_cnt + 1;
                            elsif r_no_drain = '1' then
                                state <= IDLE;
                                sts_done <= '1';
                            else
                                state <= DRAIN;
                                r_cycle_cnt <= (others => '0');
                            end if;
                        end if;

                    when DRAIN =>
                        s_ram_read_en <= '0';

                        -- Drain de um tile: ROWS ciclos de dump tiram as linhas do array (a última
                        -- linha sai primeiro) e deixam os acumuladores zerados para o próximo tile.
                        -- Só começa quando a saída comporta o tile inteiro (backpressure da FIFO).
                        if r_cycle_cnt < ROWS then

                            if r_cycle_cnt /= 0 or out_space_ok = '1' then
                                ctl_acc_dump <= '1';
                                r_cycle_cnt  <= r_cycle_cnt + 1;
                            else
                                ctl_acc_dump <= '0';
                            end if;

                        else

                            ctl_acc_dump <= '0';
                            r_cycle_cnt  <= (others => '0');

                            if r_tiles_left > 1 then
                                -- Próximo tile da sequência: os ponteiros seguem de onde pararam,
                                -- exceto os que voltam à base a cada tile
                                r_tiles_left <= r_tiles_left - 1;
                                if r_rw_w = '1' then r_wgt_rd_ptr <= wgt_base; end if;
                                if r_rw_i = '1' then r_inp_rd_ptr <= inp_base; end if;
                                state <= COMPUTE;
                            else
                                state <= FLUSH;
                            end if;

                        end if;

                    when FLUSH =>
                        s_ram_read_en <= '0';
                        r_last        <= '0';
                        -- Espera os últimos resultados atravessarem a PPU e chegarem à FIFO; no modo
                        -- encadeado, soma a latência do array (o último tile ainda está saindo dele)
                        if (r_ovl = '0' and r_cycle_cnt < C_FLUSH_LATENCY) or
                           (r_ovl = '1' and r_cycle_cnt < C_PIPE_LATENCY + C_FLUSH_LATENCY) then
                            r_cycle_cnt <= r_cycle_cnt + 1;
                        elsif out_busy = '0' then
                            state    <= IDLE;
                            sts_done <= '1';
                        end if;

                end case;
            end if;
        end if;
    end process;

    ---------------------------------------------------------------------------------------------------------

end architecture; -- rtl

-------------------------------------------------------------------------------------------------------------