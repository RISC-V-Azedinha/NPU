# Primeiros Passos (*Quickstart*)

Este guia foi desenhado para colocar você no controle da arquitetura o mais rápido possível. Em poucos minutos, você será capaz de executar simulações RTL completas e rodar sua primeira inferência de Rede Neural usando nossa stack de software em Python.

## 1. Configuração do Ambiente

Primeiro, clone o repositório e instale as dependências Python necessárias para a simulação e para a comunicação de software:
```bash
# Clone o repositório
git clone https://github.com/RISC-V-Azedinha/NPU.git

# Crie e ative um ambiente virtual (recomendado)
python -m venv venv
source venv/bin/activate # No Windows: venv\Scripts\activate

# Instale as dependências
pip install -r requirements.txt
```

## 2. Executando a Primeira Simulação

Para garantir que o core da NPU, as memórias e a máquina de estados estão funcionando corretamente na sua máquina, utilize nossa infraestrutura de testes automatizados.

O projeto conta com Makefiles modulares. Para rodar a bateria de testes de simulação de ponta a ponta (test_npu_top.py), basta executar:
```bash
make sim
```

!!! note "Simulação"
    Este comando invocará as regras definidas em `mk/rules_sim.mk`, compilando os arquivos VHDL e executando os testes em Python interligados ao RTL. Se tudo estiver correto, você verá os logs de PASS no terminal.

## 3. Hardware Físico (FPGA)

Se você possui uma placa FPGA suportada, o fluxo de *build* também está automatizado via scripts TCL.

Para gerar o Bitstream e programar a placa, utilize:
```bash
# Inicia a sintese, place & route, geração do bitstream e programa a FPGA
make fpga 
```

!!! tip "Hardware-in-the-Loop"
    Consulte as páginas [Hardware in the Loop (HIL)](https://risc-v-azedinha.github.io/NPU/software/hil/) e [FPGA Build](https://risc-v-azedinha.github.io/NPU/dev/fpga_build/) para detalhes mais aprofundados sobre a integração física.

## 4. Rodando uma Aplicacao (HIL)

A verdadeira mágica acontece quando colocamos a NPU para resolver problemas reais. O diretório `sw/` contém a API de programação da NPU e exemplos práticos.

Vamos testar a NPU executando a inferência do clássico **Dataset IRIS** (Classificação de Flores):
```bash
python sw/fpga_iris.py
```

O que este script faz:
1. Carrega os pesos e vieses (biases) de um modelo pré-treinado.
2. Injeta os dados na NPU via Memory-Mapped I/O (MMIO).
3. Aciona a Unidade de Controle (FSM) para iniciar o processamento no Arranjo Sistólico.
4. Lê os resultados quantizados descarregados pelas FIFOs e exibe a precisão da classificação no terminal.

!!! example "MNIST"
    Quer um desafio maior? Tente rodar o script de reconhecimento de dígitos: python `sw/fpga_mnist.py`! 

## Próximos Passos

Agora que você já rodou o projeto, sugerimos explorar as seguintes áreas da documentação para aprofundar seu entendimento:

- 📖 [Visão Geral da Arquitetura](https://risc-v-azedinha.github.io/NPU/hardware/overview/): Entenda como a arquitetura do hardware funciona!
- 💻 [Programação da API](https://risc-v-azedinha.github.io/NPU/software/api_programming/): Aprenda como controlar o hardware da NPU.

