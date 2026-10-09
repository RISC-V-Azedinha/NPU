-------------------------------------------------------------------------------------------------------------
--
-- File: npu_core.vhd
-- 
-- ███╗   ██╗██████╗ ██╗   ██╗
-- ████╗  ██║██╔══██╗██║   ██║
-- ██╔██╗ ██║██████╔╝██║   ██║
-- ██║╚██╗██║██╔═══╝ ██║   ██║
-- ██║ ╚████║██║     ╚██████╔╝
-- ╚═╝  ╚═══╝╚═╝      ╚═════╝ 
--
-- Descrição: Neural Processing Unit (NPU) - Interconexão CORE (Output Stationary)
--
-- Autor    : [André Maiolini]
-- Data     : [19/01/2026]
--
-------------------------------------------------------------------------------------------------------------   

library ieee;                                                -- Biblioteca padrão IEEE
use ieee.std_logic_1164.all;                                 -- Tipos de lógica digital
use ieee.numeric_std.all;                                    -- Tipos numéricos (signed, unsigned)
use work.npu_pkg.all;                                        -- Pacote de definições do NPU

-------------------------------------------------------------------------------------------------------------
-- ENTIDADE: Definição da interface da NPU CORE
-------------------------------------------------------------------------------------------------------------

entity npu_core is

    generic (

        ROWS       : integer := 4;                           -- Número de Linhas (Altura)
        COLS       : integer := 4;                           -- Número de Colunas (Largura)
        DATA_W     : integer := DATA_WIDTH;                  -- Largura dos Dados
        ACC_W      : integer := ACC_WIDTH                    -- Largura dos Acumuladores

    );

    port (

        -----------------------------------------------------------------------------------------------------
        -- Sinais de Controle e Sincronização
        -----------------------------------------------------------------------------------------------------

        clk         : in  std_logic;                         -- Sinal de clock
        rst_n       : in  std_logic;                         -- Sinal de reset síncrono local (ativo baixo)
        soc_en_i    : in  std_logic := '1';                  -- Sinal de ENABLE (default '1': habilitado se não conectado)
        acc_clear   : in  std_logic;                         -- Limpa os acumuladores internos dos PEs
        acc_dump    : in  std_logic;                         -- Ativa o modo "Drain" (saída dos dados)
        
        -----------------------------------------------------------------------------------------------------
        -- Dados de Entrada (Streams)
        -----------------------------------------------------------------------------------------------------

        -- Valid de entrada (indica que input_acts e input_weights são validos neste ciclo)
        valid_in      : in  std_logic;                       

        -- Pesos fluem verticalmente (agora precisam de skew também)
        input_weights : in  std_logic_vector((COLS * DATA_W)-1 downto 0);

        -- Ativações fluem horizontalmente
        input_acts    : in  std_logic_vector((ROWS * DATA_W)-1 downto 0);
        gemv_en       : in  std_logic := '0';                -- Modo GEMV: um peso por PE
        gemv_weights  : in  std_logic_vector((ROWS * COLS * DATA_W)-1 downto 0) := (others => '0');
        ovl_en        : in  std_logic := '0';                -- Tiles encadeados (acumuladores sombra)
        last_in       : in  std_logic := '0';                -- Esta entrada fecha o tile
        
        -----------------------------------------------------------------------------------------------------
        -- Saída
        -----------------------------------------------------------------------------------------------------

        -- Acumuladores de saída (vetor empacotado): Largura = COLS * 16 bits
        output_accs   : out std_logic_vector((COLS * ACC_W)-1 downto 0);

        -- Sinal de validade dos dados de saída
        valid_out     : out std_logic

        -----------------------------------------------------------------------------------------------------

    );

end entity npu_core;

-------------------------------------------------------------------------------------------------------------
-- ARQUITETURA: Implementação comportamental da NPU CORE
-------------------------------------------------------------------------------------------------------------

architecture struct of npu_core is

    -- Sinais de Interconexão -------------------------------------------------------------------------------

    signal acts_skewed    : std_logic_vector((ROWS * DATA_W)-1 downto 0);
    signal weights_skewed : std_logic_vector((COLS * DATA_W)-1 downto 0);

    -- Sinais do Array --------------------------------------------------------------------------------------

    signal array_out_accs : std_logic_vector((COLS * ACC_W)-1 downto 0);

    -- GEMV: o peso do PE(i,j) chega com o mesmo atraso (i + j) que teria descendo pela coluna
    type gemv_arr_t is array (0 to ROWS*COLS-1) of npu_data_t;
    signal gemv_in        : gemv_arr_t;
    signal gemv_skewed    : std_logic_vector((ROWS * COLS * DATA_W)-1 downto 0);

    -- Marca de fim de tile com o mesmo atraso (i) da ativação da linha i
    signal last_gated     : std_logic;
    signal last_skewed    : std_logic_vector(ROWS-1 downto 0);
    signal ovl_valid      : std_logic;
    signal ovl_accs       : std_logic_vector((COLS * ACC_W)-1 downto 0);

    ---------------------------------------------------------------------------------------------------------

