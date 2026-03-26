# Unidade de Pós-Processamento (PPU)

A **Unidade de Pós-Processamento (PPU - *Post-Process Unit*)** é o estágio do pipeline responsável por tratar os dados brutos (somas parciais de 32 bits) que saem do **Arranjo Sistólico**, convertendo-os em valores utilizáveis para as próximas camadas ou para o resultado final. Como as NPUs focadas em inferência utilizam matemática de ponto fixo ou inteira para maximizar a eficiência energética, a PPU desempenha o papel vital de re-escalar os dados (Quantização) e aplicar funções de ativação.

A transformação matemática executada na PPU da nossa arquitetura pode ser descrita pela seguinte equação:

$$
\text{Saída} = CLAMP\bigg[ ReLU\bigg[ \cfrac{(\text{Acc} + \text{Bias}) \times \text{QuantMult}}{2^{\text{QuantShift}}} + \text{ZeroPoint} \bigg] \bigg]
$$

Para alcançar altas frequências de clock, esta operação complexa foi dividida em um pipeline de 4 estágios, descrito a seguir:

- Estágio 1 (***Bias Addition***): O valor bruto acumulado no elemento de processamento (`acc_in`) é somado ao seu respectivo viés (`bias_in`).

- Estágio 2 (***Scaling***): Início do processo de quantização. O resultado do estágio anterior é multiplicado por um fator de escala em ponto fixo (`quant_mult`). Essa operação exige um multiplicador grande, o que justifica a isolação desta etapa em um ciclo de clock dedicado.

- Estágio 3 (***Shift & Rounding***): Para compensar a escala e trazer o valor de volta a uma faixa representável, realiza-se um deslocamento de bits à direita (*bit shift right*), definido pelo parâmetro `quant_shift`. Esse estágio também inclui a adição de um bit de arredondamento (*rounding*) antes do deslocamento, reduzindo perdas de precisão.

- Estágio 4 (**Zero Point & Clamping**): O offset de assimetria (`zero_point`) é adicionado. Se a função de ativação ReLU estiver habilitada (`en_relu`), qualquer valor resultante menor que zero é imediatamente descartado (zerado). Por fim, o valor passa por uma Saturação Dinâmica (Clamping), garantindo que a saída não estoure os limites do tipo de dado de saída (por padrão, `Int8`: limites dependem do parâmetro genérico `DATA_W`).

Essa abordagem em pipeline garante que a PPU consiga processar um novo dado por ciclo de clock, mantendo o rendimento (***throughput***) do Arranjo Sistólico.