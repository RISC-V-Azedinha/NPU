# System-on-Chip (SoC) Benchmark

## 1. CPU Baselines

### 1.1. Motivação

A avaliação de desempenho de aceleradores dedicados, como a NPU proposta neste trabalho depende da definição de uma *baseline* de CPU adequada. Comparações diretas de tempo de execução ou throughput absoluto tendem a ser fortemente influenciadas por fatores externos à arquitetura - como frequência de clock, tecnologia de fabricação, compiladores otimizados e microarquiteturas proprietárias - o que dificulta a análise do ganho arquitetura proporcionado pelo acelerador.

Dessa forma, este trabalho adota como princípio metodológico a comparação em número de ciclos e em nível arquitetural, abstraindo deliberadamente a frequência de operação. O objetivo não é reproduzir fielmente o comportamento de um microcontrolador comercial específico, mas sim estabelecer limites plausíveis para uma CPU de classe de microprocessadores embarcados (*embedded*), contra a qual o ganho da NPU possa ser avaliado de forma justa e reprodutível.

### 1.2. RV32I Multiciclo

A CPU utilizada como baseline neste SoC (System-on-a-Chip) é uma implementação RV32I-like estritamente multiciclo, sem pipeline, sem execução fora de ordem e sem extensões opcionais (M, F, V etc.). Cada instrução é decomposta em estágios funcionais sequenciais, com latências determinadas por restrições reais de FPGA, em especial:

- Latência de memória síncrona (IF e MEM com múltiplos ciclos);
- Caminhos críticos de lógica combinacional;
- Reuso de unidades funcionais para minimizar área.

Uma configuração típica de latências por instrução é apresentada abaixo:

| Estágio | Latência (ciclos) | Observações |
| --- | --- | --- |
| **IF** | 2 | Memória síncrona |
| **ID** | 1 | Decodificação e leitura de registradores |
| **EX** | 1-2 | Branches com latência adicional |
| **MEM** | 1-2 | Dependente da operação |
| **WB** | 1 | Escrita em registradores |

!!! quote "CPI Médio"
    Assim, o custo médio por instrução (CPI - *Cycles per Instruction*) situa-se tipicamente entre 6 e 8 ciclos, dependendo do código sendo executado pelo processador.

Essa CPU representa um ponto de referência conservador, porém realista, para sistemas embedded minimalistas, educacionais ou orientados a baixo consumo.

### 1.3. Comparação com MCU Comercial

Microcontroladores modernos baseados em RISC-V - como o ESP32-C3 - ou ARM (série M) incorporam uma série de otimizações microarquiteturais que dificultam uma comparação direta:

- Pipeline profundo (tipicamente 3 a 5 estágios);
- Execução especulativa e prefetch;
- Unidades aritméticas dedicadas e paralelas;
- Barramentos e hierarquias de memória otimizadas.

Embora essas técnicas reduzam o número médio de ciclos por instrução, elas existem principalmente para viabilizar frequências mais altas, e não necessariamente para reduzir o trabalho arquitetural intrínseco da computação.

Comparar diretamente tempos absolutos ou benchmarks compilados para tais CPUs introduziria variáveis difíceis de isolar, como qualidade do compilador, agressividade de otimizações e detalhes proprietários não documentados.

### 1.4. Classe de Arquiteturas Consideradas

O *baseline* proposto representa a classe de processadores com as seguintes características:

- ISA: RV32I com extensão de multiplicação (RV32IM);
- Execução escalar (1 operação aritmética por instrução);
- Sem unidades vetoriais ou SIMD;
- Sem aceleração dedicada para MACs.

Essa classe inclui tanto processadores multi-cycles simples quanto microcontroladores modernos com pipeline e multiplicador em hardware. Diferenças microarquiteturais afetam latência e frequência, mas não alteram os limites fundamentais impostos pela ISA.

Considere a computação de um único MAC escalar:

$$ 
\text{acc} \ \leftarrow \ \text{acc}+(a\times b)
$$ 

Em **RV32IM**, mesmo assumindo otimizações ideais, essa operação exige no mínimo:

1. Um `load` para o operando `a`;
2. Um `load`para o operando `b`;
3. Uma instrução de multiplicação (`mul`);
4. Uma instrução de soma (`add`).

Portanto, cada MAC requer pelo menos **4 instruções**.

Assumindo-se um cenário otimista:

- CPI = 1;
- Pipeline ideal;
- Cache perfeito;
- Sem stalls.

Obtém-se o limite inferior teórico: $\text{Ciclos}_{\text{CPU}}\ge 4\times N_{\text{MAC}}$. Esse resultado é independente de frequência, tecnologia ou microarquitetura específica.

Com base nas observações anteriores, define-se o modelo matemático do baseline de CPU como:

$$
T_{\text{CPU}}^{\text{min}}=4\cdot N_{\text{MAC}}
$$

Onde:

- $N_{\text{MAC}}$ = número total de operações MAC do workload;
- $T_{\text{CPU}}^{\text{min}}$ = tempo mínimo em ciclos.

Esse modelo não representa um processador real, mas sim um limite inferior teórico para qualquer CPU RV32 escalar compatível com a ISA.

### 1.5. Justificativa do Uso de um Core RV32I Multiciclo

A implementação de um core RV32I multi-cycle no SoC proposto não busca competir em desempenho absoluto, mas sim:

- Evidenciar de forma clara os gargalos arquiteturais da execução escalar;
- Facilitar análise ciclo-a-ciclo e verificação funcional;
- Servir como plataforma educacional e experimental.

Importante ressaltar que, **mesmo substituindo esse core por uma CPU pipelined ideal**, o limite inferior definido permanece válido.

## 2. NPU Speedup Bounds

