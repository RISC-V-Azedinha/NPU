-------------------------------------------------------------------------------------------------------------
--
-- File: npu_top.vhd
-- 
-- ███╗   ██╗██████╗ ██╗   ██╗
-- ████╗  ██║██╔══██╗██║   ██║
-- ██╔██╗ ██║██████╔╝██║   ██║
-- ██║╚██╗██║██╔═══╝ ██║   ██║
-- ██║ ╚████║██║     ╚██████╔╝
-- ╚═╝  ╚═══╝╚═╝      ╚═════╝ 
--
-- Descrição: Neural Processing Unit (NPU) - TOP-LEVEL (IP)
--
-- Autor    : [André Maiolini]
-- Data     : [21/01/2026]
--
------------------------------------------------------------------------------------------------------------- 
--
-- >>> Mapa de Memória (Offsets)
-- 
-- Base (Controle DMA/FSM)
--
--  0x00 : STATUS (RO) [0=Busy, 1=Done, 3=Saída disponível, 4=Programa de descritores terminado]
--  0x04 : CMD    (WO) 
--
--   - Bit[0]: RST_DMA_PTRS (Zera ponteiros de escrita - Nova Carga)
--   - Bit[1]: START        (Inicia a execução)
--   - Bit[2]: ACC_CLEAR    (1=Limpa Array antes de rodar, 0=Acumula/ACC_NO_CLEAR)
--   - Bit[3]: ACC_NO_DRAIN (1=Mantém resultado no Array/Tiling, 0=Salva na FIFO)
--   - Bit[4]: RST_W_RD     (1=Zera ponteiro leitura Pesos, 0=Continua de onde parou)
--   - Bit[5]: RST_I_RD     (1=Zera ponteiro leitura Inputs, 0=Continua de onde parou)
--   - Bit[6]: RST_WR_W     (1=Zera ponteiro de escrita Pesos, 0=Continua de onde parou)
--   - Bit[7]: RST_WR_I     (1=Zera ponteiro de escrita Inputs, 0=Continua de onde parou)
--   - Bit[8]: DBUF_EN      (1=Double Buffering/Ping-Pong neste START, 0=Modo legado/banco único)
--
--   Bit[8] só tem efeito se o IP for gerado com o generic DOUBLE_BUFFER => true (default: false,
--   idêntico ao comportamento/recursos originais). Com DOUBLE_BUFFER=true, o host pode carregar o
--   próximo tile (W_PORT/I_PORT) enquanto a NPU ainda está BUSY computando/drenando o tile atual,
--   pois escrita e leitura passam a usar bancos físicos distintos (ping-pong).
--
--  0x0C : DESC   (WO) [Programa do processador de comandos - Fixed Dest: WRITE/WAIT/END, ver npu_cmd_proc]
--  0x08 : CONFIG (RW) [Tamanho do Tile / Ciclos]
--  0x10 : W_PORT (WO) [Porta de Pesos - Fixed Dest]
--  0x14 : I_PORT (WO) [Porta de Inputs - Fixed Dest]
--  0x18 : O_DATA (RO) [Leitura de Saída]
--  0x1C : IMG    (WO) [Porta da imagem crua do im2col - Fixed Dest; 4 pixels int8 por palavra]
--  0x20 : W_BASE (RW) [Base da região de Pesos: destino de RST_DMA_PTRS/RST_WR_W/RST_W_RD]
--  0x24 : I_BASE (RW) [Base da região de Inputs: destino de RST_DMA_PTRS/RST_WR_I/RST_I_RD]
--
--   Com as bases, várias camadas mantêm seus pesos residentes na RAM local (cada uma
--   na sua região), carregados uma única vez. Reset = 0 (comportamento original).
--
--  0x28 : IM2COL_CTRL (RW) [Bit 0: 1 = Inputs gerados pelo im2col a partir da imagem (porta IMG)]
--  0x2C : IM2COL_GEOM (RW) [7:0 IN_W | 15:8 OUT_W | 19:16 STRIDE | 23:20 KW]
--  0x30 : IM2COL_NWIN (RW) [15:0 Total de janelas; as excedentes do último grupo leem zero]
--
--   Com o im2col ligado, cada START consome um grupo de ROWS janelas (K = CONFIG taps) e o
--   próximo START segue para o grupo seguinte; RST_I_RD no START volta à janela 0. O ponteiro
--   da porta IMG volta a zero com RST_DMA_PTRS ou RST_WR_I.
--
--  0x34 : TILES   (RW) [15:0 Tiles por START (0/1 = um tile) | 16 RW_W | 17 RW_I]
--  0x38 : OUT_CFG (RW) [0 ORDER: linhas na ordem 0..ROWS-1 | 1 UNPACK: uma ativação por palavra |
--                       2 LOOP: a saída vai para a RAM de Inputs a partir de I_BASE (fusão de camadas)]
--  0x3C : MODE    (RW) [0 GEMV: densa com lote 1; linha r acumula as features k = r mod ROWS, um
--                       peso por PE (memória de pesos em 4 bancos); as ROWS linhas são somadas
--                       antes da PPU, que entrega uma palavra por tile. Base dos pesos múltipla de 4 |
--                       1 STREAM_I: cada leitura espera o seu Input (ou os pixels do im2col) ser escrito |
--                       2 STREAM_W: idem para os Pesos | 3 OVERLAP: tiles encadeados, sem esvaziar o array
--                       (acumuladores sombra; exige CONFIG > COLS; UNPACK não é suportado nesse modo)]
--  0x80+  : BIAS   (RW) [Banco: 0x80 + 16*tile + 4*coluna; TILES bit 18 = um vetor por tile]
--
--   Com TILES = N, um START executa N tiles em sequência: cada tile computa CONFIG ciclos, esvazia
--   o array (ROWS linhas) na FIFO e segue; RW_W/RW_I voltam a leitura de Pesos/Inputs à base a
--   cada tile. A drenagem de um tile só começa quando ele cabe inteiro na FIFO. Enquanto a NPU
--   está BUSY, ler a O_DATA com a FIFO vazia segura o barramento até chegar o próximo resultado
--   (o DMA, em modo de origem fixa, esvazia a FIFO em paralelo com o cômputo).
--
-- Configuração Estática 
-- 
--  0x40 : QUANT_CFG
--  0x44 : QUANT_MULT
--  0x48 : CONTROL_FLAGS (ReLU, etc)
--
-------------------------------------------------------------------------------------------------------------

