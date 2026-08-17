# ==============================================================================
# File: test_npu_double_buffer.py
# ==============================================================================
#
# >>> Descrição: Valida a técnica de Double Buffering (Ping-Pong) adicionada ao
#       Datapath (generic DOUBLE_BUFFER).
#
#       `make cocotb TOP=npu_top TEST=test_npu_double_buffer` roda com o
#       generic default (DOUBLE_BUFFER=false): valida o modo legado e o
#       caminho de controle (CMD_DBUF_EN), mas SEM os bancos físicos extras.
#
#       Para elaborar de fato com DOUBLE_BUFFER=true, o `make cocotb` desta
#       versão do cocotb+GHDL não repassa generics corretamente (EXTRA_ARGS/
#       GHDL_RUN_ARGS não chegam ao passo de elaboração `-m`, e `-i` rejeita
#       `-g`). O caminho que funciona é chamar o GHDL diretamente, com `-g`
#       DEPOIS do nome da entidade no passo `-r` (sintaxe de override de
#       generic em tempo de execução do GHDL):
#
#         ghdl -r --std=93c --workdir=sim_build -Psim_build --work=work \
#              npu_top -gDOUBLE_BUFFER=true \
#              --vpi=$(python3 -m cocotb_tools.config --lib-name-path vpi ghdl)
#
#       (rodar `ghdl -i`/`ghdl -m` normalmente antes, com as fontes do
#       projeto, e exportar COCOTB_TEST_MODULES=test_npu_double_buffer,
#       COCOTB_TOPLEVEL=npu_top, TOPLEVEL_LANG=vhdl e PYTHONPATH=sim/...).
#       Ambos os testes abaixo foram confirmados passando dessa forma, com o
#       branch GEN_DOUBLE_BUF (dois bancos físicos) de fato instanciado.
#
#       Cenários cobertos:
#       1. Retrocompatibilidade em tempo de execução: mesmo em um build com
#          DOUBLE_BUFFER=true, se o host nunca liga o bit DBUF_EN do CMD, o
#          resultado deve ser idêntico ao fluxo legado de banco único.
#       2. Overlap real: o host carrega o Tile 2 (W_PORT/I_PORT) enquanto a
#          NPU ainda está BUSY computando o Tile 1 (DBUF_EN=1). O Tile 1 não
#          pode ser corrompido pela escrita concorrente, e o Tile 2 deve ler
#          exatamente os dados que foram escritos durante o BUSY.
#
# ==============================================================================

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge
from test_utils import log_info, log_success, log_error

# ==============================================================================
# CONSTANTES & MAPA DE REGISTRADORES
# ==============================================================================

REG_STATUS     = 0x00
REG_CMD        = 0x04
REG_CONFIG     = 0x08
REG_WRITE_W    = 0x10
REG_WRITE_A    = 0x14
REG_READ_OUT   = 0x18
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
CMD_DBUF_EN      = (1 << 8)   # Bit novo: Double Buffering (Ping-Pong) neste START

K_DIM = 4

# ==============================================================================
# DRIVERS MMIO (mesmo padrão de test_npu_top.py)
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
    for _ in range(10): await RisingEdge(dut.clk)
    dut.rst_n.value  = 1
    for _ in range(10): await RisingEdge(dut.clk)

def pack_int8(values):
    packed = 0
    for i, val in enumerate(values):
        packed |= (val & 0xFF) << (i * 8)
    return packed

def unpack_int8_lane0(packed):
    raw = packed & 0xFF
    return raw - 256 if raw & 0x80 else raw

async def npu_setup_config(dut):
    # Configuração neutra: sem quantização, sem bias, sem ReLU
    await mmio_write(dut, REG_QUANT_MULT, 1)
    await mmio_write(dut, REG_QUANT_CFG, 0)
    await mmio_write(dut, REG_FLAGS, 0)
    for i in range(4): await mmio_write(dut, REG_BIAS_BASE + (i*4), 0)

async def load_tile(dut, inp_val, wgt_val):
    """Escreve K_DIM linhas com Input=inp_val (todas as linhas) e Peso=wgt_val (todas as colunas)."""
    row_a = [inp_val] * 4
    row_w = [wgt_val] * 4
    for _ in range(K_DIM):
        await mmio_write(dut, REG_WRITE_A, pack_int8(row_a))
        await mmio_write(dut, REG_WRITE_W, pack_int8(row_w))

