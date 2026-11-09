#!/usr/bin/env tclsh
#============================================================
# 路线 A（PS GEM1 走 EMIO + GMII_to_RGMII v4.0）顶层约束
# 正本位置：S:\work\WCIS\workenv\pl_eth\pl_eth_routeA.xdc
# 替代 pl_eth_placeholder.xdc 里的名字占位；端口名＝2026-11-06 在
# workenv/pl_eth/proj_trial 副本里实测得到的（见 wiki/PL/FPGA/PL网口bring-up与GEM1EMIO.md §12.1②）。
#
# 【本文件从未在本项目任何一次实现里跑过】下面逐条标了数值出处与置信级：
#   A＝工具自己生成的文件里直读；B＝标准/手册数值，本机没找到原文；C＝工程占位，无来源。
#============================================================

#============================================================
# 一、引脚（15 只 RGMII/MDIO + 1 只复位）
#============================================================
# Bank13（RGMII/MDIO）与 Bank12（复位）的 VCCO 本机无一手依据 ⇒ C 级，全按 LVCMOS18 占位。
# 若实际是 2.5/3.3 V，改 IOSTANDARD 后整套时序要重跑。

# --- 发送（FPGA → PHY）---
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

# --- 接收（PHY → FPGA）---
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

# --- 管理（MDC/MDIO）---
# BD 里这两只脚不是 PS 直出：PS7 的 MDIO_ETHERNET_1 先接进转换核的 MDIO_GEM，
# 再由核的 MDIO_PHY 接口引到顶层（interface_nets 两条都在 ps_ai.bd 里直读到，A 级）。
# 所以顶层看到的时钟域是"PS 产生的 MDC 穿过 PL"，MDC 周期由驱动配的 GEM MDIO 分频决定。
set_property PACKAGE_PIN AE22 [get_ports MDIO_PHY_0_mdc]
set_property IOSTANDARD LVCMOS18 [get_ports MDIO_PHY_0_mdc]
set_property PACKAGE_PIN AF22 [get_ports MDIO_PHY_0_mdio_io]
set_property IOSTANDARD LVCMOS18 [get_ports MDIO_PHY_0_mdio_io]

# --- 复位 ---
# 现在这一位由 BD 里的 xlconstant 恒 1（= 不复位）。谁该驱动它还没定，
# 见 pl_eth_psgem1_emio.md §八 待裁第 6 条；本行只是把脚位与名字固定下来。
set_property PACKAGE_PIN AA13 [get_ports {phy_reset_n[0]}]
set_property IOSTANDARD LVCMOS18 [get_ports {phy_reset_n[0]}]

#============================================================
# 二、RGMII 接收侧时序
#============================================================
# 结构与数值整体照抄工具为 BD 里那颗转换核生成的
# fpai_demo_vivado.srcs/sources_1/bd/ps_ai/ip/ps_ai_gmii_to_rgmii_0_0/synth/
# ps_ai_gmii_to_rgmii_0_0_clocks.xdc 第 5/7/13/14/15/16/18/19/20/21/22/23 行（A 级＝文件直读），
# 只把端口名换成本设计顶层的 RGMII_0_*、时钟名换成不带 IP 前缀的名字。
#
# 关键点：那份文件用的是"虚拟时钟 + 假路径 + 零周期"这套，-1.5 / -2.8 这两个负数是
# 相对虚拟时钟沿量的，不是相对 rxc 焊盘沿量的 ⇒ 顶层不能只把 delay 挂到 rxc 时钟上，
# 那会把 PHY 内部约 2 ns 的移位算两遍。所以这里四行 delay + 四行 false_path + 两行
# multicycle 整套搬过来，一份不多一份不少。
#
# rxc 焊盘那颗时钟（生成文件第 5 行的 rx_clk）在 IP 自己的文件里只被引用、从没被创建
# ⇒ 创建它是顶层的责任，本文件第 2 节就是干这件事的。

# --- 2.1 rxc 焊盘时钟：IP 若已传播过来就复用，没有才建 ---
set rx_pad_clk [get_clocks -quiet -include_generated_clocks -of_objects [get_ports RGMII_0_rxc]]
if {[llength $rx_pad_clk] == 0} {
    create_clock -name rgmii_rxc -period 8.000 [get_ports RGMII_0_rxc]
    set rx_pad_clk [get_clocks rgmii_rxc]
}

# --- 2.2 接收侧虚拟时钟（对应生成文件第 7 行，无 sources 即虚拟） ---
create_clock -name rgmii_rx_vclk -period 8.000

# --- 2.3 输入延迟（对应生成文件第 13/14/15/16 行） ---
set rx_data [get_ports {RGMII_0_rd[*] RGMII_0_rx_ctl}]

set_input_delay -clock [get_clocks rgmii_rx_vclk] -max -1.5 $rx_data
set_input_delay -clock [get_clocks rgmii_rx_vclk] -min -2.8 $rx_data
set_input_delay -clock [get_clocks rgmii_rx_vclk] -clock_fall -max -1.5 -add_delay $rx_data
set_input_delay -clock [get_clocks rgmii_rx_vclk] -clock_fall -min -2.8 -add_delay $rx_data