library ieee;                                                    -- Biblioteca padrão IEEE
use ieee.std_logic_1164.all;                                     -- Tipos de lógica digital
use ieee.numeric_std.all;                                        -- Tipos numéricos (signed, unsigned)
use work.npu_pkg.all;                                            -- Pacote de definições do NPU

-------------------------------------------------------------------------------------------------------------
-- ENTIDADE: Definição da interface da NPU
-------------------------------------------------------------------------------------------------------------

entity npu_top is

    generic (

        ROWS        : integer := 4;                              -- Quantidade de Linhas do Array Sistólico
        COLS        : integer := 4;                              -- Quantidade de Colunas do Array Sistólico
        ACC_W       : integer := 32;                             -- Largura do Acumulador de Entrada
        DATA_W      : integer := 8;                              -- Largura do Dado de Saída
        QUANT_W     : integer := 32;                             -- Largura dos Parâmetros de Quantização
        FIFO_DEPTH  : integer := 2048;                           -- Define o tamanho da RAM (4KB = 1024 * 32b)
        DOUBLE_BUFFER : boolean := false;                        -- Retrocompatível: false = recursos originais
        IM2COL      : boolean := true                            -- false = NPU sem o hardware de im2col

    );

    port (

        -----------------------------------------------------------------------------------------------------
        -- Sinais de Controle e Sincronização
        -----------------------------------------------------------------------------------------------------

        clk         : in  std_logic;                             -- Clock do sistema
        rst_n       : in  std_logic;                             -- Reset síncrono (ativo em nível baixo)
        soc_en_i    : in  std_logic := '1';                      -- Sinal de ENABLE (default '1': testbenches que não conectam continuam habilitadas)

        -----------------------------------------------------------------------------------------------------
        -- Interface para Mapeamento em Memória (MMIO)
        -----------------------------------------------------------------------------------------------------

        vld_i       : in  std_logic;                             -- Valid
        rdy_o       : out std_logic;                             -- Ready
        we_i        : in  std_logic;                             -- 1=Write, 0=Read
        addr_i      : in  std_logic_vector(31 downto 0);         -- Endereço
        data_i      : in  std_logic_vector(31 downto 0);         -- Dado vindo da CPU
        data_o      : out std_logic_vector(31 downto 0);         -- Dado indo para a CPU

        -----------------------------------------------------------------------------------------------------
        -- Interface para Interrupção (IRQ)
        -----------------------------------------------------------------------------------------------------

        irq_done_o  : out std_logic

        -----------------------------------------------------------------------------------------------------

    );