async def drain_first_lane(dut):
    """Espera DONE e drena os K_DIM x 4 resultados, devolvendo o primeiro valor lido (lane 0)."""
    while (await mmio_read(dut, REG_STATUS) & STATUS_DONE) == 0:
        await RisingEdge(dut.clk)

    first = None
    for _ in range(4):
        while (await mmio_read(dut, REG_STATUS) & STATUS_OUT_VALID) == 0:
            await RisingEdge(dut.clk)
        val = unpack_int8_lane0(await mmio_read(dut, REG_READ_OUT))
        if first is None:
            first = val
    return first

def expected_result(inp_val, wgt_val):
    return max(-128, min(127, inp_val * wgt_val * K_DIM))

# ==============================================================================
# TESTE 1: Retrocompatibilidade (DBUF_EN nunca setado, mesmo em build DOUBLE_BUFFER=true)
# ==============================================================================

@cocotb.test()
async def test_legacy_mode_unaffected(dut):
    cocotb.start_soon(Clock(dut.clk, 10, unit="ns").start())
    await reset_dut(dut)
    await npu_setup_config(dut)

    log_info("Modo legado: START sem DBUF_EN deve se comportar como banco único.")

    await mmio_write(dut, REG_CMD, CMD_RST_DMA_PTRS)
    await load_tile(dut, inp_val=5, wgt_val=2)

    await mmio_write(dut, REG_CONFIG, K_DIM)
    await mmio_write(dut, REG_CMD, CMD_START | CMD_RST_W_RD | CMD_RST_I_RD | CMD_ACC_CLEAR)

    result = await drain_first_lane(dut)
    expected = expected_result(5, 2)

    if result == expected:
        log_success(f"SUCESSO: Modo legado íntegro (esperado={expected}, obtido={result}).")
    else:
        log_error(f"FALHA: Modo legado divergiu. Esperado={expected}, Obtido={result}.")
        assert False

# ==============================================================================
# TESTE 2: Double Buffering real — overlap de escrita do Tile 2 durante BUSY do Tile 1
# ==============================================================================

@cocotb.test()
async def test_double_buffer_overlap(dut):
    cocotb.start_soon(Clock(dut.clk, 10, unit="ns").start())
    await reset_dut(dut)
    await npu_setup_config(dut)

    tile1 = dict(inp_val=5, wgt_val=2)   # banco A (wr_bank=0 no início)
    tile2 = dict(inp_val=7, wgt_val=3)   # deve cair no banco B, liberado no START do Tile 1

    log_info("Carregando Tile 1 no banco 0...")
    await mmio_write(dut, REG_CMD, CMD_RST_DMA_PTRS)
    await load_tile(dut, **tile1)

    await mmio_write(dut, REG_CONFIG, K_DIM)
    log_info("START Tile 1 com DBUF_EN=1 (troca de banco: leitura=0, escrita liberada=1)...")
    await mmio_write(dut, REG_CMD, CMD_START | CMD_RST_W_RD | CMD_RST_I_RD | CMD_ACC_CLEAR | CMD_DBUF_EN)

    busy = await mmio_read(dut, REG_STATUS) & STATUS_BUSY
    if not busy:
        log_error("FALHA: NPU não ficou BUSY após o START do Tile 1 (timing inesperado).")
        assert False

    log_info("NPU está BUSY com o Tile 1 — carregando Tile 2 concorrentemente (banco livre)...")
    await load_tile(dut, **tile2)

    result1 = await drain_first_lane(dut)
    expected1 = expected_result(**tile1)

    if result1 == expected1:
        log_success(f"SUCESSO: Tile 1 não foi corrompido pela escrita concorrente do Tile 2 "
                     f"(esperado={expected1}, obtido={result1}).")
    else:
        log_error(f"FALHA: Tile 1 corrompido. Esperado={expected1}, Obtido={result1}.")
        assert False

    log_info("START Tile 2 (lê o banco que acabou de ser preenchido durante o BUSY do Tile 1)...")
    # Sem RST_W_RD/RST_I_RD: os ponteiros de leitura continuam de onde o Tile 1 parou,
    # exatamente onde o Tile 2 foi escrito (ponteiros de escrita também não foram resetados).
    await mmio_write(dut, REG_CMD, CMD_START | CMD_ACC_CLEAR | CMD_DBUF_EN)

    result2 = await drain_first_lane(dut)
    expected2 = expected_result(**tile2)

    if result2 == expected2:
        log_success(f"SUCESSO: Tile 2 lido corretamente do banco ping-pong "
                     f"(esperado={expected2}, obtido={result2}).")
    else:
        log_error(f"FALHA: Tile 2 incorreto. Esperado={expected2}, Obtido={result2}.")
        assert False
