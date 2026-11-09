# 查 BD 顶层引出的端口名（RGMII 与 MDIO PHY 侧）
set xpr "S:/work/WCIS/workenv/pl_eth/proj_trial/fpai_demo_fpga/fpai_demo_vivado.xpr"
open_project $xpr
open_bd_design [lindex [get_files -quiet *.bd] 0]
set gt [get_bd_cells gmii_to_rgmii_0]

puts "=== gmii_to_rgmii_0 的 interface pins ==="
foreach ip [get_bd_intf_pins -of_objects $gt] {
    set n [get_property NAME $ip]
    set mode [get_property MODE $ip]
    set net [get_bd_intf_nets -quiet -of_objects $ip]
    puts "  INTF $n mode=$mode net=$net"
}

puts ""
puts "=== RGMII / MDIO_PHY 接口内部的引脚 ==="
foreach ipn {RGMII MDIO_PHY} {
    set ip [get_bd_intf_pins -quiet $gt/$ipn]
    if {$ip ne ""} {
        puts "--- $ipn ---"
        foreach p [get_bd_intf_pins -of_objects [get_bd_intf_nets -quiet -of_objects $ip]] {
            puts "    [get_property NAME $p] dir=[get_property DIR $p]"
        }
    }
}

puts ""
puts "=== BD 顶层端口（external ports） ==="
foreach p [get_bd_ports] {
    set n [get_property NAME $p]
    set dir [get_property DIR $p]
    set l [get_property LEFT $p]
    set r [get_property RIGHT $p]
    puts "  PORT $n dir=$dir \[$l:$r\]"
}

puts ""
puts "=== BD 顶层所有 interface ports ==="
foreach ip [get_bd_intf_ports] {
    puts "  IFPORT [get_property NAME $ip]"
}

close_project
exit 0
