#=============================================================================
# clock_groups.xdc -- 时钟分组（**综合后**才施加）
#
# 为什么单独一个文件、而且必须放在 constrs_2：
#
# set_clock_groups 里的 get_clocks 是**求值**的，不像 create_clock 可以
# 挂到层次名上等设计长出来。放在 constrs_1（read_xdc 阶段）时，
# clk_fpga_0 和 clk_out*_clk_wiz_0 还不存在，get_clocks 返回空集合，
# Vivado 只会给一条 CRITICAL WARNING 然后**悄悄不做任何事**：
#
#   CRITICAL WARNING: [Vivado 12-4739] set_clock_groups:No valid object(s)
#   found for '-group [get_clocks -quiet {clk_fpga_0 *clk_wiz_0}]'
#
# constrs_2 在 synth_design 之后读，这时所有时钟都真实存在。
# build.tcl 里还会检查三组非空，为空直接 ABORT —— 静默失效的约束比
# 没有约束更危险。
#
# 为什么要分组：
#
#   cam_clk 是个时钟多路选择器
#       assign cam_clk = rx0_locked ? rx_usrclk : sys_clk_100m;
#   Vivado 把它拆成两根独立时钟，于是去算"cam_clk(rx 分支起沿) ->
#   cam_clk(100 MHz 分支收沿)"这种组合。而选择位 rx0_locked 在运行期
#   是静态的，这种组合在真实系统里根本不存在。时序报告据此报出
#   341 个 -7.454 ns 的**假违例**，路径形如
#
#       u_cdc_addr/s1_reg[8] -> u_wr/send_cnt_reg[*]/CE
#
# 两端本来都是 cam_clk 域。分组之后 Vivado 不再跨组算时序，
# 也就等于告诉它"时钟多路选择器的两个分支互斥"。
#
# 三组：
#   G1 GT 侧   —— 恢复出来的像素时钟、发射时钟、GT 参考时钟及其派生
#   G2 PS 侧   —— FCLK0 与 clk_wiz_0 的 100/200 MHz（同一个 MMCM，彼此同步）
#   G3 板载晶振侧 —— sys_clk_p 与 rx_sdi 里 sys_clk_inst0 派生的测量参考
#
# 真的跨组信号全部经过 sdi_cap_cdc 的两级同步器，切掉是对的：
#   fclk0 -> cam_clk   配置下发（cfg_enable / cfg_buf_addr / cfg_ring_bytes）
#   cam_clk -> fclk0   状态上报（自由运行计数器，读者做差值）
#=============================================================================

set GT_CLKS  [get_clocks -quiet {*RXOUTCLK* *TXOUTCLK* *mgtclk*}]
set PS_CLKS  [get_clocks -quiet {clk_fpga_0 *clk_wiz_0}]
set OSC_CLKS [get_clocks -quiet {sys_clk_p *sys_clk}]

foreach {name coll} [list GT $GT_CLKS PS $PS_CLKS OSC $OSC_CLKS] {
    if {[llength $coll] == 0} {
        puts "CLOCKGROUPS: ABORT -- group $name matched no clocks"
        puts "CLOCKGROUPS: get_clocks was evaluated before the design existed."
        puts "CLOCKGROUPS: make sure this file is in constrs_2, not constrs_1."
        error "clock group $name is empty"
    }
    puts "CLOCKGROUPS: group $name = [llength $coll] clocks"
}

set_clock_groups -asynchronous -group $GT_CLKS -group $PS_CLKS -group $OSC_CLKS
puts "CLOCKGROUPS: three groups declared asynchronous"