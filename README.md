# NPU

![VHDL](https://img.shields.io/badge/VHDL-2008-1F5FA8?style=for-the-badge)
![Python](https://img.shields.io/badge/Python-3776AB?style=for-the-badge&logo=python&logoColor=white)
![GHDL](https://img.shields.io/badge/Simulator-GHDL-2E8B57?style=for-the-badge)
![Cocotb](https://img.shields.io/badge/Testbench-Cocotb-E07B1A?style=for-the-badge)
![Vivado](https://img.shields.io/badge/Synthesis-Vivado-C0392B?style=for-the-badge)
![FPGA](https://img.shields.io/badge/Platform-FPGA-6A5ACD?style=for-the-badge)

A **NPU** é uma Unidade de Processamento Neural para inferência de redes neurais, escrita em **VHDL-2008**: um arranjo sistólico 4×4 de precisão **INT8**, com fluxo de dados *Output Stationary* e um modo GEMV (produto matriz-vetor) para camadas densas. O projeto nasceu como parte de um Trabalho de Conclusão de Curso (TCC), como coprocessador do [SoC RISC-V](https://github.com/RISC-V-Azedinha/RISC-V) da organização, e também pode ser testado isoladamente na FPGA, controlado por um computador via UART.

Para a fundamentação, a arquitetura detalhada, o mapeamento das camadas no arranjo e os resultados medidos na placa, veja a [documentação](https://risc-v-azedinha.github.io/NPU/).

## Características

![Array](https://img.shields.io/badge/Array-4x4_Systolic-blue)
![Dataflow](https://img.shields.io/badge/Dataflow-Output_Stationary-success)
![Precision](https://img.shields.io/badge/Precision-INT8%20%2F%20INT32-orange)

- Arranjo sistólico 4×4 com acumuladores de 32 bits e modo GEMV para camadas densas;
- Pós-processamento (PPU) em *pipeline* de 4 estágios: viés, escala, arredondamento, ReLU e saturação;
- Mecanismos de movimentação de dados: pesos e vieses residentes, *im2col* em hardware, sequenciador de *tiles*, *tiles* encadeados, *streaming* e fusão de camadas;
- Processador de comandos que executa a rede inteira a partir de um programa de descritores (`WRITE`/`WAIT`/`END`) enviado por DMA;
- Verificação com Cocotb e *hardware-in-the-loop* na Nexys A7-100T (Artix-7) a 100 MHz.

Integrada ao SoC, a NPU chega a **12,2 MACs úteis por ciclo** (76% do teto de 16), **7.477×** mais rápida que o núcleo RV32I no mesmo produto de matrizes, e executa a CNN do MNIST em **1.506 ciclos** (15 µs) por imagem.

## Começando rápido

Pré-requisitos: `ghdl`, `gtkwave`, Python 3 com `cocotb` e, para a FPGA, o Xilinx Vivado.

```bash
# Simular a NPU completa
make cocotb TOP=npu_top TEST=test_npu_top

# Gerar o bitstream (se necessário) e programar a placa
make fpga

# Rodar uma aplicação na FPGA (hardware-in-the-loop)
make hil_iris
```

Sem argumentos, `make` lista todos os alvos disponíveis.

## Documentação

A documentação completa do projeto — fundamentos, arquitetura, mapeamento de camadas, API de programação e avaliação — está em [`docs/`](docs/) e é servida com [MkDocs](https://www.mkdocs.org/) + [Material for MkDocs](https://squidfunk.github.io/mkdocs-material/). É acessível em: [Documentação](https://risc-v-azedinha.github.io/NPU/)

Para visualizar localmente:

```bash
pip install mkdocs-material mkdocs-git-revision-date-localized-plugin
mkdocs serve
```

Depois abra `http://127.0.0.1:8000`.

## Estrutura do repositório

```text
NPU/
├── docs/            # Documentação (MkDocs)
├── rtl/             # Código VHDL
│   ├── core/        # PE, arranjo sistólico e buffers de entrada
│   ├── ppu/         # Unidade de pós-processamento
│   ├── common/      # FIFOs e memórias (RAM de porta dupla, pesos em bancos)
│   └── fpga_tester/ # Top-level de teste na FPGA (UART + processador de comandos do host)
├── pkg/             # Pacotes VHDL compartilhados
├── sim/             # Testbenches em Python (Cocotb)
├── sw/              # Drivers do hospedeiro e aplicações (HIL)
├── fpga/            # Restrições (XDC) e scripts TCL do Vivado
├── mk/              # Regras modulares do makefile
└── makefile         # Simulação, síntese e HIL
```
