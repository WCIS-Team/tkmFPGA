# 步骤③后置校验：拿综合后的网表验 pl_eth_routeA.xdc 里每一个对象名解析不解析得动
# 只读 dcp、不跑实现、不出位流、不碰板子。
set dcp "S:/work/WCIS/workenv/pl_eth/proj_trial/fpai_demo_fpga/fpai_demo_vivado.runs/synth_1/ai7030_edif_top.dcp"
set xdc "S:/work/WCIS/workenv/pl_eth/pl_eth_routeA.xdc"
if {![file exists $dcp]} {
    set cand [glob -nocomplain "S:/work/WCIS/workenv/pl_eth/proj_trial/fpai_demo_fpga/fpai_demo_vivado.runs/synth_1/*.dcp"]
    if {$cand eq ""} { puts "NO_DCP"; exit 1 }
    set dcp [lindex $cand 0]
}
puts "DCP = $dcp"
open_checkpoint $dcp

proc prop {obj attr} {
    if {[catch {get_property $attr $obj} v]} { return "N/A" }
    if {$v eq ""} { return "<empty>" }
    return $v
}

puts ""
puts "=== 1) 15 只脚对应的 9 个端口名模式逐个解析 ==="
set names {RGMII_0_txc RGMII_0_tx_ctl {RGMII_0_td[3]} MDIO_PHY_0_mdc MDIO_PHY_0_mdio_io {phy_reset_n[0]} RGMII_0_rxc RGMII_0_rx_ctl {RGMII_0_rd[3]}}
foreach n $names {
    set obj [get_ports -quiet $n]
    if {[llength $obj] == 0} { puts "  MISS  $n" } else {
        foreach o $obj {
            puts [format "  HIT   %-18s DIR=%-7s IOSTD=%-9s LOC=%-6s ISCLK=%s" \
                [prop $o NAME] [prop $o DIR] [prop $o IOSTANDARD] [prop $o LOC] [prop $o IS_CLOCK]]
        }
    }
}
set all [get_ports -quiet -filter {(name =~ "RGMII_0*") || (name =~ "MDIO_PHY_0*") || (name =~ "phy_reset*")}]
puts [format "  顶层 RGMII/MDIO/复位端口对象总数 = %d（应为 15 只脚 + phy_reset_n[0] = 16，bus 展开计）" [llength $all]]
puts [format "  其中 inout = %d（应只有 mdio_io 一个）" [llength [get_ports -quiet -filter {DIR == "TRI"}]]]

puts ""
puts "=== 2) read_xdc 之前，txc/rxc/mdc 三只脚上工具自己传出来的时钟 ==="
foreach p {RGMII_0_txc RGMII_0_rxc MDIO_PHY_0_mdc} {
    set pt [get_ports -quiet $p]
    if {[llength $pt] == 0} { puts "  $p -> 端口不存在"; continue }
    if {[catch {get_clocks -quiet -of_objects $pt} cl]} { set cl "ERR" }
    puts [format "  %-16s 上游时钟 = %s" $p [prop $cl NAME]]
}
puts [format "  全设计含 rgmii 的时钟 = %s" [prop [get_clocks -quiet -filter {name =~ *rgmii*}] NAME]]
puts [format "  全设计含 mdio/mdc 的时钟 = %s" [prop [get_clocks -quiet -filter {(name =~ *mdio*) || (name =~ *mdc*)}] NAME]]

puts ""
puts "=== 3) IOBUF 在网表里的样子 ==="
set iob [get_cells -quiet -hier -filter {REF_NAME == "IOBUF"}]
puts [format "  IOBUF 实例数 = %d" [llength $iob]]
foreach c $iob {
    puts [format "  %s  LOC=%s  REF=%s" [prop $c FULL_NAME] [prop $c LOC] [prop $c REF_NAME]]
}

puts ""
puts "=== 4) 正式 read_xdc -unmanaged ==="
if {[catch {read_xdc -unmanaged $xdc} err]} {
    puts "READ_XDC_FAIL: [string trim $err]"
} else {
    puts "READ_XDC_OK"
    puts [format "  时钟总数 = %d" [llength [get_clocks -quiet]]]
    foreach cn {rgmii_rxc mdio_mdc} {
        set c [get_clocks -quiet $cn]
        puts [format "  CLK %-10s PERIOD=%s" $cn [prop $c PERIOD]]
    }
    set tx [get_clocks -quiet -of_objects [get_ports -quiet RGMII_0_txc]]
    puts [format "  tx_clk 对象数 = %d" [llength $tx]]
    puts [format "  txc 上的时钟（XDC 里 set tx_clk 引它）= %s" [prop tx NAME]]
    foreach p [get_ports -quiet -filter {(name =~ "RGMII_0*") || (name =~ "MDIO_PHY_0*") || (name =~ "phy_reset*")}] {
        puts [format "  PIN %-18s IOSTD=%-9s PACKAGE_PIN=%-6s" [prop $p NAME] [prop $p IOSTANDARD] [prop $p PACKAGE_PIN]]
    }
    if {[catch {report_clocks} rc]} { puts "  report_clocks 不可用" } else {
        puts [format "  report_clocks 行数 = %d" [llength [split [string trim $rc] \n]]]
    }
}
close_design
exit 0
