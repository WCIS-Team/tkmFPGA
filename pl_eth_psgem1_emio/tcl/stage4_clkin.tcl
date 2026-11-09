# 丙类 stage4：补 clkin（200MHz）-> validate -> save
set xpr "S:/work/WCIS/workenv/pl_eth/proj_trial/fpai_demo_fpga/fpai_demo_vivado.xpr"
open_project $xpr
open_bd_design [lindex [get_files -quiet *.bd] 0]
set ps [get_bd_cells processing_system7_0]
set gt [get_bd_cells gmii_to_rgmii_0]

puts "=== PS7 里所有 FCLK 相关 pin ==="
foreach pn [get_bd_pins -of_objects $ps] {
    set n [get_property NAME $pn]
    if {[string match *FCLK* $n] || [string match *CLK* $n]} { puts "  $n dir=[get_property DIR $pn]" }
}
puts "=== 核的 clkin 现状 ==="
set clk [get_bd_pins -quiet $gt/clkin]
puts "clkin = $clk net=[get_bd_nets -quiet -of_objects $clk]"

# 用 FCLK0(50M) 经 clk_wiz 出 200M 给 clkin
if {[llength [get_bd_cells -quiet clk_wiz_eth]] == 0} {
    create_bd_cell -type ip -vlnv xilinx.com:ip:clk_wiz:6.0 clk_wiz_eth
}
set cw [get_bd_cells clk_wiz_eth]
set_property -dict [list \
    CONFIG.PRIM_IN_FREQ {50.000} \
    CONFIG.CLKOUT1_REQUESTED_OUT_FREQ {200.000} \
    CONFIG.USE_LOCKED {false} \
    CONFIG.USE_RESET {false} \
] $cw

if {[catch {connect_bd_net [get_bd_pins $ps/FCLK_CLK0] [get_bd_pins $cw/clk_in1]} e1]} { puts "CLKIN_FAIL $e1" } else { puts "clk_wiz in <- FCLK0(50M)" }
if {[catch {connect_bd_net [get_bd_pins $cw/clk_out1] [get_bd_pins $gt/clkin]} e2]} { puts "CLKOUT_FAIL $e2" } else { puts "clkin <- clk_wiz 200M" }

puts "=== VALIDATE ==="
puts "validate rc=[catch {validate_bd_design} verr] err=$verr"

save_bd_design
puts "BD SAVED"
close_project
puts "PROJECT CLOSED"
