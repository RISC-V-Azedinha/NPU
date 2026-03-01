# API de Programação da NPU

## Visão Geral
A NPU opera como um periférico mapeado em memória (MMIO) com arquitetura **Output Stationary**. Isso significa que os acumuladores internos mantêm os resultados parciais (Princípio da Localidade) até que o processamento completo de um vetor (Tile) seja concluído ou que um comando de `DUMP` seja enviado.

## Mapa de Registradores (Base Address + Offset)

| Offset | Registrador | Acesso | Descrição |
| :--- | :--- | :--- | :--- |
| `0x00` | **STATUS** | RO | Estado do núcleo. |
| `0x04` | **CMD** | WO | Comandos de disparo e controle de ponteiros. |
| `0x08` | **CONFIG** | RW | Tamanho da execução (K_DIM). |
| `0x10` | **WRITE_W** | WO | Porta de escrita de Pesos (Weights). |
| `0x14` | **WRITE_A** | WO | Porta de escrita de Ativações (Inputs). |
| `0x18` | **READ_OUT** | RO | Porta de leitura de Resultados. |
| `0x40` | **QUANT_CFG** | RW | Bits [4:0]: Shift Amount. Bits [15:8]: Zero Point. |
| `0x44` | **QUANT_MULT**| RW | Multiplicador Inteiro da PPU. |
| `0x80` | **BIAS_BASE** | RW | Vetor de Bias (4 x 32-bit). |

## Detalhe dos Registradores

### CMD (0x04) - Command Register
Este registrador controla a Máquina de Estados e os Ponteiros de DMA. É *Write-Only*.

| Bit | Nome | Descrição |
| :--- | :--- | :--- |
| **0** | `RST_DMA_PTRS` | Reseta TODOS os ponteiros de escrita e leitura para zero. Usado no início de uma nova inferência. |
| **1** | `START` | Inicia a execução da Matriz Sistólica. |
| **2** | `ACC_CLEAR` | **1**: Limpa os acumuladores (Outputs) antes de iniciar. **0**: Acumula sobre o valor anterior (Tiling Temporal). |
| **4** | `RST_W_RD` | Reseta apenas o ponteiro de **leitura** de Pesos. |
| **5** | `RST_I_RD` | Reseta apenas o ponteiro de **leitura** de Inputs. |
| **6** | `RST_WR_W` | Reseta apenas o ponteiro de **escrita** de Pesos (Recarga parcial). |
| **7** | `RST_WR_I` | Reseta apenas o ponteiro de **escrita** de Inputs. |

### STATUS (0x00) - Status Register

| Bit | Nome | Descrição |
| :--- | :--- | :--- |
| **1** | `DONE` | **1**: Processamento concluído. O Host pode ler os resultados ou iniciar novo tile. |
| **3** | `OUT_VALID` | **1**: A FIFO de saída contém dados válidos para leitura. |

## Estratégia de Tiling (Output Stationary)

Graças ao reuso da memória interna e do princípio da localidade, redes maiores que o array físico (4x4) podem ser computadas em partes com menor impacto no tráfego de dados no barramento:

1. Carregue o Input Vetor completo uma única vez.
2. Carregue o primeiro bloco de Pesos.
3. Execute (Output Stationary acumula o resultado parcial).
4. Para o próximo bloco: 
    - Envie `CMD_RST_WR_W` (reseta ponteiro de escrita de pesos)
    - Carregue novos pesos 
    - Envie `CMD_START` com `RST_W_RD | RST_I_RD` (para reler o input e acumular no mesmo output).