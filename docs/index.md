# Visão Geral do Projeto

!!! info "Sobre a NPU"
    Bem-vindo à documentação oficial da **Unidade de Processamento Neural (NPU)**. Este projeto é um acelerador de hardware baseado em uma arquitetura de Array Sistólico, projetado especificamente para acelerar cargas de trabalho de inferência de Redes Neurais. O hardware foi desenvolvido inteiramente em **VHDL-2008**.

## Arquitetura e Design

!!! abstract "Output-Stationary e o Princípio da Localidade"
    O design implementa uma arquitetura **Output-Stationary**. Essa abordagem aproveita o princípio da localidade, que é garantido pelas **memórias locais (*scratchpads*)** da NPU, para maximizar o reuso de dados internos. 
    
    Além disso, como as somas parciais (*partial sums*) são acumuladas localmente nos *Processing Elements* (PEs), há uma redução drástica na largura de banda necessária para escrever os resultados intermediários de volta na memória.

## Objetivos e Recursos Principais

* **Arquitetura**: Array Sistólico (**Output Stationary**) 4x4.
* **Otimização**: Alto reuso de memória interna via localidade de registradores.
* **Precisão**: Quantização `INT8` para Entradas e Pesos; `INT32` para os Acumuladores MAC.
* **Comunicação**: UART de Alta Velocidade (**921.600 bps**).
* **Integração**: Hardware-in-the-Loop (HIL) em tempo real com interface Python/PyQt6.

## Estrutura do Repositório

O repositório está organizado para separar o design de hardware (RTL), os *testbenches* de verificação e os softwares de controle:

```text
npu/
├── rtl/               # Código fonte VHDL (Core, PPU, FIFOs)
├── sim/               # Testbenches em Python (Cocotb)
├── fpga/              # Constraints do Vivado (XDC) e Scripts de Build
├── sw/                # Drivers de Host (Python) e Aplicações HIL
├── pkg/               # Pacotes VHDL compartilhados
└── mk/                # Sistema modular de Build (Makefiles)
```

!!! tip "Por onde começar?"
    Se você deseja compilar e simular o projeto pela primeira vez, visite a página de [Requisitos e Setup](intro/setup.md).


