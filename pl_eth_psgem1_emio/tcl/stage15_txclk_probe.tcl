# 查 RGMII 发送时钟在网表里的真身：谁驱动顶层 RGMII_0_txc、它算不算时钟源、
# 转换核内部那个 rgmii_txc_out 在不在（vendor 生成文件用 -source 指它）。
# 只读 dcp，不改任何东西、不跑实现。
set dcp "S:/work/WCIS/workenv/pl_eth/proj_trial/fpai_demo_fpga/fpai_demo_vivado.runs/synth_1/ai7030_edif_top.dcp"
open_checkpoint $dcp

puts ""
puts "=== A) 端口属性（用 get_name，上一轮 prop 里 NAME 取空） ==="
foreach n {RGMII_0_txc RGMII_0_rxc MDIO_PHY_0_mdc MDIO_PHY_0_mdio_io phy_reset_n} {
    set p [get_ports -quiet $n]
    if {[llength $p] == 0} { puts "  MISS  $n"; continue }
    foreach o $p {
        puts [format "  %-18s NAME=%-20s DIR=%-7s/%-7s IS_CLOCK=%s" $n [get_property NAME $o] [get_property -quiet DIRECTION $o] \
            [get_property DIR $o] [get_property -quiet IS_CLOCK $o]]
    }
}
set iob [get_cells -quiet -hier -filter {REF_NAME == "IOBUF"}]
foreach c $iob { puts [format "  IOBUF NAME=%s REF=%s" [get_property NAME $c] [get_property REF_NAME $c]] }

puts ""
puts "=== B) 顶层 RGMII_0_txc 这条网的驱动是谁 ==="
set nt [get_nets -quiet -of_objects [get_ports -quiet RGMII_0_txc]]
puts [format "  NET=%s" [get_property NAME $nt]]
set drv [get_pins -quiet -of_objects $nt]
foreach d $drv {
    puts [format "  CONNECTED PIN=%s CELL=%s REF=%s PIN_DIR=%s" [get_property NAME $d] \
        [get_cells -quiet -of_objects $d] \
        [get_property -quiet REF_NAME [get_cells -quiet -of_objects $d]] \
        [get_property -quiet DIR $d]]
}

puts ""
puts "=== C) vendor 生成文件里那个 rgmii_txc_out 在不在本设计 ==="
set c1 [get_cells -quiet -hier -filter {name =~ *rgmii_txc_out*}]
puts [format "  cells 匹配 *rgmii_txc_out* = %d" [llength $c1]]
foreach c $c1 { puts [format "    %s REF=%s" [get_property NAME $c] [get_property REF_NAME $c]] }
set p1 [get_pins -quiet -hier -filter {name =~ *rgmii_txc_out*/*}]
puts [format "  pins 匹配 = %d" [llength $p1]]
foreach p [lrange $p1 0 9] { puts [format "    %s DIR=%s" [get_property NAME $p] [get_property DIR $p]] }

puts ""
puts "=== D) 核自己那套转换逻辑在网表里叫什么（找 gmii_to_rgmii 实例路径） ==="
set c2 [get_cells -quiet -hier -filter {name =~ *gmii_to_rgmii*}]
puts [format "  匹配 *gmii_to_rgmii* 的 cell = %d" [llength $c2]]
foreach c [lrange $c2 0 14] { puts [format "    %s REF=%s" [get_property NAME $c] [get_property REF_NAME $c]] }

puts ""
puts "=== E) ODDR/OBUFT 在 txc 通路上吗（发送时钟一般经 ODDR+IOBUFT 出脚） ==="
foreach r {ODDDR OBUFT IBUFODDR ODDR} {
    set k [get_cells -quiet -hier -filter "REF_NAME == $r"]
    puts [format "  REF_NAME=%-8s 实例数=%d" $r [llength $k]]
}
set txcnet [get_nets -quiet -of_objects [get_ports -quiet RGMII_0_txc]]
set lds [get_pins -quiet -of_objects $txcnet]
puts [format "  txc 这条网连着的引脚数 = %d" [llength $lds]]
foreach q [lrange $lds 0 14] { puts [format "    PIN=%s DIR=%s" [get_property NAME $q] [get_property -quiet DIR $q]] }

puts ""
puts "=== F) 顶层还挂着哪些 125 MHz 级别的网络名（找 master clock 的候选） ==="
set nn [get_nets -quiet -hier -filter {name =~ *125* || name =~ *gmii_clk*}]
puts [format "  候选网络数 = %d" [llength $nn]]
foreach x [lrange $nn 0 19] { puts [format "    %s" [get_property NAME $x]] }

close_design
exit 0
