# NPU: Neural Processing Unit 

![VHDL](https://img.shields.io/badge/VHDL-2008-blue?style=for-the-badge&logo=vhdl)
![GHDL](https://img.shields.io/badge/Simulator-GHDL-green?style=for-the-badge&logo=ghdl)
![GTKWave](https://img.shields.io/badge/Waveform-GTKWave-9cf?style=for-the-badge&logo=gtkwave)
![Python](https://img.shields.io/badge/Python-3.10-blue?style=for-the-badge&logo=python)

```text
    ███╗   ██╗██████╗ ██╗   ██╗
    ████╗  ██║██╔══██╗██║   ██║
    ██╔██╗ ██║██████╔╝██║   ██║
    ██║╚██╗██║██╔═══╝ ██║   ██║     ->> PROJECT: NPU Systolic Array Accelerator
    ██║ ╚████║██║     ╚██████╔╝     ->> AUTHOR: André Solano F. R. Maiolini
    ╚═╝  ╚═══╝╚═╝      ╚═════╝      ->> DATE: 23/1/2026
```

Este repositório contém a implementação de uma Unidade de Processamento Neural (NPU) baseada em uma arquitetura de Array Sistólico, projetada para acelerar cargas de trabalho de Redes Neurais (NN). O projeto é desenvolvido inteiramente em VHDL-2008 com suporte para síntese em FPGA.

## 📖 Documentação Completa

Toda a documentação de arquitetura, integração, simulação e o guia de programação do mapa de registradores (MMIO) foi migrada para o nosso portal dedicado:

👉 [Acesse a Documentação Completa Aqui!](https://nyfeu.github.io/NPU/)

## 🎯 Objetivos e Recursos

- **Arquitetura**: Array Sistólico (Output Stationary) 4x4
- **Otimização**: Alto reuso de memória interna através da Localidade de Registradores
- **Precisão**: INT8 para Entradas/Pesos, INT32 para Acumuladores
- **Comunicação**: UART de Alta Velocidade (921.600 bps)
- **HIL**: Hardware-in-the-Loop em tempo real com Interface Python/PyQt6

## 🛠️ Stack Tecnológica

O projeto utiliza um ecossistema moderno para design, verificação e implementação de hardware:

- **VHDL-2008**: Linguagem principal de Descrição de Hardware (RTL).
- **GHDL**: Simulador open-source utilizado para validação lógica.
- **Cocotb / Python 3**: Framework para testbenches baseados em corrotinas, permitindo integração direta com modelos de referência em Python.
- **GTKWave**: Análise e debug de formas de onda.
- **Xilinx Vivado**: Síntese, roteamento e geração de bitstream para FPGAs Xilinx.
- **Make**: Automação de todo o fluxo de build, simulação e deploy.

## 🧪 Verificação e Hardware-in-the-Loop (HIL)

A verificação é um pilar central deste projeto. O ambiente de testes utiliza Cocotb para simulação automatizada, contando com testes unitários, fuzzing randomizado contra Modelos de Referência (Golden Models) em Python, e testes de integração end-to-end (E2E).

Além disso, o projeto suporta Hardware-in-the-Loop (HIL) em tempo real:

1. O host (PC) treina a rede e quantiza os pesos.
2. Um script em Python envia os dados serializados via UART para a FPGA.
3. A NPU executa a inferência acelerada em hardware e devolve os scores das classes para o PC.

Aplicações já validadas na FPGA:

- 🔢 **MNIST Dataset**: Reconhecimento de dígitos manuscritos.
- 🌸 **IRIS Dataset**: Classificação de espécies de flores.

Mais sobre as aplicações testadas pode ser visto na documentação.

## 📂 Estrutura do Repositório

```text
npu/
├── rtl/               # Código Fonte em VHDL (Core, PPU, FIFOs, UART)
├── sim/               # Testbenches em Python (Cocotb)
├── fpga/              # Restrições (XDC) e Scripts Tcl para o Xilinx Vivado
├── sw/                # Drivers Host em Python e Aplicações HIL (MNIST/IRIS)
├── docs/              # Documentação MkDocs
└── Makefile           # Sistema de automação de Build/Simulação
```
