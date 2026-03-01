# Hardware-in-the-Loop (HIL)

O conceito de **Hardware-in-the-Loop (HIL)** permite que validemos a NPU em seu ambiente real (a FPGA) enquanto ainda mantemos o controle do fluxo de dados através do PC (Host). 

![NPU Hardware-in-the-Loop](../assets/HIL_NPU.svg)

!!! note "Protocolo de Comunicação Serial"
    A interface entre o PC e a FPGA é feita através de uma conexão **UART de alta velocidade (921.600 bps)**. O módulo UART Controller no hardware em FPGA é responsável por comunicar os pacotes que são comandos a serem processados pela NPU ou resultados obtidos por uma operação.

## Arquitetura do Driver em Python

Os scripts na pasta `sw/` (como o `fpga_driver.py`) atuam como o "cérebro" do sistema. Eles executam a seguinte lógica sequencial:

### 1. Quantização (`FP32` para `INT8`)
A NPU não processa ponto flutuante para economizar área de silício. O script em Python pega os pesos de uma rede treinada (Keras/PyTorch) e aplica uma conversão linear afim para **INT8** (valore **entre -128 e 127**). Os parâmetros de **escala** (*Scale*) e **ponto zero** (*Zero Point*) são extraídos e enviados para a NPU.

### 2. Protocolo MMIO sobre UART
O driver não manda bytes aleatórios. Ele empacota os dados endereçando registradores específicos da NPU (Memory-Mapped I/O).

- Para enviar pesos, o Python manda os bytes empacotados apontando para o endereço `REG_WRITE_W` (`0x10`).

- Para enviar os dados da imagem (ativações), ele aponta para `REG_WRITE_A` (`0x14`).

### 3. Execução da Inferência
Após carregar os pesos:

1. O Python escreve a configuração de execução no `CSR_CONFIG` (`0x08`).

2. Envia um pulso de Start no `CSR_CMD` (`0x04`).

3. Fica fazendo *Polling* (checando repetidamente) o registrador `CSR_STATUS` (`0x00`) até que a flag de `DONE` retorne verdadeira.

4. Lê os resultados finais no registrador `REG_READ_OUT` (`0x18`).

## Como rodar o HIL

Com a FPGA programada e conectada na porta USB do seu PC, você pode executar as aplicações de validação real:

```bash
# Treina um modelo MNIST, quantiza, envia para a FPGA e mede a acurácia
make hil_mnist

# Executa o mesmo processo para o dataset Iris
make hil_iris
```