-------------------------------------------------------------------------------------------------------------
--
-- File: npu_cmd_proc.vhd
--
-- Descrição: NPU - Processador de comandos (descritores de camada)
--
--            Executa um programa de configuração recebido pela porta DESC (0x0C), tipicamente por DMA
--            a partir de uma lista montada uma única vez na RAM: a CPU dispara a rede inteira com uma
--            transferência, em vez de dezenas de escritas MMIO por camada.
--
--            Formato (palavras de 32 bits):
--              WRITE : cabeçalho [31:28] = 1, [7:0] = offset do registrador; a palavra seguinte é o
--                      dado. Escreve qualquer registrador de configuração (inclusive CMD/START).
--              WAIT  : cabeçalho [31:28] = 2. Espera a execução disparada pelo último START terminar
--                      (DONE e não BUSY) antes de seguir para o próximo comando.
--              END   : cabeçalho [31:28] = 3. Marca o fim do programa (STATUS bit 4 = 1 quando a fila
--                      está vazia e o último comando executado foi um END).
--
--            Regras: todo START deve ser seguido de um WAIT antes de novas escritas de configuração
--            (o register file ignora escritas de configuração com a NPU ocupada). As portas de dados
--            (W_PORT, I_PORT, IMG, O_DATA) continuam livres para o barramento durante o programa.
--
-------------------------------------------------------------------------------------------------------------

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity npu_cmd_proc is

    generic (
        DEPTH       : integer := 128                             -- Palavras de programa em fila
    );

    port (
        clk         : in  std_logic;
        rst_n       : in  std_logic;
        soc_en_i    : in  std_logic := '1';

        -- Porta DESC (escrita pelo barramento/DMA)
        desc_we     : in  std_logic;
        desc_data   : in  std_logic_vector(31 downto 0);

        -- Escrita de configuração no register file
        cp_we       : out std_logic;
        cp_addr     : out std_logic_vector(7 downto 0);
        cp_data     : out std_logic_vector(31 downto 0);

        -- Estado da NPU
        sts_busy    : in  std_logic;
        sts_done    : in  std_logic;

        -- 1 = programa terminado (fila vazia e último comando foi END)
        cp_idle     : out std_logic;

        -- 1 = a fila aceita mais uma palavra (a porta DESC segura o barramento quando cheia)
        desc_ready  : out std_logic
    );

end entity npu_cmd_proc;

architecture rtl of npu_cmd_proc is

    constant OP_WRITE : std_logic_vector(3 downto 0) := "0001";
    constant OP_WAIT  : std_logic_vector(3 downto 0) := "0010";
    constant OP_END   : std_logic_vector(3 downto 0) := "0011";

    -- Após o START, o DONE da execução anterior ainda leva alguns ciclos para cair
    constant C_WAIT_ARM : integer := 4;

    type state_t is (S_FETCH, S_DATA, S_WAIT);
    signal state      : state_t := S_FETCH;

    signal s_q_valid  : std_logic;
    signal s_q_data   : std_logic_vector(31 downto 0);
    signal s_q_pop    : std_logic;
    signal s_q_ready  : std_logic;

    signal r_addr     : std_logic_vector(7 downto 0) := (others => '0');
    signal r_wcnt     : integer range 0 to C_WAIT_ARM := 0;
    signal r_ended    : std_logic := '1';

begin

    u_queue : entity work.fifo_sync
        generic map (DATA_W => 32, DEPTH => DEPTH)
        port map (
            clk     => clk,
            rst_n   => rst_n,
            w_valid => desc_we,
            w_ready => s_q_ready,
            w_data  => desc_data,
            r_valid => s_q_valid,
            r_ready => s_q_pop,
            r_data  => s_q_data,
            count   => open
        );

    -- Consome uma palavra da fila na busca do cabeçalho e na busca do dado de um WRITE
    s_q_pop <= '1' when soc_en_i = '1' and s_q_valid = '1' and (state = S_FETCH or state = S_DATA) else '0';

    desc_ready <= s_q_ready;

    cp_idle <= '1' when r_ended = '1' and s_q_valid = '0' and state = S_FETCH else '0';

    process(clk)
    begin
        if rising_edge(clk) then
            if rst_n = '0' then
                state   <= S_FETCH;
                cp_we   <= '0';
                cp_addr <= (others => '0');
                cp_data <= (others => '0');
                r_wcnt  <= 0;
                r_ended <= '1';

            elsif soc_en_i = '1' then
                cp_we <= '0';

                case state is
                    when S_FETCH =>
                        if s_q_valid = '1' then
                            r_ended <= '0';
                            case s_q_data(31 downto 28) is
                                when OP_WRITE =>
                                    r_addr <= s_q_data(7 downto 0);
                                    state  <= S_DATA;
                                when OP_WAIT =>
                                    r_wcnt <= C_WAIT_ARM;
                                    state  <= S_WAIT;
                                when OP_END =>
                                    r_ended <= '1';
                                when others =>
                                    null;                         -- Palavra desconhecida: ignorada
                            end case;
                        end if;

                    when S_DATA =>
                        if s_q_valid = '1' then
                            cp_we   <= '1';
                            cp_addr <= r_addr;
                            cp_data <= s_q_data;
                            state   <= S_FETCH;
                        end if;

                    when S_WAIT =>
                        if r_wcnt /= 0 then
                            r_wcnt <= r_wcnt - 1;
                        elsif sts_done = '1' and sts_busy = '0' then
                            state <= S_FETCH;
                        end if;
                end case;
            end if;
        end if;
    end process;

end architecture; -- rtl

-------------------------------------------------------------------------------------------------------------
