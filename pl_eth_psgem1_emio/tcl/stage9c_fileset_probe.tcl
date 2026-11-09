# 步骤②离线探针 · 第三查：综合文件集里到底是哪一份 ps_ai_wrapper（只读）
set xpr "S:/work/WCIS/workenv/pl_eth/proj_trial/fpai_demo_fpga/fpai_demo_vivado.xpr"
open_project $xpr
set fs [get_filesets sources_1]
puts "=== sources_1 里所有名字含 wrapper 的文件 ==="
foreach f [get_files -quiet -of_objects $fs *wrapper*] {
    puts "  FILE $f"
    puts "     FILEGROUP=[get_property -quiet FILEGROUP $f] AUTO=[get_property -quiet AUTO_GENERATED $f] TYPE=[get_property -quiet TYPE $f]"
}
puts ""
puts "=== BD 文件与它的生成产物登记 ==="
foreach f [get_files -quiet -of_objects $fs *.bd] {
    puts "  BD $f USED_IN=[get_property -quiet USED_IN $f]"
}
puts ""
puts "=== synth_1 这个 run 实际会读的文件集（READonly 查询） ==="
set rs [get_filesets -quiet synth_1]
puts "  synth_1 fileset = $rs"
puts ""
puts "=== sources_1 顶层与 BD 的关系：BD 是否被标为 DesignMode 源 ==="
puts "  DESIGN_MODE  = [get_property -quiet DESIGN_MODE $fs]"
puts "  TOP          = [get_property -quiet TOP $fs]"
puts "  TOP_AUTO     = [get_property -quiet TOP_AUTO $fs]"
puts ""
puts "=== 手操 wrapper 那份的端口里有没有 RGMII/MDIO/phy_reset（直接读文件属性没用，看行数） ==="
set wf [get_files -quiet -of_objects $fs rtl/ps_ai_wrapper.sv]
puts "  flat wrapper file = $wf"
close_project
exit 0
