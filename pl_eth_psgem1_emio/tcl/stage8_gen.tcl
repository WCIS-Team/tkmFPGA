set xpr "S:/work/WCIS/workenv/pl_eth/proj_trial/fpai_demo_fpga/fpai_demo_vivado.xpr"
open_project $xpr
set bd [lindex [get_files -quiet *.bd] 0]
puts "BD = $bd"
set rc [catch {generate_target all [get_files $bd]} err]
puts "generate_target rc=$rc err=$err"

open_bd_design $bd
puts "=== 重新生成的 RGMII_0 逻辑端口（portMap） ==="
set ifp [get_bd_intf_ports -quiet RGMII_0]
if {$ifp ne ""} {
    foreach pin [get_bd_intf_pins -quiet -of_objects [get_bd_intf_nets -quiet -of_objects $ifp]] {
        puts "  NETPIN [get_property NAME $pin]"
    }
}
close_bd_design
puts "=== wrapper 文件 ==="
set wf [get_files -quiet *ps_ai_wrapper.v]
puts "wrapper = $wf"
close_project
exit 0
