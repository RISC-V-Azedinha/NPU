# Desenvolvimento

A verificação e a síntese são automatizadas pelo `makefile` da raiz do repositório: o mesmo fluxo roda as simulações em GHDL com Cocotb e gera o *bitstream* com o Vivado em modo *batch*.

## Simulação com Cocotb

A verificação do hardware é feita utilizando o **COCOTB**, um framework baseado em Python, operando em conjunto com o simulador **GHDL**. Toda a automação de compilação e execução é gerenciada pelo `Makefile` na raiz do projeto.

!!! info "Por que usar COCOTB?"
    O COCOTB permite escrever estímulos de hardware usando **Python 3**. Isso traz uma vantagem gigantesca: podemos instanciar redes neurais reais (usando bibliotecas como NumPy ou PyTorch) em Python, gerar os *Golden Models* (resultados esperados perfeitos) e comparar em tempo real com a saída do hardware simulado no GHDL.

### Estrutura do Testbench

Todos os testes automatizados residem na pasta `sim/`. A lógica de um teste típico do projeto segue este fluxo:

1. **Reset e Inicialização**: O script Python aplica sinais de clock e reseta a entidade VHDL.
2. **Estímulo**: O Python envia dados (Pesos e Ativações) para as portas de entrada do VHDL.
3. **Golden Model**: O Python calcula a mesma operação matricial matematicamente.
4. **Asserção (Assert)**: O resultado que sai do VHDL é comparado com o resultado do Golden Model. Se divergirem, o teste falha.

### Comandos de Simulação

Todos os testes automatizados residem na pasta `sim/`. Para rodar um teste, você precisa especificar o testbench (`TEST`) e a entidade de topo (`TOP`):

```bash
make cocotb TEST=<nome_do_testbench> TOP=<entidade_top_level>
```

!!! example "Exemplo Prático"
    Para rodar os testes do Processing Element (PE), execute:
    `make cocotb TEST=test_mac_pe TOP=mac_pe`

### Visualização de Ondas (GTKWave)

Após a simulação, um arquivo `.vcd` é gerado na pasta `build/`. Para inspecionar os sinais:

```bash
make view TEST=<nome_do_testbench>
```

### Atalhos para Datasets

Para simulações de integração completa do sistema (End-to-End), temos atalhos prontos:

- `make sim_mnist`: Roda a simulação completa para a rede do MNIST.
- `make sim_iris`: Roda a simulação completa para a rede do IRIS.

!!! tip "Limpeza"
    Para limpar todos os arquivos gerados pelas simulações, basta rodar `make clean`.

## Síntese em FPGA

O processo de transformar o código VHDL em portas lógicas físicas na FPGA é gerenciado pela suíte **Xilinx Vivado**. No entanto, para manter a produtividade e a integração contínua, **não utilizamos a interface gráfica (GUI) do Vivado**. Todo o fluxo é baseado em scripts (TCL) orquestrados pelo nosso `Makefile`.

!!! abstract "Target Físico"
    O projeto está configurado para a família **Xilinx Artix-7** (XC7A100T-CSG324-1), amplamente utilizada em placas acadêmicas e de prototipagem como a Nexys 4.

### Organização dos Scripts TCL

Na pasta `fpga/scripts/`, temos scripts TCL que ditam as regras de síntese:

- **`build.tcl`**: Lê todos os arquivos `.vhd` da pasta `rtl/`, lê o arquivo de restrições de pinos (`fpga/constraints/pins.xdc`), executa a Síntese, a Implementação (Place & Route) e gera o arquivo `npu.bit`.

- **`program.tcl`**: Conecta ao servidor de hardware via USB e grava o arquivo `.bit` diretamente na memória SRAM da FPGA.

### Comandos de Build (Makefile)

A partir da raiz do repositório, você pode invocar o Vivado em modo *batch* (sem interface gráfica) através do Makefile.

#### Fluxo Inteligente Completo
Verifica se o bitstream já existe. Se não existir, ele sintetiza o projeto e, em seguida, grava na FPGA conectada via USB.

```bash
make fpga
```

#### Forçar a Geração do Bitstream

Se você alterou o código VHDL e precisa forçar uma nova síntese e implementação do zero:

```bash
make fpga_bit
```

!!! tip "Rastreamento de Modificações"
    O comando `make fpga` rastreia se os os arquivos fonte para sínteses foram modificados previamente. Em outras palavras, caso tenham, roda automaticamente `make fpga_bit`.

#### Apenas Programar

Se o bitstream já estiver gerado e você só quiser regravar a placa:

```bash
make fpga_prog
```

!!! tip "Upload para a FPGA"
    Se o bitstream já foi gerado anteriormente, então, basta rodar `make fpga` para programar a placa.
