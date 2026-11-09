# 步骤③自检：整板综合（只在内存里跑，不落 run 目录、不出位流、不保存工程）
# 目的：证明三层透传在真综合里连得起来，顶层真的长出这 17 只脚，IOBUF 真被推出来。
set out "S:/work/WCIS/workenv/pl_eth"
open_project "S:/work/WCIS/workenv/pl_eth/proj_trial/fpai_demo_fpga/fpai_demo_vivado.xpr"
puts "PART = [get_property PART [current_project]]"
puts "TOP  = [get_property TOP [current_fileset]]"

if {[catch {synth_design -top ai7030_edif_top} err]} {
    puts "SYNTH_FAIL: $err"
    close_project
    exit 1
}
puts "SYNTH_OK"

puts ""
puts "=== 顶层新增端口（透传通没通，看这里） ==="
set p [get_ports -quiet -filter {(name =~ "RGMII_0*" || name =~ "MDIO_PHY_0*" || name =~ "phy_reset*")}]
puts "count = [llength $p]"
foreach x $p { puts "  PORT [get_property NAME $x] DIR=[get_property DIR $x]" }

puts ""
puts "=== IOBUF / OBUF 实例 ==="
foreach c [get_cells -quiet -hier -filter {REF_NAME == "IOBUF"}] { puts "  IOBUF [get_property NAME $c]" }

puts ""
puts "=== 转换核与 clk_wiz 是否进网表 ==="
foreach c [get_cells -quiet -hier -filter {(name =~ "*gmii_to_rgmii*" || name =~ "*clk_wiz_eth*") && (NAME =~ "*ps_ai_gmii_to_rgmii_0_0*" || NAME =~ "*ps_ai_clk_wiz_eth_0*")}] {
    puts "  CELL [get_property NAME $c] REF=[get_property -quiet REF_NAME $c]"
}
puts "  gmii_to_rgmii 相关实例总数 = [llength [get_cells -quiet -hier -filter {name =~ *gmii_to_rgmii*}]]"
set ic {}
foreach c [get_cells -quiet -hier -filter {REF_NAME == "IDELAYCTRL"}] { lappend ic [get_property NAME $c] }
puts "  IDELAYCTRL 实例 = $ic"

report_utilization -file "$out/a2_synth_util.rpt" -hierarchical
catch {write_checkpoint -force "$out/a2_synth_post.dcp"}
close_project
exit 0
