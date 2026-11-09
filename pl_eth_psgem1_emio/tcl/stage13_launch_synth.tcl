# 步骤③自检（正规路）：托管综合，先补齐缺失的 OOC IP 产物，再跑顶层 synth_1
# 只在副本里跑：不出位流、不做 implementation、不碰板子、不保存任何工程级改动。
set proj "S:/work/WCIS/workenv/pl_eth/proj_trial/fpai_demo_fpga/fpai_demo_vivado.xpr"
set out  "S:/work/WCIS/workenv/pl_eth"
open_project $proj
puts "PART = [get_property PART [current_project]]"
puts "TOP  = [get_property TOP [current_fileset]]"

puts "=== OOC run 清单（综合前） ==="
foreach r [get_runs -quiet -filter {TYPE =~ synth*}] {
    puts "  RUN [get_property NAME $r] DIR=[get_property DIRECTORY $r]"
}

if {[catch {reset_run synth_1} e]} { puts "RESET_RUN_MSG = [string trim $e]" }
if {[catch {launch_runs synth_1 -jobs 8} e]} {
    puts "LAUNCH_FAIL: [string trim $e]"
    close_project
    exit 1
}
wait_on_run synth_1
set st [get_property STATUS [get_runs synth_1]]
puts "SYNTH1_STATUS = $st"
puts "SYNTH1_PROGRESS = [get_property PROGRESS [get_runs synth_1]]"

if {![string match "*synth_design Complete*" $st]} {
    puts "SYNTH_NOT_COMPLETE"
    close_project
    exit 2
}

open_run synth_1 -name top_synth
puts ""
puts "=== 顶层新增端口（透传通没通，看这里） ==="
set p [get_ports -quiet -filter {(name =~ "RGMII_0*" || name =~ "MDIO_PHY_0*" || name =~ "phy_reset*")}]
puts "  count = [llength $p]"
foreach x $p { puts "  PORT [get_property NAME $x] DIR=[get_property DIR $x]" }

puts ""
puts "=== IOBUF 实例 ==="
set i [get_cells -quiet -hier -filter {REF_NAME == "IOBUF"}]
puts "  count = [llength $i]"
foreach c $i { puts "  IOBUF [get_property NAME $c]" }

puts ""
puts "=== 转换核 / 时钟 / 常量 ==="
foreach c [get_cells -quiet -hier -filter {name =~ "*gmii_to_rgmii*" || name =~ "*clk_wiz_eth*" || name =~ "*phy_rst_const*"}] {
    puts "  CELL [get_property FULL_NAME $c] REF=[get_property -quiet REF_NAME $c]"
}
puts "  上述实例总数 = [llength [get_cells -quiet -hier -filter {name =~ \"*gmii_to_rgmii*\" || name =~ \"*clk_wiz_eth*\" || name =~ \"*phy_rst_const*\"}]]"
puts ""
puts "=== IDELAYCTRL / ODDR 数量（RGMII 核内部应当有） ==="
puts "  IDELAYCTRL = [llength [get_cells -quiet -hier -filter {REF_NAME == "IDELAYCTRL"}]]"
puts "  ODDR       = [llength [get_cells -quiet -hier -filter {REF_NAME == "ODDR"}]]"
puts "  IDDR       = [llength [get_cells -quiet -hier -filter {REF_NAME == "IDDR"}]]"

catch {report_utilization -file "$out/a2_synth_util.rpt" -hierarchical} ru
puts "UTIL_RPT_MSG = [string trim $ru]"
catch {report_timing_summary -file "$out/a2_synth_timing_placeholder.rpt" -max_paths 1} rt
puts "TIMING_RPT_MSG = [string trim $rt]"
close_project
exit 0
