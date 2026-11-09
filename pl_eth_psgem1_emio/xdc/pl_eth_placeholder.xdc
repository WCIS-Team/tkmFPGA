#!/usr/bin/env tclsh
# PL 网口引脚约束与 RGMII 时序约束
# 重要：文件内注释写明 VCCO 未知这一点

#============================================================
# 一、PL_PHY_RESET (AA13)，低有效
#============================================================
# 待确认：Bank12 的 VCCO 电平（1.8/2.5/3.3V）。先按 1.8V 占位。
set_property PACKAGE_PIN AA13 [get_ports pl_phy_reset]
set_property IOSTANDARD LVCMOS18 [get_ports pl_phy_reset]

#============================================================
# 二、RGMII 引脚（Bank13，全部 HR 银行）
#============================================================
# 待确认：Bank13 的 VCCO 电平。先按 1.8V 占位。
# 如果实际是 3.3V，1G 很难稳；改成 LVCMOS33 后要重新评估时序。

# 发送
set_property PACKAGE_PIN AD23 [get_ports RGMII_0_txc]
set_property IOSTANDARD LVCMOS18 [get_ports RGMII_0_txc]
set_property PACKAGE_PIN AD26 [get_ports RGMII_0_tx_ctl]
set_property IOSTANDARD LVCMOS18 [get_ports RGMII_0_tx_ctl]
set_property PACKAGE_PIN AF24 [get_ports {RGMII_0_td[0]}]
set_property IOSTANDARD LVCMOS18 [get_ports {RGMII_0_td[0]}]
set_property PACKAGE_PIN AF25 [get_ports {RGMII_0_td[1]}]
set_property IOSTANDARD LVCMOS18 [get_ports {RGMII_0_td[1]}]
set_property PACKAGE_PIN AA24 [get_ports {RGMII_0_td[2]}]
set_property IOSTANDARD LVCMOS18 [get_ports {RGMII_0_td[2]}]
set_property PACKAGE_PIN AB24 [get_ports {RGMII_0_td[3]}]
set_property IOSTANDARD LVCMOS18 [get_ports {RGMII_0_td[3]}]

# 接收
set_property PACKAGE_PIN AC23 [get_ports RGMII_0_rxc]
set_property IOSTANDARD LVCMOS18 [get_ports RGMII_0_rxc]
set_property PACKAGE_PIN AA25 [get_ports RGMII_0_rx_ctl]
set_property IOSTANDARD LVCMOS18 [get_ports RGMII_0_rx_ctl]
set_property PACKAGE_PIN AB26 [get_ports {RGMII_0_rd[0]}]
set_property IOSTANDARD LVCMOS18 [get_ports {RGMII_0_rd[0]}]
set_property PACKAGE_PIN AC26 [get_ports {RGMII_0_rd[1]}]
set_property IOSTANDARD LVCMOS18 [get_ports {RGMII_0_rd[1]}]
set_property PACKAGE_PIN AE25 [get_ports {RGMII_0_rd[2]}]
set_property IOSTANDARD LVCMOS18 [get_ports {RGMII_0_rd[2]}]
set_property PACKAGE_PIN AE26 [get_ports {RGMII_0_rd[3]}]
set_property IOSTANDARD LVCMOS18 [get_ports {RGMII_0_rd[3]}]

#============================================================
# 三、MDIO（Bank13）
#============================================================
# 注意：MDC/MDIO 由 BD 内的 MDIO_PHY 接口引出，若 wrapper 未把它引到顶层，
# 需要在 BD 里 make_bd_intf_pins_external，或在这里改成对应的端口名。
# 先按预留处理，等确认 wrapper 端口名后再启用下面两行。
# set_property PACKAGE_PIN AE22 [get_ports mdio_phy_mdc]
# set_property PACKAGE_PIN AF22 [get_ports mdio_phy_mdio]

#============================================================
# 四、RGMII 时序约束
#============================================================
# 注意：GMII_to_RGMII 核内部已包含 IDELAY/ODELAY 逻辑与 MMCM，
# 官方 example design 的约束文件里有完整的 set_input_delay/set_output_delay。
# 这里给出的是骨架，实际数值要按 PHY 的 RGMII 时序要求（Tskew 等）填。

# 接收时钟
create_clock -name rgmii_rxc -period 8.000 [get_ports RGMII_0_rxc]
set_false_path -from [get_ports RGMII_0_rxc]

# 发送时钟（由 FPGA 输出，源同步）
# 125MHz = 8ns
# 注意：txc 是输出，不应 create_clock，应该由核内部的时钟驱动
# 如果工具报 unconstruined，按 example design 的方式加 set_output_delay

# 占位：先不写具体 set_input_delay/set_output_delay，
# 等综合后看时序报告再决定。

puts "XDC loaded (placeholder IOSTANDARD=LVCMOS18, VCCO unverified)"
