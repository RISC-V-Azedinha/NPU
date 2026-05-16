-------------------------------------------------------------------------------------------------------------
--
-- File: npu_register_file.vhd
-- 
-- ██████╗ ███████╗ ██████╗         ███████╗██╗██╗     ███████╗
-- ██╔══██╗██╔════╝██╔════╝         ██╔════╝██║██║     ██╔════╝
-- ██████╔╝█████╗  ██║  ███╗        █████╗  ██║██║     █████╗  
-- ██╔══██╗██╔══╝  ██║   ██║        ██╔══╝  ██║██║     ██╔══╝  
-- ██║  ██║███████╗╚██████╔╝███████╗██║     ██║███████╗███████╗
-- ╚═╝  ╚═╝╚══════╝ ╚═════╝ ╚══════╝╚═╝     ╚═╝╚══════╝╚══════╝  
--                                                        
-- Descrição: NPU - Register File & MMIO Decoder (Atualizado: Dual-Path Fast Streaming / Edge Guard)
--
-- Autor    : [André Maiolini]
-- Data     : [21/01/2026]
--
-------------------------------------------------------------------------------------------------------------

library ieee;
use ieee.std_logic_1164.all;                                     -- Tipos de lógica digital
use ieee.numeric_std.all;                                        -- Tipos numéricos (signed, unsigned)
use work.npu_pkg.all;                                            -- Pacote de definições do NPU

-------------------------------------------------------------------------------------------------------------
-- ENTIDADE: Definição da interface do banco de registradores
-------------------------------------------------------------------------------------------------------------

entity npu_register_file is

    generic (
        
        ACC_W       : integer := 32;                             -- Largura do Acumulador de Entrada
        DATA_W      : integer := 8;                              -- Largura do Dado de Saída
        QUANT_W     : integer := 32;                             -- Largura dos Parâmetros de Quantização
        COLS        : integer := 4                               -- Quantidade de Colunas do Array Sistólico
    
    );
    port (

        -----------------------------------------------------------------------------------------------------
        -- Sinais de Controle e Sincronização
        -----------------------------------------------------------------------------------------------------

        clk           : in  std_logic;
        rst_n         : in  std_logic;

        -----------------------------------------------------------------------------------------------------
        -- Interface MMIO 
        -----------------------------------------------------------------------------------------------------

        vld_i         : in  std_logic;
        rdy_o         : out std_logic;
        we_i          : in  std_logic;
        addr_i        : in  std_logic_vector(31 downto 0);
        data_i        : in  std_logic_vector(31 downto 0);
        data_o        : out std_logic_vector(31 downto 0);

        -----------------------------------------------------------------------------------------------------
        -- Interface com Controller (Status & Comandos)
        -----------------------------------------------------------------------------------------------------

        sts_busy      : in  std_logic;
        sts_done      : in  std_logic;
        cmd_start     : out std_logic;
        cmd_clear     : out std_logic;
        cmd_no_drain  : out std_logic;
        cmd_rst_w     : out std_logic;                           -- Reset Read Ptr Weights
        cmd_rst_i     : out std_logic;                           -- Reset Read Ptr Inputs

        -----------------------------------------------------------------------------------------------------
        -- Interface com Datapath (FIFO Read)
        -----------------------------------------------------------------------------------------------------

        fifo_r_valid  : in  std_logic;
        fifo_r_data   : in  std_logic_vector(31 downto 0);
        fifo_pop      : out std_logic;

        -----------------------------------------------------------------------------------------------------
        -- Interface com Datapath (RAM Write Control)
        -----------------------------------------------------------------------------------------------------

        ram_w_data    : out std_logic_vector(31 downto 0);
        wgt_we        : out std_logic;
        inp_we        : out std_logic;
        wgt_wr_ptr    : out unsigned(31 downto 0);
        inp_wr_ptr    : out unsigned(31 downto 0);

        -----------------------------------------------------------------------------------------------------
        -- Configurações Exportadas
        -----------------------------------------------------------------------------------------------------

        cfg_run_size  : out unsigned(31 downto 0);
        cfg_relu      : out std_logic;
        cfg_quant_sh  : out std_logic_vector(4 downto 0);
        cfg_quant_zo  : out std_logic_vector(DATA_W-1 downto 0);
        cfg_quant_mul : out std_logic_vector(QUANT_W-1 downto 0);
        cfg_bias_vec  : out std_logic_vector((COLS*ACC_W)-1 downto 0)

        -----------------------------------------------------------------------------------------------------

    );
