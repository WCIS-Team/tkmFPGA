# 在厂商工程的副本上试开 GEM1 + EMIO：只读试验，不保存
set xpr "S:/work/WCIS/workenv/pl_eth/proj_trial/fpai_demo_fpga/fpai_demo_vivado.xpr"
puts "=== open_project ==="
open_project $xpr

puts "=== bd files ==="
set bds [get_files -quiet *.bd]
puts "BD: $bds"
if {[llength $bds] == 0} { puts "NO_BD"; exit 2 }
open_bd_design [lindex $bds 0]
set bd [current_bd_design]
puts "current_bd_design = $bd"

set ps [get_bd_cells -quiet ps_ai_processing_system7_0_0]
if {$ps eq ""} {
    puts "PS7_CELL_NOT_FOUND"
    foreach c [get_bd_cells] { if {[string match *processing_system7* $c]} { puts "candidate: $c" ; set ps $c } }
}
puts "PS7 cell = $ps"

set plist {PCW_EN_ENET1 PCW_ENET1_PERIPHERAL_ENABLE PCW_ENET1_ENET1_IO PCW_EN_EMIO_ENET1 PCW_ENET1_GRP_MDIO_ENABLE PCW_ENET1_GRP_MDIO_IO PCW_ENET1_PERIPHERAL_FREQMHZ PCW_ENET1_RESET_ENABLE PCW_FPGA0_PERIPHERAL_FREQMHZ PCW_FPGA1_PERIPHERAL_FREQMHZ PCW_FPGA2_PERIPHERAL_FREQMHZ}

puts "=== BEFORE ==="
foreach p $plist {
    if {[catch {get_property CONFIG.$p $ps} v]} { puts "$p = <ERR>" } else { puts "$p = $v" }
}

puts "=== APPLY ==="
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
puts "set_property rc=$rc"
puts "set_property err=$err"

puts "=== AFTER ==="
foreach p $plist {
    if {[catch {get_property CONFIG.$p $ps} v]} { puts "$p = <ERR>" } else { puts "$p = $v" }
}

puts "=== PS7 interface pins (after) ==="
foreach ip [get_bd_intf_pins -quiet -of_objects $ps] { puts "  [get_property NAME $ip]" }

puts "=== ENABLEMENT ==="
foreach n {GMII_ETHERNET_1 MDIO_ETHERNET_1} {
    set ip [get_bd_intf_pins -quiet $ps/$n]
    if {$ip eq ""} { puts "$n : ABSENT" } else { puts "$n : PRESENT" }
}

puts "=== VALIDATE ==="
set vrc [catch {validate_bd_design} verr]
puts "validate rc=$vrc err=$verr"

puts "=== DONE, closing without save ==="
close_bd_design -quiet $bd
close_project -quiet
exit 0
