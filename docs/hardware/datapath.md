# Gestão e Reutilização de Dados (Datapath)

O arquivo `npu_datapath.vhd` atua como a espinha dorsal da NPU. Enquanto a FSM dita "quando" as coisas acontecem, o Datapath define "como" os dados trafegam fisicamente entre os componentes de armazenamento e processamento. Ele integra as memórias SRAM, o Arranjo Sistólico (Core), as PPUs e as FIFOs de saída em uma única macroestrutura.

## 1. Armazenamento Local (*Scratchpads*)

Para evitar o alto custo energético de buscar pesos e ativações na memória principal do sistema (DRAM) repetidas vezes, a NPU instancia dois blocos de memórias Dual-Port locais (ram_dual), chamadas de Scratchpads:

1. ***Weight RAM***: Armazena os parâmetros aprendidos (Pesos).
2. ***Input RAM***: Armazena as ativações de entrada da camada atual.

A interface primária (MMIO) possui controle de uma das portas dessas memórias (para escrita de dados pelo sistema hospedeiro), enquanto a segunda porta fica à disposição exclusiva da Unidade de Controle da NPU (FSM) para alimentar o arranjo em velocidade máxima durante a fase `COMPUTE`.

!!! abstract "Princípio da Localidade"
    Essa abordagem aproveita o princípio da localidade, que é garantido pelas **memórias locais (*scratchpads*)** da NPU, para maximizar o reuso de dados internos. 

## 2. Interligação do Subsistema

O Datapath mapeia de forma arquitetural a transição dos dados pela topologia espacial:

1. Geração e Alimentação: O módulo core (npu_core) é instanciado e conectado às RAMs locais. Seu tamanho é estático, parametrizado pelos generics genéricos `ROWS` e `COLS`.

2. Vetorização PPU: A saída do Arranjo Sistólico não é escalar, e sim um vetor largo contendo os dados de cada coluna processada. O Datapath utiliza um GENERATE na linguagem VHDL para instanciar dinamicamente um array de blocos PPU (`post_process`), mapeando corretamente a fatia (`slice`) do acumulador e seu respectivo vetor de Bias para a PPU correspondente àquela coluna.

3. Filas e Sincronização: Após a quantização e ativação, as PPUs validam os resultados. O Datapath concentra essas saídas em um buffer circular (`fifo_sync`). Este componente é essencial para dessincronizar o fim do processamento ultrarrápido do hardware da velocidade variável com que a CPU lê esses resultados via software, enviando o sinal `fifo_ready_feedback` de volta à FSM para regular o fluxo (Backpressure).

## 3. Double Buffering (Ping-Pong)

Por padrão, os Scratchpads de Pesos e Entradas são um único banco: a mesma região de memória é usada tanto para a escrita (host, via MMIO) quanto para a leitura (Core), o que obriga o host a esperar o fim do `COMPUTE`/`DRAIN` de um tile antes de poder carregar o próximo — a movimentação de dados fica em série com a computação.

Quando o IP é gerado com o generic `DOUBLE_BUFFER => true`, o Datapath duplica cada Scratchpad em dois bancos físicos (A/B). A cada `START` com o bit `DBUF_EN` habilitado, o controlador troca de banco em *ping-pong*: passa a ler o banco que acabou de ser preenchido e libera o outro banco para a próxima escrita via MMIO — que pode acontecer imediatamente, mesmo com a NPU ainda `BUSY` computando/drenando o tile anterior. Isso sobrepõe a movimentação de dados do próximo tile com a computação do tile corrente, em vez de serializá-las.

!!! info "Retrocompatibilidade"
    O generic `DOUBLE_BUFFER` tem default `false`, o que preserva exatamente a estrutura de RTL e o consumo de BRAM da versão de banco único. Mesmo com `DOUBLE_BUFFER => true`, o bit `DBUF_EN` do registrador `CMD` (bit 8) é opcional: se o host nunca o define, a NPU permanece presa ao banco 0, reproduzindo bit-a-bit o comportamento legado.

