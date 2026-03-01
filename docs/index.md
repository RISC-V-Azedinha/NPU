# Visão Geral do Projeto

![VHDL](https://img.shields.io/badge/VHDL-2008-blue?style=for-the-badge&logo=vhdl)
![GHDL](https://img.shields.io/badge/Simulator-GHDL-green?style=for-the-badge&logo=ghdl)
![GTKWave](https://img.shields.io/badge/Waveform-GTKWave-9cf?style=for-the-badge&logo=gtkwave)
![Python](https://img.shields.io/badge/Python-3.10-blue?style=for-the-badge&logo=python)

![Neural Processing Unit](./assets/npu_soc){ .hero-img }

Bem-vindo à documentação oficial da **Unidade de Processamento Neural (NPU)**. Este projeto é um acelerador de hardware baseado em uma arquitetura de Array Sistólico, projetado especificamente para acelerar cargas de trabalho de inferência de Redes Neurais. O hardware foi desenvolvido inteiramente em **VHDL-2008**.

## Contextualização

A evolução das arquiteturas de computadores tem sido fortemente influenciada pela crescente demanda por desempenho, eficiência energética e especialização para **cargas de trabalhos específicas**. Durante décadas, o aumento de desempenho foi sustentado principalmente pela elevação da frequência de clock e pela exploração de paralelismo em nível de instrução. No entanto, limitações físicas, como consumo de energia e dissipação térmica, tornaram esse modelo insustentável. Nesse contexto, o **coprocessamento** emerge como uma estratégia fundamental para ampliar o desempenho de sistemas computacionais modernos.

Coprocessadores são unidades de hardware especializadas, projetadas para executar classes específicas de operações de forma mais eficiente do que uma CPU de propósito geral. Em vez de tentar otimizar um único núcleo para todas as aplicações possíveis, sistemas modernos adotam uma abordagem **heterogênea**, combinando CPUs com aceleradores dedicados, como GPUs, DSPs, unidades criptográficas e, mais recentemente, **Neural Processing Units (NPUs)**. Essa abordagem permite ganhos significativos de desempenho e eficiência energética ao alinhar a microarquitetura do hardware às características do algoritmo executado.

Historicamente, coprocessadores foram introduzidos como extensões funcionais da CPU, como as unidades de ponto flutuante (FPUs), acessadas por meio de instruções especiais. Com o aumento da complexidade dos sistemas, essa integração evoluiu para modelos mais flexíveis, nos quais coprocessadores são conectados por barramentos internos, acessados via **endereçamento em memória (MMIO - *Memory Mapped I/O*)** ou operam de forma parcialmente autônoma, utilizando mecanismos como **acesso direto à memória (DMA)**. Essas formas de comunicação definem o grau de acoplamento entre CPU e coprocessador, impactando latência, coerência de memória e complexidade de software.

As **Neural Processing Units (NPUs)** representam uma classe moderna de coprocessadores especializados, projetados especificamente para acelerar algoritmos de aprendizado de máquina, em especial **redes neurais artificiais**. Diferentemente de CPUs, que priorizam flexibilidade, e de GPUs, que exploram paralelismo massivo de dados de forma genérica, NPUs são arquitetadas para maximizar a eficiência em operações características de redes neurais, como: **multiplicações e acumulações matriciais (MAC), convoluções e operações de ativação**. Para isso, exploram intensivamente paralelismo espacial, reutilização de dados e hierarquias de memória otimizadas para alto throughput e baixo consumo energético. 

!!! info "Multiply-accumulate operation (MAC)"
    Em computação, operações de multiplicações e acumulações são etapas comuns que calculam o produto entre dois números e adicionam esse produto ao acumulador. 
    $$
    a\leftarrow a+(b\times c)
    $$
    Esse tipo de operação é chave para aceleração de cálculos como: produtos escalares, convoluções e redes neurais artificiais.
    
Em sistemas contemporâneos, NPUs são frequentemente integradas como coprocessadores em **Systems-on-Chip (SoCs)**, especialmente em dispositivos móveis embarcados e de borda (edge computing). Nesses sistemas, a CPU atua como unidade de controle, responsável por inicializar, configurar e coordenar a execução da NPU, enquanto o processamento intensivo é delegado ao acelerador. Esse modelo reforça a separação entre controle e computação, um princípio recorrente em arquitetura heterogêneas.

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


