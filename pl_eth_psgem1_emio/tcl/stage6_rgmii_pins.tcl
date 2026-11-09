set xpr "S:/work/WCIS/workenv/pl_eth/proj_trial/fpai_demo_fpga/fpai_demo_vivado.xpr"
open_project $xpr

puts "=== 工程顶层 ==="
puts "top = [get_property top [current_fileset]]"
foreach f [get_files -quiet *.v] {
    if {[string match *ai7030* $f] || [string match *top* $f]} { puts "  VFILE $f" }
}

open_bd_design [lindex [get_files -quiet *.bd] 0]

puts "=== RGMII_0 接口内的引脚 ==="
set ifp [get_bd_intf_ports -quiet RGMII_0]
puts "ifport = $ifp"
if {$ifp ne ""} {
    foreach p [get_bd_intf_pins -quiet -of_objects $ifp] {
        puts "  [get_property NAME $p] dir=[get_property DIR $p] left=[get_property LEFT $p] right=[get_property RIGHT $p]"
    }
}

puts "=== 该接口 portMap（逻辑端口名） ==="
foreach lp [get_property -quiet PORTMAP_PORTS $ifp] { puts "  PORTMAP $lp" }

puts "=== 列出 RGMII_0 的全部属性名 ==="
foreach pp [list_property $ifp] { if {[string match *PORT* $pp] || [string match *NAME* $pp]} { puts "  $pp" } }

close_project
exit 0