begin

    -- INPUT BUFFER HORIZONTAL ------------------------------------------------------------------------------

    -- Aplica atrasos triangulares nas linhas de input_acts

    u_input_acts_buffer : entity work.input_buffer
        generic map ( 
            ROWS          => ROWS, -- Número de canais de skew (aqui são as linhas)
            DATA_W        => DATA_W 
        )
        port map (
            clk           => clk,
            rst_n         => rst_n,
            soc_en_i      => soc_en_i,
            valid_in      => valid_in,
            data_in       => input_acts,
            data_out      => acts_skewed
        );

    -- INPUT BUFFER VERTICAL --------------------------------------------------------------------------------

    -- Aplica atrasos triangulares nas colunas de input_weights

    u_input_weights_buffer : entity work.input_buffer
        generic map ( 
            ROWS          => COLS, -- Para pesos, o número de canais é o número de COLUNAS
            DATA_W        => DATA_W 
        )
        port map (
            clk           => clk,
            rst_n         => rst_n,
            soc_en_i      => soc_en_i,
            valid_in      => valid_in,
            data_in       => input_weights,
            data_out      => weights_skewed
        );

    -- SYSTOLIC ARRAY ---------------------------------------------------------------------------------------

    u_systolic_array : entity work.systolic_array
        generic map ( 
            ROWS          => ROWS, 
            COLS          => COLS, 
            DATA_W        => DATA_W, 
            ACC_W         => ACC_W 
        )
        port map (
            clk           => clk,
            rst_n         => rst_n,
            soc_en_i      => soc_en_i,
            clear_acc     => acc_clear,
            drain_output  => acc_dump,
            input_weights => weights_skewed,
            input_acts    => acts_skewed,
            gemv_en       => gemv_en,
            gemv_weights  => gemv_skewed,
            ovl_en        => ovl_en,
            input_last    => last_skewed,
            ovl_valid     => ovl_valid,
            ovl_accs      => ovl_accs,
            output_accs   => array_out_accs
        );

    -- Saída ------------------------------------------------------------------------------------------------

    -- No modo OS, a saída é válida enquanto estamos drenando (acc_dump = '1').
    
    output_accs <= ovl_accs  when ovl_en = '1' else array_out_accs;

    last_gated <= last_in and valid_in;

    GEN_LAST_SKEW : for i in 0 to ROWS-1 generate
        GEN_L0 : if i = 0 generate
            last_skewed(0) <= last_gated;
        end generate;
        GEN_LN : if i > 0 generate
            signal sr : std_logic_vector(0 to i-1) := (others => '0');
        begin
            process(clk)
            begin
                if rising_edge(clk) then
                    if rst_n = '0' then
                        sr <= (others => '0');
                    elsif soc_en_i = '1' then
                        sr(0) <= last_gated;
                        for k in 1 to i-1 loop
                            sr(k) <= sr(k-1);
                        end loop;
                    end if;
                end if;
            end process;
            last_skewed(i) <= sr(i-1);
        end generate;
    end generate GEN_LAST_SKEW;

    GEN_GEMV_SKEW : for idx in 0 to ROWS*COLS-1 generate
        constant C_DELAY : integer := (idx / COLS) + (idx mod COLS);
    begin
        gemv_in(idx) <= signed(gemv_weights((idx+1)*DATA_W-1 downto idx*DATA_W)) when valid_in = '1'
                        else (others => '0');

        GEN_D0 : if C_DELAY = 0 generate
            gemv_skewed((idx+1)*DATA_W-1 downto idx*DATA_W) <= std_logic_vector(gemv_in(idx));
        end generate;

        GEN_DN : if C_DELAY > 0 generate
            type sr_t is array (0 to C_DELAY-1) of npu_data_t;
            signal sr : sr_t := (others => (others => '0'));
        begin
            process(clk)
            begin
                if rising_edge(clk) then
                    if rst_n = '0' then
                        sr <= (others => (others => '0'));
                    elsif soc_en_i = '1' then
                        sr(0) <= gemv_in(idx);
                        for k in 1 to C_DELAY-1 loop
                            sr(k) <= sr(k-1);
                        end loop;
                    end if;
                end if;
            end process;
            gemv_skewed((idx+1)*DATA_W-1 downto idx*DATA_W) <= std_logic_vector(sr(C_DELAY-1));
        end generate;
    end generate GEN_GEMV_SKEW;
    
    -- Como o Systolic Array (no modo Drain) já coloca o dado na saída combinacionalmente
    -- (baseado no registrador interno), o dado é válido no mesmo ciclo que acc_dump está alto.

    valid_out   <= ovl_valid when ovl_en = '1' else acc_dump;

    ---------------------------------------------------------------------------------------------------------

end architecture; -- rtl

-------------------------------------------------------------------------------------------------------------