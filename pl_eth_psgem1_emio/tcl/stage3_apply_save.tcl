# 丙类 stage3：把改动真正落进副本并保存（PS7 + FCLK + GMII_to_RGMII + 连线 + validate）
set xpr "S:/work/WCIS/workenv/pl_eth/proj_trial/fpai_demo_fpga/fpai_demo_vivado.xpr"
open_project $xpr
open_bd_design [lindex [get_files -quiet *.bd] 0]
set ps [get_bd_cells processing_system7_0]

# 1) PS7：ENET1 + EMIO + MDIO EMIO + 两路 FCLK
set_property -dict [list \
    CONFIG.PCW_EN_ENET1                 {1} \
    CONFIG.PCW_ENET1_PERIPHERAL_ENABLE  {1} \
    CONFIG.PCW_ENET1_ENET1_IO           {EMIO} \
    CONFIG.PCW_EN_EMIO_ENET1            {1} \
    CONFIG.PCW_ENET1_GRP_MDIO_ENABLE    {1} \
    CONFIG.PCW_ENET1_GRP_MDIO_IO        {EMIO} \
    CONFIG.PCW_ENET1_PERIPHERAL_FREQMHZ {1000 Mbps} \
    CONFIG.PCW_FPGA1_PERIPHERAL_FREQMHZ {200} \
    CONFIG.PCW_FPGA2_PERIPHERAL_FREQMHZ {125} \
] $ps
puts "PS7 ok: ENET1=[get_property CONFIG.PCW_EN_ENET1 $ps] IO=[get_property CONFIG.PCW_ENET1_ENET1_IO $ps] FCLK1=[get_property CONFIG.PCW_FPGA1_PERIPHERAL_FREQMHZ $ps] FCLK2=[get_property CONFIG.PCW_FPGA2_PERIPHERAL_FREQMHZ $ps]"

# 2) GMII_to_RGMII：shared logic 放核内，PHY 加 2ns，PHY 地址 8
if {[llength [get_bd_cells -quiet gmii_to_rgmii_0]] == 0} {
    create_bd_cell -type ip -vlnv xilinx.com:ip:gmii_to_rgmii:4.0 gmii_to_rgmii_0
}
set gt [get_bd_cells gmii_to_rgmii_0]
set_property -dict [list \
    CONFIG.SupportLevel    {Include_Shared_Logic_in_Core} \
    CONFIG.RGMII_TXC_SKEW  {0} \
    CONFIG.C_PHYADDR       {8} \
] $gt
puts "IP ok: SupportLevel=[get_property CONFIG.SupportLevel $gt] skew=[get_property CONFIG.RGMII_TXC_SKEW $gt] phyaddr=[get_property CONFIG.C_PHYADDR $gt]"

# 3) 数据面/管理面
if {[catch {connect_bd_intf_net [get_bd_intf_pins $ps/GMII_ETHERNET_1] [get_bd_intf_pins $gt/GMII]} e1]} { puts "GMII_CONNECT_FAIL $e1" } else { puts "GMII connected" }
if {[catch {connect_bd_intf_net [get_bd_intf_pins $ps/MDIO_ETHERNET_1] [get_bd_intf_pins $gt/MDIO_GEM]} e2]} { puts "MDIO_CONNECT_FAIL $e2" } else { puts "MDIO connected" }

# 4) 时钟：ref_clk_in <- FCLK1(200M)，gmii_clk_125m_in <- FCLK2(125M)
if {[catch {connect_bd_net [get_bd_pins $ps/FCLK_CLK1] [get_bd_pins $gt/ref_clk_in]} e3]} { puts "REFCLK_FAIL $e3" } else { puts "ref_clk_in <- FCLK1(200M)" }
if {[catch {connect_bd_net [get_bd_pins $ps/FCLK_CLK2] [get_bd_pins $gt/gmii_clk_125m_in]} e4]} { puts "G125_FAIL $e4" } else { puts "gmii_clk_125m_in <- FCLK2(125M)" }

# 5) 复位：核的 tx_reset/rx_reset 是高有效，用反相器接 peripheral_aresetn
if {[catch {
    create_bd_cell -type ip -vlnv xilinx.com:ip:util_vector_logic:2.0 gmii_rst_inv
    set_property -dict [list CONFIG.C_OPERATION {not} CONFIG.C_SIZE {1}] [get_bd_cells gmii_rst_inv]
    connect_bd_net [get_bd_pins proc_sys_reset_0/peripheral_aresetn] [get_bd_pins gmii_rst_inv/Op1]
    connect_bd_net [get_bd_pins gmii_rst_inv/Res] [get_bd_pins $gt/tx_reset]
    connect_bd_net [get_bd_pins gmii_rst_inv/Res] [get_bd_pins $gt/rx_reset]
} e5]} { puts "RESET_FAIL $e5" } else { puts "resets wired (inverted peripheral_aresetn)" }

# 6) RGMII 引到顶层端口（引脚约束下一步再做）
if {[catch {make_bd_intf_pins_external [get_bd_intf_pins $gt/RGMII]} e6]} { puts "EXT_FAIL $e6" } else { puts "RGMII made external" }

# 7) 还剩哪些没连
puts "=== 未连的核输入脚 ==="
foreach pn [get_bd_pins -of_objects $gt] {
    set dir [get_property DIR $pn]
    set name [get_property NAME $pn]
    set net [get_bd_nets -quiet -of_objects $pn]
    if {$dir eq "I" && [llength $net] == 0} { puts "  UNCONNECTED_IN $name" }
}

puts "=== VALIDATE ==="
puts "validate rc=[catch {validate_bd_design} verr] err=$verr"

save_bd_design
puts "BD SAVED"
close_project
puts "PROJECT CLOSED"
