# 只验一件事：能不能把 BD 生成源以 add_files 的形式喂进 fileset（不保存工程）
open_project "S:/work/WCIS/workenv/pl_eth/proj_trial/fpai_demo_fpga/fpai_demo_vivado.xpr"
set fs [get_filesets sources_1]
set base "S:/work/WCIS/workenv/pl_eth/proj_trial/fpai_demo_fpga/fpai_demo_vivado.srcs/sources_1/bd/ps_ai/ip"
foreach f [list "$base/ps_ai_s00_regslice_0_1/synth/ps_ai_s00_regslice_0.v" \
                "$base/ps_ai_s00_regslice_1_1/synth/ps_ai_s00_regslice_1.v" \
                "$base/ps_ai_s01_regslice_0_1/synth/ps_ai_s01_regslice_0.v" \
                "$base/ps_ai_m00_regslice_0_1/synth/ps_ai_m00_regslice_0.v"] {
    if {[catch {add_files -norecurse -fileset $fs $f} err]} {
        puts "ADD_FAIL [file tail $f] :: [string trim $err]"
    } else {
        puts "ADD_OK   [file tail $f]"
    }
}
puts "SCOPED_AFTER = [llength [get_files -quiet -of $fs]]"
close_project
exit 0
