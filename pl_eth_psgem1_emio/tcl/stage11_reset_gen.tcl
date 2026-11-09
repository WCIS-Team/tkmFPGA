# 步骤③自检前置：把 BD 的输出产物复位后重新生成
# 起因：stage9b 的 generate_target 把 4 颗 axi_register_slice 写进了 ip/*_1/ 新目录，
#       而 ps_ai.bd 里注册的 xci_name 仍是不带后缀的 ps_ai_s00_regslice_0 等，
#       于是 stage10 综合报 Synth 8-439 module not found。
# 只做离线产物复位，不动位流、不上板、不保存工程。
set out "S:/work/WCIS/workenv/pl_eth"
open_project "S:/work/WCIS/workenv/pl_eth/proj_trial/fpai_demo_fpga/fpai_demo_vivado.xpr"

set bdf [get_files -quiet -filter {NAME =~ *sources_1/bd/ps_ai/ps_ai.bd}]
puts "BD_FILE = $bdf"
if {$bdf eq ""} { puts "NO_BD"; close_project; exit 1 }
puts "BEFORE synth_v:"
foreach f [glob -nocomplain "S:/work/WCIS/workenv/pl_eth/proj_trial/fpai_demo_fpga/fpai_demo_vivado.srcs/sources_1/bd/ps_ai/ip/*/synth/*.v"] {
    puts "  $f"
}

catch {reset_target all $bdf} e1
puts "RESET_MSG = [string trim $e1]"
catch {generate_target all $bdf} e2
puts "GEN_MSG = [string trim $e2]"

puts "AFTER ip dirs:"
foreach d [glob -type d -nocomplain "S:/work/WCIS/workenv/pl_eth/proj_trial/fpai_demo_fpga/fpai_demo_vivado.srcs/sources_1/bd/ps_ai/ip/*"] {
    set sv [glob -nocomplain "$d/synth/*.v"]
    puts "  [file tail $d]  synth_v=[llength $sv]"
}

puts "AFTER synth_v list:"
foreach f [glob -nocomplain "S:/work/WCIS/workenv/pl_eth/proj_trial/fpai_demo_fpga/fpai_demo_vivado.srcs/sources_1/bd/ps_ai/ip/*/synth/*.v"] {
    puts "  $f"
}

puts "wrapper:"
foreach f [glob -nocomplain "S:/work/WCIS/workenv/pl_eth/proj_trial/fpai_demo_fpga/fpai_demo_vivado.srcs/sources_1/bd/ps_ai/hdl/*.v"] {
    puts "  $f"
}
close_project
exit 0