A aceleração obtida por meio de unidades especializadas, como NPUs (Neural Processing Units), é frequentemente reportada como um fator de *speedup* em relação à execução puramente em software. No entanto, tais valores isolados podem ser enganosos se não forem contextualizados por limites teóricos e arquiteturais bem definidos.

Este capítulo busca estabelecer:

- A natureza do *workload* (operações matriciais e convolucionais);
- Restrições impostas por memória, DMA e interconexão;
- Grau de paralelismo efetivamente explorável.

Dessa forma, busca-se responder à pergunta central:

!!! question "Speedup"
    O speedup observado representa um limite estrutural da arquitetura ou um artefato da CPU baseline escolhida?

### 2.1. Definição Formal de Speedup

O speedup é definido de forma clássica como:

$$
S=\cfrac{T_{\text{CPU}}}{T_{\text{CPU+NPU}}}
$$

onde:

- $T_{\text{CPU}}$ = tempo de execução do workload completo utilizando apenas a CPU;
- $T_{\text{CPU+NPU}}$ = tempo de execução considerando offload da computação para a NPU.

Como a análise é feita em termos arquiteturais, o tempo é expresso em **número de ciclos de clock**, não em segundos, eliminando a dependência de frequência de clock.

### 2.2. Overhead de Offload

O primeiro limite fundamental é que nenhuma NPU pode ser mais rápida do que o custo de invocá-la. O tempo total com aceleração pode ser decomposto como:

$$
T_{\text{CPU+NPU}}=T_{\text{setup}}+T_{\text{DMA}}+T_{\text{NPU}}+T_{\text{sync}}
$$

Onde:

- $T_{\text{setup}}$ = escrita de CSRs e comandos;
- $T_{\text{DMA}}$ = transferência de dados;
- $T_{\text{NPU}}$ = computação efetiva;
- $T_{\text{sync}}$ = polling ou interrupção.

Isso implica que workloads pequenos ou com baixa intensidade aritmética possuem **speedup próximo de 1 ou até < 1**, independentemente da NPU.

Esse limite explica porque: vetores curtos; poucas iterações; ou kernels pouco densos, não se beneficiam significativamente da aceleração. 

O limite superior teórico ocorre quando:

1. Todo o tempo de computação da CPU é substituído por computação paralela na NPU;
2. Overheads de comunicação são desprezíveis;
3. A NPU opera com utilização plena.

Nesse cenário hipotético:

$$
S_{\text{max}}\approx\cfrac{C_{\text{CPU}}}{C_{\text{NPU}}}
$$

onde:

- $C_{\text{CPU}}$ = ciclos necessários para executar o kernel em software;
- $C_{\text{NPU}}$ = ciclos necessários para executar o mesmo kernel na NPU.

Para workloads típicos de inferência (MACs, convoluções, GEMMs):

$$
C_{\text{CPU}} \propto N_{\text{ops}}
$$

$$
C_{\text{NPU}} \propto \ \cfrac{N_{\text{ops}}}{P}
$$

onde $P$ é o grau de paralelismo da NPU.

Assim, o *speedup* máximo teórico é aproximadamente: $S_{\text{max}}\approx P$. Esse resultado é consistente com literatura clássica de arquiteturas SIMD, arranjos sistólicos e aceleradores.

### 2.3. Lei de Amdahl Aplicada à NPU

Na prática, apenas uma fração do código é acelerável. Aplicando a Lei de Amdahl:

$$
S=\cfrac{1}{(1-f)+\cfrac{f}{s_{\text{acc}}}}
$$

onde:

- $f$ = fração do tempo total originalmente gasta em computação acelerável;
- $S_{\text{acc}}$ = speedup do trecho acelerado.

Mesmo com $S_{\text{acc}} \rightarrow \infty$, o speedup total é limitado por $1\ / \ (1-f)$. No contexto deste SoC:

- loops de MACs e ReLU $\rightarrow$  alto $f$;
- controle, configuração, I/O $\rightarrow$ baixo $f$.

Isso explica porque o speedup observado **satura** mesmo quando a NPU é escalada.

### 2.4. Limite Prático

Na implementação real de um SoC, o teto de speedup é reduzido por:

1. **Largura de banda da memória**: a NPU só é tão rápida quanto o fornecimento de dados;
2. **Arbitragem do barramento**: mesmo com comportamento determinístico, há ciclos não produtivos;
3. **Granularidade do DMA**: transferências em blocos impõem latência mínima.

Esses fatores impõem um teto prático:

$$
S_{\text{prático}}<S_{\text{max}}
$$

A observação de ciclos praticamente constantes entre execuções reforça que:

- O sistema opera em regime determinístico e previsível;
- O teto observado é estrutural, não estatístico.

O speedup máximo medido experimentalmente deve ser interpretado como: o teto de aceleração da arquitetura atual para aquele padrão de workload e hierarquia de memória. Não se trata de um limite universal - mas, sim, um ponto de equilíbrio entre paralelismo computacional, capacidade de alimentação de dados e custo de orquestração pela CPU.

## Referências

- AMDAHL, Gene M. Validity of the single processor approach to achieving large scale computing capabilities. In: Proceedings of the April 18-20, 1967, spring joint computer conference. 1967. p. 483-485.
- Espressif Documentation. Disponível em: <https://documentation.espressif.com/esp32-c3_datasheet_en.pdf>.
- HENNESSY, John L.; PATTERSON, David A. Computer architecture: a quantitative approach. Elsevier, 2011.
- PATTERSON, David A.; HENNESSY, John L. Computer organization and Design. The Hardware/Soft, 2022.
- HARRIS, Sarah; HARRIS, David. Digital Design and Computer Architecture, RISC-V Edition. Morgan Kaufmann, 2021.