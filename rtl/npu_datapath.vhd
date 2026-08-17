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
        DOUBLE_BUFFER  : boolean := false     -- Retrocompatível: false = 1 banco (RTL/recursos idênticos ao legado)
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

        -- Controle de Memória (Leitura - Controller)
        wgt_rd_ptr          : in  unsigned(31 downto 0);
        inp_rd_ptr          : in  unsigned(31 downto 0);

        -- Double Buffering (Ping-Pong): ignorado quando DOUBLE_BUFFER = false
        wr_bank             : in  std_logic := '0';
        rd_bank             : in  std_logic := '0';

        -- Controle do Core
        ctl_acc_clear       : in  std_logic;
        ctl_acc_dump        : in  std_logic;
        ctl_valid_in        : in  std_logic;

        -- Configurações PPU
        cfg_relu            : in  std_logic;
        cfg_quant_sh        : in  std_logic_vector(4 downto 0);
        cfg_quant_zo        : in  std_logic_vector(DATA_W-1 downto 0);
        cfg_quant_mul       : in  std_logic_vector(QUANT_W-1 downto 0);
        cfg_bias_vec        : in  std_logic_vector((COLS*ACC_W)-1 downto 0);

        -- Saída FIFO
        fifo_pop            : in  std_logic;
        fifo_r_valid        : out std_logic;
        fifo_r_data         : out std_logic_vector(31 downto 0);
        fifo_ready_feedback : out std_logic
    );
end entity npu_datapath;

-------------------------------------------------------------------------------------------------------------
-- ARQUITETURA: Implementação estrutural do caminho de dados
-------------------------------------------------------------------------------------------------------------

architecture rtl of npu_datapath is

    -- Controle de Memória 
    signal wgt_ram_rdata    : std_logic_vector(31 downto 0);
    signal inp_ram_rdata    : std_logic_vector(31 downto 0);
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

