# Unidade de Controle (FSM)

A Unidade de Controle (`npu_controller.vhd`) atua como o **micro-sequenciador** do sistema. Implementada como uma Máquina de Estados Finita (FSM), ela traduz os comandos de alto nível da CPU em sinais de controle de baixo nível ciclo a ciclo, governando o datapath, a injeção de dados no arranjo sistólico e o esvaziamento dos acumuladores.

A FSM opera de forma simplificada e robusta através de três estados principais:

## 1. Estado `IDLE`

É o estado de repouso. A NPU aguarda o sinal cmd_start enviado pela interface MMIO. Ao receber o gatilho, a FSM captura as configurações de execução (como o tamanho da execução `cfg_run_size` e o modo de operação `cmd_no_drain`) e transita para o estado de processamento. Se requisitado, zera os ponteiros de leitura da RAM.

## 2. Estado `COMPUTE`

Neste estado, o controlador orquestra o fluxo contínuo de dados para as memórias locais.

- A cada ciclo de clock, a FSM incrementa os ponteiros de leitura das RAMs de Pesos e Entradas (`wgt_rd_ptr` e `inp_rd_ptr`), enviando o sinal de habilitação de leitura (`ctl_ram_re`).

- A FSM possui um contador interno sensível à latência do pipeline (`C_PIPE_LATENCY`). Ela sabe exatamente quando os últimos dados inseridos no Arranjo Sistólico terminarão de ser processados.

- Multiplexação no Tempo (***Tiling***): Caso a execução seja apenas um cálculo parcial de uma matriz muito grande (indicado pelo sinal `cmd_no_drain`), a FSM transita de volta para IDLE assim que a conta termina, preservando o valor nos acumuladores do PE. Se for o processamento final, ela avança para drenar os dados.

## 3. Estado `DRAIN` e `BACKPRESSURE`

Para descarregar os resultados, a FSM emite o sinal `ctl_acc_dump`, forçando os Processing Elements a soltarem seus valores. É aqui que entra a lógica de Backpressure (Contrapressão):

- A FSM monitora constantemente o sinal `fifo_ready_i` vindo da FIFO de saída.

- Se a CPU não estiver lendo os dados da saída rápido o suficiente e a FIFO encher, o controlador congela o pipeline (pausa o `ctl_acc_dump`), mantendo as somas parciais a salvo dentro dos PEs do Arranjo Sistólico até que haja espaço para recebê-las.