# --- 2.4 虚拟钟 ↔ 焊盘钟之间的假路径与零周期（对应生成文件第 18–23 行） ---
set_false_path -rise_from [get_clocks rgmii_rx_vclk] -fall_to $rx_pad_clk -setup
set_false_path -fall_from [get_clocks rgmii_rx_vclk] -rise_to $rx_pad_clk -setup
set_false_path -rise_from [get_clocks rgmii_rx_vclk] -rise_to $rx_pad_clk -hold
set_false_path -fall_from [get_clocks rgmii_rx_vclk] -fall_to $rx_pad_clk -hold

set_multicycle_path -from [get_clocks rgmii_rx_vclk] -to $rx_pad_clk -setup 0
set_multicycle_path -from [get_clocks rgmii_rx_vclk] -to $rx_pad_clk -hold -1

#============================================================
# 三、RGMII 发送侧时序
#============================================================
# 3.1 先说清一个实测到的边界（A 级，2026-11-06，workenv/pl_eth/stage15.log）：
# 生成文件第 27 行建发送时钟用的是
#   -source [get_pins -of [get_cells -hier -filter {name =~ *rgmii_txc_out}] -filter {name =~ *C}]
#   -master_clock [get_clocks -of [get_ports gmii_clk_125m*]]
# 而综合后的网表里 *rgmii_txc_out* 匹配到 0 个 cell／0 个 pin，转换核整颗是 OOC 黑盒
# （只有一层实例 U0_ps_ai_peripheral/ps_ai_wrapper_u0/ps_ai_i/gmii_to_rgmii_0，
#  REF=ps_ai_gmii_to_rgmii_0_0）。⇒ 顶层 XDC 抄不了这两行，也造不出这颗 generated clock，
# 它只能由 IP 自己那份 scoped clocks.xdc 在实现连接 OOC 黑盒时建立并传播到顶层端口。
# 所以本节不 create_clock，只"取"——取到就加 delay，取不到就明确报一行 WARN，
# 绝不允许"发送侧静默不约束"。
#
# 3.2 -1.0 / -2.6 同样照抄生成文件第 35/36/37/38 行（A 级）。

set tx_clk [get_clocks -quiet -of_objects [get_ports RGMII_0_txc]]
if {[llength $tx_clk] == 0} {
    set tx_clk [get_clocks -quiet -filter {name =~ *rgmii_tx_clk*}]
}
if {[llength $tx_clk] == 0} {
    puts "WARN routeA-XDC: 顶层取不到 RGMII 发送时钟（OOC 黑盒还没连进来），本节 4 条 output delay 暂时跳过。"
    puts "WARN routeA-XDC:   这条 WARN 在实现跑完后必须是 0 次，否则发送侧等于没约束。"
} else {
    puts [format "INFO routeA-XDC: 发送时钟取到 = %s" [get_property NAME $tx_clk]]
    set tx_data [get_ports {RGMII_0_td[*] RGMII_0_tx_ctl}]
    set_output_delay -clock $tx_clk -max -1.0 $tx_data
    set_output_delay -clock $tx_clk -min -2.6 $tx_data -add_delay
    set_output_delay -clock $tx_clk -clock_fall -max -1.0 $tx_data
    set_output_delay -clock $tx_clk -clock_fall -min -2.6 $tx_data
}

#============================================================
# 四、MDC / MDIO
#============================================================
# MDC 上限 2.5 MHz ＝ IEEE 802.3 的规定（B 级：数值来自标准，这颗 GEM 实际分到多少
# 由板端驱动写的 MDIO 分频寄存器决定，本机没核）。
# MDIO 窗口 ±10 ns ＝ 802.3 给的 setup/hold 各 10 ns（B 级），
# 这里是"双向都留 10 ns"的保守写法；inout 脚一份约束同时管收发，
# 真跑实现后按报告再收（未测）。
# MDC 在顶层是 OUT 脚（stage15.log A 级），在它上面 create_clock ＝把"这脚往外发的钟"
# 定义成约束基准；时钟总数在上一轮实测就是这一颗＋rgmii_rxc 两颗。

set mdc_clk [get_clocks -quiet -of_objects [get_ports MDIO_PHY_0_mdc]]
if {[llength $mdc_clk] == 0} {
    create_clock -name mdio_mdc -period 400.000 [get_ports MDIO_PHY_0_mdc]
    set mdc_clk [get_clocks mdio_mdc]
}

set mdio_pin [get_ports MDIO_PHY_0_mdio_io]
set_output_delay -clock $mdc_clk -max 10.000 $mdio_pin
set_output_delay -clock $mdc_clk -min -10.000 $mdio_pin
set_input_delay  -clock $mdc_clk -max 10.000 $mdio_pin
set_input_delay  -clock $mdc_clk -min -10.000 $mdio_pin

#============================================================
# 五、复位脚
#============================================================
# 静态/异步输出，不参与时序收敛；驱动它的那个时序由"谁驱动 AA13"定了以后再加。
set_false_path -to [get_ports {phy_reset_n[0]}]

puts "XDC routeA loaded (pins resolved; LVCMOS18 / VCCO still unverified; never run in an implementation here)"
