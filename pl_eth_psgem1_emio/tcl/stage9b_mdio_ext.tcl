# 步骤②离线探针 · 第二查：把 MDIO_PHY 引到 BD 外部 + 加复位输出，看重生成后的 wrapper 端口表长什么样
# 只在 workenv 的工程副本里做；不综合、不布线、不出位流、不碰板子。
set xpr "S:/work/WCIS/workenv/pl_eth/proj_trial/fpai_demo_fpga/fpai_demo_vivado.xpr"
open_project $xpr
open_bd_design [lindex [get_files -quiet *.bd] 0]

puts ""
puts "=== 0. 动作前：gmii_to_rgmii_0/MDIO_PHY 这条接口线里到底有哪些信号 ==="
set mp [get_bd_intf_pins -quiet gmii_to_rgmii_0/MDIO_PHY]
if {$mp eq ""} {
    puts "FATAL no MDIO_PHY intf pin"
    close_project
    exit 1
}
puts "MODE=[get_property -quiet MODE $mp] VLNV=[get_property -quiet VLNV $mp]"
foreach s [get_bd_intf_pin -quiet -of_objects $mp] { puts "  SIG [get_property NAME $s] DIR=[get_property -quiet DIR $s]" }
puts "  PORTS-PROP = [get_property -quiet PORTS $mp]"

puts ""
puts "=== 1. 把 MDIO_PHY 变成 BD 外部接口 ==="
make_bd_intf_pins_external $mp
set imp [get_bd_intf_ports -quiet MDIO_PHY_0]
if {$imp eq ""} {
    set names {}
    foreach p [get_bd_intf_ports] { lappend names [get_property NAME $p] }
    puts "created intf ports = $names"
    foreach p [get_bd_intf_ports] {
        if {[string match MDIO* [get_property NAME $p]]} { set imp $p; break }
    }
}
puts "IFPORT = [get_property NAME $imp] MODE=[get_property -quiet MODE $imp] VLNV=[get_property -quiet VLNV $imp]"
foreach s [get_bd_intf_ports -quiet -of_objects $imp] {
    puts "  SIG [get_property NAME $s] DIR=[get_property -quiet DIR $s]"
}
foreach pn [get_property -quiet PORTS $imp] {
    puts "  MEMBER $pn DIR=[get_property -quiet DIR [get_bd_ports $pn]]"
}

puts ""
puts "=== 2. PHY 复位（AA13）：探针档 = 输出一路恒 1（释放复位），可软件侧不改 ==="
set xr [create_bd_cell -type ip -vlnv xilinx.com:ip:xlconstant:1.1 phy_rst_const]
set_property -dict [list CONFIG.CONST_WIDTH {1} CONFIG.CONST_VAL {1}] $xr
set rp [create_bd_port -dir O -type rst phy_reset_n]
connect_bd_net [get_bd_pins phy_rst_const/dout] $rp
puts "const cell = [get_property NAME $xr] VAL=[get_property -quiet CONFIG.CONST_VAL $xr]"
puts "reset port = [get_property NAME $rp] DIR=[get_property DIR $rp]"

puts ""
puts "=== 3. validate ==="
set v [validate_bd_design]
puts "validate_bd_design output = <<$v>>"

puts ""
puts "=== 4. save + generate_target all ==="
save_bd_design
set bd [get_files -quiet *.bd]
puts "bd file = $bd"
generate_target all $bd
puts "generate_target rc done"

puts ""
puts "=== 5. BD 顶层端口全表（探针后） ==="
foreach p [get_bd_ports] {
    puts "  PORT [get_property NAME $p] DIR=[get_property DIR $p] type=[get_property -quiet TYPE $p]"
}
foreach p [get_bd_intf_ports] {
    puts "  IFPORT [get_property NAME $p] MODE=[get_property -quiet MODE $p]"
}

close_project
exit 0