end entity npu_top;

-------------------------------------------------------------------------------------------------------------
-- ARQUITETURA: Implementação comportamental da NPU
-------------------------------------------------------------------------------------------------------------

architecture rtl of npu_top is

    -- Register File <-> Controller -------------------------------------------------------------------------

    signal s_cmd_start           : std_logic := '0';
    signal s_cmd_no_drain        : std_logic := '0';
    signal s_cmd_rst_w           : std_logic := '0';
    signal s_cmd_rst_i           : std_logic := '0';
    signal s_cmd_dbuf_en         : std_logic := '0';
    signal s_sts_busy            : std_logic := '0';
    signal s_sts_done            : std_logic := '0';
    signal s_cfg_run_size        : unsigned(31 downto 0) := (others => '0');
    signal s_wgt_base            : unsigned(31 downto 0) := (others => '0');
    signal s_inp_base            : unsigned(31 downto 0) := (others => '0');

    -- im2col em hardware ------------------------------------------------------------------------------------

    signal s_img_we              : std_logic := '0';
    signal s_img_wr_ptr          : unsigned(31 downto 0) := (others => '0');
    signal s_cfg_im2col_en       : std_logic := '0';
    signal s_cfg_im_in_w         : unsigned(7 downto 0) := (others => '0');
    signal s_cfg_im_out_w        : unsigned(7 downto 0) := (others => '0');
    signal s_cfg_im_stride       : unsigned(3 downto 0) := (others => '0');
    signal s_cfg_im_kw           : unsigned(3 downto 0) := (others => '0');
    signal s_cfg_im_nwin         : unsigned(15 downto 0) := (others => '0');

    -- Double Buffering (Ping-Pong) ---------------------------------------------------------------------------

    signal s_wr_bank             : std_logic := '0';
    signal s_rd_bank             : std_logic := '0';

    -- Register File <-> Datapath ---------------------------------------------------------------------------

    signal s_cmd_clear           : std_logic := '0';
    signal s_ram_w_data          : std_logic_vector(31 downto 0) := (others => '0');
    signal s_wgt_we              : std_logic := '0';
    signal s_inp_we              : std_logic := '0';
    signal s_wgt_wr_ptr          : unsigned(31 downto 0) := (others => '0');
    signal s_inp_wr_ptr          : unsigned(31 downto 0) := (others => '0');
    signal s_fifo_pop            : std_logic := '0';
    signal s_fifo_r_valid        : std_logic := '0';
    signal s_fifo_r_data         : std_logic_vector(31 downto 0) := (others => '0');

    -- Config Signals ---------------------------------------------------------------------------------------

    signal s_cfg_relu            : std_logic := '0';
    signal s_cfg_quant_sh        : std_logic_vector(4 downto 0) := (others => '0');
    signal s_cfg_quant_zo        : std_logic_vector(DATA_W-1 downto 0) := (others => '0');
    signal s_cfg_quant_mul       : std_logic_vector(QUANT_W-1 downto 0) := (others => '0');
    signal s_cfg_bias_vec        : std_logic_vector((BIAS_TILES*COLS*ACC_W)-1 downto 0) := (others => '0');
    signal s_cfg_bias_per_tile   : std_logic := '0';
    signal s_cfg_bias_base       : unsigned(2 downto 0) := (others => '0');

    -- Descritores de camada (processador de comandos) ------------------------------------------------------

    signal s_desc_we             : std_logic := '0';
    signal s_cp_we               : std_logic := '0';
    signal s_cp_addr             : std_logic_vector(7 downto 0) := (others => '0');
    signal s_cp_data             : std_logic_vector(31 downto 0) := (others => '0');
    signal s_cp_idle             : std_logic := '1';
    signal s_desc_ready          : std_logic := '1';
    signal s_cfg_gemv            : std_logic := '0';
    signal s_cfg_stream_i        : std_logic := '0';
    signal s_cfg_stream_w        : std_logic := '0';
    signal s_cfg_overlap         : std_logic := '0';
    signal s_cfg_out_loop        : std_logic := '0';
    signal s_ctl_issue           : std_logic := '0';
    signal s_ctl_core_last       : std_logic := '0';
    signal s_im2col_ready        : std_logic := '1';

    -- Controller <-> Datapath ------------------------------------------------------------------------------

    signal s_wgt_rd_ptr          : unsigned(31 downto 0) := (others => '0');
    signal s_inp_rd_ptr          : unsigned(31 downto 0) := (others => '0');
    signal s_ctl_acc_dump        : std_logic := '0';
    signal s_ctl_core_vld        : std_logic := '0';
    signal s_out_space_ok        : std_logic := '1';
    signal s_out_busy            : std_logic := '0';

    -- Sequenciador de tiles e formato da saída ----------------------------------------------------------------

    signal s_cfg_tiles           : unsigned(15 downto 0) := (others => '0');
    signal s_cfg_tile_rw_w       : std_logic := '0';
    signal s_cfg_tile_rw_i       : std_logic := '0';
    signal s_cfg_out_order       : std_logic := '0';
    signal s_cfg_out_unpack      : std_logic := '0';

    -- Sinal Auxiliar para Edge Detector --------------------------------------------------------------------

    signal r_done_dly            : std_logic := '0';

    ---------------------------------------------------------------------------------------------------------

