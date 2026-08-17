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

        fifo_ready_i  : in  std_logic                            -- (1 = Pode enviar, 0 = Pare)

        -----------------------------------------------------------------------------------------------------

    );

end entity npu_controller;

-------------------------------------------------------------------------------------------------------------
-- ARQUITETURA: Implementação comportamental do controlador (FSM)
-------------------------------------------------------------------------------------------------------------

architecture rtl of npu_controller is

    -- Constantes de Latência -------------------------------------------------------------------------------

    constant C_PIPE_LATENCY : integer := 1 + 1 + (ROWS + COLS);
    constant C_DUMP_LATENCY : integer := ROWS + 2;

    -- Estados da FSM ---------------------------------------------------------------------------------------

    type state_t is (IDLE, COMPUTE, DRAIN);
    signal state : state_t := IDLE;

    signal r_cycle_cnt  : unsigned(31 downto 0) := (others => '0');
    signal s_ram_read_en: std_logic := '0';
    
    -- Ponteiros internos -----------------------------------------------------------------------------------

    signal r_wgt_rd_ptr : unsigned(31 downto 0) := (others => '0');
    signal r_inp_rd_ptr : unsigned(31 downto 0) := (others => '0');

    -- Shadow Registers -------------------------------------------------------------------------------------

    signal r_no_drain   : std_logic := '0';

    -- Double Buffering (Ping-Pong) ---------------------------------------------------------------------------
    -- r_wr_bank: banco atualmente aberto para escrita via MMIO (W_PORT/I_PORT).
    -- r_rd_bank: banco que o Core está consumindo na COMPUTE/DRAIN corrente.
    -- Quando cmd_dbuf_en = '0' em um START, ambos são forçados a '0' (banco único),
    -- reproduzindo exatamente o endereçamento legado (retrocompatível).

    signal r_wr_bank    : std_logic := '0';
    signal r_rd_bank    : std_logic := '0';

    ---------------------------------------------------------------------------------------------------------

begin

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
                ctl_acc_dump  <= '0';
                sts_busy <= '0';
                sts_done <= '0';
                r_no_drain <= '0';
                r_wr_bank <= '0';
                r_rd_bank <= '0';

            elsif soc_en_i = '1' then

                -- Pipeline do Valid (Acompanha latência de 1 ciclo da BRAM)
                ctl_core_vld <= s_ram_read_en;

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
                            if cmd_rst_w = '1' then r_wgt_rd_ptr <= (others => '0'); end if;
                            if cmd_rst_i = '1' then r_inp_rd_ptr <= (others => '0'); end if;
                        end if;

                    when COMPUTE =>
                        sts_busy <= '1';
                        
                        -- Lógica 1: Controle de Leitura da RAM 
                        if r_cycle_cnt < cfg_run_size then
                            s_ram_read_en <= '1';
                            r_wgt_rd_ptr <= r_wgt_rd_ptr + 1;
                            r_inp_rd_ptr <= r_inp_rd_ptr + 1;
                        else
                            s_ram_read_en <= '0';
                        end if;

                        -- Lógica 2: Controle de Estado (Run + Latência de Propagação)
                        if r_cycle_cnt < (cfg_run_size + C_PIPE_LATENCY) then
                            r_cycle_cnt <= r_cycle_cnt + 1;
                        else
                            -- Pipeline esvaziou. Verificar se é Tiling ou Drain.
                            if r_no_drain = '1' then
                                -- MODO TILING: Acumula resultado, não limpa FIFO, volta IDLE
                                state <= IDLE;
                                sts_done <= '1'; 
                            else
                                -- MODO FINAL: Hora de drenar resultados
                                state <= DRAIN;
                                r_cycle_cnt <= (others => '0');
                            end if;
                        end if;

                    when DRAIN =>
                        s_ram_read_en <= '0';

                        -- Backpressure (STALL)
                        if fifo_ready_i = '1' then

                            -- Caminho livre: Ativa o Dump e conta o tempo
                            ctl_acc_dump <= '1';
                            
                            if r_cycle_cnt < C_DUMP_LATENCY then

                                r_cycle_cnt <= r_cycle_cnt + 1;

                            else

                                state <= IDLE;
                                sts_done <= '1';
                                ctl_acc_dump <= '0';

                            end if;

                        else

                            -- FIFO Cheia: Congela o Dump
                            -- O Array sistólico mantém os dados internamente até o dump voltar a 1
                            ctl_acc_dump <= '0';

                        end if;

                end case;
            end if;
        end if;
    end process;

    ---------------------------------------------------------------------------------------------------------

end architecture; -- rtl

-------------------------------------------------------------------------------------------------------------