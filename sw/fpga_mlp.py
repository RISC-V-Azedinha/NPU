import numpy as np
import torch
import torch.nn as nn
import torch.optim as optim
from torchvision import datasets, transforms
from torch.utils.data import DataLoader
import tkinter as tk
from PIL import Image, ImageDraw
import serial
import struct
import time
import sys

# ==============================================================================
# CONFIGURAÇÃO DE HARDWARE
# ==============================================================================
SERIAL_PORT = '/dev/ttyUSB1'  # Verifique se é a porta correta da sua placa
BAUD_RATE   = 921600

# Mapa de Registradores
REG_STATUS     = 0x00
REG_CMD        = 0x04
REG_CONFIG     = 0x08
REG_WRITE_W    = 0x10 
REG_WRITE_A    = 0x14 
REG_READ_OUT   = 0x18 
REG_QUANT_CFG  = 0x40
REG_QUANT_MULT = 0x44
REG_BIAS_BASE  = 0x80

# Flags e Comandos
STATUS_DONE      = (1 << 1)
STATUS_OUT_VALID = (1 << 3)
CMD_RST_DMA_PTRS = (1 << 0)
CMD_START        = (1 << 1)
CMD_ACC_CLEAR    = (1 << 2)
CMD_RST_W_RD     = (1 << 4)
CMD_RST_I_RD     = (1 << 5)
CMD_RST_WR_W     = (1 << 6)
CMD_RST_WR_I     = (1 << 7)

# ==============================================================================
# DRIVER UART (COMUNICAÇÃO COM A FPGA)
# ==============================================================================
class NPUDriver:
    def __init__(self, port, baud):
        try:
            self.ser = serial.Serial(port, baud, timeout=2.0)
            self.ser.reset_input_buffer()
            print(f"\n[INFO] FPGA Conectada com Sucesso: {port} @ {baud} bps")
        except Exception as e:
            print(f"\n[ERRO CRÍTICO] Falha na Serial: {e}")
            sys.exit(1)

    def close(self): 
        self.ser.close()

    def write_reg(self, addr, data):
        self.ser.write(struct.pack('>B I I', 0x01, addr, int(data) & 0xFFFFFFFF))

    def read_reg(self, addr):
        self.ser.write(struct.pack('>B I', 0x02, addr))
        resp = self.ser.read(4)
        return struct.unpack('>I', resp)[0] if len(resp) == 4 else 0

    def wait_done(self):
        while not (self.read_reg(REG_STATUS) & STATUS_DONE): pass

    def read_results(self):
        res = []
        for _ in range(4):
            while not (self.read_reg(REG_STATUS) & STATUS_OUT_VALID): pass
            val = self.read_reg(REG_READ_OUT)
            res.append(self.unpack_int8(val))
            self.read_reg(REG_STATUS) 
        return res[::-1] 

    def pack_int8(self, v): 
        return ((int(v[0]) & 0xFF)) | \
               ((int(v[1]) & 0xFF) << 8) | \
               ((int(v[2]) & 0xFF) << 16) | \
               ((int(v[3]) & 0xFF) << 24)
    
    def unpack_int8(self, p):
        return [(p >> (i*8) & 0xFF) - 256 if (p >> (i*8) & 0xFF) & 0x80 else (p >> (i*8) & 0xFF) for i in range(4)]

