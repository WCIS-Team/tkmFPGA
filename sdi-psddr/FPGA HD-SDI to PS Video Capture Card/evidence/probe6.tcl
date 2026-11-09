# probe6.tcl -- READ ONLY. 网表验收：**按网查驱动/负载**（这个网表的层次被
#               Vivado "rebuilt" 过，模块端口引脚名不可靠，上一版 probe5 就是
#               在这上面栽跟头的）。
#
# 验收项：
#   A. S_AXI_HP2（写帧器 -> PS DDR）：每根线的驱动/负载方向对不对
#   B. M_AXI_GP1（PS -> 寄存器块）：同上
#   C. 跨时钟域的七个粘滞/控制信号（8-2900 修没修好）
set dcp "S:/apps/llm/agentwork/sdi-cap/sdi_cap.runs/impl_1/sdi_cap_top_routed.dcp"
open_checkpoint $dcp

proc sh {pat} {
    set ns [get_nets -quiet -hierarchical -filter "NAME =~ $pat"]
    if {[llength $ns] == 0} { puts "P6| NET $pat : *** NOT FOUND ***"; return }
    foreach n $ns {
        set lp [get_pins -quiet -leaf -of_objects $n]
        set drv {}; set loads {}
        foreach p $lp {
            if {[get_property DIRECTION $p] eq "OUT"} { lappend drv [get_property NAME $p] } else { lappend loads [get_property NAME $p] }
        }
        puts "P6| NET [get_property NAME $n]"
        puts "P6|     drv  : $drv"
        puts "P6|     loads: [lrange $loads 0 4] ([llength $loads] total)"
    }
}

proc shpin {pat} {
    set ps [get_pins -quiet -hierarchical -filter "NAME =~ $pat"]
    if {[llength $ps] == 0} { puts "P6| PIN $pat : *** NOT FOUND ***"; return }
    foreach p $ps {
        set nn [get_nets -quiet -of_objects $p]
        if {[llength $nn] == 0} { puts "P6| PIN $p : *** NO NET ***"; continue }
        set n [lindex $nn 0]
        set lp [get_pins -quiet -leaf -of_objects $n]
        set drv {}; set loads {}
        foreach q $lp {
            if {[get_property DIRECTION $q] eq "OUT"} { lappend drv [get_property NAME $q] } else { lappend loads [get_property NAME $q] }
        }
        puts "P6| PIN $p  dir=[get_property DIRECTION $p]"
        puts "P6|     net  : [get_property NAME $n]"
        puts "P6|     drv  : $drv"
        puts "P6|     loads: [lrange $loads 0 4] ([llength $loads] total)"
    }
}

puts "P6|################ A. S_AXI_HP2 (PL 是主机) ################"
# PS7 是这条路线的**从机**：AW/W 是它的输入，BVALID 是它的输出。
foreach s {SAXIHP2AWVALID SAXIHP2AWREADY SAXIHP2WVALID SAXIHP2WREADY SAXIHP2BVALID SAXIHP2BREADY} {
    shpin "*PS7_i/$s"
}
foreach s {SAXIHP2BRESP[0] SAXIHP2BRESP[1] SAXIHP2BID[5]} {
    shpin "*PS7_i/$s"
}
foreach s {SAXIHP2WLAST SAXIHP2WSTRB[0]} {
    shpin "*PS7_i/$s"
}
foreach pat {*wr_awvalid *wr_awready *wr_wvalid *wr_wready *wr_bvalid *wr_bready *wr_bresp[0] *wr_awaddr[0] *wr_awaddr[31] *wr_wdata[0] *wr_wstrb[0] *wr_awlen[0] *wr_awsize[1] *wr_awcache[0] *wr_awqos[0] *wr_awid[0] *wr_bid[0]} {
    sh $pat
}

puts "P6|################ B. M_AXI_GP1 (PS 是主机) ################"
# 这条反过来：PS7 是主机，AW/W/AR 是它的**输出**，READY/RDATA/BRESP 是它的输入。
foreach s {MAXIGP1AWVALID MAXIGP1AWREADY MAXIGP1WVALID MAXIGP1WREADY MAXIGP1BVALID MAXIGP1BREADY MAXIGP1ARVALID MAXIGP1ARREADY MAXIGP1RVALID MAXIGP1RREADY} {
    shpin "*PS7_i/$s"
}
foreach s {MAXIGP1RDATA[0] MAXIGP1RRESP[0] MAXIGP1BRESP[0]} {
    shpin "*PS7_i/$s"
}
foreach pat {*m_awaddr[0] *m_awaddr[11] *m_awvalid *m_awready *m_wdata[0] *m_wstrb[0] *m_wvalid *m_wready *m_bresp[0] *m_bvalid *m_bready *m_araddr[0] *m_araddr[11] *m_arvalid *m_arready *m_rdata[0] *m_rresp[0] *m_rvalid *m_rready} {
    sh $pat
}

puts "P6|################ C. 七个跨域信号（8-2900 的验收）################"
foreach pat {*cfg_enable *p_enable *cfg_rearm *p_rearm *p_rearm_cam *px_overflow_cam *px_overflow *wr_idle_axi *wr_idle *starving_axi *starving} {
    sh $pat
}
puts "P6|DONE"
