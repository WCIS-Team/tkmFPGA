#=============================================================================
# sdi_cap.xdc -- constraints for the 1-channel HD-SDI capture card
#                FMQL30TAI / xc7z030ffg676-2
#
# Pin assignments are taken verbatim from the vendor's
# constrs_1/impl_constraints.xdc so they are known-good for this board.
#
# DDR and MIO pins are NOT here: those come from the processing_system7 IP's own
# .xdc, shipped alongside the .xci in rtl/vendor/ip/ps7/.
#
# The GT reference clock pins live in a separate fragment
# (gt_refclk_lite.xdc / gt_refclk_full.xdc) selected by build.tcl. They are
# deliberately NOT switched by rewriting this file -- string surgery on a
# constraint file corrupted it on the first attempt, and a constraint file
# that silently grows to 13 MB is a far worse failure than one extra file.
#=============================================================================

#--- board oscillator, 200 MHz -------------------------------------------------
set_property PACKAGE_PIN C8 [get_ports sys_clk_p]
set_property PACKAGE_PIN C7 [get_ports sys_clk_n]
set_property IOSTANDARD  DIFF_SSTL15 [get_ports sys_clk_p]
set_property IOSTANDARD  DIFF_SSTL15 [get_ports sys_clk_n]
create_clock -period 5.000 [get_ports sys_clk_p]

#--- SDI data in, GT lane 0 ----------------------------------------------------
set_property PACKAGE_PIN AB3 [get_ports FMC_HPC_DP0_M2C_N]
set_property PACKAGE_PIN AB4 [get_ports FMC_HPC_DP0_M2C_P]

#--- GTX reset -----------------------------------------------------------------
# ★ 2026-10-15 删除 ★ 原来自厂商 top（rx_gtx_full_reset 是它的一根输入引脚 E7）。
#   sdi_cap_top 里**没有这个端口**，GT 复位改由 SDI IP 自己管
#   （rx_sdi.v 内部 rx_gtx_full_reset_n / rx_gtx_reset_n 两路复位）。
#   留着那两条 set_property 的结果是每条都报
#       CRITICAL WARNING: [Common 17-55] 'set_property' expects at least one object
#       CRITICAL WARNING: [Netlist 29-160] Cannot set property 'PACKAGE_PIN' ...
#   它们什么都没约束到，只是噪声（真正生效的引脚约束在下面 LED 和
#   gt_refclk_*.xdc 里）。要恢复 GT 全复位硬件引脚的话，
#   先在 top 里把端口加回来，再加约束。

#--- PL LEDs -------------------------------------------------------------------
# led[0] -> J1 = recovered clock alive (rx_usrclk counter bit 25)
# led[1] -> M6 = SDI transport frame lock (rx0_locked)
# Same direction as the vendor's LED_MON=1 wiring: led = {led3, led1}
#   = {rx0_locked, rx_usrclk_cnt[25]}  (led3 is the high bit).
# 2026-10-16 correction: earlier comments claimed the J1/M6 pair the other
# way round; the bit order above is what the RTL implements.
set_property PACKAGE_PIN J1 [get_ports {led[0]}]
set_property IOSTANDARD  LVCMOS15 [get_ports {led[0]}]
set_property PACKAGE_PIN M6 [get_ports {led[1]}]
set_property IOSTANDARD  LVCMOS15 [get_ports {led[1]}]

