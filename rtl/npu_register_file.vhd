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
        cmd_dbuf_en   : out std_logic;                           -- Double Buffering (Ping-Pong) neste START

        fifo_r_valid  : in  std_logic;
        fifo_r_data   : in  std_logic_vector(31 downto 0);
        fifo_pop      : out std_logic;

        ram_w_data    : out std_logic_vector(31 downto 0);
        wgt_we        : out std_logic;
        inp_we        : out std_logic;
        wgt_wr_ptr    : out unsigned(31 downto 0);
        inp_wr_ptr    : out unsigned(31 downto 0);
        wgt_base      : out unsigned(31 downto 0);               -- Endereço base da região de Pesos
        inp_base      : out unsigned(31 downto 0);               -- Endereço base da região de Inputs

        img_we        : out std_logic;                           -- Escrita na imagem do im2col (porta IMG)
        img_wr_ptr    : out unsigned(31 downto 0);
        cfg_im2col_en : out std_logic;                           -- 1 = Inputs vêm do im2col em hardware
        cfg_im_in_w   : out unsigned(7 downto 0);
        cfg_im_out_w  : out unsigned(7 downto 0);
        cfg_im_stride : out unsigned(3 downto 0);
        cfg_im_kw     : out unsigned(3 downto 0);
        cfg_im_nwin   : out unsigned(15 downto 0);

        cfg_tiles     : out unsigned(15 downto 0);               -- Tiles por START (0/1 = um tile, legado)
        cfg_tile_rw_w : out std_logic;                           -- Volta a leitura de Pesos à base a cada tile
        cfg_tile_rw_i : out std_logic;                           -- Volta a leitura de Inputs à base a cada tile
        cfg_out_order : out std_logic;                           -- Saída na ordem das linhas (0, 1, ..., ROWS-1)
        cfg_out_unpack: out std_logic;                           -- Saída com uma ativação por palavra

        cfg_run_size  : out unsigned(31 downto 0);
        cfg_relu      : out std_logic;
        cfg_quant_sh  : out std_logic_vector(4 downto 0);
        cfg_quant_zo  : out std_logic_vector(DATA_W-1 downto 0);
        cfg_quant_mul : out std_logic_vector(QUANT_W-1 downto 0);
        cfg_bias_vec  : out std_logic_vector((BIAS_TILES*COLS*ACC_W)-1 downto 0);  -- Banco de bias (0x80..)
        cfg_bias_per_tile : out std_logic;                       -- TILES bit 18: um vetor de bias por tile
        cfg_bias_base : out unsigned(2 downto 0);                -- TILES bits 21:19: banco de bias do primeiro tile
        cfg_gemv      : out std_logic;                           -- MODE bit 0: camada densa em modo GEMV
        cfg_stream_i  : out std_logic;                           -- MODE bit 1: espera os Inputs chegarem
        cfg_stream_w  : out std_logic;                           -- MODE bit 2: espera os Pesos chegarem
        cfg_overlap   : out std_logic;                           -- MODE bit 3: tiles encadeados
        cfg_out_loop  : out std_logic;                           -- OUT_CFG bit 2: saída vai para a RAM de Inputs

        -- Descritores de camada: porta DESC (0x0C, fast path) e escritas vindas do processador
        -- de comandos (têm prioridade sobre as escritas de configuração pelo barramento)
        desc_we       : out std_logic;
        cp_we         : in  std_logic := '0';
        cp_addr       : in  std_logic_vector(7 downto 0) := (others => '0');
        cp_data       : in  std_logic_vector(31 downto 0) := (others => '0');
        cp_idle       : in  std_logic := '1';                    -- STATUS bit 4: programa terminado
        desc_ready    : in  std_logic := '1'                     -- Fila de descritores aceita uma palavra
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

    -- Bases das regiões (Pesos residentes): resets de ponteiro voltam para cá, e não para zero
    signal r_wgt_base    : unsigned(31 downto 0) := (others => '0');
    signal r_inp_base    : unsigned(31 downto 0) := (others => '0');

    -- im2col em hardware: ponteiro de escrita da imagem e geometria
    signal r_img_wr_ptr  : unsigned(31 downto 0) := (others => '0');
    signal r_im2col_en   : std_logic := '0';
    signal r_im_geom     : std_logic_vector(23 downto 0) := (others => '0');
    signal r_im_nwin     : unsigned(15 downto 0) := (others => '0');

    -- Sequenciador de tiles e formato da saída
    signal r_tiles_cfg   : std_logic_vector(21 downto 0) := (others => '0');
    signal r_out_cfg     : std_logic_vector(2 downto 0) := (others => '0');

    signal s_out_stall   : boolean;
    signal s_desc_stall  : boolean;                                -- Fila de descritores cheia

    -- Escrita de configuração aceita do barramento, aplicada no ciclo seguinte (a decodificação
    -- dos registradores parte só de registradores, fora do caminho combinacional do crossbar)
    signal r_bus_wr      : std_logic := '0';
    signal r_bus_addr    : integer range 0 to 255 := 0;
    signal r_bus_data    : std_logic_vector(31 downto 0) := (others => '0');

    -- Configurações Estáticas
    signal r_en_relu     : std_logic := '0';
    signal r_quant_shift : std_logic_vector(4 downto 0) := (others => '0');
    signal r_quant_zero  : std_logic_vector(DATA_W-1 downto 0) := (others => '0');
    signal r_quant_mult  : std_logic_vector(QUANT_W-1 downto 0) := (others => '0');
    signal r_bias_vec    : std_logic_vector((BIAS_TILES*COLS*ACC_W)-1 downto 0) := (others => '0');
    signal r_mode        : std_logic_vector(3 downto 0) := (others => '0');

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
    wgt_base      <= r_wgt_base;
    inp_base      <= r_inp_base;
    img_wr_ptr    <= r_img_wr_ptr;
    cfg_im2col_en <= r_im2col_en;
    cfg_im_in_w   <= unsigned(r_im_geom(7 downto 0));
    cfg_im_out_w  <= unsigned(r_im_geom(15 downto 8));
    cfg_im_stride <= unsigned(r_im_geom(19 downto 16));
    cfg_im_kw     <= unsigned(r_im_geom(23 downto 20));
    cfg_im_nwin   <= r_im_nwin;
    cfg_tiles     <= unsigned(r_tiles_cfg(15 downto 0));
    cfg_tile_rw_w <= r_tiles_cfg(16);
    cfg_tile_rw_i <= r_tiles_cfg(17);
    cfg_bias_per_tile <= r_tiles_cfg(18);
    cfg_bias_base <= unsigned(r_tiles_cfg(21 downto 19));
    cfg_gemv      <= r_mode(0);
    cfg_stream_i  <= r_mode(1);
    cfg_stream_w  <= r_mode(2);
    cfg_overlap   <= r_mode(3);
    cfg_out_loop  <= r_out_cfg(2);
    cfg_out_order <= r_out_cfg(0);
    cfg_out_unpack<= r_out_cfg(1);
    ram_w_data    <= data_i; 
    cmd_start     <= s_cmd_start;
    cmd_clear     <= s_acc_clear;

    -- Decodificação Combinacional
    s_addr_idx     <= to_integer(unsigned(addr_i(7 downto 0))) when not is_x(addr_i(7 downto 0)) else 0;
    s_is_data_port <= (s_addr_idx = 16#10#) or (s_addr_idx = 16#14#) or (s_addr_idx = 16#18#) or (s_addr_idx = 16#1C#) or
                      (s_addr_idx = 16#0C#);

    -- ========================================================================
    -- MULTIPLEXAÇÃO COMBINACIONAL (Zero Latency Bar)
    -- ========================================================================
    -- Leitura da O_DATA com a FIFO vazia enquanto a NPU trabalha (ou um programa de descritores
    -- ainda executa): segura o barramento até chegar o próximo resultado (permite que o DMA ou a
    -- CPU esvaziem a FIFO durante a execução). Com a NPU parada e sem programa, responde na hora,
    -- como antes, para nunca travar o barramento.
    s_out_stall <= (s_addr_idx = 16#18#) and we_i = '0' and fifo_r_valid = '0' and (sts_busy = '1' or cp_idle = '0');

    rdy_o  <= r_rdy_spath when not s_is_data_port else
              '0'         when s_out_stall or s_desc_stall else
              vld_i;

    data_o <= (0 => sts_busy, 1 => sts_done, 3 => fifo_r_valid, 4 => cp_idle, others => '0') when s_addr_idx = 16#00# else
              fifo_r_data when s_addr_idx = 16#18# else
              std_logic_vector(r_wgt_base) when s_addr_idx = 16#20# else
              std_logic_vector(r_inp_base) when s_addr_idx = 16#24# else
              (0 => r_im2col_en, others => '0') when s_addr_idx = 16#28# else
              x"00" & r_im_geom when s_addr_idx = 16#2C# else
              x"0000" & std_logic_vector(r_im_nwin) when s_addr_idx = 16#30# else
              "0000000000" & r_tiles_cfg when s_addr_idx = 16#34# else
              "00000000000000000000000000000" & r_out_cfg when s_addr_idx = 16#38# else
              "0000000000000000000000000000" & r_mode when s_addr_idx = 16#3C# else
              (others => '0');

    -- ========================================================================
    -- STROBES COMBINACIONAIS DE DADOS (FAST PATH - CORREÇÃO DE BURST)
    -- ========================================================================
    -- Estes sinais não podem ser registrados (FF), pois precisam habilitar a
    -- RAM/FIFO no exato instante em que o DMA apresenta o dado no barramento.
    wgt_we   <= '1' when (s_is_data_port and vld_i = '1' and we_i = '1' and s_addr_idx = 16#10#) else '0';
    inp_we   <= '1' when (s_is_data_port and vld_i = '1' and we_i = '1' and s_addr_idx = 16#14#) else '0';
    img_we   <= '1' when (s_is_data_port and vld_i = '1' and we_i = '1' and s_addr_idx = 16#1C#) else '0';
    s_desc_stall <= (s_addr_idx = 16#0C#) and we_i = '1' and desc_ready = '0';
    desc_we  <= '1' when (s_is_data_port and vld_i = '1' and we_i = '1' and s_addr_idx = 16#0C# and not s_desc_stall) else '0';
    fifo_pop <= '1' when (s_is_data_port and vld_i = '1' and we_i = '0' and s_addr_idx = 16#18# and not s_out_stall) else '0';


    -- Processo Síncrono (Atualização de Pointers e Slow Path)
    process(clk)
        variable v_wr   : boolean;
        variable v_addr : integer range 0 to 255;
        variable v_data : std_logic_vector(31 downto 0);
    begin
        if rising_edge(clk) then
            if rst_n = '0' then
                r_rdy_spath  <= '0';
                r_bus_wr     <= '0';
                r_wgt_wr_ptr <= (others => '0');
                r_inp_wr_ptr <= (others => '0');
                r_wgt_base   <= (others => '0');
                r_inp_base   <= (others => '0');
                r_img_wr_ptr <= (others => '0');
                r_im2col_en  <= '0';
                r_im_geom    <= (others => '0');
                r_im_nwin    <= (others => '0');
                r_tiles_cfg  <= (others => '0');
                r_out_cfg    <= (others => '0');
                s_cmd_start  <= '0';
                s_acc_clear  <= '0';
                cmd_no_drain <= '0';
                cmd_rst_w    <= '0';
                cmd_rst_i    <= '0';
                cmd_dbuf_en  <= '0';
                r_en_relu    <= '0';
                r_run_size   <= (others => '0');
                r_quant_shift<= (others => '0');
                r_quant_zero <= (others => '0');
                r_quant_mult <= (others => '0');
                r_bias_vec   <= (others => '0');
                r_mode       <= (others => '0');
            else
                -- Defaults para Strobes Síncronos
                s_cmd_start <= '0'; 
                s_acc_clear <= '0';
                v_wr   := false;
                v_addr := 0;
                v_data := (others => '0');

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
                            elsif s_addr_idx = 16#1C# then
                                r_img_wr_ptr <= r_img_wr_ptr + 1;
                            end if;
                        end if;
                    end if;
                    r_rdy_spath <= '0'; 

                -- --------------------------------------------------------------------
                -- CAMINHO 2: SLOW PATH (Registradores de Controle com Edge Guard)
                -- --------------------------------------------------------------------
                -- Com um programa de descritores em execução, escritas de configuração pelo
                -- barramento esperam (rdy só sobe quando o programa termina), então as duas
                -- fontes nunca escrevem no mesmo ciclo.
                else
                    if vld_i = '1' and r_rdy_spath = '0' and cp_idle = '1' then
                        r_rdy_spath <= '1';
                        if we_i = '1' and sts_busy = '0' then
                            r_bus_wr   <= '1';
                            r_bus_addr <= s_addr_idx;
                            r_bus_data <= data_i;
                        end if;
                    elsif vld_i = '0' then
                        r_rdy_spath <= '0';
                    end if;
                end if;

                if r_bus_wr = '1' then
                    r_bus_wr <= '0';
                    v_wr     := true;
                    v_addr   := r_bus_addr;
                    v_data   := r_bus_data;
                elsif cp_we = '1' and sts_busy = '0' then
                    v_wr   := true;
                    v_addr := to_integer(unsigned(cp_addr));
                    v_data := cp_data;
                end if;

                -- --------------------------------------------------------------------
                -- Escrita de configuração (barramento ou processador de comandos)
                -- --------------------------------------------------------------------
                if v_wr then
                    case v_addr is
                        when 16#04# => 
                            if v_data(0) = '1' then 
                                r_wgt_wr_ptr <= r_wgt_base;
                                r_inp_wr_ptr <= r_inp_base;
                                r_img_wr_ptr <= (others => '0');
                            end if;
                            if v_data(6) = '1' then 
                                r_wgt_wr_ptr <= r_wgt_base;
                            end if;
                            if v_data(7) = '1' then 
                                r_inp_wr_ptr <= r_inp_base;
                                r_img_wr_ptr <= (others => '0');
                            end if;
                            
                            s_acc_clear <= v_data(2);
                            
                            if v_data(1) = '1' then
                                s_cmd_start  <= '1';
                                cmd_no_drain <= v_data(3);
                                cmd_rst_w    <= v_data(4);
                                cmd_rst_i    <= v_data(5);
                                cmd_dbuf_en  <= v_data(8);
                            end if;

                        when 16#08# => r_run_size <= unsigned(v_data);
                        when 16#20# => r_wgt_base <= unsigned(v_data);
                        when 16#24# => r_inp_base <= unsigned(v_data);
                        when 16#28# => r_im2col_en <= v_data(0);
                        when 16#2C# => r_im_geom   <= v_data(23 downto 0);
                        when 16#30# => r_im_nwin   <= unsigned(v_data(15 downto 0));
                        when 16#34# => r_tiles_cfg <= v_data(21 downto 0);
                        when 16#3C# => r_mode      <= v_data(3 downto 0);
                        when 16#38# => r_out_cfg   <= v_data(2 downto 0);
                        when 16#40# => 
                            r_quant_shift <= v_data(4 downto 0);
                            r_quant_zero  <= v_data(15 downto 8);
                        when 16#44# => r_quant_mult <= v_data;
                        when 16#48# => r_en_relu    <= v_data(0);
                        when others =>
                            -- Banco de bias: 0x80 + 4*i, i = tile*COLS + coluna
                            if v_addr >= 16#80# and (v_addr mod 4) = 0 and
                               (v_addr - 16#80#) / 4 < BIAS_TILES * COLS then
                                r_bias_vec(((v_addr - 16#80#)/4 + 1)*32 - 1 downto ((v_addr - 16#80#)/4)*32) <= v_data;
                            end if;
                    end case;
                end if;

            end if;
        end if;
    end process;

end architecture;