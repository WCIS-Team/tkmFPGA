# routeA XDC 复校：两趟对照，验证第 3 节那个 if 的两个分支都能走通。
# 趟 1 = 裸网表（OOC 黑盒未连，发送时钟取不到）⇒ 期望：0 ERROR + 那两行 WARN 出现。
# 趟 2 = 先手工在 RGMII_0_txc 上放一颗钟，模拟实现连进 OOC 黑盒后 IP 传播出来的样子
#        ⇒ 期望：0 ERROR + 4 条发送侧 output delay 真落上。
# 只读 dcp，不跑实现、不出位流、不碰板子。
set dcp "S:/work/WCIS/workenv/pl_eth/proj_trial/fpai_demo_fpga/fpai_demo_vivado.runs/synth_1/ai7030_edif_top.dcp"
set xdc "S:/work/WCIS/workenv/pl_eth/pl_eth_routeA.xdc"

proc count_pat {txt pat} {
    set n 0
    foreach line [split $txt \n] { if {[string match "*${pat}*" $line]} { incr n } }
    return $n
}

proc pass {tag precreate roundtrip} {
    global dcp xdc
    puts ""
    puts "########## $tag ##########"
    open_checkpoint $dcp
    if {$precreate} {
        create_clock -name standin_tx_clk -period 8.000 [get_ports RGMII_0_txc]
        puts "  预置了一颗 stand-in 发送时钟（模拟 IP scoped 约束传播到顶层）"
    }
    if {[catch {read_xdc -unmanaged $xdc} err]} {
        puts "  READ_XDC_THROW: [string trim $err]"
    } else {
        puts "  READ_XDC_RETURNED"
    }
    puts [format "  时钟数 = %d  名字 = %s" [llength [get_clocks -quiet]] \
        [get_property NAME [get_clocks -quiet]]]
    if {[catch {write_xdc -unmerged $roundtrip} e]} {
        puts "  write_xdc -unmerged 失败: [string trim $e]"
    } else {
        set f [open $roundtrip r]; set txt [read $f]; close $f
        foreach pat {create_clock create_generated_clock set_input_delay set_output_delay set_false_path set_multicycle_path PACKAGE_PIN IOSTANDARD} {
            puts [format "  反写 %-22s = %d 行" $pat [count_pat $txt $pat]]
        }
        set n 0
        foreach line [split $txt \n] {
            if {[string match "*set_output_delay*" $line] && [string match "*RGMII_0_td*" $line]} { incr n }
        }
        puts [format "  直数：引用 RGMII_0_td 的 set_output_delay = %d 行" $n]
        set m 0
        foreach line [split $txt \n] {
            if {[string match "*set_input_delay*" $line] && [string match "*RGMII_0_rd*" $line]} { incr m }
        }
        puts [format "  直数：引用 RGMII_0_rd 的 set_input_delay = %d 行" $m]
    }
    close_design
}

pass {趟 1：裸网表，发送时钟应当取不到} 0 "S:/work/WCIS/workenv/pl_eth/a2_xdc_rt_pass1.xdc"
pass {趟 2：预置发送时钟，4 条 output delay 应当落上} 1 "S:/work/WCIS/workenv/pl_eth/a2_xdc_rt_pass2.xdc"
exit 0
