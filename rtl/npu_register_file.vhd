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
-- Descrição: NPU - Register File & MMIO Decoder 
--            (Atualizado: True Burst Data Strobes e Edge Guard no Controle)
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
-- ENTIDADE: Definição da interface do banco de registradores
-------------------------------------------------------------------------------------------------------------

entity npu_register_file is

    generic (
        ACC_W       : integer := 32;                             
        DATA_W      : integer := 8;                              
        QUANT_W     : integer := 32;                             
        COLS        : integer := 4                               
    );
    port (
        clk           : in  std_logic;
        rst_n         : in  std_logic;

        vld_i         : in  std_logic;
        rdy_o         : out std_logic;
        we_i          : in  std_logic;
        addr_i        : in  std_logic_vector(31 downto 0);
        data_i        : in  std_logic_vector(31 downto 0);
        data_o        : out std_logic_vector(31 downto 0);

        sts_busy      : in  std_logic;
        sts_done      : in  std_logic;
        cmd_start     : out std_logic;
        cmd_clear     : out std_logic;
        cmd_no_drain  : out std_logic;
        cmd_rst_w     : out std_logic; 
        cmd_rst_i     : out std_logic; 

        fifo_r_valid  : in  std_logic;
        fifo_r_data   : in  std_logic_vector(31 downto 0);
        fifo_pop      : out std_logic;

        ram_w_data    : out std_logic_vector(31 downto 0);
        wgt_we        : out std_logic;
        inp_we        : out std_logic;
        wgt_wr_ptr    : out unsigned(31 downto 0);
        inp_wr_ptr    : out unsigned(31 downto 0);

        cfg_run_size  : out unsigned(31 downto 0);
        cfg_relu      : out std_logic;
        cfg_quant_sh  : out std_logic_vector(4 downto 0);
        cfg_quant_zo  : out std_logic_vector(DATA_W-1 downto 0);
        cfg_quant_mul : out std_logic_vector(QUANT_W-1 downto 0);
        cfg_bias_vec  : out std_logic_vector((COLS*ACC_W)-1 downto 0)
    );
end entity npu_register_file;

-------------------------------------------------------------------------------------------------------------
-- ARQUITETURA
-------------------------------------------------------------------------------------------------------------

architecture rtl of npu_register_file is

    -- Trava Síncrona do Edge Guard para o Slow Path (Controle)
    signal r_rdy_spath   : std_logic := '0';

    -- Registradores Internos (Ponteiros de Datapath)
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

    -- Sinais auxiliares combinacionais
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

    -- Decodificação Combinacional
    s_addr_idx     <= to_integer(unsigned(addr_i(7 downto 0))) when not is_x(addr_i(7 downto 0)) else 0;
    s_is_data_port <= (s_addr_idx = 16#10#) or (s_addr_idx = 16#14#) or (s_addr_idx = 16#18#);

    -- ========================================================================
    -- MULTIPLEXAÇÃO COMBINACIONAL (Zero Latency Bar)
    -- ========================================================================
    rdy_o  <= vld_i when s_is_data_port else r_rdy_spath;

    data_o <= (0 => sts_busy, 1 => sts_done, 3 => fifo_r_valid, others => '0') when s_addr_idx = 16#00# else
              fifo_r_data when s_addr_idx = 16#18# else
              (others => '0');

    -- ========================================================================
    -- STROBES COMBINACIONAIS DE DADOS (FAST PATH - CORREÇÃO DE BURST)
    -- ========================================================================
    -- Estes sinais não podem ser registrados (FF), pois precisam habilitar a
    -- RAM/FIFO no exato instante em que o DMA apresenta o dado no barramento.
    wgt_we   <= '1' when (s_is_data_port and vld_i = '1' and we_i = '1' and s_addr_idx = 16#10#) else '0';
    inp_we   <= '1' when (s_is_data_port and vld_i = '1' and we_i = '1' and s_addr_idx = 16#14#) else '0';
    fifo_pop <= '1' when (s_is_data_port and vld_i = '1' and we_i = '0' and s_addr_idx = 16#18#) else '0';


    -- Processo Síncrono (Atualização de Pointers e Slow Path)
    process(clk)
    begin
        if rising_edge(clk) then
            if rst_n = '0' then
                r_rdy_spath  <= '0';
                r_wgt_wr_ptr <= (others => '0');
                r_inp_wr_ptr <= (others => '0');
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
                -- Defaults para Strobes Síncronos
                s_cmd_start <= '0'; 
                s_acc_clear <= '0';

                -- --------------------------------------------------------------------
                -- CAMINHO 1: FAST PATH (Apenas Pointers)
                -- --------------------------------------------------------------------
                if s_is_data_port then
                    if vld_i = '1' then
                        if we_i = '1' then
                            if s_addr_idx = 16#10# then
                                r_wgt_wr_ptr <= r_wgt_wr_ptr + 1;
                            elsif s_addr_idx = 16#14# then
                                r_inp_wr_ptr <= r_inp_wr_ptr + 1;
                            end if;
                        end if;
                    end if;
                    r_rdy_spath <= '0'; 

                -- --------------------------------------------------------------------
                -- CAMINHO 2: SLOW PATH (Registradores de Controle com Edge Guard)
                -- --------------------------------------------------------------------
                else
                    if vld_i = '1' and r_rdy_spath = '0' then
                        r_rdy_spath <= '1'; 
                        
                        if we_i = '1' and sts_busy = '0' then
                            case s_addr_idx is
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
                                    
                                    s_acc_clear <= data_i(2);
                                    
                                    if data_i(1) = '1' then
                                        s_cmd_start  <= '1';
                                        cmd_no_drain <= data_i(3);
                                        cmd_rst_w    <= data_i(4); 
                                        cmd_rst_i    <= data_i(5); 
                                    end if;

                                when 16#08# => r_run_size <= unsigned(data_i);
                                when 16#40# => 
                                    r_quant_shift <= data_i(4 downto 0);
                                    r_quant_zero  <= data_i(15 downto 8);
                                when 16#44# => r_quant_mult <= data_i;
                                when 16#48# => r_en_relu    <= data_i(0);
                                when 16#80# => r_bias_vec(31 downto 0)   <= data_i;
                                when 16#84# => r_bias_vec(63 downto 32)  <= data_i;
                                when 16#88# => r_bias_vec(95 downto 64)  <= data_i;
                                when 16#8C# => r_bias_vec(127 downto 96) <= data_i;
                                when others => null;
                            end case;
                        end if;
                    elsif vld_i = '0' then
                        r_rdy_spath <= '0'; 
                    end if;
                end if;

            end if;
        end if;
    end process;

end architecture;