end entity npu_register_file;

-------------------------------------------------------------------------------------------------------------
-- ARQUITETURA: Implementação comportamental do banco de registradores
-------------------------------------------------------------------------------------------------------------

architecture rtl of npu_register_file is

    -- Trava Síncrona do Edge Guard para o Slow Path (Controle)
    signal r_rdy_spath   : std_logic := '0';

    -- Registradores Internos
    signal r_run_size    : unsigned(31 downto 0) := (others => '0');
    signal r_wgt_wr_ptr  : unsigned(31 downto 0) := (others => '0');
    signal r_inp_wr_ptr  : unsigned(31 downto 0) := (others => '0');

    -- Configurações Estáticas
    signal r_en_relu     : std_logic := '0';
    signal r_quant_shift : std_logic_vector(4 downto 0) := (others => '0');
    signal r_quant_zero  : std_logic_vector(DATA_W-1 downto 0) := (others => '0');
    signal r_quant_mult  : std_logic_vector(QUANT_W-1 downto 0) := (others => '0');
    signal r_bias_vec    : std_logic_vector((COLS*ACC_W)-1 downto 0) := (others => '0');

    -- Comandos (Strobes)
    signal s_cmd_start   : std_logic := '0';
    signal s_acc_clear   : std_logic := '0';

    -- Sinais auxiliares para decodificação combinacional estável
    signal s_addr_idx    : integer range 0 to 255 := 0;
    signal s_is_data_port: boolean;

