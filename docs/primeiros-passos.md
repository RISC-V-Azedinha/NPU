# Primeiros passos

Este capítulo descreve as ferramentas necessárias, como rodar a primeira simulação e como executar a NPU na FPGA.

## Ferramentas

!!! warning "Dependências do sistema"
    Instale as ferramentas abaixo e verifique se estão no `PATH`:

    * **GHDL:** simulador VHDL de código aberto;
    * **GTKWave:** visualizador de formas de onda;
    * **Python 3** com **Cocotb:** *testbenches* em Python e drivers do hospedeiro;
    * **Xilinx Vivado:** apenas para síntese e gravação na FPGA.

Clone o repositório e instale as dependências Python em um ambiente virtual:

```bash
git clone https://github.com/RISC-V-Azedinha/NPU.git
cd NPU
python -m venv .venv
source .venv/bin/activate
pip install cocotb numpy pyserial scikit-learn
pip install torch torchvision   # apenas para os exemplos com PyTorch (fpga_mlp.py)
```

Todos os comandos a seguir são executados na raiz do repositório. Sem argumentos, `make` mostra a lista de alvos disponíveis.

## Primeira simulação

A verificação usa *testbenches* Cocotb, que geram os estímulos e o resultado esperado em Python e o comparam com a saída do RTL simulado no GHDL. Para simular a NPU completa:

```bash
make cocotb TOP=npu_top TEST=test_npu_top
```

Para abrir as formas de onda da última simulação no GTKWave:

```bash
make view TEST=test_npu_top
```

Há também atalhos para as redes de exemplo, que executam uma inferência completa em simulação:

```bash
make sim_mnist
make sim_iris
```

Os detalhes estão em [Simulação com Cocotb](desenvolvimento.md#simulacao-com-cocotb). Para remover os artefatos gerados, use `make clean`.

## Execução na FPGA

Com uma Nexys A7-100T conectada por USB, o alvo `fpga` gera o *bitstream* (se necessário) e programa a placa:

```bash
make fpga
```

O *top-level* de teste (`rtl/fpga_tester/`) liga a NPU a uma UART a 921.600 bit/s. Com a placa programada, os scripts de `sw/` treinam um modelo, quantizam os parâmetros, enviam tudo à NPU e medem a acurácia na própria placa:

```bash
make hil_iris     # classificação do conjunto Iris
make hil_mnist    # classificação de dígitos do MNIST
```

O protocolo e os scripts estão em [Hardware-in-the-loop](software.md#hardware-in-the-loop), e o fluxo de síntese, em [Síntese em FPGA](desenvolvimento.md#sintese-em-fpga).

!!! tip "Próximos passos"
    Para entender o que a NPU calcula e por quê, comece por [Arranjos sistólicos](fundamentos.md#arranjos-sistolicos) e pela [visão geral da arquitetura](arquitetura/visao-geral.md). Para programá-la, veja a [API de programação](software.md#api-de-programacao).
