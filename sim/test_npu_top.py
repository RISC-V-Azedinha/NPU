# ==============================================================================
# File: test_npu_top.py (ULTIMATE STRESS EDITION)
# ==============================================================================

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge, ClockCycles
import random
from test_utils import *

# ==============================================================================
# CONSTANTES
# ==============================================================================

REG_STATUS     = 0x00
REG_CMD        = 0x04
REG_CONFIG     = 0x08
REG_WRITE_W    = 0x10
REG_WRITE_A    = 0x14
REG_READ_OUT   = 0x18
REG_WRITE_IMG  = 0x1C
REG_W_BASE     = 0x20
REG_I_BASE     = 0x24
REG_IM2COL_EN  = 0x28
REG_IM2COL_GEO = 0x2C
REG_IM2COL_NW  = 0x30
REG_TILES      = 0x34
REG_OUT_CFG    = 0x38
REG_MODE       = 0x3C
MODE_GEMV      = (1 << 0)
MODE_STREAM_I  = (1 << 1)
MODE_STREAM_W  = (1 << 2)
MODE_OVERLAP   = (1 << 3)
OUT_LOOP       = (1 << 2)
REG_DESC       = 0x0C
STATUS_PROG_END = (1 << 4)
TILES_BIAS     = (1 << 18)

TILES_RW_W     = (1 << 16)
TILES_RW_I     = (1 << 17)
OUT_ORDER      = (1 << 0)
OUT_UNPACK     = (1 << 1)
REG_QUANT_CFG  = 0x40
REG_QUANT_MULT = 0x44
REG_FLAGS      = 0x48
REG_BIAS_BASE  = 0x80

STATUS_BUSY      = (1 << 0)
STATUS_DONE      = (1 << 1)
STATUS_OUT_VALID = (1 << 3)

CMD_RST_DMA_PTRS = (1 << 0)
CMD_START        = (1 << 1)
CMD_ACC_CLEAR    = (1 << 2)
CMD_NO_DRAIN     = (1 << 3)
CMD_RST_W_RD     = (1 << 4)
CMD_RST_I_RD     = (1 << 5)
CMD_RST_WR_W     = (1 << 6)
CMD_RST_WR_I     = (1 << 7)

# ==============================================================================
# MODELO DE REFERÊNCIA
# ==============================================================================

def clamp_int8(val):
    if val > 127: return 127
    if val < -128: return -128
    return int(val)

def model_ppu(acc, bias, mult, shift, zero, en_relu):
    val = acc + bias
    val = val * mult
    if shift > 0:
        round_bit = 1 << (shift - 1)
        val = (val + round_bit) >> shift
    val = val + zero
    if en_relu and val < 0: val = 0
    return clamp_int8(val)

def compute_ref(mat_A, mat_B, k_dim, bias, mult, shift, zero, en_relu):
    acc_matrix = [[0]*4 for _ in range(4)]
    for r in range(4):
        for c in range(4):
            acc_matrix[r][c] = sum(mat_A[r][k] * mat_B[k][c] for k in range(k_dim))
            
    final_out = []
    for r in range(4):
        row_res = []
        for c in range(4):
            val = model_ppu(acc_matrix[r][c], bias[c], mult, shift, zero, en_relu)
            row_res.append(val)
        final_out.append(row_res)
    return final_out

def pack_int8(values):
    packed = 0
    for i, val in enumerate(values):
        val_8bit = val & 0xFF
        packed |= (val_8bit << (i * 8))
    return packed

def unpack_int8(packed):
    values = []
    for i in range(4):
        raw = (packed >> (i * 8)) & 0xFF
        if raw & 0x80: raw -= 256
        values.append(raw)
    return values

# ==============================================================================
# DRIVERS MMIO
# ==============================================================================

async def mmio_write(dut, addr, data):
    dut.addr_i.value = addr
    dut.data_i.value = int(data) & 0xFFFFFFFF
    dut.we_i.value   = 1
    dut.vld_i.value  = 1
    
    timeout = 1000
    while timeout > 0:
        await RisingEdge(dut.clk)
        if dut.rdy_o.value == 1: break
        timeout -= 1
            
    dut.vld_i.value = 0
    dut.we_i.value  = 0
    await RisingEdge(dut.clk) 

async def mmio_read(dut, addr):
    dut.addr_i.value = addr
    dut.we_i.value   = 0
    dut.vld_i.value  = 1
    
    data = 0
    timeout = 1000
    while timeout > 0:
        await RisingEdge(dut.clk)
        if dut.rdy_o.value == 1:
            data = int(dut.data_o.value)
            break
        timeout -= 1
    dut.vld_i.value = 0
    await RisingEdge(dut.clk) 
    return data

async def reset_dut(dut):
    dut.vld_i.value  = 0
    dut.we_i.value   = 0
    dut.addr_i.value = 0
    dut.data_i.value = 0
    dut.rst_n.value  = 0
    await ClockCycles(dut.clk, 10)
    dut.rst_n.value  = 1
    await ClockCycles(dut.clk, 10)

async def npu_setup_config(dut, mult, shift, zero, bias, en_relu=False):
    await mmio_write(dut, REG_QUANT_MULT, mult)
    await mmio_write(dut, REG_QUANT_CFG, ((zero & 0xFF) << 8) | (shift & 0x1F))
    await mmio_write(dut, REG_FLAGS, 1 if en_relu else 0)
    for i in range(4): await mmio_write(dut, REG_BIAS_BASE + (i*4), bias[i])

async def npu_load_data(dut, mat_A, mat_B, k_dim):
    await mmio_write(dut, REG_CMD, CMD_RST_DMA_PTRS)
    for k in range(k_dim):
        col_A = [mat_A[r][k] for r in range(4)]
        row_B = mat_B[k]
        await mmio_write(dut, REG_WRITE_A, pack_int8(col_A))
        await mmio_write(dut, REG_WRITE_W, pack_int8(row_B))

# ==============================================================================
# TESTES DE TORTURA
# ==============================================================================

