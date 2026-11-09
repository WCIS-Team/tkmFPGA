set xpr "S:/work/WCIS/workenv/pl_eth/proj_trial/fpai_demo_fpga/fpai_demo_vivado.xpr"
open_project $xpr
open_bd_design [lindex [get_files -quiet *.bd] 0]
write_bd_tcl -force "S:/work/WCIS/workenv/pl_eth/bd_current.tcl"
puts "written"
close_project
exit 0