begin

    ---------------------------------------------------------------------------------------------------------
    -- Memórias (Weights & Inputs)
    ---------------------------------------------------------------------------------------------------------
    
    -- CORREÇÃO: Remoção do "- 1" nos write pointers, pois o write enable agora é 0-latency.
    wgt_wr_addr_calc <= std_logic_vector(wgt_wr_ptr);
    inp_wr_addr_calc <= std_logic_vector(inp_wr_ptr);

    -- Os Read Pointers mantêm o "- 1" pois o npu_controller pré-incrementa síncronamente na FSM.
    wgt_rd_addr_calc <= std_logic_vector(wgt_rd_ptr - 1);
    inp_rd_addr_calc <= std_logic_vector(inp_rd_ptr - 1);

    -- CASO 1: Buffer Único (Comportamento Legado) -----------------------------------------------------------
    -- Retrocompatível: quando DOUBLE_BUFFER = false (default), esta é a MESMA estrutura de sempre,
    -- sem qualquer mux ou recurso extra de BRAM.
    GEN_SINGLE_BUF : if not DOUBLE_BUFFER generate
    begin

        u_ram_w : entity work.ram_dual
            generic map (DATA_W => 32, DEPTH => FIFO_DEPTH)
            port map (
                clk     => clk,
                wr_en   => wgt_we,
                wr_addr => wgt_wr_addr_calc,
                wr_data => w_data,
                rd_addr => wgt_rd_addr_calc,
                rd_data => wgt_ram_rdata
            );

        u_ram_i : entity work.ram_dual
            generic map (DATA_W => 32, DEPTH => FIFO_DEPTH)
            port map (
                clk     => clk,
                wr_en   => inp_we,
                wr_addr => inp_wr_addr_calc,
                wr_data => w_data,
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
        signal inp_rdata_a, inp_rdata_b : std_logic_vector(31 downto 0);

        -- Write-enables qualificados por banco (sinais próprios: mantém os port maps abaixo como
        -- simples nomes estáticos, evitando restrições de expressão em port map dentro de generate)
        signal s_wgt_we_a, s_wgt_we_b : std_logic;
        signal s_inp_we_a, s_inp_we_b : std_logic;

    begin

        s_wgt_we_a <= wgt_we and (not wr_bank);
        s_wgt_we_b <= wgt_we and wr_bank;
        s_inp_we_a <= inp_we and (not wr_bank);
        s_inp_we_b <= inp_we and wr_bank;

        u_ram_w_a : entity work.ram_dual
            generic map (DATA_W => 32, DEPTH => FIFO_DEPTH)
            port map (
                clk     => clk,
                wr_en   => s_wgt_we_a,
                wr_addr => wgt_wr_addr_calc,
                wr_data => w_data,
                rd_addr => wgt_rd_addr_calc,
                rd_data => wgt_rdata_a
            );

        u_ram_w_b : entity work.ram_dual
            generic map (DATA_W => 32, DEPTH => FIFO_DEPTH)
            port map (
                clk     => clk,
                wr_en   => s_wgt_we_b,
                wr_addr => wgt_wr_addr_calc,
                wr_data => w_data,
                rd_addr => wgt_rd_addr_calc,
                rd_data => wgt_rdata_b
            );

        u_ram_i_a : entity work.ram_dual
            generic map (DATA_W => 32, DEPTH => FIFO_DEPTH)
            port map (
                clk     => clk,
                wr_en   => s_inp_we_a,
                wr_addr => inp_wr_addr_calc,
                wr_data => w_data,
                rd_addr => inp_rd_addr_calc,
                rd_data => inp_rdata_a
            );

        u_ram_i_b : entity work.ram_dual
            generic map (DATA_W => 32, DEPTH => FIFO_DEPTH)
            port map (
                clk     => clk,
                wr_en   => s_inp_we_b,
                wr_addr => inp_wr_addr_calc,
                wr_data => w_data,
                rd_addr => inp_rd_addr_calc,
                rd_data => inp_rdata_b
            );

        -- Mux de leitura: o Core sempre enxerga o banco "rd_bank" corrente (registrado dentro da RAM,
        -- então o mux não acrescenta latência: continua sendo 1 ciclo endereço -> dado, como no legado)
        wgt_ram_rdata <= wgt_rdata_b when rd_bank = '1' else wgt_rdata_a;
        inp_ram_rdata <= inp_rdata_b when rd_bank = '1' else inp_rdata_a;

    end generate GEN_DOUBLE_BUF;

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
            valid_in      => ctl_valid_in,
            input_weights => wgt_ram_rdata,
            input_acts    => inp_ram_rdata,
            output_accs   => core_accs,
            valid_out     => core_valid_out
        );

    ---------------------------------------------------------------------------------------------------------
    -- Post Processing Units (PPU)
    ---------------------------------------------------------------------------------------------------------

    GEN_PPU : for i in 0 to COLS-1 generate
        u_ppu : entity work.post_process
            port map (
                clk         => clk,
                rst_n       => rst_n,
                soc_en_i    => soc_en_i,
                valid_in    => core_valid_out,
                acc_in      => core_accs((i+1)*ACC_W-1 downto i*ACC_W),
                bias_in     => cfg_bias_vec((i+1)*ACC_W-1 downto i*ACC_W),
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

    ofifo_w_valid <= ppu_valid_vec(0);
    ofifo_w_data  <= std_logic_vector(resize(unsigned(ppu_data_vec), 32));

    -- Exportando o sinal de ready (backpressure)
    fifo_ready_feedback <= ofifo_w_ready;
    
    -- Reset da FIFO
    s_fifo_rst_n  <= rst_n and not ctl_acc_clear;

    u_ofifo : entity work.fifo_sync
        generic map (DATA_W => 32, DEPTH => 64) 
        port map (
            clk     => clk, 
            rst_n   => s_fifo_rst_n,
            w_valid => ofifo_w_valid, 
            w_ready => ofifo_w_ready, 
            w_data  => ofifo_w_data,
            r_valid => fifo_r_valid, 
            r_ready => fifo_pop, 
            r_data  => fifo_r_data
        );

end architecture;