@cocotb.test()
async def test_corner_cases_from_hell(dut):
    """
    Testa limites matemáticos extremos:
    - Saturação máxima positiva
    - Saturação máxima negativa
    - Zeros
    - Overflow de acumulador
    """
    log_header("TESTE: CORNER CASES FROM HELL")
    cocotb.start_soon(Clock(dut.clk, 10, unit="ns").start())
    await reset_dut(dut)

    corner_cases = [
        # Caso 1: Max Gain (Mult=255, Shift=0), Inputs Max -> Deve saturar em 127
        {
            "name": "MAX POSITIVE SATURATION",
            "A": 127, "B": 127, "bias": 1000, "mult": 255, "shift": 0, "zero": 0, "relu": False
        },
        # Caso 2: Max Negative (Mult=255), Bias Negativo -> Deve saturar em -128
        {
            "name": "MAX NEGATIVE SATURATION",
            "A": 127, "B": -128, "bias": -1000, "mult": 255, "shift": 0, "zero": 0, "relu": False
        },
        # Caso 3: Zeros limpos
        {
            "name": "ALL ZEROS",
            "A": 0, "B": 0, "bias": 0, "mult": 1, "shift": 0, "zero": 0, "relu": False
        },
        # Caso 4: Accumulator Stress (Muitos valores pequenos somando muito)
        # K=100, 10*10 = 100 por MAC -> 10.000 total no acc.
        {
            "name": "ACCUMULATOR STRESS",
            "A": 10, "B": 10, "bias": 0, "mult": 1, "shift": 0, "zero": 0, "relu": False
        }
    ]

    for case in corner_cases:
        log_info(f"Running: {case['name']}")
        K_DIM = 100
        mat_A = [[case["A"]]*K_DIM for _ in range(4)]
        mat_B = [[case["B"]]*4 for _ in range(K_DIM)]
        bias  = [case["bias"]]*4

        await npu_setup_config(dut, case["mult"], case["shift"], case["zero"], bias, case["relu"])
        await npu_load_data(dut, mat_A, mat_B, K_DIM)
        
        # Executa
        await mmio_write(dut, REG_CONFIG, K_DIM)
        await mmio_write(dut, REG_CMD, CMD_START | CMD_RST_W_RD | CMD_RST_I_RD | CMD_ACC_CLEAR)
        
        while (await mmio_read(dut, REG_STATUS) & STATUS_DONE) == 0:
            await ClockCycles(dut.clk, 10)

        # Lê
        results = []
        for _ in range(4):
            val = await mmio_read(dut, REG_READ_OUT)
            results.append(unpack_int8(val))
        results.reverse()

        ref = compute_ref(mat_A, mat_B, K_DIM, bias, case["mult"], case["shift"], case["zero"], case["relu"])
        
        if results != ref:
            log_error(f"FALHA NO CASO {case['name']}")
            log_error(f"Esperado: {ref}")
            log_error(f"Obtido:   {results}")
            assert False
        else:
            log_success(f"{case['name']} - OK")


@cocotb.test()
async def test_chaos_monkey_mmio(dut):
    """
    Testa a resiliência do BUSY LOCK.
    Enquanto a NPU processa uma matriz grande, uma thread paralela
    tenta escrever lixo em registros críticos.
    """
    log_header("TESTE: CHAOS MONKEY (Busy Lock Stress)")
    cocotb.start_soon(Clock(dut.clk, 10, unit="ns").start())
    await reset_dut(dut)

    K_DIM = 128
    mat_A = [[1]*K_DIM for _ in range(4)]
    mat_B = [[1]*4 for _ in range(K_DIM)]
    bias = [0]*4
    
    # Configuração Inicial Correta
    await npu_setup_config(dut, mult=1, shift=0, zero=0, bias=bias)
    await npu_load_data(dut, mat_A, mat_B, K_DIM)

    # Inicia NPU
    log_info("Iniciando NPU...")
    await mmio_write(dut, REG_CONFIG, K_DIM)
    await mmio_write(dut, REG_CMD, CMD_START | CMD_RST_W_RD | CMD_RST_I_RD | CMD_ACC_CLEAR)

    # --- O MACACO DO CAOS ---
    async def chaos_monkey():
        for _ in range(50): # 50 tentativas de sabotagem
            # A trava só protege a NPU enquanto ela está BUSY: depois do DONE, uma escrita no CMD
            # (ex.: ACC_CLEAR, que zera a FIFO) é legítima, então o macaco para de sabotar ali
            if dut.s_sts_busy.value == 0: break
            target_reg = random.choice([REG_CONFIG, REG_QUANT_MULT, REG_WRITE_W, REG_CMD])
            garbage_data = random.randint(0, 0xFFFFFFFF)
            
            # Tenta escrever sem esperar handshake (fire and forget)
            dut.addr_i.value = target_reg
            dut.data_i.value = garbage_data
            dut.we_i.value = 1
            dut.vld_i.value = 1
            await RisingEdge(dut.clk)
            dut.vld_i.value = 0
            dut.we_i.value = 0
            
            await ClockCycles(dut.clk, random.randint(1, 5))

    # Roda o Chaos Monkey em paralelo
    chaos_task = cocotb.start_soon(chaos_monkey())

    # Espera NPU terminar
    while (await mmio_read(dut, REG_STATUS) & STATUS_DONE) == 0:
        await ClockCycles(dut.clk, 10)
    
    await chaos_task # Garante que o macaco parou

    # Verifica integridade
    results = []
    for _ in range(4):
        val = await mmio_read(dut, REG_READ_OUT)
        results.append(unpack_int8(val))
    results.reverse()

    # Se K=128, A=1, B=1 -> Acc=128 -> Clamped to 127.
    # Se o macaco tivesse mudado o MULT para 0 ou o RUN_SIZE, daria erro.
    if results[0][0] == 127:
        log_success("Chaos Monkey falhou em quebrar a NPU! Lock funciona.")
    else:
        log_error(f"NPU foi sabotada! Resultado: {results[0][0]}")
        assert False