begin

    -- Wiring outputs estáticos
    cfg_run_size  <= r_run_size;
    cfg_relu      <= r_en_relu;
    cfg_quant_sh  <= r_quant_shift;
    cfg_quant_zo  <= r_quant_zero;
    cfg_quant_mul <= r_quant_mult;
    cfg_bias_vec  <= r_bias_vec;
    wgt_wr_ptr    <= r_wgt_wr_ptr;
    inp_wr_ptr    <= r_inp_wr_ptr;
    ram_w_data    <= data_i; 
    cmd_start     <= s_cmd_start;
    cmd_clear     <= s_acc_clear;

    -- Decodificação Combinacional de Endereço e Classificação de Fluxo
    s_addr_idx     <= to_integer(unsigned(addr_i(7 downto 0))) when not is_x(addr_i(7 downto 0)) else 0;
    s_is_data_port <= (s_addr_idx = 16#10#) or (s_addr_idx = 16#14#) or (s_addr_idx = 16#18#);

    -- ========================================================================
    -- MULTIPLEXAÇÃO COMBINACIONAL DE PRONTIDÃO E LEITURA (Zero Latency Bar)
    -- ========================================================================
    rdy_o  <= vld_i when s_is_data_port else r_rdy_spath;

    data_o <= (0 => sts_busy, 1 => sts_done, 3 => fifo_r_valid, others => '0') when s_addr_idx = 16#00# else
              fifo_r_data when s_addr_idx = 16#18# else
              (others => '0');

    -- Processo Síncrono principal (Genciamento de Escrita e Mutação de Estado)
    process(clk)
    begin
        if rising_edge(clk) then
            if rst_n = '0' then
                r_rdy_spath  <= '0';
                r_wgt_wr_ptr <= (others => '0');
                r_inp_wr_ptr <= (others => '0');
                wgt_we       <= '0';
                inp_we       <= '0';
                fifo_pop     <= '0';
                s_cmd_start  <= '0';
                s_acc_clear  <= '0';
                cmd_no_drain <= '0';
                cmd_rst_w    <= '0';
                cmd_rst_i    <= '0';
                r_en_relu    <= '0';
                r_run_size   <= (others => '0');
                r_quant_shift<= (others => '0');
                r_quant_zero <= (others => '0');
                r_quant_mult <= (others => '0');
                r_bias_vec   <= (others => '0');
            else
                -- Defaults para Strobes (Limpam automaticamente no ciclo seguinte)
                wgt_we      <= '0';
                inp_we      <= '0';
                fifo_pop    <= '0';
                s_cmd_start <= '0'; 
                s_acc_clear <= '0';

                -- --------------------------------------------------------------------
                -- CAMINHO 1: FAST PATH (Portas de Dados - Capazes de aceitar rajadas contínuas)
                -- --------------------------------------------------------------------
                if s_is_data_port then
                    if vld_i = '1' then
                        if we_i = '1' then
                            if s_addr_idx = 16#10# then
                                wgt_we <= '1';
                                r_wgt_wr_ptr <= r_wgt_wr_ptr + 1;
                            elsif s_addr_idx = 16#14# then
                                inp_we <= '1';
                                r_inp_wr_ptr <= r_inp_wr_ptr + 1;
                            end if;
                        else
                            if s_addr_idx = 16#18# then
                                fifo_pop <= '1'; -- Consome a palavra da FIFO interna na borda
                            end if;
                        end if;
                    end if;
                    r_rdy_spath <= '0'; -- Reseta o prontidão do Slow Path para transições consecutivas

                -- --------------------------------------------------------------------
                -- CAMINHO 2: SLOW PATH (Registradores de Controle/Configuração com Edge Guard)
                -- --------------------------------------------------------------------
                else
                    if vld_i = '1' and r_rdy_spath = '0' then
                        r_rdy_spath <= '1'; -- Trava o ciclo de Handshake
                        
                        if we_i = '1' and sts_busy = '0' then
                            case s_addr_idx is
                                -- [0x04] CMD
                                when 16#04# => 
                                    if data_i(0) = '1' then 
                                        r_wgt_wr_ptr <= (others => '0');
                                        r_inp_wr_ptr <= (others => '0');
                                    end if;
                                    if data_i(6) = '1' then 
                                        r_wgt_wr_ptr <= (others => '0');
                                    end if;
                                    if data_i(7) = '1' then 
                                        r_inp_wr_ptr <= (others => '0');
                                    end if;
                                    
                                    s_acc_clear <= data_i(2); -- Gatilho de Clear do Acumulador
                                    
                                    if data_i(1) = '1' then
                                        s_cmd_start  <= '1';
                                        cmd_no_drain <= data_i(3);
                                        cmd_rst_w    <= data_i(4); 
                                        cmd_rst_i    <= data_i(5); 
                                    end if;

                                -- [0x08] CONFIG
                                when 16#08# => r_run_size <= unsigned(data_i);

                                -- Parâmetros de Quantização
                                when 16#40# => 
                                    r_quant_shift <= data_i(4 downto 0);
                                    r_quant_zero  <= data_i(15 downto 8);
                                when 16#44# => r_quant_mult <= data_i;
                                when 16#48# => r_en_relu    <= data_i(0);
                                
                                -- Vetor de Bias Sistólico
                                when 16#80# => r_bias_vec(31 downto 0)   <= data_i;
                                when 16#84# => r_bias_vec(63 downto 32)  <= data_i;
                                when 16#88# => r_bias_vec(95 downto 64)  <= data_i;
                                when 16#8C# => r_bias_vec(127 downto 96) <= data_i;
                                when others => null;
                            end case;
                        end if;
                    elsif vld_i = '0' then
                        r_rdy_spath <= '0'; -- Destrava o Edge Guard quando a CPU solta o barramento
                    end if;
                end if;

            end if;
        end if;
    end process;

end architecture;