
# Requisitos e Setup 

!!! warning "Dependências do Sistema"
    Para compilar e simular este projeto, instale as seguintes ferramentas e certifique-se de que elas estão no seu `PATH`:
    
    * **GHDL**: Simulador VHDL open-source.
    * **GTKWave**: Visualizador de formas de onda.
    * **COCOTB**: Framework Python para testbenches baseados em corrotinas.
    * **Python 3**: Necessário para rodar o Cocotb e os drivers de host.
    * **Xilinx Vivado**: Apenas se for realizar a síntese e gravação na FPGA.

## Automação via Makefile

Todos os comandos devem ser executados a partir da raiz do repositório. O `Makefile` automatiza o fluxo de simulação, visualização e síntese.

### Limpeza do Projeto
Remove todos os arquivos temporários e artefatos de build gerados:
```bash
make clean
```
### Simulação com Cocotb

Rode testes automatizados informando o nome do testbench e do top-level:
```bash
make cocotb TEST=<testbench_name> TOP=<top_level>
```

!!! example "Visualização de Ondas"
    Para abrir a última simulação no GTKWave e analisar os sinais em detalhes, execute:
    `make view TEST=<testbench_name>`

### Atalhos de Simulação Prontos

Já existem comandos configurados para simular os datasets principais do projeto:

- `make sim_mnist`: Simula a rede de reconhecimento de dígitos.
- `make sim_iris`: Simula a rede de classificação do dataset Iris.