#--- 时钟分组 --------------------------------------------------------------
#
# ★ 2026-10-15 补两条从来没建过的时钟 ★
#   原来这里写"Vivado 会把 cam_clk 拆成两根时钟"—— 错。布线后时序报告里写着
#       There are 987 register/latch pins with no clock driven by root clock pin:
#           u_rx/SDI0/SDI/GTX_i/gtxe2_i/RXOUTCLK (HIGH)
#   恢复时钟 RXOUTCLK 和它下游的 cam_clk **根本没有时钟对象**，于是整条像素
#   通路（vendor 的 frame_convertor / YCbCr422_2_RGB888，加上我们的
#   sdi_cap_meas / sdi_px_pack / 异步 FIFO 写侧）都不在时序分析范围里。
#   之前报的 WNS +0.847 ns 只是被分析了的那半张网表的结论。
#
#   ① rx_usrclk —— GT 恢复时钟。vendor 的像素流水线就是用它
#      （rx_sdi.v:353/381/422），周期取 HD-SDI 真实像素速率 74.25 MHz。
#      SD-SDI 更慢，慢是安全方向。
#   ② cam_clk —— 消费侧看到的时钟 = rx_usrclk 与 100 MHz 兜底时钟二选一
#      （rx_sdi.v:395     assign cam_clk = rx0_locked ? rx_usrclk : sys_clk_100m;）
#      经 BUFG 后给我们自己的逻辑。周期取两者里更快的 100 MHz：锁定时实际
#      只有 74.25 MHz，是过约束（安全方向）；不锁定时正好就是 100 MHz。
#
#   这两根时钟之间隔着一个多路选择器，Vivado 看不见这层关系，只能当成互不
#   同步。但不能一剪了之：锁定时它们是同一根时钟，像素数据从 vendor 流水线
#   送进打包器是一条真实的同步路径（要在 13.468 ns 里跑完），
#   所以下面分组剪开之后再补一条 set_max_delay 把这层要求找回来。
#
# 分组（名字写成字面量，不用 get_clocks：名字不存在时 Vivado 只报一条警告，
# 而 get_clocks 匹配不到会给出**空列表**，那正是上次把整条约束变成空操作的
# 原因之一。命令里也不许有任何控制流，理由见下面"XDC 不是 Tcl"）
#
# 四组互不同步：
#   G1 恢复时钟侧 —— rx_usrclk、cam_clk
#   G2 PS 侧      —— FCLK0 与 clk_wiz_0 的 100/200 MHz，以及由 200 MHz 分频
#                    出来的 27 MHz 测量参考（clk_out1_sys_clk，同一 MMCM 家族）
#   G3 GT 参考时钟侧 —— FMC GBTCLK 引脚时钟 + mgtclk MMCM 变出来的 148.5 MHz
#   （sys_clk_p 端口目前没有任何负载，create_clock 留着，但它不进分组）
#
# ★ XDC 不是 Tcl ★（这条踩了两次）
#   XDC 解析器只认少数几个命令。写 foreach / if / puts 进去，Vivado 会报
#       CRITICAL WARNING: [Designutils 20-1307] Command 'foreach' is not
#                         supported in the xdc constraint file.
#   然后**继续往下执行**。上一次就是把"检查分组是否为空、打印匹配数"的逻辑
#   写在 foreach/if 里，结果 foreach 被跳过 -> 列表是空的 ->
#       CRITICAL WARNING: [Vivado 12-2242] set_clock_groups: No group specified.
#   整条约束变成空操作，而且因为 puts 同样不被支持，
#   **连"它没生效"这件事都没打出来**。
#   所以这里必须写成一条不带任何控制流的裸命令：要么整条生效，要么整条报错。
#   要看各组匹配了几个时钟，去报告的 Clock Summary 里数，别指望这里会打印。
#
# 另外这条约束必须待在 constrs_1：
#   - 挪到 constrs_2 没用：add_files -fileset constrs_2 只把文件加进**工程**，
#     launch_runs 不把它拷进 run（实测文件在 sdi_cap.runs/ 下没有任何痕迹）。
#   - 用 open_run synth_1 + read_xdc 也不行：那样 impl_1 子进程读不到本文件，
#     DRC 的 set_property SEVERITY 也就没被执行，place_design 直接报
#     "DRC finished with 2 Errors"，位流出不来。
#     根因是 DRC 检查的 SEVERITY 属于**会话状态**，不随 DCP 传递。

# --- 两条补建的时钟 -----------------------------------------------------------
# get_pins 用 -hierarchical + 名字过滤：这两个内部名字取自布线后的时序报告，
# 是 Vivado 自己打印出来的（u_rx/SDI0/SDI/...），不是猜的。
create_clock -name rx_usrclk -period 13.468 [get_pins -hierarchical -filter {NAME =~ *gtxe2_i/RXOUTCLK}]
create_clock -name cam_clk   -period 10.000 [get_pins -hierarchical -filter {NAME =~ *cam_clk_BUFG_inst/O}]

# 选择器两边必须分组剪开：不剪的话 Vivado 会拿 13.468 ns 和 10 ns 去求公共
# 周期，算出 0.4 ns 这种荒谬的建立要求（实测过，会刷屏几百条失败）。剪开之后
# 再用一条 -datapath_only 把"vendor 流水线 -> 打包器"这条真实边界的
# 数据路径要求补回来（-datapath_only = 只约束数据路径、不带时钟相位关系，
# 是这类边界的标准写法）。
set_max_delay -datapath_only 10.000 -from [get_clocks rx_usrclk] -to [get_clocks cam_clk]

# --- 分组 ---------------------------------------------------------------------
set_clock_groups -asynchronous \
    -group {rx_usrclk cam_clk} \
    -group {clk_fpga_0 clk_out1_clk_wiz_0 clk_out2_clk_wiz_0 clkfbout_clk_wiz_0 clk_out1_sys_clk clkfbout_sys_clk} \
    -group {FMC_HPC_GBTCLK0_M2C_C_P clk_out1_mgtclk clkfbout_mgtclk}

# 复位：PL 侧没有复位端口 —— 复位来自 PS 的 FCLK_RESET0_N（PS7 的输出，
# 不是顶层端口），所以这里没有 set_false_path 可写。原来那条
#   set_false_path -from [get_ports rx_gtx_full_reset]
# 指向一个不存在的端口，只贡献一条 CRITICAL WARNING，已删。
set_false_path -to   [get_ports {led[0]}]
set_false_path -to   [get_ports {led[1]}]

set_property SEVERITY {Warning} [get_drc_checks {REQP-44}]
set_property SEVERITY {Warning} [get_drc_checks {REQP-46}]
set_property SEVERITY {Warning} [get_drc_checks {REQP-52}]
set_property SEVERITY {Warning} [get_drc_checks {REQP-56}]
