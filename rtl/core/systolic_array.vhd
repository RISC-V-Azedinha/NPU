-------------------------------------------------------------------------------------------------------------
--
-- File: systolic_array.vhd
--
-- ███████╗██╗   ██╗███████╗████████╗ ██████╗ ██╗     ██╗ ██████╗
-- ██╔════╝╚██╗ ██╔╝██╔════╝╚══██╔══╝██╔═══██╗██║     ██║██╔════╝
-- ███████╗ ╚████╔╝ ███████╗   ██║   ██║   ██║██║     ██║██║     
-- ╚════██║  ╚██╔╝  ╚════██║   ██║   ██║   ██║██║     ██║██║     
-- ███████║   ██║   ███████║   ██║   ╚██████╔╝███████╗██║╚██████╗
-- ╚══════╝   ╚═╝   ╚══════╝   ╚═╝    ╚═════╝ ╚══════╝╚═╝ ╚═════╝
--
-- Descrição: Neural Processing Unit (NPU) - Systolic Array MAC Processing Element (PE)
--
-- Autor    : [André Maiolini]
-- Data     : [11/01/2026]
--
-------------------------------------------------------------------------------------------------------------
                                               
library ieee;                                                -- Biblioteca padrão IEEE
use ieee.std_logic_1164.all;                                 -- Tipos de lógica digital
use ieee.numeric_std.all;                                    -- Tipos numéricos (signed, unsigned)
use work.npu_pkg.all;                                        -- Pacote de definições do NPU

-------------------------------------------------------------------------------------------------------------
-- ENTIDADE: Definição da interface do Systolic Array
-------------------------------------------------------------------------------------------------------------

entity systolic_array is

    generic (

        ROWS       : integer := 4;                           -- Número de Linhas (Altura)
        COLS       : integer := 4;                           -- Número de Colunas (Largura)
        DATA_W     : integer := DATA_WIDTH; 
        ACC_W      : integer := ACC_WIDTH

    );

    port (

        -----------------------------------------------------------------------------------------------------
        -- Sinais de Controle e Sincronização
        -----------------------------------------------------------------------------------------------------

        clk         : in  std_logic;                         -- Sinal de clock
        rst_n       : in  std_logic;                         -- Sinal de reset síncrono local (ativo baixo)
        soc_en_i    : in  std_logic;                         -- Sinal de ENABLE
        
        -- Controles OS

        clear_acc   : in  std_logic;                         -- Zera o acumulador interno
        drain_output: in  std_logic;                         -- 1: Desloca dados (Shift Vertical), 0: Calcula

        -----------------------------------------------------------------------------------------------------
        -- Entradas (Vetores Empacotados)
        -----------------------------------------------------------------------------------------------------

        -- Streams de Entrada

        input_weights : in  std_logic_vector((COLS * DATA_W)-1 downto 0);
        input_acts    : in  std_logic_vector((ROWS * DATA_W)-1 downto 0);

        -----------------------------------------------------------------------------------------------------
        -- Saídas (Vetores Empacotados)
        -----------------------------------------------------------------------------------------------------

        -- Accs: saída válida apenas durante 'drain'

        output_accs   : out std_logic_vector((COLS * ACC_W)-1 downto 0)

        -----------------------------------------------------------------------------------------------------

    );
end entity systolic_array;

-------------------------------------------------------------------------------------------------------------
-- ARQUITETURA: Implementação comportamental do Systolic Array
-------------------------------------------------------------------------------------------------------------

architecture rtl of systolic_array is

    -- LINEARIZAÇÃO (1D) DO SYSTOLIC ARRAY ------------------------------------------------------------------

    -- FIOS HORIZONTAIS (Ativações):

    -- Cada linha tem 'COLS' PEs, mas precisa de COLS+1 conexões (1 entrada + conexões internas + 1 saída final).
    -- Total de nós = ROWS * (COLS + 1)

    type h_wires_t is array (0 to ROWS * (COLS + 1) - 1) of npu_data_t;
    signal act_wires : h_wires_t;

    -- FIOS VERTICAIS (Pesos e Acumuladores):

    -- Cada coluna tem 'ROWS' PEs, precisa de ROWS+1 conexões (cima à baixo).
    -- Total de nós = (ROWS + 1) * COLS

    type v_wires_w_t is array (0 to (ROWS + 1) * COLS - 1) of npu_data_t;
    signal weight_wires : v_wires_w_t;

    type v_wires_a_t is array (0 to (ROWS + 1) * COLS - 1) of npu_acc_t;
    signal acc_wires : v_wires_a_t;

    -- Calcula índice linear para fios HORIZONTAIS
    -- Imagine esticar as linhas uma depois da outra.
    -- Largura da "linha virtual" é COLS + 1

    function get_h_idx(row, col : integer) return integer is
    begin
        return row * (COLS + 1) + col;
    end function;

    -- Calcula índice linear para fios VERTICAIS
    -- Imagine esticar as linhas de conexão vertical.
    -- A largura aqui é COLS (número de colunas)

    function get_v_idx(row, col : integer) return integer is
    begin
        return row * COLS + col;
    end function;

    ---------------------------------------------------------------------------------------------------------

begin 

    -- Injeção de Dados nas Bordas --------------------------------------------------------------------------

    -- Borda Esquerda (Ativações): Conecta a porta de entrada no índice (row, 0)
    GEN_INPUT_ACTS: for i in 0 to ROWS-1 generate
        act_wires(get_h_idx(i, 0)) <= signed(input_acts((i+1)*DATA_W-1 downto i*DATA_W));
    end generate;

    -- Borda Superior (Pesos): Conecta a porta de entrada no índice (0, col)
    GEN_INPUT_WEIGHTS: for j in 0 to COLS-1 generate
        weight_wires(get_v_idx(0, j)) <= signed(input_weights((j+1)*DATA_W-1 downto j*DATA_W));
    end generate;

    -- Borda Superior (Acumuladores): Injeta ZERO no topo (índice 0, col)
    GEN_INPUT_ACCS: for j in 0 to COLS-1 generate
        acc_wires(get_v_idx(0, j)) <= (others => '0'); 
    end generate;

    -- Criação da Matriz ------------------------------------------------------------------------------------

    GEN_ROWS: for i in 0 to ROWS-1 generate
        GEN_COLS: for j in 0 to COLS-1 generate
            pe_inst: entity work.mac_pe
                port map (
                    clk          => clk,
                    rst_n        => rst_n,
                    soc_en_i     => soc_en_i,
                    clear_acc    => clear_acc,
                    drain_output => drain_output,
                    weight_in    => weight_wires(get_v_idx(i, j)),
                    weight_out   => weight_wires(get_v_idx(i+1, j)),
                    act_in       => act_wires(get_h_idx(i, j)),
                    act_out      => act_wires(get_h_idx(i, j+1)),
                    acc_in       => acc_wires(get_v_idx(i, j)),
                    acc_out      => acc_wires(get_v_idx(i+1, j))
                );
        end generate GEN_COLS;
    end generate GEN_ROWS;

    -- Coleta de Saídas  ------------------------------------------------------------------------------------

    GEN_OUTPUTS: for j in 0 to COLS-1 generate
        output_accs((j+1)*ACC_W-1 downto j*ACC_W) <= std_logic_vector(acc_wires(get_v_idx(ROWS, j)));
    end generate;

end architecture; -- rtl

-------------------------------------------------------------------------------------------------------------