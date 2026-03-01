# Ambiente de Testes com COCOTB

A verificação do hardware é feita utilizando o **COCOTB**, um framework baseado em Python, operando em conjunto com o simulador **GHDL**. Toda a automação de compilação e execução é gerenciada pelo `Makefile` na raiz do projeto.

!!! info "Por que usar COCOTB?"
    O COCOTB permite escrever estímulos de hardware usando **Python 3**. Isso traz uma vantagem gigantesca: podemos instanciar redes neurais reais (usando bibliotecas como NumPy ou PyTorch) em Python, gerar os *Golden Models* (resultados esperados perfeitos) e comparar em tempo real com a saída do hardware simulado no GHDL.

## Estrutura do Testbench

Todos os testes automatizados residem na pasta `sim/`. A lógica de um teste típico do projeto segue este fluxo:

1. **Reset e Inicialização**: O script Python aplica sinais de clock e reseta a entidade VHDL.
2. **Estímulo**: O Python envia dados (Pesos e Ativações) para as portas de entrada do VHDL.
3. **Golden Model**: O Python calcula a mesma operação matricial matematicamente.
4. **Asserção (Assert)**: O resultado que sai do VHDL é comparado com o resultado do Golden Model. Se divergirem, o teste falha.

## Comandos de Simulação

Todos os testes automatizados residem na pasta `sim/`. Para rodar um teste, você precisa especificar o testbench (`TEST`) e a entidade de topo (`TOP`):

```bash
make cocotb TEST=<nome_do_testbench> TOP=<entidade_top_level>
```

!!! example "Exemplo Prático"
    Para rodar os testes do Processing Element (PE), execute:
    `make cocotb TEST=test_mac_pe TOP=mac_pe`

## Visualização de Ondas (GTKWave)

Após a simulação, um arquivo `.vcd` é gerado na pasta `build/`. Para inspecionar os sinais:

```bash
make view TEST=<nome_do_testbench>
```

## Atalhos para Datasets

Para simulações de integração completa do sistema (End-to-End), temos atalhos prontos:

- `make sim_mnist`: Roda a simulação completa para a rede do MNIST.
- `make sim_iris`: Roda a simulação completa para a rede do IRIS.

!!! tip "Limpeza"
    Para limpar todos os arquivos gerados pelas simulações, basta rodar `make clean`.

