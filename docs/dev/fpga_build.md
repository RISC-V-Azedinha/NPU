# Fluxo de Síntese (FPGA)

O processo de transformar o código VHDL em portas lógicas físicas na FPGA é gerenciado pela suíte **Xilinx Vivado**. No entanto, para manter a produtividade e a integração contínua, **não utilizamos a interface gráfica (GUI) do Vivado**. Todo o fluxo é baseado em scripts (TCL) orquestrados pelo nosso `Makefile`.

!!! abstract "Target Físico"
    O projeto está configurado para a família **Xilinx Artix-7** (XC7A100T-CSG324-1), amplamente utilizada em placas acadêmicas e de prototipagem como a Nexys 4.

## Organização dos Scripts TCL

Na pasta `fpga/scripts/`, temos scripts TCL que ditam as regras de síntese:

- **`build.tcl`**: Lê todos os arquivos `.vhd` da pasta `rtl/`, lê o arquivo de restrições de pinos (`fpga/constraints/pins.xdc`), executa a Síntese, a Implementação (Place & Route) e gera o arquivo `npu.bit`.

- **`program.tcl`**: Conecta ao servidor de hardware via USB e grava o arquivo `.bit` diretamente na memória SRAM da FPGA.

## Comandos de Build (Makefile)

A partir da raiz do repositório, você pode invocar o Vivado em modo *batch* (sem interface gráfica) através do Makefile.

### 1. Fluxo Inteligente Completo
Verifica se o bitstream já existe. Se não existir, ele sintetiza o projeto e, em seguida, grava na FPGA conectada via USB.

```bash
make fpga
```

### 2. Forçar a Geração do Bitstream

Se você alterou o código VHDL e precisa forçar uma nova síntese e implementação do zero:

```bash
make fpga_bit
```

!!! tip "Rastreamento de Modificações"
    O comando `make fpga` rastreia se os os arquivos fonte para sínteses foram modificados previamente. Em outras palavras, caso tenham, roda automaticamente `make fpga_bit`.

### 3. Apenas Programar

Se o bitstream já estiver gerado e você só quiser regravar a placa:

```bash
make fpga_prog
```

!!! tip "Upload para a FPGA"
    Se o bitstream já foi gerado anteriormente, então, basta rodar `make fpga` para programar a placa.