# ==============================================================================
# ORQUESTRADOR DE CAMADA DENSAS NA FPGA
# ==============================================================================
def run_layer_on_fpga(driver, inputs, W, B, mult, shift, apply_relu):
    """
    Executa uma camada Dense arbitraria na FPGA via Tiling.
    W deve ter shape [out_features, in_features]
    """
    in_features = len(inputs)
    out_features = W.shape[0]
    
    # Configura PPU
    driver.write_reg(REG_QUANT_MULT, mult)
    driver.write_reg(REG_QUANT_CFG, shift)
    
    # Reset Total de Ponteiros
    driver.write_reg(REG_CMD, CMD_RST_DMA_PTRS | CMD_RST_WR_W | CMD_RST_WR_I)
    
    # 1. Carrega os inputs (Como Batch = 1, alocamos tudo na Linha 0 do Array)
    for k in range(in_features):
        driver.write_reg(REG_WRITE_A, driver.pack_int8([inputs[k], 0, 0, 0]))
        
    outputs = []
    
    # 2. Processa em blocos de 4 neurônios de saída (Tiling Horizontal)
    for chunk_start in range(0, out_features, 4):
        chunk_end = min(chunk_start + 4, out_features)
        chunk_size = chunk_end - chunk_start
        
        # Carrega Vieses (Bias) para as 4 colunas
        for b in range(chunk_size):
            driver.write_reg(REG_BIAS_BASE + b*4, int(B[chunk_start + b]))
        for b in range(chunk_size, 4):
            driver.write_reg(REG_BIAS_BASE + b*4, 0) # Padding
            
        # Reset apenas do ponteiro de escrita de PESOS
        driver.write_reg(REG_CMD, CMD_RST_WR_W)
        
        # Carrega a matriz de Pesos para esses 4 neurônios
        for k in range(in_features):
            w_padded = [0, 0, 0, 0]
            for c in range(chunk_size):
                w_padded[c] = W[chunk_start + c, k]
            driver.write_reg(REG_WRITE_W, driver.pack_int8(w_padded))
            
        # Executa Inferência na NPU
        driver.write_reg(REG_CONFIG, in_features)
        driver.write_reg(REG_CMD, CMD_START | CMD_RST_W_RD | CMD_RST_I_RD | CMD_ACC_CLEAR)
        driver.wait_done()
        
        # Lê os resultados (Apenas a linha 0 tem resultados válidos devido ao nosso mapeamento de entrada)
        res = driver.read_results()
        chunk_out = res[0][:chunk_size]
        
        # Aplica ReLU no Host se necessário
        if apply_relu:
            chunk_out = [max(0, val) for val in chunk_out]
            
        outputs.extend(chunk_out)
        
    return np.array(outputs, dtype=np.int8)

# ==============================================================================
# PYTORCH MODEL & QUANTIZAÇÃO
# ==============================================================================
class MLP_Model(nn.Module):
    def __init__(self):
        super(MLP_Model, self).__init__()
        self.flatten = nn.Flatten()
        self.hidden_layer = nn.Linear(28 * 28, 128)
        self.relu = nn.ReLU()
        self.output_layer = nn.Linear(128, 10)

    def forward(self, x):
        x = self.flatten(x)
        x = self.hidden_layer(x)
        x = self.relu(x)
        return self.output_layer(x)

def quantize_tensor(tensor_float, target_dtype, max_val_int):
    max_abs = np.max(np.abs(tensor_float))
    scale = max_val_int / max_abs if max_abs > 0 else 1.0
    tensor_quant = np.round(tensor_float * scale)
    return np.clip(tensor_quant, -max_val_int, max_val_int).astype(target_dtype), scale

def treinar_e_extrair():
    print("--- FASE 1: TREINO RÁPIDO DO MODELO (PYTORCH) ---")
    transform = transforms.Compose([transforms.ToTensor()])
    train_dataset = datasets.MNIST(root='./data', train=True, download=True, transform=transform)
    train_loader = DataLoader(train_dataset, batch_size=32, shuffle=True)
    
    model = MLP_Model()
    criterion = nn.CrossEntropyLoss()
    optimizer = optim.Adam(model.parameters(), lr=0.001)

    epochs = 3 # 3 épocas são suficientes para demonstração interativa
    for epoch in range(epochs):
        model.train()
        running_loss = 0.0
        for images, labels in train_loader:
            optimizer.zero_grad()
            outputs = model(images)
            loss = criterion(outputs, labels)
            loss.backward()
            optimizer.step()
            running_loss += loss.item()
        print(f"Época {epoch+1}/{epochs} - Loss: {running_loss/len(train_loader):.4f}")

    print("\n--- FASE 2: QUANTIZAÇÃO INT8/INT32 ---")
    model.eval()
    with torch.no_grad():
        w1_float = model.hidden_layer.weight.numpy()
        b1_float = model.hidden_layer.bias.numpy()
        w2_float = model.output_layer.weight.numpy()
        b2_float = model.output_layer.bias.numpy()

    w1_int8, scale_w1 = quantize_tensor(w1_float, np.int8, 127)
    w2_int8, scale_w2 = quantize_tensor(w2_float, np.int8, 127)

    b1_int32 = np.round(b1_float * scale_w1 * 255.0).astype(np.int32)
    b2_int32 = np.round(b2_float * scale_w2 * 127.0).astype(np.int32)
    
    return w1_int8, b1_int32, w2_int8, b2_int32