begin

    -- ========================================================================
    -- DETECTOR DE BORDA DA INTERRUPÇÃO
    -- ========================================================================
    -- Gera um pulso de 1 ciclo quando 's_sts_done' transita de 0 para 1.
    
    process(clk)
    begin

        if rising_edge(clk) then

            if rst_n = '0' then

                r_done_dly <= '0';
                irq_done_o <= '0';

            elsif soc_en_i = '1' then 

                r_done_dly <= s_sts_done; 

                if (s_sts_done = '1' and r_done_dly = '0') then
                    irq_done_o <= '1'; 
                else
                    irq_done_o <= '0';
                end if;

            end if;
        end if;

    end process;

    ---------------------------------------------------------------------------------------------------------
    -- Instância: Register File & MMIO
    ---------------------------------------------------------------------------------------------------------

    u_reg_file : entity work.npu_register_file
        generic map (
            ACC_W         => ACC_W, 
            DATA_W        => DATA_W, 
            QUANT_W       => QUANT_W, 
            COLS          => COLS
        )
        port map (
            
            -- Sinais de Controle e Sincronismo
            clk           => clk, 
            rst_n         => rst_n,

            -- Memory Mapped I/O (MMIO)
            vld_i         => vld_i, 
            rdy_o         => rdy_o, 
            we_i          => we_i, 
            addr_i        => addr_i, 
            data_i        => data_i, 
            data_o        => data_o,

            -- Controller Interface
            sts_busy      => s_sts_busy, 
            sts_done      => s_sts_done,
            cmd_start     => s_cmd_start,
            cmd_clear     => s_cmd_clear,
            cmd_no_drain  => s_cmd_no_drain,
            cmd_rst_w     => s_cmd_rst_w,
            cmd_rst_i     => s_cmd_rst_i,
            cmd_dbuf_en   => s_cmd_dbuf_en,

            -- Datapath Interface
            fifo_r_valid  => s_fifo_r_valid, 
            fifo_r_data   => s_fifo_r_data, 
            fifo_pop      => s_fifo_pop,
            ram_w_data    => s_ram_w_data, 
            wgt_we        => s_wgt_we, 
            inp_we        => s_inp_we, 
            wgt_wr_ptr    => s_wgt_wr_ptr, 
            inp_wr_ptr    => s_inp_wr_ptr,
            wgt_base      => s_wgt_base,
            inp_base      => s_inp_base,
            img_we        => s_img_we,
            img_wr_ptr    => s_img_wr_ptr,
            cfg_im2col_en => s_cfg_im2col_en,
            cfg_im_in_w   => s_cfg_im_in_w,
            cfg_im_out_w  => s_cfg_im_out_w,
            cfg_im_stride => s_cfg_im_stride,
            cfg_im_kw     => s_cfg_im_kw,
            cfg_im_nwin   => s_cfg_im_nwin,
            cfg_tiles     => s_cfg_tiles,
            cfg_tile_rw_w => s_cfg_tile_rw_w,
            cfg_tile_rw_i => s_cfg_tile_rw_i,
            cfg_out_order => s_cfg_out_order,
            cfg_out_unpack=> s_cfg_out_unpack,

            -- Configs Interface
            cfg_run_size  => s_cfg_run_size, 
            cfg_relu      => s_cfg_relu, 
            cfg_quant_sh  => s_cfg_quant_sh, 
            cfg_quant_zo  => s_cfg_quant_zo, 
            cfg_quant_mul => s_cfg_quant_mul, 
            cfg_bias_vec  => s_cfg_bias_vec,
            cfg_bias_per_tile => s_cfg_bias_per_tile,
            cfg_bias_base => s_cfg_bias_base,
            cfg_gemv      => s_cfg_gemv,
            cfg_stream_i  => s_cfg_stream_i,
            cfg_stream_w  => s_cfg_stream_w,
            cfg_overlap   => s_cfg_overlap,
            cfg_out_loop  => s_cfg_out_loop,
            desc_we       => s_desc_we,
            cp_we         => s_cp_we,
            cp_addr       => s_cp_addr,
            cp_data       => s_cp_data,
            cp_idle       => s_cp_idle,
            desc_ready    => s_desc_ready

        );

    ---------------------------------------------------------------------------------------------------------
    -- Instância: Processador de comandos (descritores de camada, porta DESC)
    ---------------------------------------------------------------------------------------------------------

    u_cmd_proc : entity work.npu_cmd_proc
        port map (
            clk           => clk,
            rst_n         => rst_n,
            soc_en_i      => soc_en_i,
            desc_we       => s_desc_we,
            desc_data     => data_i,
            cp_we         => s_cp_we,
            cp_addr       => s_cp_addr,
            cp_data       => s_cp_data,
            sts_busy      => s_sts_busy,
            sts_done      => s_sts_done,
            cp_idle       => s_cp_idle,
            desc_ready    => s_desc_ready
        );

    ---------------------------------------------------------------------------------------------------------
    -- Instância: Controller (FSM)
    ---------------------------------------------------------------------------------------------------------

    u_controller : entity work.npu_controller
        generic map (
            ROWS          => ROWS, 
            COLS          => COLS
        )
        port map (

            -- Sinais de Controle e Sincronismo
            clk           => clk, 
            rst_n         => rst_n,
            soc_en_i      => soc_en_i,

            -- RegFile Interface
            cmd_start     => s_cmd_start,
            cmd_no_drain  => s_cmd_no_drain,
            cmd_rst_w     => s_cmd_rst_w,
            cmd_rst_i     => s_cmd_rst_i,
            cmd_dbuf_en   => s_cmd_dbuf_en,
            cfg_run_size  => s_cfg_run_size,
            wgt_base      => s_wgt_base,
            inp_base      => s_inp_base,
            cfg_tiles     => s_cfg_tiles,
            cfg_tile_rw_w => s_cfg_tile_rw_w,
            cfg_tile_rw_i => s_cfg_tile_rw_i,
            cfg_gemv      => s_cfg_gemv,
            cfg_stream_i  => s_cfg_stream_i,
            cfg_stream_w  => s_cfg_stream_w,
            inp_wr_ptr    => s_inp_wr_ptr,
            wgt_wr_ptr    => s_wgt_wr_ptr,
            cfg_im2col_en => s_cfg_im2col_en,
            im2col_ready  => s_im2col_ready,
            cfg_overlap   => s_cfg_overlap,
            ctl_issue     => s_ctl_issue,
            ctl_core_last => s_ctl_core_last,

            -- System Interface
            sts_busy      => s_sts_busy,
            sts_done      => s_sts_done,

            -- Datapath Interface
            wgt_rd_ptr    => s_wgt_rd_ptr,
            inp_rd_ptr    => s_inp_rd_ptr,
            ctl_ram_re    => open,
            ctl_core_vld  => s_ctl_core_vld,
            ctl_acc_dump  => s_ctl_acc_dump,

            -- Double Buffering (Ping-Pong)
            rd_bank_o     => s_rd_bank,
            wr_bank_o     => s_wr_bank,

            -- Backpressure (STALL)
            out_space_ok  => s_out_space_ok,
            out_busy      => s_out_busy

        );

    ---------------------------------------------------------------------------------------------------------
    -- Instância: Datapath (RAMs, Core, FIFO)
    ---------------------------------------------------------------------------------------------------------

    u_datapath : entity work.npu_datapath
        generic map (
            ROWS          => ROWS,
            COLS          => COLS,
            ACC_W         => ACC_W,
            DATA_W        => DATA_W,
            QUANT_W       => QUANT_W,
            FIFO_DEPTH    => FIFO_DEPTH,
            DOUBLE_BUFFER => DOUBLE_BUFFER,
            IM2COL        => IM2COL
        )
        port map (

            clk                 => clk,
            rst_n               => rst_n,
            soc_en_i            => soc_en_i,

            -- Write Side (RegFile)
            wgt_we              => s_wgt_we,
            inp_we              => s_inp_we,
            w_data              => s_ram_w_data,
            wgt_wr_ptr          => s_wgt_wr_ptr,
            inp_wr_ptr          => s_inp_wr_ptr,

            -- Read Side (Controller)
            wgt_rd_ptr          => s_wgt_rd_ptr,
            inp_rd_ptr          => s_inp_rd_ptr,
            ctl_acc_clear       => s_cmd_clear,
            ctl_acc_dump        => s_ctl_acc_dump,
            ctl_valid_in        => s_ctl_core_vld,

            -- im2col em hardware
            img_we              => s_img_we,
            img_wr_ptr          => s_img_wr_ptr,
            cfg_im2col_en       => s_cfg_im2col_en,
            cfg_im_in_w         => s_cfg_im_in_w,
            cfg_im_out_w        => s_cfg_im_out_w,
            cfg_im_stride       => s_cfg_im_stride,
            cfg_im_kw           => s_cfg_im_kw,
            cfg_im_nwin         => s_cfg_im_nwin,
            cfg_run_size        => s_cfg_run_size,
            ctl_start           => s_cmd_start,
            ctl_rst_i           => s_cmd_rst_i,

            -- Double Buffering (Ping-Pong)
            wr_bank             => s_wr_bank,
            rd_bank             => s_rd_bank,

            -- Configs
            cfg_relu            => s_cfg_relu, 
            cfg_quant_sh        => s_cfg_quant_sh, 
            cfg_quant_zo        => s_cfg_quant_zo, 
            cfg_quant_mul       => s_cfg_quant_mul, 
            cfg_bias_vec        => s_cfg_bias_vec,
            
            -- FIFO
            fifo_pop            => s_fifo_pop, 
            fifo_r_valid        => s_fifo_r_valid, 
            fifo_r_data         => s_fifo_r_data,
            cfg_bias_per_tile   => s_cfg_bias_per_tile,
            cfg_bias_base       => s_cfg_bias_base,
            cfg_gemv            => s_cfg_gemv,
            ctl_last            => s_ctl_core_last,
            ctl_issue           => s_ctl_issue,
            im2col_ready_o      => s_im2col_ready,
            cfg_overlap         => s_cfg_overlap,
            cfg_out_loop        => s_cfg_out_loop,
            inp_base            => s_inp_base,
            cfg_out_order       => s_cfg_out_order,
            cfg_out_unpack      => s_cfg_out_unpack,
            out_space_ok        => s_out_space_ok,
            out_busy            => s_out_busy
        
        );

    ---------------------------------------------------------------------------------------------------------

end architecture; -- rtl

-------------------------------------------------------------------------------------------------------------