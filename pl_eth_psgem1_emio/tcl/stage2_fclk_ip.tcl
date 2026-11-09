# 丙类第 1-2 步：基线留档 -> 改 FCLK1/2 -> 加 GMII_to_RGMII -> 连线 -> 验证 -> 保存到副本
set xpr "S:/work/WCIS/workenv/pl_eth/proj_trial/fpai_demo_fpga/fpai_demo_vivado.xpr"
set outdir "S:/work/WCIS/workenv/pl_eth"

open_project $xpr
set bd [lindex [get_files -quiet *.bd] 0]
open_bd_design $bd
set ps [get_bd_cells processing_system7_0]
puts "PS = $ps"

# ---------- 基线留档 ----------
write_bd_tcl -force $outdir/ps_ai_baseline.tcl
puts "BASELINE_TCL written"
if {[catch {report_property -all $ps} rp]} { puts "REPORT_FAIL $rp" } else {
    set fh [open $outdir/ps7_baseline_params.txt w]
    puts $fh $rp
    close $fh
    puts "BASELINE_PARAMS written"
}

# ---------- ENET1 + EMIO（第十一节的结论，这次要保存） ----------
set rc [catch {
    set_property -dict [list \
        CONFIG.PCW_EN_ENET1                 {1} \
        CONFIG.PCW_ENET1_PERIPHERAL_ENABLE  {1} \
        CONFIG.PCW_ENET1_ENET1_IO           {EMIO} \
        CONFIG.PCW_EN_EMIO_ENET1            {1} \
        CONFIG.PCW_ENET1_GRP_MDIO_ENABLE    {1} \
        CONFIG.PCW_ENET1_GRP_MDIO_IO        {EMIO} \
        CONFIG.PCW_ENET1_PERIPHERAL_FREQMHZ {1000 Mbps} \
    ] $ps
} err]
puts "ENET1 set rc=$rc err=$err"

# ---------- FCLK1=200M（IDELAYCTRL 参考）, FCLK2=125M（GMII gtx_clk） ----------
set rc2 [catch {
    set_property -dict [list \
        CONFIG.PCW_FPGA1_PERIPHERAL_FREQMHZ {200} \
        CONFIG.PCW_FPGA2_PERIPHERAL_FREQMHZ {125} \
    ] $ps
} err2]
puts "FCLK set rc=$rc2 err=$err2"
foreach p {PCW_FPGA0_PERIPHERAL_FREQMHZ PCW_FPGA1_PERIPHERAL_FREQMHZ PCW_FPGA2_PERIPHERAL_FREQMHZ PCW_FPGA3_PERIPHERAL_FREQMHZ} {
    puts "$p = [get_property CONFIG.$p $ps]"
}

# ---------- 加 GMII_to_RGMII ----------
if {[catch {create_bd_cell -type ip -vlnv xilinx.com:ip:gmii_to_rgmii:4.0 gmii_to_rgmii_0} cerr]} {
    puts "CREATE_IP_FAIL $cerr"
} else {
    puts "CREATE_IP_OK"
    set gt [get_bd_cells gmii_to_rgmii_0]
    puts "=== gmii_to_rgmii properties (CONFIG.*) ==="
    foreach pr [list_property $gt] {
        if {[string match CONFIG.* $pr]} { puts "  $pr = [get_property $pr $gt]" }
    }
    puts "=== gmii_to_rgmii pins ==="
    foreach pn [get_bd_pins -of_objects $gt] { puts "  PIN [get_property NAME $pn]" }
    foreach ip [get_bd_intf_pins -of_objects $gt] { puts "  INTF [get_property NAME $ip]" }
}

puts "=== DONE ==="
puts "NOT_SAVED_YET"
