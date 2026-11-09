# 趟 2 的收口：把约束反写出来，逐行数清发送侧 4 条 output delay 到底有没有落上。
# write_xdc 在 2018.3 没有 -unmerged（stage16 里那条失败就是它），这里用默认形式。
set dcp "S:/work/WCIS/workenv/pl_eth/proj_trial/fpai_demo_fpga/fpai_demo_vivado.runs/synth_1/ai7030_edif_top.dcp"
set xdc "S:/work/WCIS/workenv/pl_eth/pl_eth_routeA.xdc"
set out "S:/work/WCIS/workenv/pl_eth/a2_xdc_rt_pass2.xdc"

open_checkpoint $dcp
create_clock -name standin_tx_clk -period 8.000 [get_ports RGMII_0_txc]
if {[catch {read_xdc -unmanaged $xdc} err]} { puts "THROW: [string trim $err]" } else { puts "READ_XDC_RETURNED" }
write_xdc $out
close_design

set f [open $out r]; set txt [read $f]; close $f
proc cnt {txt pat} { set n 0; foreach l [split $txt \n] { if {[string match "*$pat*" $l]} { incr n } }; return $n }
puts "=== 反写文件 $out 的行计数 ==="
foreach {lbl pat} {
    PACKAGE_PIN PACKAGE_PIN
    IOSTANDARD IOSTANDARD
    create_clock {create_clock }
    create_generated_clock {create_generated_clock}
    set_input_delay_总 set_input_delay
    set_output_delay_总 set_output_delay
    set_false_path set_false_path
    set_multicycle_path set_multicycle_path
} {
    puts [format "  %-26s = %d 行" $lbl [cnt $txt $pat]]
}
set a 0; set b 0; set c 0
foreach l [split $txt \n] {
    if {[string match "*set_output_delay*" $l] && [string match "*RGMII_0_td*" $l]} { incr a }
    if {[string match "*set_input_delay*" $l] && ([string match "*RGMII_0_rd*" $l] || [string match "*RGMII_0_rx_ctl*" $l])} { incr b }
    if {[string match "*MDIO_PHY_0_mdio_io*" $l] && ([string match "*set_input_delay*" $l] || [string match "*set_output_delay*" $l])} { incr c }
}
puts [format "  引用 RGMII_0_td/tx_ctl 的 set_output_delay = %d 行（期望 4）" $a]
puts [format "  引用 RGMII_0_rd/rx_ctl 的 set_input_delay  = %d 行（期望 4）" $b]
puts [format "  引用 MDIO_PHY_0_mdio_io 的 in/out delay     = %d 行（期望 4）" $c]
exit 0
