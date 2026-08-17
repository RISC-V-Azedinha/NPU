# fpga/build.tcl (Atualizado/Simplificado)

# Captura argumentos (Top Entity e Part)
if { $argc != 2 } {
    puts "Uso: vivado -mode batch -source build.tcl -tclargs <top_entity> <part>"
    exit 1
}
set topEntity [lindex $argv 0]
set targetPart [lindex $argv 1]

# Configura projeto em memória
create_project -in_memory -part $targetPart

# --- LENDO ARQUIVOS ---

# Package
read_vhdl "pkg/npu_pkg.vhd"

# Common & RTL
read_vhdl [glob rtl/common/*.vhd]
read_vhdl [glob rtl/core/*.vhd]
read_vhdl [glob rtl/ppu/*.vhd]
read_vhdl [glob rtl/*.vhd]

# FPGA Tester (HIL Wrapper)
read_vhdl [glob rtl/fpga_tester/*.vhd]

# Constraints
read_xdc "fpga/constraints/pins.xdc"

# --- FLUXO DE COMPILAÇÃO ---
# -retiming: permite ao Vivado mover registradores através de lógica combinacional
# durante a síntese para equilibrar caminhos críticos (sem alterar o comportamento).
synth_design -top $topEntity -part $targetPart -flatten_hierarchy rebuilt -retiming

# Timing summary pós-síntese (estimativa: ainda sem atrasos reais de roteamento)
report_timing_summary -delay_type max -max_paths 10 -file "build/${topEntity}_synth_timing_summary.rpt"

# Implementação com maior esforço de otimização de timing (o design está muito
# próximo do fechamento — poucas dezenas de ps — então vale gastar mais tempo
# de ferramenta em vez de mudar o RTL/pipeline).
opt_design -directive Explore
place_design -directive ExtraTimingOpt

# Otimização física pós-placement (retiming/replicação local orientada a timing)
phys_opt_design -directive AggressiveExplore

route_design -directive Explore

# Otimização física pós-rota (usa os atrasos reais de roteamento)
phys_opt_design -directive AggressiveExplore

# Timing summary pós-rota (definitivo: usado para avaliar timing closure real)
report_timing_summary -delay_type max -max_paths 10 -file "build/${topEntity}_route_timing_summary.rpt"

# Alerta explícito de fechamento de timing (WNS/WHS negativos = falha de closure)
set wns [get_property SLACK [get_timing_paths -delay_type max -max_paths 1]]
set whs [get_property SLACK [get_timing_paths -delay_type min -max_paths 1]]
puts ">>> TIMING: WNS (setup) = ${wns} ns | WHS (hold) = ${whs} ns"
if { $wns < 0 || $whs < 0 } {
    puts "!!! AVISO: Timing closure FALHOU (slack negativo). Veja build/${topEntity}_route_timing_summary.rpt"
}

# --- GERAR BITSTREAM ---
write_bitstream -force "build/${topEntity}.bit"

exit