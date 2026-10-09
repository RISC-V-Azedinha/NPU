-------------------------------------------------------------------------------------------------------------
--
-- File: mac_pe.vhd
--
-- ███╗   ███╗ █████╗  ██████╗    ██████╗ ███████╗
-- ████╗ ████║██╔══██╗██╔════╝    ██╔══██╗██╔════╝
-- ██╔████╔██║███████║██║         ██████╔╝█████╗  
-- ██║╚██╔╝██║██╔══██║██║         ██╔═══╝ ██╔══╝  
-- ██║ ╚═╝ ██║██║  ██║╚██████╗    ██║     ███████╗
-- ╚═╝     ╚═╝╚═╝  ╚═╝ ╚═════╝    ╚═╝     ╚══════╝
--
-- Descrição: Neural Processing Unit (NPU) - MAC Processing Element (PE)
--
-- Autor    : [André Maiolini]
-- Data     : [11/01/2026]
--
-------------------------------------------------------------------------------------------------------------
                                               

library ieee;                  -- Biblioteca padrão IEEE
use ieee.std_logic_1164.all;   -- Tipos de lógica digital
use ieee.numeric_std.all;      -- Tipos numéricos (signed, unsigned)
use work.npu_pkg.all;          -- Pacote de definições do NPU

-------------------------------------------------------------------------------------------------------------
-- ENTIDADE: Definição da interface do MAC Processing Element (PE)
-------------------------------------------------------------------------------------------------------------

entity mac_pe is 

    port (

        -----------------------------------------------------------------------------------------------------
        -- Sinais de Controle e Sincronização
        -----------------------------------------------------------------------------------------------------

        clk         : in  std_logic;                      -- Sinal de clock
        rst_n       : in  std_logic;                      -- Sinal de reset síncrono local (ativo baixo)
        soc_en_i    : in  std_logic := '1';               -- Sinal de ENABLE (default '1': habilitado se não conectado)
        
        -- Controle OS (Output Stationary)

        clear_acc   : in  std_logic;                      -- Zera o acumulador interno
        drain_output: in  std_logic;                      -- 1: Desloca dados (Shift Vertical), 0: Calcula

        -- Tiles encadeados: a MAC marcada com last_in fecha o tile; o resultado vai para o
        -- acumulador sombra (lido sem parar o array) e o acumulador recomeça do zero
        ovl_en      : in  std_logic := '0';
        last_in     : in  std_logic := '0';               -- Marca de fim de tile (viaja com a ativação)

        -----------------------------------------------------------------------------------------------------
        -- Entradas de Dados
        -----------------------------------------------------------------------------------------------------

        weight_in  : in  npu_data_t;                      -- Entrada de peso (8 bits assinados)
        act_in     : in  npu_data_t;                      -- Entrada de ativação (8 bits assinados)
        acc_in     : in  npu_acc_t;                       -- Entrada de acumulador (32 bits assinados)

        -----------------------------------------------------------------------------------------------------
        -- Saídas de Dados
        -----------------------------------------------------------------------------------------------------

        weight_out : out npu_data_t;                      -- Saída de peso (8 bits assinados)
        act_out    : out npu_data_t;                      -- Saída de ativação (8 bits assinados)
        acc_out    : out npu_acc_t;                       -- Saída de acumulador (32 bits assinados)
        last_out   : out std_logic;                       -- Marca de fim de tile para o PE à direita
        shadow_out : out npu_acc_t                        -- Resultado do último tile fechado (modo encadeado)

        -----------------------------------------------------------------------------------------------------

    );

end entity mac_pe;

-------------------------------------------------------------------------------------------------------------
-- ARQUITETURA: Imeplementação comportamental do MAC Processing Element (PE)
-------------------------------------------------------------------------------------------------------------

architecture rtl of mac_pe is

    -- Registradores internos para armazenar peso, ativação e acumulador ------------------------------------

    signal weight_reg : npu_data_t := (others => '0');    -- Registro de peso
    signal act_reg    : npu_data_t := (others => '0');    -- Registro de ativação
    signal acc_reg    : npu_acc_t  := (others => '0');    -- Registro de acumulador
    signal last_reg   : std_logic  := '0';                -- Marca de fim de tile
    signal shadow_reg : npu_acc_t  := (others => '0');    -- Acumulador sombra (tiles encadeados)

    ---------------------------------------------------------------------------------------------------------

begin 

    -- Deslocamento dos dados dos registradores para as saídas ----------------------------------------------

    act_out    <= act_reg;                                -- Saída da ativação
    weight_out <= weight_reg;                             -- Saída do peso
    acc_out    <= acc_reg;                                -- Saída do acumulador
    last_out   <= last_reg;                               -- Marca de fim de tile
    shadow_out <= shadow_reg;                             -- Resultado do último tile fechado

    -- Processo Síncrono ------------------------------------------------------------------------------------

    process(clk)
    begin

        if rising_edge(clk) then
            if rst_n = '0' then
                
                weight_reg <= (others => '0');
                act_reg    <= (others => '0');
                acc_reg    <= (others => '0');
                last_reg   <= '0';
                shadow_reg <= (others => '0');

            elsif soc_en_i = '1' then

                -- 1. Pipeline de Dados (Systolic Flow)
                -- Os dados de entrada são passados para os registradores de saída
                -- para serem consumidos pelos vizinhos no próximo ciclo.

                weight_reg <= weight_in;
                act_reg    <= act_in;
                last_reg   <= last_in;

                -- 2. Lógica do Acumulador (Output Stationary)
                if clear_acc = '1' then

                    -- Reset do acumulador para nova inferência
                    acc_reg <= (others => '0');
                
                elsif drain_output = '1' then

                    -- Modo DRAIN: Comporta-se como um shift-register vertical.
                    -- Pega o dado do PE de cima (acc_in) e passa para baixo.
                    acc_reg <= acc_in;

                elsif ovl_en = '1' and last_in = '1' then

                    -- Modo ENCADEADO: a última MAC do tile vai para o acumulador sombra, de onde o
                    -- resultado é lido enquanto o acumulador já recomeça o próximo tile
                    shadow_reg <= acc_reg + resize(weight_in * act_in, ACC_WIDTH);
                    acc_reg    <= (others => '0');

                else

                    -- Modo COMPUTAÇÃO: MAC (Multiply-Accumulate)
                    -- Acumula sobre si mesmo.
                    -- Usamos weight_in/act_in direto para minimizar latência de captura.
                    acc_reg <= acc_reg + resize(weight_in * act_in, ACC_WIDTH);
                    
                end if;

            end if;
        end if;
    end process;

    ---------------------------------------------------------------------------------------------------------

end architecture; -- rtl

-------------------------------------------------------------------------------------------------------------