@cocotb.test()
async def test_backpressure_torture(dut):
    """
    Testa o BACKPRESSURE (Stall).
    Lê os resultados da FIFO com atrasos aleatórios e longos,
    forçando a FIFO a encher e o controlador a pausar o DRAIN.
    """
    log_header("TESTE: BACKPRESSURE TORTURE (Leitura Intermitente)")
    cocotb.start_soon(Clock(dut.clk, 10, unit="ns").start())
    await reset_dut(dut)

    # Configuração
    await npu_setup_config(dut, mult=1, shift=0, zero=0, bias=[0]*4)
    
    K_DIM = 4
    # Matriz que gera valores conhecidos: Linha 0 -> 10, Linha 1 -> 20, etc.
    mat_A = [[(r+1)]*K_DIM for r in range(4)] # Linhas: 1, 2, 3, 4
    mat_B = [[10//K_DIM]*4 for _ in range(K_DIM)] # Colunas somam para dar scale
    # Na verdade, simplificando: A=1, B=1 -> Soma = K_DIM.
    # Vamos fazer: A = [[1..], [2..], [3..], [4..]], B = [[1..], ..]
    # Acc[r][c] = K_DIM * (r+1)
    
    await npu_load_data(dut, mat_A, [[1]*4]*K_DIM, K_DIM)
    
    log_info("Iniciando NPU...")
    await mmio_write(dut, REG_CONFIG, K_DIM)
    await mmio_write(dut, REG_CMD, CMD_START | CMD_RST_W_RD | CMD_RST_I_RD | CMD_ACC_CLEAR)

    log_info("Iniciando leitura lenta...")
    results = []
    
    # Precisamos ler 4 linhas
    for i in range(4):
        # Espera aleatória ANTES de tentar ler
        delay = random.randint(10, 200) # Delay grande
        await ClockCycles(dut.clk, delay)
        
        # Polling pelo Valid
        while (await mmio_read(dut, REG_STATUS) & STATUS_OUT_VALID) == 0:
            await RisingEdge(dut.clk)
            
        val = await mmio_read(dut, REG_READ_OUT)
        results.append(unpack_int8(val))
        log_info(f"Leitura {i+1}/4 concluída após delay de {delay} ciclos.")

    results.reverse()
    
    expected = [[(r+1)*K_DIM]*4 for r in range(4)]
    
    if results == expected:
        log_success("Backpressure funcionou! Dados íntegros.")
    else:
        log_error(f"Falha no Backpressure. Lido: {results}, Esperado: {expected}")
        assert False


@cocotb.test()
async def test_consecutive_runs_no_reset(dut):
    """
    Testa múltiplas execuções consecutivas SEM reset de hardware (RST_N).
    Garante que a FSM limpa seus estados internos corretamente.
    """
    log_header("TESTE: 10 EXECUÇÕES CONSECUTIVAS (Sem Hard Reset)")
    cocotb.start_soon(Clock(dut.clk, 10, unit="ns").start())
    await reset_dut(dut) # Reset inicial apenas

    for i in range(10):
        # Variamos o K a cada run para garantir que o contador limpa
        K_DIM = 4 + i 
        val_A = random.randint(1, 5)
        
        await npu_setup_config(dut, mult=1, shift=0, zero=0, bias=[0]*4)
        
        # Carga
        mat_A = [[val_A]*K_DIM for _ in range(4)]
        mat_B = [[1]*4 for _ in range(K_DIM)]
        await npu_load_data(dut, mat_A, mat_B, K_DIM)
        
        # Execução (Importante: CMD_ACC_CLEAR deve limpar o acumulador anterior)
        await mmio_write(dut, REG_CONFIG, K_DIM)
        await mmio_write(dut, REG_CMD, CMD_START | CMD_RST_W_RD | CMD_RST_I_RD | CMD_ACC_CLEAR)
        
        # Espera
        while (await mmio_read(dut, REG_STATUS) & STATUS_DONE) == 0:
            await RisingEdge(dut.clk)
            
        # Leitura
        results = []
        for _ in range(4):
            val = await mmio_read(dut, REG_READ_OUT)
            results.append(unpack_int8(val))
        results.reverse()
        
        expected_val = val_A * K_DIM
        if results[0][0] != expected_val:
            log_error(f"Erro na execução {i+1}! Esperado {expected_val}, Lido {results[0][0]}")
            assert False
        
    log_success("10 execuções consecutivas passaram com sucesso.")

@cocotb.test()
async def test_locality_feature(dut):
    """
    Testa a reutilização de dados (Localidade).
    Cenário: Imagem (Input) constante, troca apenas os Pesos (Filtros).
    """
    log_header("TESTE: LOCALIDADE DE DADOS (Reuse Inputs)")
    cocotb.start_soon(Clock(dut.clk, 10, unit="ns").start())
    await reset_dut(dut)

    K_DIM = 4
    # Configuração Neutra
    await npu_setup_config(dut, mult=1, shift=0, zero=0, bias=[0]*4)

    # -------------------------------------------------------
    # PASSADA 1: Carrega TUDO (Input A, Peso A)
    # -------------------------------------------------------
    input_A = [[10]*K_DIM for _ in range(4)] # Inputs = 10
    weight_A = [[1]*4 for _ in range(K_DIM)] # Pesos = 1
    
    log_info("Passada 1: Carregando Input A e Peso A...")
    await npu_load_data(dut, input_A, weight_A, K_DIM)
    
    # Executa Passada 1
    await mmio_write(dut, REG_CONFIG, K_DIM)
    await mmio_write(dut, REG_CMD, CMD_START | CMD_RST_W_RD | CMD_RST_I_RD | CMD_ACC_CLEAR)
    
    while (await mmio_read(dut, REG_STATUS) & STATUS_DONE) == 0: await RisingEdge(dut.clk)
    
    # Drena saída (para limpar FIFO, não precisamos validar agora)
    for _ in range(4): 
        while (await mmio_read(dut, REG_STATUS) & STATUS_OUT_VALID) == 0: await RisingEdge(dut.clk)
        await mmio_read(dut, REG_READ_OUT)

    # -------------------------------------------------------
    # PASSADA 2: Troca APENAS Pesos (Input A mantém, Peso B)
    # -------------------------------------------------------
    weight_B = [[2]*4 for _ in range(K_DIM)] # Pesos = 2
    
    log_info("Passada 2: Resetando APENAS ponteiro de Pesos...")
    # Zera ponteiro de escrita de Pesos (Bit 6), mas NÃO o de Inputs (Bit 7 ou 0)
    await mmio_write(dut, REG_CMD, CMD_RST_WR_W) 
    
    log_info("Carregando Peso B (Input A deve estar lá)...")
    for k in range(K_DIM):
        row_B = weight_B[k]
        # Escreve apenas na porta de Pesos!
        await mmio_write(dut, REG_WRITE_W, pack_int8(row_B))
        
    # Executa Passada 2 (Importante: Resetar ponteiros de LEITURA para ler do zero)
    await mmio_write(dut, REG_CMD, CMD_START | CMD_RST_W_RD | CMD_RST_I_RD | CMD_ACC_CLEAR)
    
    while (await mmio_read(dut, REG_STATUS) & STATUS_DONE) == 0: await RisingEdge(dut.clk)
    
    # Verifica Resultado: Input A (10) * Peso B (2) * K(4) = 80
    results = []
    for _ in range(4):
        val = await mmio_read(dut, REG_READ_OUT)
        results.append(unpack_int8(val))
    results.reverse()
    
    expected_val = 10 * 2 * 4 # = 80
    if results[0][0] == expected_val:
        log_success("SUCESSO: Dados de Input foram reutilizados corretamente!")
    else:
        log_error(f"FALHA: Esperado {expected_val}, Lido {results[0][0]}. (Input foi apagado?)")
        assert False

@cocotb.test()
async def test_resident_weights(dut):
    """
    Testa os registradores W_BASE/I_BASE (Pesos residentes).
    Cenário: duas camadas com pesos em regiões distintas da RAM, carregados uma única vez;
    várias "imagens" trocam apenas os Inputs, e cada camada é selecionada pela sua base.
    """
    log_header("TESTE: PESOS RESIDENTES (W_BASE / I_BASE)")
    cocotb.start_soon(Clock(dut.clk, 10, unit="ns").start())
    await reset_dut(dut)

    K1, K2 = 3, 5
    await npu_setup_config(dut, mult=1, shift=0, zero=0, bias=[0]*4)

    # Bases zeradas no reset (retrocompatível)
    assert await mmio_read(dut, REG_W_BASE) == 0
    assert await mmio_read(dut, REG_I_BASE) == 0

    # Pesos das duas camadas: camada 1 na base 0, camada 2 na base K1
    w1 = [[random.randint(-8, 8) for _ in range(4)] for _ in range(K1)]
    w2 = [[random.randint(-8, 8) for _ in range(4)] for _ in range(K2)]

    await mmio_write(dut, REG_CMD, CMD_RST_WR_W)
    for k in range(K1): await mmio_write(dut, REG_WRITE_W, pack_int8(w1[k]))

    # A camada 2 é gravada de forma independente: a base redireciona o RST_WR_W
    await mmio_write(dut, REG_W_BASE, K1)
    assert await mmio_read(dut, REG_W_BASE) == K1
    await mmio_write(dut, REG_CMD, CMD_RST_WR_W)
    for k in range(K2): await mmio_write(dut, REG_WRITE_W, pack_int8(w2[k]))

    async def run_layer(w_base, i_base, inputs, weights, k_dim):
        await mmio_write(dut, REG_W_BASE, w_base)
        await mmio_write(dut, REG_I_BASE, i_base)
        await mmio_write(dut, REG_CMD, CMD_RST_WR_I)
        for k in range(k_dim):
            await mmio_write(dut, REG_WRITE_A, pack_int8([inputs[r][k] for r in range(4)]))
        await mmio_write(dut, REG_CONFIG, k_dim)
        await mmio_write(dut, REG_CMD, CMD_START | CMD_RST_W_RD | CMD_RST_I_RD | CMD_ACC_CLEAR)
        while (await mmio_read(dut, REG_STATUS) & STATUS_DONE) == 0: await RisingEdge(dut.clk)
        results = []
        for _ in range(4):
            while (await mmio_read(dut, REG_STATUS) & STATUS_OUT_VALID) == 0: await RisingEdge(dut.clk)
            results.append(unpack_int8(await mmio_read(dut, REG_READ_OUT)))
        results.reverse()
        expected = compute_ref(inputs, weights, k_dim, [0]*4, 1, 0, 0, False)
        if results != expected:
            log_error(f"Esperado {expected}, Lido {results}")
            assert False

    for img in range(3):
        a1 = [[random.randint(-8, 8) for _ in range(K1)] for _ in range(4)]
        a2 = [[random.randint(-8, 8) for _ in range(K2)] for _ in range(4)]
        # Inputs da camada 2 numa base não nula, para exercitar I_BASE também
        await run_layer(0,  0,  a1, w1, K1)
        await run_layer(K1, 16, a2, w2, K2)
        log_info(f"Imagem {img+1}: duas camadas corretas sem recarregar pesos")

    log_success("Pesos residentes reutilizados corretamente entre imagens.")


async def run_im2col_conv(dut, in_w, in_h, stride, kw, kh):
    """ Convolução com im2col em hardware: envia a imagem crua pela porta IMG e confere
    cada grupo de 4 janelas contra o im2col de referência + compute_ref. """
    out_w = (in_w - kw) // stride + 1
    out_h = (in_h - kh) // stride + 1
    nwin  = out_w * out_h
    k_dim = kw * kh

    img = [random.randint(-128, 127) for _ in range(in_w * in_h)]
    wgt = [[random.randint(-128, 127) for _ in range(4)] for _ in range(k_dim)]
    bias = [random.randint(-5000, 5000) for _ in range(4)]
    mult, shift = random.randint(1, 4), random.randint(6, 10)

    def window(p):
        if p >= nwin: return [0] * k_dim
        u, v = divmod(p, out_w)
        return [img[(u*stride + i) * in_w + v*stride + j] for i in range(kh) for j in range(kw)]

    await npu_setup_config(dut, mult=mult, shift=shift, zero=0, bias=bias, en_relu=False)
    await mmio_write(dut, REG_CMD, CMD_RST_DMA_PTRS)
    for k in range(k_dim): await mmio_write(dut, REG_WRITE_W, pack_int8(wgt[k]))
    img_padded = img + [0] * (-len(img) % 4)
    for w in range(len(img_padded) // 4): await mmio_write(dut, REG_WRITE_IMG, pack_int8(img_padded[4*w:4*w+4]))

    geom = (kw << 20) | (stride << 16) | (out_w << 8) | in_w
    await mmio_write(dut, REG_IM2COL_GEO, geom)
    await mmio_write(dut, REG_IM2COL_NW, nwin)
    await mmio_write(dut, REG_IM2COL_EN, 1)
    assert await mmio_read(dut, REG_IM2COL_GEO) == geom
    await mmio_write(dut, REG_CONFIG, k_dim)

    groups = (nwin + 3) // 4
    for g in range(groups):
        first = CMD_RST_W_RD | CMD_RST_I_RD if g == 0 else CMD_RST_W_RD
        await mmio_write(dut, REG_CMD, CMD_START | CMD_ACC_CLEAR | first)
        while (await mmio_read(dut, REG_STATUS) & STATUS_DONE) == 0: await RisingEdge(dut.clk)
        results = []
        for _ in range(4):
            while (await mmio_read(dut, REG_STATUS) & STATUS_OUT_VALID) == 0: await RisingEdge(dut.clk)
            results.append(unpack_int8(await mmio_read(dut, REG_READ_OUT)))
        results.reverse()
        mat_A = [window(4*g + r) for r in range(4)]
        expected = compute_ref(mat_A, wgt, k_dim, bias, mult, shift, 0, False)
        if results != expected:
            log_error(f"Grupo {g}: Esperado {expected}, Lido {results}")
            assert False

    await mmio_write(dut, REG_IM2COL_EN, 0)
    log_info(f"im2col {in_w}x{in_h}, kernel {kw}x{kh}, stride {stride}: {nwin} janelas em {groups} grupos OK")

@cocotb.test()
async def test_im2col_hw(dut):
    """
    Testa o im2col em hardware (porta IMG + IM2COL_*):
    - Geometria do MNIST da CNN (28x28, 3x3, stride 2): 169 janelas, último grupo parcial
    - Geometrias com quebra de linha em posições diferentes e kernel retangular
    - Retorno ao modo legado (RAM de Inputs) com o im2col desligado
    """
    log_header("TESTE: IM2COL EM HARDWARE")
    cocotb.start_soon(Clock(dut.clk, 10, unit="ns").start())
    await reset_dut(dut)

    await run_im2col_conv(dut, in_w=28, in_h=28, stride=2, kw=3, kh=3)
    await run_im2col_conv(dut, in_w=11, in_h=9,  stride=1, kw=3, kh=2)
    await run_im2col_conv(dut, in_w=17, in_h=13, stride=3, kw=5, kh=4)

    # Modo legado depois do im2col: os Inputs voltam a sair da RAM
    K = 4
    mat_A = [[random.randint(-20, 20) for _ in range(K)] for _ in range(4)]
    mat_B = [[random.randint(-20, 20) for _ in range(4)] for _ in range(K)]
    await npu_setup_config(dut, mult=1, shift=0, zero=0, bias=[0]*4)
    await npu_load_data(dut, mat_A, mat_B, K)
    await mmio_write(dut, REG_CONFIG, K)
    await mmio_write(dut, REG_CMD, CMD_START | CMD_RST_W_RD | CMD_RST_I_RD | CMD_ACC_CLEAR)
    while (await mmio_read(dut, REG_STATUS) & STATUS_DONE) == 0: await RisingEdge(dut.clk)
    results = []
    for _ in range(4):
        while (await mmio_read(dut, REG_STATUS) & STATUS_OUT_VALID) == 0: await RisingEdge(dut.clk)
        results.append(unpack_int8(await mmio_read(dut, REG_READ_OUT)))
    results.reverse()
    assert results == compute_ref(mat_A, mat_B, K, [0]*4, 1, 0, 0, False), "Modo legado falhou após o im2col"

    log_success("im2col em hardware confere com a referência em todas as geometrias.")


@cocotb.test()
async def test_tile_sequencer(dut):
    """
    Testa o sequenciador de tiles (TILES) e o formatador de saída (OUT_CFG):
    - Conv 28x28 inteira num único START: 43 tiles, im2col, pesos voltando à base a cada tile,
      saída na ordem das janelas e uma ativação por palavra (688 palavras > FIFO de 64)
    - Leitura atrasada: a NPU tem de parar com a FIFO cheia e retomar quando ela esvazia
    - Sequência estilo densa: entradas voltam à base a cada tile, pesos avançam
    """
    log_header("TESTE: SEQUENCIADOR DE TILES + FORMATO DE SAÍDA")
    cocotb.start_soon(Clock(dut.clk, 10, unit="ns").start())
    await reset_dut(dut)

    # ---------------------------------------------------------------- Conv num único START
    in_w, stride, kw = 28, 2, 3
    out_w = (in_w - kw) // stride + 1
    nwin, k_dim = out_w * out_w, kw * kw
    tiles = (nwin + 3) // 4

    img  = [random.randint(-128, 127) for _ in range(in_w * in_w)]
    wgt  = [[random.randint(-128, 127) for _ in range(4)] for _ in range(k_dim)]
    bias = [random.randint(-5000, 5000) for _ in range(4)]

    def window(p):
        if p >= nwin: return [0] * k_dim
        u, v = divmod(p, out_w)
        return [img[(u*stride + i) * in_w + v*stride + j] for i in range(kw) for j in range(kw)]

    await npu_setup_config(dut, mult=3, shift=8, zero=0, bias=bias, en_relu=True)
    await mmio_write(dut, REG_CMD, CMD_RST_DMA_PTRS)
    for k in range(k_dim): await mmio_write(dut, REG_WRITE_W, pack_int8(wgt[k]))
    for w in range(len(img) // 4): await mmio_write(dut, REG_WRITE_IMG, pack_int8(img[4*w:4*w+4]))
    await mmio_write(dut, REG_IM2COL_GEO, (kw << 20) | (stride << 16) | (out_w << 8) | in_w)
    await mmio_write(dut, REG_IM2COL_NW, nwin)
    await mmio_write(dut, REG_IM2COL_EN, 1)
    await mmio_write(dut, REG_CONFIG, k_dim)
    await mmio_write(dut, REG_TILES, tiles | TILES_RW_W)
    await mmio_write(dut, REG_OUT_CFG, OUT_ORDER | OUT_UNPACK)
    assert await mmio_read(dut, REG_TILES) == tiles | TILES_RW_W

    await mmio_write(dut, REG_CMD, CMD_START | CMD_ACC_CLEAR | CMD_RST_W_RD | CMD_RST_I_RD)

    # Ninguém lê por um tempo: a FIFO enche e a NPU precisa esperar, sem perder resultados
    await ClockCycles(dut.clk, 800)
    assert (await mmio_read(dut, REG_STATUS)) & STATUS_BUSY, "NPU deveria estar parada esperando a FIFO"

    expected = []
    for g in range(tiles):
        mat_A = [window(4*g + r) for r in range(4)]
        for row in compute_ref(mat_A, wgt, k_dim, bias, 3, 8, 0, True):
            expected += [v & 0xFF for v in row]

    got = [await mmio_read(dut, REG_READ_OUT) for _ in range(len(expected))]
    if got != expected:
        bad = next(i for i in range(len(got)) if got[i] != expected[i])
        log_error(f"Palavra {bad} (janela {bad // 4}, canal {bad % 4}): esperado {expected[bad]}, lido {got[bad]}")
        assert False
    while (await mmio_read(dut, REG_STATUS) & STATUS_DONE) == 0: await RisingEdge(dut.clk)
    assert (await mmio_read(dut, REG_STATUS)) & STATUS_OUT_VALID == 0, "Sobrou dado na FIFO"
    log_info(f"Conv: {tiles} tiles num único START, {len(got)} palavras na ordem certa")

    # ---------------------------------------------------------------- Sequência estilo densa
    await mmio_write(dut, REG_IM2COL_EN, 0)
    K, T = 6, 3
    acts = [[random.randint(-20, 20) for _ in range(K)] for _ in range(4)]
    wts  = [[[random.randint(-20, 20) for _ in range(4)] for _ in range(K)] for _ in range(T)]
    await npu_setup_config(dut, mult=1, shift=0, zero=0, bias=[0]*4)
    await mmio_write(dut, REG_CMD, CMD_RST_DMA_PTRS)
    for k in range(K): await mmio_write(dut, REG_WRITE_A, pack_int8([acts[r][k] for r in range(4)]))
    for t in range(T):
        for k in range(K): await mmio_write(dut, REG_WRITE_W, pack_int8(wts[t][k]))
    await mmio_write(dut, REG_CONFIG, K)
    await mmio_write(dut, REG_TILES, T | TILES_RW_I)
    await mmio_write(dut, REG_OUT_CFG, OUT_ORDER)
    await mmio_write(dut, REG_CMD, CMD_START | CMD_ACC_CLEAR | CMD_RST_W_RD | CMD_RST_I_RD)
    for t in range(T):
        exp = compute_ref(acts, wts[t], K, [0]*4, 1, 0, 0, False)
        got = [unpack_int8(await mmio_read(dut, REG_READ_OUT)) for _ in range(4)]
        assert got == exp, f"Tile {t}: esperado {exp}, lido {got}"
    while (await mmio_read(dut, REG_STATUS) & STATUS_DONE) == 0: await RisingEdge(dut.clk)
    log_info(f"Densa: {T} tiles reaproveitando as entradas, linhas na ordem natural")

    await mmio_write(dut, REG_TILES, 0)
    await mmio_write(dut, REG_OUT_CFG, 0)
    log_success("Sequenciador de tiles e formatador de saída corretos.")


async def run_gemv(dut, n_out, k_in, w_base, out_cfg, mult, shift, relu):
    """ Densa y = W x + b com lote 1 no modo GEMV, num único START (um tile por bloco de 4 neurônios). """
    tiles = (n_out + 3) // 4
    k_pad = (k_in + 3) // 4 * 4
    W = [[random.randint(-128, 127) for _ in range(k_in)] for _ in range(n_out)]
    x = [random.randint(-128, 127) for _ in range(k_in)]
    b = [random.randint(-20000, 20000) for _ in range(n_out)]

    await npu_setup_config(dut, mult=mult, shift=shift, zero=0, bias=[0]*4, en_relu=relu)
    for n in range(tiles * 4):
        await mmio_write(dut, REG_BIAS_BASE + 4*n, b[n] if n < n_out else 0)

    # Pesos no layout de sempre (palavra k do bloco j = neurônios 4j..4j+3 da feature k), a partir
    # de uma base alinhada; o que vem antes dela é lixo que não pode ser lido
    await mmio_write(dut, REG_W_BASE, 0)
    await mmio_write(dut, REG_CMD, CMD_RST_WR_W)
    for _ in range(w_base): await mmio_write(dut, REG_WRITE_W, random.randint(0, 0xFFFFFFFF))
    for j in range(tiles):
        for k in range(k_pad):
            vals = [W[4*j + c][k] if (4*j + c < n_out and k < k_in) else 0 for c in range(4)]
            await mmio_write(dut, REG_WRITE_W, pack_int8(vals))

    # Entradas: 4 features por palavra (byte r = feature 4t + r)
    xp = x + [0] * (k_pad - k_in)
    await mmio_write(dut, REG_CMD, CMD_RST_WR_I)
    for t in range(k_pad // 4): await mmio_write(dut, REG_WRITE_A, pack_int8(xp[4*t:4*t+4]))

    await mmio_write(dut, REG_W_BASE, w_base)
    await mmio_write(dut, REG_MODE, MODE_GEMV)
    await mmio_write(dut, REG_CONFIG, k_pad // 4)
    await mmio_write(dut, REG_TILES, tiles | TILES_RW_I | TILES_BIAS)
    await mmio_write(dut, REG_OUT_CFG, out_cfg)
    await mmio_write(dut, REG_CMD, CMD_START | CMD_ACC_CLEAR | CMD_RST_W_RD | CMD_RST_I_RD)

    y = [model_ppu(sum(W[n][k] * x[k] for k in range(k_in)), b[n], mult, shift, 0, relu) for n in range(n_out)]
    got = []
    words = tiles * (4 if out_cfg & OUT_UNPACK else 1)
    for _ in range(words):
        v = await mmio_read(dut, REG_READ_OUT)
        got += unpack_int8(v) if not (out_cfg & OUT_UNPACK) else [unpack_int8(v)[0]]
    while (await mmio_read(dut, REG_STATUS) & STATUS_DONE) == 0: await RisingEdge(dut.clk)
    if got[:n_out] != y:
        log_error(f"GEMV {n_out}x{k_in}: esperado {y}, lido {got[:n_out]}")
        assert False

    await mmio_write(dut, REG_MODE, 0)
    await mmio_write(dut, REG_TILES, 0)
    await mmio_write(dut, REG_OUT_CFG, 0)
    await mmio_write(dut, REG_W_BASE, 0)
    log_info(f"GEMV {n_out}x{k_in} (base {w_base}, OUT_CFG={out_cfg}): {tiles} tiles, {k_pad // 4} ciclos por tile")

@cocotb.test()
async def test_gemv_dense(dut):
    """
    Testa o modo GEMV (densa com lote 1 usando as 4 linhas do array):
    - Pesos em memória de 4 bancos, um peso por PE por ciclo; K/4 ciclos por bloco de 4 neurônios
    - Redução das 4 linhas antes da PPU e bias por tile (BIAS_PER_TILE)
    - Densa da CNN (676 -> 10), K não múltiplo de 4, saída empacotada e desempacotada
    - Modo normal volta a funcionar depois do GEMV
    """
    log_header("TESTE: CAMADA DENSA EM MODO GEMV")
    cocotb.start_soon(Clock(dut.clk, 10, unit="ns").start())
    await reset_dut(dut)

    await run_gemv(dut, n_out=10, k_in=676, w_base=12, out_cfg=0,          mult=1, shift=8,  relu=False)
    await run_gemv(dut, n_out=7,  k_in=37,  w_base=0,  out_cfg=OUT_UNPACK, mult=3, shift=10, relu=True)
    await run_gemv(dut, n_out=32, k_in=8,   w_base=4,  out_cfg=OUT_ORDER,  mult=1, shift=6,  relu=False)

    # Modo normal depois do GEMV
    K = 4
    mat_A = [[random.randint(-20, 20) for _ in range(K)] for _ in range(4)]
    mat_B = [[random.randint(-20, 20) for _ in range(4)] for _ in range(K)]
    await npu_setup_config(dut, mult=1, shift=0, zero=0, bias=[0]*4)
    await npu_load_data(dut, mat_A, mat_B, K)
    await mmio_write(dut, REG_CONFIG, K)
    await mmio_write(dut, REG_CMD, CMD_START | CMD_RST_W_RD | CMD_RST_I_RD | CMD_ACC_CLEAR)
    while (await mmio_read(dut, REG_STATUS) & STATUS_DONE) == 0: await RisingEdge(dut.clk)
    results = [unpack_int8(await mmio_read(dut, REG_READ_OUT)) for _ in range(4)]
    results.reverse()
    assert results == compute_ref(mat_A, mat_B, K, [0]*4, 1, 0, 0, False), "Modo normal falhou após o GEMV"

    log_success("Modo GEMV confere com a referência.")


async def slow_writes(dut, reg, words):
    """ Escreve as palavras com pausas aleatórias (simula um DMA lento chegando durante o cômputo). """
    for w in words:
        await mmio_write(dut, reg, w)
        if random.random() < 0.3:
            await ClockCycles(dut.clk, random.randint(1, 12))

def conv_case(in_w, in_h, stride, kw, kh):
    out_w = (in_w - kw) // stride + 1
    out_h = (in_h - kh) // stride + 1
    img  = [random.randint(-128, 127) for _ in range(in_w * in_h)]
    img += [0] * (-len(img) % 4)
    wgt  = [[random.randint(-128, 127) for _ in range(4)] for _ in range(kw * kh)]
    bias = [random.randint(-5000, 5000) for _ in range(4)]
    nwin = out_w * out_h
    def window(p):
        if p >= nwin: return [0] * (kw * kh)
        u, v = divmod(p, out_w)
        return [img[(u*stride + i) * in_w + v*stride + j] for i in range(kh) for j in range(kw)]
    return dict(in_w=in_w, out_w=out_w, stride=stride, kw=kw, kh=kh, img=img, wgt=wgt, bias=bias, nwin=nwin, window=window)

async def run_conv_seq(dut, c, mode, out_cfg, stream_img):
    """ Conv inteira num START (im2col + sequenciador), com a imagem escrita antes ou depois do START. """
    k_dim, tiles = c["kw"] * c["kh"], (c["nwin"] + 3) // 4
    await npu_setup_config(dut, mult=3, shift=8, zero=0, bias=c["bias"], en_relu=True)
    await mmio_write(dut, REG_W_BASE, 0)
    await mmio_write(dut, REG_I_BASE, 0)
    await mmio_write(dut, REG_CMD, CMD_RST_DMA_PTRS)
    for k in range(k_dim): await mmio_write(dut, REG_WRITE_W, pack_int8(c["wgt"][k]))
    img_words = [pack_int8(c["img"][4*w:4*w+4]) for w in range(len(c["img"]) // 4)]
    if not stream_img:
        for w in img_words: await mmio_write(dut, REG_WRITE_IMG, w)
    await mmio_write(dut, REG_IM2COL_GEO, (c["kw"] << 20) | (c["stride"] << 16) | (c["out_w"] << 8) | c["in_w"])
    await mmio_write(dut, REG_IM2COL_NW, c["nwin"])
    await mmio_write(dut, REG_IM2COL_EN, 1)
    await mmio_write(dut, REG_CONFIG, k_dim)
    await mmio_write(dut, REG_TILES, tiles | TILES_RW_W)
    await mmio_write(dut, REG_OUT_CFG, out_cfg)
    await mmio_write(dut, REG_MODE, mode)
    await mmio_write(dut, REG_CMD, CMD_START | CMD_ACC_CLEAR | CMD_RST_W_RD | CMD_RST_I_RD)
    if stream_img:
        await slow_writes(dut, REG_WRITE_IMG, img_words)
    expected = []
    for g in range(tiles):
        for row in compute_ref([c["window"](4*g + r) for r in range(4)], c["wgt"], k_dim, c["bias"], 3, 8, 0, True):
            expected.append(pack_int8(row))
    return expected

async def finish(dut):
    while (await mmio_read(dut, REG_STATUS) & STATUS_DONE) == 0: await RisingEdge(dut.clk)
    for reg in (REG_MODE, REG_TILES, REG_OUT_CFG, REG_IM2COL_EN, REG_W_BASE, REG_I_BASE):
        await mmio_write(dut, reg, 0)

@cocotb.test()
async def test_stream_overlap_fusion(dut):
    """
    Testa as otimizações de movimentação de dados:
    - Streaming (MODE.STREAM_I/W): entradas, imagem e pesos escritos DEPOIS do START, com pausas
    - Tiles encadeados (MODE.OVERLAP): acumuladores sombra, sem esvaziar o array entre tiles
    - Fusão de camadas (OUT_CFG.LOOP): a Conv grava a saída na RAM de Inputs e a densa (GEMV)
      lê dali, sem passar pela CPU
    """
    log_header("TESTE: STREAMING + TILES ENCADEADOS + FUSÃO DE CAMADAS")
    cocotb.start_soon(Clock(dut.clk, 10, unit="ns").start())
    await reset_dut(dut)

    # ------------------------------------------------ Conv: streaming e/ou encadeado
    for mode, stream in ((0, False), (MODE_STREAM_I, True), (MODE_OVERLAP, False), (MODE_OVERLAP | MODE_STREAM_I, True)):
        c = conv_case(28, 28, 2, 3, 3) if mode & MODE_OVERLAP else conv_case(11, 9, 1, 3, 2)
        expected = await run_conv_seq(dut, c, mode, OUT_ORDER, stream)
        got = [await mmio_read(dut, REG_READ_OUT) for _ in range(len(expected))]
        await finish(dut)
        if got != expected:
            bad = next(i for i in range(len(got)) if got[i] != expected[i])
            log_error(f"Conv MODE={mode:#x}: janela {bad}: esperado {expected[bad]:#010x}, lido {got[bad]:#010x}")
            assert False
        assert (await mmio_read(dut, REG_STATUS)) & STATUS_OUT_VALID == 0, "Sobrou dado na FIFO"
        log_info(f"Conv MODE={mode:#x} ({len(got)} palavras, imagem {'depois' if stream else 'antes'} do START) OK")

    # ------------------------------------------------ GEMV: streaming de entradas e pesos, encadeado
    for mode in (MODE_GEMV | MODE_STREAM_I, MODE_GEMV | MODE_OVERLAP | MODE_STREAM_I,
                 MODE_GEMV | MODE_OVERLAP | MODE_STREAM_I | MODE_STREAM_W):
        n_out, k_in, w_base = 10, 64, 8
        tiles = (n_out + 3) // 4
        W = [[random.randint(-128, 127) for _ in range(k_in)] for _ in range(n_out)]
        x = [random.randint(-128, 127) for _ in range(k_in)]
        b = [random.randint(-20000, 20000) for _ in range(n_out)]
        await npu_setup_config(dut, mult=1, shift=8, zero=0, bias=[0]*4)
        for n in range(tiles * 4): await mmio_write(dut, REG_BIAS_BASE + 4*n, b[n] if n < n_out else 0)
        w_words = [pack_int8([W[4*j + c][k] if 4*j + c < n_out else 0 for c in range(4)])
                   for j in range(tiles) for k in range(k_in)]
        await mmio_write(dut, REG_W_BASE, w_base)
        await mmio_write(dut, REG_CMD, CMD_RST_WR_W | CMD_RST_WR_I)
        if not mode & MODE_STREAM_W:
            for w in w_words: await mmio_write(dut, REG_WRITE_W, w)
        await mmio_write(dut, REG_MODE, mode)
        await mmio_write(dut, REG_CONFIG, k_in // 4)
        await mmio_write(dut, REG_TILES, tiles | TILES_RW_I | TILES_BIAS)
        await mmio_write(dut, REG_CMD, CMD_START | CMD_ACC_CLEAR | CMD_RST_W_RD | CMD_RST_I_RD)
        # Entradas (e pesos) chegam depois do START, intercalados
        x_words = [pack_int8(x[4*t:4*t+4]) for t in range(k_in // 4)]
        if mode & MODE_STREAM_W:
            await slow_writes(dut, REG_WRITE_W, w_words[:k_in])
        await slow_writes(dut, REG_WRITE_A, x_words)
        if mode & MODE_STREAM_W:
            await slow_writes(dut, REG_WRITE_W, w_words[k_in:])
        y = [model_ppu(sum(W[n][k] * x[k] for k in range(k_in)), b[n], 1, 8, 0, False) for n in range(n_out)]
        got = []
        for _ in range(tiles): got += unpack_int8(await mmio_read(dut, REG_READ_OUT))
        await finish(dut)
        assert got[:n_out] == y, f"GEMV MODE={mode:#x}: esperado {y}, lido {got[:n_out]}"
        log_info(f"GEMV MODE={mode:#x} (entradas{' e pesos' if mode & MODE_STREAM_W else ''} depois do START) OK")

    # ------------------------------------------------ Fusão: Conv -> RAM de Inputs -> GEMV
    c = conv_case(28, 28, 2, 3, 3)
    expected_conv = await run_conv_seq(dut, c, MODE_OVERLAP, OUT_ORDER | OUT_LOOP, False)
    await finish(dut)
    assert (await mmio_read(dut, REG_STATUS)) & STATUS_OUT_VALID == 0, "Fusão não deveria usar a FIFO"
    feats = []
    for wd in expected_conv[:c["nwin"]]: feats += unpack_int8(wd)          # features 4p..4p+3
    n_out, k_in = 10, len(feats)                                            # 676
    W = [[random.randint(-128, 127) for _ in range(k_in)] for _ in range(n_out)]
    b = [random.randint(-20000, 20000) for _ in range(n_out)]
    tiles, w_base = 3, 12
    await npu_setup_config(dut, mult=1, shift=8, zero=0, bias=[0]*4)
    for n in range(tiles * 4): await mmio_write(dut, REG_BIAS_BASE + 4*n, b[n] if n < n_out else 0)
    await mmio_write(dut, REG_W_BASE, w_base)
    await mmio_write(dut, REG_CMD, CMD_RST_WR_W)
    for j in range(tiles):
        for k in range(k_in):
            await mmio_write(dut, REG_WRITE_W, pack_int8([W[4*j + cc][k] if 4*j + cc < n_out else 0 for cc in range(4)]))
    await mmio_write(dut, REG_MODE, MODE_GEMV | MODE_OVERLAP)
    await mmio_write(dut, REG_CONFIG, k_in // 4)
    await mmio_write(dut, REG_TILES, tiles | TILES_RW_I | TILES_BIAS)
    await mmio_write(dut, REG_CMD, CMD_START | CMD_ACC_CLEAR | CMD_RST_W_RD | CMD_RST_I_RD)
    got = []
    for _ in range(tiles): got += unpack_int8(await mmio_read(dut, REG_READ_OUT))
    await finish(dut)
    y = [model_ppu(sum(W[n][k] * feats[k] for k in range(k_in)), b[n], 1, 8, 0, False) for n in range(n_out)]
    assert got[:n_out] == y, f"Fusão: esperado {y}, lido {got[:n_out]}"
    log_info("Fusão Conv -> RAM de Inputs -> GEMV (676 -> 10) OK, sem a CPU no meio")

    log_success("Streaming, tiles encadeados e fusão de camadas corretos.")


def d_write(reg, val): return [0x10000000 | reg, val & 0xFFFFFFFF]
D_WAIT, D_END = [0x20000000], [0x30000000]

@cocotb.test()
async def test_layer_descriptors(dut):
    """
    Testa os descritores de camada (porta DESC + processador de comandos) e os biases residentes:
    - Biases da Conv (banco 3) e da densa (bancos 0..2) gravados uma única vez
    - A CNN inteira (Conv com streaming/encadeamento/fusão + densa em GEMV) roda a partir de um
      programa; a imagem chega pela porta IMG enquanto o programa executa
    - Duas imagens seguidas: o epílogo do programa prepara a próxima execução
    """
    log_header("TESTE: DESCRITORES DE CAMADA + BIASES RESIDENTES")
    cocotb.start_soon(Clock(dut.clk, 10, unit="ns").start())
    await reset_dut(dut)
    assert (await mmio_read(dut, REG_STATUS)) & STATUS_PROG_END, "Processador deveria começar ocioso"

    in_w, stride, kw = 28, 2, 3
    out_w = (in_w - kw) // stride + 1
    nwin, k_c = out_w * out_w, kw * kw
    tiles_c = (nwin + 3) // 4
    n_out, k_d = 10, nwin * 4
    tiles_d, wd_base = 3, 12
    sh_c, sh_d = 8, 9

    wc = [[random.randint(-128, 127) for _ in range(4)] for _ in range(k_c)]
    bc = [random.randint(-5000, 5000) for _ in range(4)]
    Wd = [[random.randint(-128, 127) for _ in range(k_d)] for _ in range(n_out)]
    bd = [random.randint(-20000, 20000) for _ in range(n_out)]

    # ---------------------------------------------- Modelo (uma vez): pesos e biases residentes
    await mmio_write(dut, REG_W_BASE, 0)
    await mmio_write(dut, REG_CMD, CMD_RST_WR_W)
    for k in range(k_c): await mmio_write(dut, REG_WRITE_W, pack_int8(wc[k]))
    for _ in range(wd_base - k_c): await mmio_write(dut, REG_WRITE_W, 0)
    for j in range(tiles_d):
        for k in range(k_d):
            await mmio_write(dut, REG_WRITE_W, pack_int8([Wd[4*j + c][k] if 4*j + c < n_out else 0 for c in range(4)]))
    for c in range(4): await mmio_write(dut, REG_BIAS_BASE + 16*3 + 4*c, bc[c])                 # banco 3
    for n in range(tiles_d * 4): await mmio_write(dut, REG_BIAS_BASE + 4*n, bd[n] if n < n_out else 0)

    # ---------------------------------------------- Programa (uma vez)
    prog  = d_write(REG_QUANT_MULT, 1) + d_write(REG_QUANT_CFG, sh_c) + d_write(REG_FLAGS, 1)
    prog += d_write(REG_W_BASE, 0) + d_write(REG_I_BASE, 0)
    prog += d_write(REG_IM2COL_GEO, (kw << 20) | (stride << 16) | (out_w << 8) | in_w)
    prog += d_write(REG_IM2COL_NW, nwin) + d_write(REG_IM2COL_EN, 1) + d_write(REG_CONFIG, k_c)
    prog += d_write(REG_TILES, tiles_c | TILES_RW_W | (3 << 19))
    prog += d_write(REG_OUT_CFG, OUT_ORDER | OUT_LOOP) + d_write(REG_MODE, MODE_STREAM_I | MODE_OVERLAP)
    prog += d_write(REG_CMD, CMD_START | CMD_ACC_CLEAR | CMD_RST_W_RD | CMD_RST_I_RD) + D_WAIT
    prog += d_write(REG_QUANT_CFG, sh_d) + d_write(REG_FLAGS, 0) + d_write(REG_IM2COL_EN, 0)
    prog += d_write(REG_W_BASE, wd_base) + d_write(REG_OUT_CFG, 0) + d_write(REG_MODE, MODE_GEMV | MODE_OVERLAP)
    prog += d_write(REG_CONFIG, k_d // 4) + d_write(REG_TILES, tiles_d | TILES_RW_I | TILES_BIAS)
    prog += d_write(REG_CMD, CMD_START | CMD_ACC_CLEAR | CMD_RST_W_RD | CMD_RST_I_RD) + D_WAIT
    prog += d_write(REG_MODE, 0) + d_write(REG_TILES, 0) + d_write(REG_CMD, CMD_RST_WR_I) + D_END   # epílogo

    for img_n in range(2):
        img = [random.randint(-128, 127) for _ in range(in_w * in_w)]
        for w in prog: await mmio_write(dut, REG_DESC, w)
        await slow_writes(dut, REG_WRITE_IMG, [pack_int8(img[4*w:4*w+4]) for w in range(len(img) // 4)])
        got = []
        for _ in range(tiles_d): got += unpack_int8(await mmio_read(dut, REG_READ_OUT))
        while (await mmio_read(dut, REG_STATUS) & STATUS_PROG_END) == 0: await RisingEdge(dut.clk)

        # Referência: Conv (ReLU) -> features 4p + c -> densa
        feats = []
        for p in range(nwin):
            u, v = divmod(p, out_w)
            win = [img[(u*stride + i) * in_w + v*stride + j] for i in range(kw) for j in range(kw)]
            for c in range(4):
                feats.append(model_ppu(sum(win[k] * wc[k][c] for k in range(k_c)), bc[c], 1, sh_c, 0, True))
        y = [model_ppu(sum(Wd[n][k] * feats[k] for k in range(k_d)), bd[n], 1, sh_d, 0, False) for n in range(n_out)]
        assert got[:n_out] == y, f"Imagem {img_n}: esperado {y}, lido {got[:n_out]}"
        log_info(f"Imagem {img_n + 1}: CNN inteira a partir de {len(prog)} palavras de programa OK")

    # Programa maior que a fila (128 palavras): a porta DESC segura o barramento, nada se perde
    vals = [random.randint(0, 0xFFFFFFFF) for _ in range(100)]
    long_prog = []
    for i, v in enumerate(vals): long_prog += d_write(REG_BIAS_BASE + 4 * (i % 32), v)
    long_prog = D_WAIT + long_prog + D_END
    # Uma execução longa (K = 2000) prende o processador no WAIT enquanto a fila enche
    await mmio_write(dut, REG_CONFIG, 2000)
    await mmio_write(dut, REG_CMD, CMD_START | CMD_ACC_CLEAR | CMD_RST_W_RD | CMD_RST_I_RD)
    max_fill = 0
    for w in long_prog:
        await mmio_write(dut, REG_DESC, w)
        max_fill = max(max_fill, int(dut.u_cmd_proc.u_queue.count.value))
    assert max_fill == 128, f"A fila deveria ter enchido (máximo {max_fill})"
    await ClockCycles(dut.clk, 3000)
    while (await mmio_read(dut, REG_STATUS) & STATUS_PROG_END) == 0: await RisingEdge(dut.clk)
    last = {i % 32: v for i, v in enumerate(vals)}
    assert int(dut.u_reg_file.r_bias_vec.value) == sum(v << (32 * i) for i, v in last.items()), "Programa longo perdeu palavras"
    log_info(f"Programa de {len(long_prog)} palavras (> fila de 128) executado sem perdas")

    log_success("Descritores de camada e biases residentes corretos.")
