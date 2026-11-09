# 步骤②离线探针 · 第一查：MDIO／复位在 BD 里到底是什么状态（只读，不改任何东西）
set xpr "S:/work/WCIS/workenv/pl_eth/proj_trial/fpai_demo_fpga/fpai_demo_vivado.xpr"
open_project $xpr
open_bd_design [lindex [get_files -quiet *.bd] 0]

set gt [get_bd_cells -quiet gmii_to_rgmii_0]
puts "GMII2RGMII cell = $gt"
puts "MODE  = [get_property -quiet MODE $gt]"
puts "VTNLV = [get_property -quiet VLNV $gt]"

puts ""
puts "=== gmii_to_rgmii_0 全部 intf pin 与连接状态 ==="
foreach ip [get_bd_intf_pins -of_objects $gt] {
    set n [get_property NAME $ip]
    set net [get_bd_intf_nets -quiet -of_objects $ip]
    puts "  IF $n  connected=$net"
}

puts ""
puts "=== gmii_to_rgmii_0 全部 pin（含时钟/复位）与连接状态 ==="
foreach p [get_bd_pins -of_objects $gt] {
    set n [get_property NAME $p]
    set net [get_bd_nets -quiet -of_objects $p]
    puts "  PIN $n  connected=$net"
}

puts ""
puts "=== BD 顶层已有 intf port / port ==="
foreach ip [get_bd_intf_ports] { puts "  IFPORT [get_property NAME $ip]" }
foreach p [get_bd_ports]      { puts "  PORT   [get_property NAME $p] dir=[get_property DIR $p] type=[get_property -quiet TYPE $p]" }

puts ""
puts "=== 未连接的 intf pin（整张 BD） ==="
foreach ip [get_bd_intf_pins -quiet -filter {LINK_STATUS != "CONNECTED" && MODE=="Slave"}] {
    puts "  UNBOUND_SLAVE [get_property NAME $ip]"
}
foreach ip [get_bd_intf_pins -quiet -filter {LINK_STATUS == "UNCONNECTED"}] {
    puts "  UNCONNECTED [get_property NAME $ip]"
}

puts ""
puts "=== xlconstant / util_vector_logic 现有实例 ==="
foreach c [get_bd_cells -quiet] {
    if {[string match *xlconstant* [get_property -quiet VLNV $c]] || [string match *util_vector_logic* [get_property -quiet VLNV $c]]} {
        puts "  CELL [get_property NAME $c] VLNV=[get_property VLNV $c] params=[get_property -quiet CONFIG.C_OPERATION $c]/[get_property -quiet CONFIG.C_CONST_VALUE $c]"
    }
}

close_project
exit 0