# ==============================================================================
# INTERFACE GRÁFICA (HIL + TKINTER)
# ==============================================================================
class NPU_HIL_App:
    def __init__(self, w1, b1, w2, b2):
        self.w1, self.b1 = w1, b1
        self.w2, self.b2 = w2, b2
        self.driver = NPUDriver(SERIAL_PORT, BAUD_RATE)
        
        self.janela = tk.Tk()
        self.janela.title("HIL: NPU (FPGA) - Inference Inteira")
        
        self.canvas_size = 280
        self.imagem_virtual = Image.new("L", (self.canvas_size, self.canvas_size), color=0)
        self.draw = ImageDraw.Draw(self.imagem_virtual)

        self.lbl_instrucao = tk.Label(self.janela, text="Desenhe o dígito com o mouse:", font=("Consolas", 12))
        self.lbl_instrucao.pack(pady=5)

        self.cv = tk.Canvas(self.janela, width=self.canvas_size, height=self.canvas_size, bg="black")
        self.cv.pack(pady=10)
        self.cv.bind("<B1-Motion>", self.pintar)

        frame_botoes = tk.Frame(self.janela)
        frame_botoes.pack(pady=5)

        tk.Button(frame_botoes, text="Inferir na FPGA", command=self.executar_inferencia, font=("Consolas", 12), bg="#4CAF50", fg="white").pack(side=tk.LEFT, padx=10)
        tk.Button(frame_botoes, text="Limpar", command=self.limpar_tela, font=("Consolas", 12)).pack(side=tk.RIGHT, padx=10)

        self.lbl_resultado = tk.Label(self.janela, text="Aguardando hardware...", font=("Consolas", 14))
        self.lbl_resultado.pack(pady=10)

    def pintar(self, event):
        x1, y1 = (event.x - 12), (event.y - 12)
        x2, y2 = (event.x + 12), (event.y + 12)
        self.cv.create_oval(x1, y1, x2, y2, fill="white", outline="white")
        self.draw.ellipse([x1, y1, x2, y2], fill=255)

    def limpar_tela(self):
        self.cv.delete("all")
        self.draw.rectangle([0, 0, self.canvas_size, self.canvas_size], fill=0)
        self.lbl_resultado.config(text="Desenhe um dígito (0-9)...", fg="black")

    def executar_inferencia(self):
        bbox = self.imagem_virtual.getbbox()
        if bbox is None:
            self.lbl_resultado.config(text="Por favor, desenhe um número.", fg="red")
            return

        self.lbl_resultado.config(text="Enviando matrizes via UART...", fg="blue")
        self.janela.update()

        # PRE-PROCESSAMENTO GEOMÉTRICO
        img_cropped = self.imagem_virtual.crop(bbox)
        width, height = img_cropped.size
        max_dim = max(width, height)
        ratio = 20.0 / max_dim
        new_width, new_height = int(width * ratio), int(height * ratio)

        img_resized = img_cropped.resize((new_width, new_height), Image.Resampling.LANCZOS)
        img_28x28 = Image.new("L", (28, 28), color=0)
        img_28x28.paste(img_resized, ((28 - new_width) // 2, (28 - new_height) // 2))

        img_array = np.array(img_28x28)
        img_npu = np.clip(img_array.flatten() // 2, 0, 127).astype(np.int8)

        # ====================================================================
        # INFERÊNCIA HIL NA FPGA
        # ====================================================================
        try:
            start_time = time.time()
            
            # Passada 1 (784 -> 128)
            ativacoes_layer1 = run_layer_on_fpga(
                self.driver, inputs=img_npu, W=self.w1, B=self.b1, 
                mult=1, shift=9, apply_relu=True
            )
            
            # Passada 2 (128 -> 10)
            logits_layer2 = run_layer_on_fpga(
                self.driver, inputs=ativacoes_layer1, W=self.w2, B=self.b2, 
                mult=1, shift=9, apply_relu=False
            )
            
            latencia = (time.time() - start_time) * 1000
            predicao = np.argmax(logits_layer2)

            self.lbl_resultado.config(
                text=f"Predição FPGA: {predicao}\nScores: {logits_layer2}\nLatência UART+NPU: {latencia:.0f} ms",
                fg="green"
            )
        except Exception as e:
            self.lbl_resultado.config(text=f"Erro de Comunicação: {e}", fg="red")

    def iniciar(self):
        self.janela.protocol("WM_DELETE_WINDOW", self.on_fechar)
        self.janela.mainloop()
        
    def on_fechar(self):
        print("Encerrando conexão com a FPGA...")
        self.driver.close()
        self.janela.destroy()

if __name__ == "__main__":
    w1, b1, w2, b2 = treinar_e_extrair()
    print("\nIniciando Interface HIL. Olhe a janela do Tkinter!")
    app = NPU_HIL_App(w1, b1, w2, b2)
    app.iniciar()