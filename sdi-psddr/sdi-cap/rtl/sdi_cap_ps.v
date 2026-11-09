//============================================================================
// sdi_cap_ps -- PS7 + 三个 AXI 口的布线。
//
// 手写封装而不是 Block Design，两个理由：
//   1. 这块板的 PS7 配置不是标准件——从厂商的
//      ps_ai_processing_system7_0_0.xci 原样搬来的（约 200 条 PCW 属性，
//      DDR3 32bit/534MHz/CL7/MT41K256M16，FCLK0=50MHz，
//      NUM_F2P_INTR_INPUTS=3，M_AXI_GP0 和 M_AXI_GP1 都开着），
//      已经在 xc7z030ffg676-2 上验证过能综合能布局。在 Tcl 里重新推导一遍
//      是这个项目最大的风险来源，而收益为零。
//   2. 数据搬运通路对 PS 的需求只有两条：一个 64 bit AXI 主机写 PS DDR，
//      一个小 AXI4-Lite 寄存器窗口。
//
// ★★ 2026-10-15：写数据通路从 M_AXI_GP0 改到 S_AXI_HP2 ★★
//   原来用的是 GP0，方向错了：
//     M_AXI_GP0 是 **PS 的出口**（PS 当主机），PL 从设备挂它下面；
//     而我们要的是 PL 当主机、PS 当从机 —— 那是 **S_AXI_HP0..3**。
//   证据（合成后网表 + 合成日志）：
//     net u_ps/wr_awvalid 上只有一个引脚 u_ps/u_ps7/M_AXI_GP0_AWVALID，
//     方向 OUT；wr_awvalid 在 IP 里是 output，而模块端口是 input ——
//     合成器直接给了
//       WARNING: [Synth 8-6104] Input port 'wr_awvalid' has an internal driver
//     u_wr（写帧器）的 m_axi_* 引脚全部被优化掉，AXI 主机在网表里不存在。
//   现在：S_AXI_HP2（厂商自己的写帧器 frame_to_ps_largebuf 用的就是这个口），
//   64 bit 宽，AWLEN 4 bit 上限 16 拍，ACLK 接常驻的 clk_100m。
//
// ★ 为什么寄存器用 GP1、写数据用 HP2，两条路互不干扰 ★
//   最初把寄存器块和写帧器挂在同一个 GP 口上，按地址译码选路。问题是
//   **先有鸡还是先有蛋**：要决定走哪条路得先看 PS7 驱动的地址，可那个地址
//   又是两个从设备地址的多路选择结果。第一版写成了
//   `assign gp0_awvalid = gp0_awvalid & ~sel_reg_wr;`——对输出端口自赋值，
//   综合会过，opt_design 报
//       [DRC MDRV-1] Net .../aw_hold_a[7]_i_3_n_0 has multiple drivers:
//              .../MAXIGP0AWVALID, and .../aw_hold_a[7]_i_3/O
//
//   现在每个口只有**一个**功能，全是直通线：没有译码、没有多路选择、
//   没有自赋值、没有反馈环。
//
//   S_AXI_HP2 <- 写帧器（PL 当主机，64 bit，只写，目标是 PS DDR）
//   M_AXI_GP1 -> 寄存器块（PS 当主机，AXI4-Lite，读 + 写）
//   M_AXI_GP0 不用（整组不接）
//
// ★ 端口名注意 ★
//   processing_system7 IP **不叫** block design wrapper 那套名字。
//   真实的名字（读自 rtl/vendor/ip/ps7/synth/ps_ai_processing_system7_0_0.v）：
//   FIXED_IO_mio -> MIO      DDR_ba -> DDR_BankAddr
//   DDR_ck_p/n  -> DDR_Clk / DDR_Clk_n     DDR_dqs_p/n -> DDR_DQS / DDR_DQS_n
//   DDR_odt     -> DDR_ODT   DDR_ras_n -> DDR_RAS_n
//   DDR_reset_n -> DDR_DRSTB DDR_we_n   -> DDR_WEB
//   FIXED_IO_ddr_vrn/vrp -> DDR_VRN / DDR_VRP
//   ps_clk_out 和 pll_lock 这两个 BD wrapper 合成的端口在 IP 上根本不存在；
//   IRQ_F2P 是 PS7 的**输入**，FCLK_RESET0_N 是 PS7 的**输出**。
//   S_AXI_HP2_* 的位宽（同一份 HDL 里读出来的，不是从 AXI 规范推的）：
//   WDATA 64、WSTRB 8、AWSIZE 3、AWLEN 4、AWID/BID/WID 6、
//   RCOUNT 8 / WCOUNT 8 / RACOUNT 3 / WACOUNT 6（★ 下面这段要看 ★）
//
//   S_AXI_HP2_RCOUNT/WCOUNT/RACOUNT/WACOUNT 这四组在 IP 上存在，但
//   厂商 2026-10-12 的客户说明《PS-PL AXI HP 事务计数与复位语义》明确写了
//   该芯片 **不提供** 这些计数（AXI 协议本身也没有这种信号），
//   所以本设计刻意不接它们，在途事务数由 PL 自己数（写帧器里的 inflight）。
//
// 只开了 FCLK0（50 MHz），SDI 需要的 200 MHz 由 clk_wiz_0 从 FCLK0 生成，
// 与厂商设计做法一致。AXI 主机的 100 MHz 同样来自 clk_wiz_0（clk_out1）。
//============================================================================
`timescale 1ns / 1ps

module sdi_cap_ps (
    // ---- PS DDR ----
    inout  wire [14:0] DDR_addr,
    inout  wire [2:0]  DDR_ba,
    inout  wire        DDR_cas_n,
    inout  wire        DDR_ck_n,
    inout  wire        DDR_ck_p,
    inout  wire        DDR_cke,
    inout  wire        DDR_cs_n,
    inout  wire [3:0]  DDR_dm,
    inout  wire [31:0] DDR_dq,
    inout  wire [3:0]  DDR_dqs_n,
    inout  wire [3:0]  DDR_dqs_p,
    inout  wire        DDR_odt,
    inout  wire        DDR_ras_n,
    inout  wire        DDR_reset_n,
    inout  wire        DDR_we_n,
    inout  wire        FIXED_IO_ddr_vrn,
    inout  wire        FIXED_IO_ddr_vrp,

    // ---- PS MIO / 专用引脚 ----
    inout  wire [53:0] FIXED_IO_mio,
    inout  wire        FIXED_IO_ps_clk,
    inout  wire        FIXED_IO_ps_srstb,

    input  wire        sys_clk_p,
    input  wire        sys_clk_n,

    // ---- fabric 时钟 ----
    output wire        fclk0_clk,
    output wire        clk200,
    output wire        clk_100m,
    output wire        pl_reset_n,     // 低有效，等 clk_wiz 锁定

    // ---- 写帧器：S_AXI_HP2 写通道（64 bit，PL 当主机），全是直通线 ----
    input  wire [31:0] wr_awaddr,
    input  wire [5:0]  wr_awid,
    input  wire [3:0]  wr_awlen,
    input  wire [2:0]  wr_awsize,
    input  wire [1:0]  wr_awburst,
    input  wire        wr_awlock,
    input  wire [3:0]  wr_awcache,
    input  wire [2:0]  wr_awprot,
    input  wire [3:0]  wr_awqos,
    input  wire        wr_awvalid,
    input  wire [63:0] wr_wdata,
    input  wire [7:0]  wr_wstrb,
    input  wire        wr_wlast,
    input  wire        wr_wvalid,
    input  wire [5:0]  wr_wid,
    output wire        wr_awready,
    output wire        wr_wready,
    // ★ B 通道方向（2026-10-15 修的第二个同类 bug）★
    //   BVALID/BRESP/BID 是**从设备（PS 侧）给的回执** —— PS7 的输出；
    //   BREADY 是**主机（写帧器）给的应答** —— 写帧器的输出。
    //   四条原来全写反了，综合器报
    //       WARNING: [Synth 8-6104] Input port 'wr_bvalid' has an internal driver
    //   后果：回执到不了写帧器 → inflight 永不归零 → 跑满 8 个未完成突发
    //   之后**永久停住**（不是写错地方，是根本不写了）。
    output wire        wr_bvalid,
    output wire [1:0]  wr_bresp,
    output wire [5:0]  wr_bid,
    input  wire        wr_bready,

    // ---- 寄存器块：GP1（PS 当主机，PL 当从机），AXI4-Lite 直通 ----
    // 方向按厂商 IP 原样来（rtl/vendor/ip/ps7/synth/ps_ai_processing_system7_0_0.v
    // 末尾有引脚表）：
    //   主机（PS7）的输出  -> 本模块的 output：AWADDR/AWVALID/WDATA/WSTRB/
    //                        WVALID/ARADDR/ARVALID/BREADY/RREADY
    //   从机（寄存器块）的输出 -> 本模块的 input：AWREADY/WREADY/BRESP/BVALID/
    //                        ARREADY/RDATA/RRESP/RVALID
    // 第一版把 BRESP/BVALID/RDATA/RRESP/RVALID 写成 output、把 BREADY/RREADY
    // 写成 input，还额外用 assign 把输入端口往回接（"Input port 'm_arready'
    // has an internal driver"）—— 结果是 PS 侧收不到 ARREADY/BRESP/RVALID，
    // **寄存器读写双双挂死**。
    //
    // 地址给 32 bit（PS7 的 AWADDR/ARADDR 本身就是 32 bit），到寄存器块再截到
    // 12 bit。截位必须发生在**输入端口**上；反过来在 PS7 的**输出**引脚上写
    // 拼接会被综合器丢掉（"[Synth 8-2900] ignoring illegal expression in
    // output port connection"），第一版就是这样把地址丢成恒 0 的。
    output wire [31:0] m_awaddr,
    output wire        m_awvalid,
    input  wire        m_awready,
    output wire [31:0] m_wdata,
    output wire [3:0]  m_wstrb,
    output wire        m_wvalid,
    input  wire        m_wready,
    output wire        m_bready,       // PS7 的输出
    input  wire [1:0]  m_bresp,        // 寄存器块的输出
    input  wire        m_bvalid,
    output wire [31:0] m_araddr,
    output wire        m_arvalid,
    input  wire        m_arready,
    output wire        m_rready,       // PS7 的输出
    input  wire [31:0] m_rdata,        // 寄存器块的输出
    input  wire [1:0]  m_rresp,
    input  wire        m_rvalid,

    input  wire        cap_intr
);

    //--------------------------------------------------------------------------
    // 时钟
    //--------------------------------------------------------------------------
    wire clk_wiz_locked;

    clk_wiz_0 u_clk_wiz (
        .clk_in1  (fclk0_clk),
        .reset    (1'b0),
        .locked   (clk_wiz_locked),
        .clk_out1 (clk_100m),
        .clk_out2 (clk200)
    );

    // FCLK_RESET0_N 是 PS7 自己给的 FCLK0 域复位（低有效）。
    // 再和 clk_wiz_locked 相与，让 fabric 在 MMCM 输出稳定之前一直保持复位。
    // clk_wiz_locked 与 fclk0_clk 同步而 MMCM 输出不同步，这两级门是故意的。
    wire ps_fclk_rst_n;
    assign pl_reset_n = ps_fclk_rst_n & clk_wiz_locked;

    //--------------------------------------------------------------------------
    // PS7
    //--------------------------------------------------------------------------
    // IRQ_F2P 是 PS7 的输入（fabric -> processor），位宽由 PCW 的
    // NUM_F2P_INTR_INPUTS 决定，这里是 3 位。只用 bit0，其余拉低而不是悬空。
    wire [2:0] f2p_in = {2'b00, cap_intr};

    // --- S_AXI_HP2：写帧器（PL 当主机，PS 当从机，64 bit）---
    // ★ 2026-10-15 更正 ★
    //   原来写帧器挂在 M_AXI_GP0 上，那是个方向性错误：
    //   M_AXI_GP0 是 **PS 的出口**（PS 当主机），AWVALID/AWADDR/WDATA 是这个
    //   黑盒的 **输出**，PL 只能当从设备挂上去。合成后的网表里
    //       u_wr/m_axi_awvalid … m_axi_wdata 全部不在网表里，
    //       net u_ps/wr_awvalid 上只有一个引脚 u_ps/u_ps7/M_AXI_GP0_AWVALID，
    //       AWREADY/WREADY 被接地、BVALID/BID 悬空、ACLK 没接，
    //   合成日志同时给出根因：
    //       WARNING: [Synth 8-6104] Input port 'wr_awvalid' has an internal driver
    //   结论：PL 要把数据写进 PS DDR，唯一正确的通路是 S_AXI_HP0..3。
    //   厂商自己的写帧器 frame_to_ps_largebuf 就挂在 S_AXI_HP2 上
    //   （fpai_demo_fpga/rtl/ps_ai_peripheral.sv）。这里照抄那条通路。
    //
    //   本 PS7 IP 里 S_AXI_HP2 的实际位宽（读自 ps_ai_processing_system7_0_0.v）：
    //       WDATA 64、WSTRB 8、AWSIZE 3、AWLEN 4（最多 16 拍）、AWID/BID/WID 6
    //   ACLK 用常驻的 clk_100m（不是恢复出来的像素时钟 —— 那个失锁会换频）。

    // --- GP1：寄存器块 ---
    // 直连，没有中间 wire。第一版用 gp1_* 加 assign 桥接，方向写反之后综合器
    // 报了一串 "Input port 'm_arready' has an internal driver"，并在 PS7 的
    // ARREADY/RDATA/RRESP/RVALID/BRESP/BVALID 引脚上各拖出一根只有负载、
    // 没有驱动的网线 —— 实测 u_ps/m_arready 的驱动是个 LUT，而那个 LUT 的
    // 输入就是 PS7 自己的 ARREADY 引脚（成环，恒 0），PS 侧永远等不到应答。
    // 直接把引脚接到端口上，就没有这一类问题。

    ps_ai_processing_system7_0_0 u_ps7 (
        .MIO                (FIXED_IO_mio),
        .PS_CLK             (FIXED_IO_ps_clk),
        .PS_SRSTB           (FIXED_IO_ps_srstb),
        .IRQ_F2P            (f2p_in),
        .FCLK_CLK0          (fclk0_clk),
        .FCLK_RESET0_N      (ps_fclk_rst_n),

        .DDR_Addr           (DDR_addr),
        .DDR_BankAddr       (DDR_ba),
        .DDR_CAS_n          (DDR_cas_n),
        .DDR_CKE            (DDR_cke),
        .DDR_CS_n           (DDR_cs_n),
        .DDR_Clk_n          (DDR_ck_n),
        .DDR_Clk            (DDR_ck_p),
        .DDR_DM             (DDR_dm),
        .DDR_DQ             (DDR_dq),
        .DDR_DQS_n          (DDR_dqs_n),
        .DDR_DQS            (DDR_dqs_p),
        .DDR_ODT            (DDR_odt),
        .DDR_RAS_n          (DDR_ras_n),
        .DDR_DRSTB          (DDR_reset_n),
        .DDR_WEB            (DDR_we_n),
        .DDR_VRN            (FIXED_IO_ddr_vrn),
        .DDR_VRP            (FIXED_IO_ddr_vrp),

        // ---------------- M_AXI_GP0：本设计不用，整组不接 ----------------
        // GP0 是 PS 的出口（PS 当主机），PL 从设备才挂在它下面；
        // 写帧器已经改到 S_AXI_HP2。这里**刻意不接**：未连接的引脚由
        // 综合器自行处理，不会再出现 Synth 8-6104 那种
        // "输入端口在内部还有驱动" 的自相矛盾。
        //
        // ---------------- S_AXI_HP2 <- 写帧器（PL 主机，只写）----------------
        // 读通道不用，明确拉死（不悬空），免得综合器报一堆 driverless。
        .S_AXI_HP2_ACLK     (clk_100m),
        .S_AXI_HP2_AWADDR   (wr_awaddr),
        .S_AXI_HP2_AWID     (wr_awid),
        .S_AXI_HP2_AWLEN    (wr_awlen),
        .S_AXI_HP2_AWSIZE   (wr_awsize),
        .S_AXI_HP2_AWBURST  (wr_awburst),
        // AWLOCK 位宽（2026-11-10 修）：写帧器是 AXI4 主机，AWLOCK 1 bit
        //（0=Normal/1=Exclusive）；HP 口是 AXI3，AWLOCK 2 bit
        //（00=Normal/01=Exclusive/10=Locked）。AXI4 的 1 bit 语义对应 AXI3
        // 的低位，高位补 0 即等价映射（本主机恒 Normal，恒 00）。
        .S_AXI_HP2_AWLOCK   ({1'b0, wr_awlock}),
        .S_AXI_HP2_AWCACHE  (wr_awcache),
        .S_AXI_HP2_AWPROT   (wr_awprot),
        .S_AXI_HP2_AWQOS    (wr_awqos),
        .S_AXI_HP2_AWVALID  (wr_awvalid),
        .S_AXI_HP2_AWREADY  (wr_awready),
        .S_AXI_HP2_WDATA    (wr_wdata),
        .S_AXI_HP2_WSTRB    (wr_wstrb),
        .S_AXI_HP2_WID      (wr_wid),
        .S_AXI_HP2_WLAST    (wr_wlast),
        .S_AXI_HP2_WVALID   (wr_wvalid),
        .S_AXI_HP2_WREADY   (wr_wready),
        .S_AXI_HP2_BID      (wr_bid),
        .S_AXI_HP2_BRESP    (wr_bresp),
        .S_AXI_HP2_BVALID   (wr_bvalid),
        .S_AXI_HP2_BREADY   (wr_bready),
        // 发送能力使能：厂商设计里也是拉低（ps_ai_peripheral.sv:952-953）
        .S_AXI_HP2_RDISSUECAP1_EN (1'b0),
        .S_AXI_HP2_WRISSUECAP1_EN (1'b0),
        // 读通道（不用）
        .S_AXI_HP2_ARADDR   (32'd0),
        .S_AXI_HP2_ARID     (6'd0),
        .S_AXI_HP2_ARLEN    (4'd0),
        .S_AXI_HP2_ARSIZE   (3'b011),
        .S_AXI_HP2_ARBURST  (2'b01),
        .S_AXI_HP2_ARLOCK   (1'b0),
        .S_AXI_HP2_ARCACHE  (4'b0011),
        .S_AXI_HP2_ARPROT   (3'b000),
        .S_AXI_HP2_ARQOS    (4'b1111),
        .S_AXI_HP2_ARVALID  (1'b0),
        .S_AXI_HP2_RREADY   (1'b0),

        // ---------------- GP1 -> 寄存器块（PS 主机，PL 从机，AXI4-Lite）----------------
        // ★ 2026-11-10 修 ★ M_AXI_GP1_ACLK 原来整段漏接。它是 PS7 的**输入**
        //   （GP 交换矩阵在这颗时钟下采样 PL 从机的回执）——悬空时 PS7 内部
        //   综合成恒 0，GP1 上的任何 AXI 握手都成立不了：PS 对 0x8000_0000
        //   的读写永远等不到应答。寄存器块用 fclk0_clk（50 MHz），时钟必须同源。
        //   HP2 的 ACLK 一直是接好的（下面 clk_100m），漏的只有 GP1 这一个。
        //   证据：stub ps_ai_processing_system7_0_0_stub.v:179 input M_AXI_GP1_ACLK
        //   从未出现在本文件的 GP1 段；routed DRC 里也没有 PSB-2 类的报错，
        //   即这个错综合/布线都不报，只有上板读写挂死才暴露。
        //
        //   其余全部直连，不经过任何中间 wire、不用 assign。方向按厂商 IP 原样：
        //     PS7 的输出（我们的 output 端口）  : AWADDR/AWVALID/WDATA/WSTRB/
        //                                        WVALID/ARADDR/ARVALID/BREADY/RREADY
        //     寄存器块的输出（我们的 input 端口）: AWREADY/WREADY/BRESP/BVALID/
        //                                        ARREADY/RDATA/RRESP/RVALID
        //   不用的 PS7 输出整段留空 ()：AWLEN/AWSIZE/AWBURST/AWLOCK/AWCACHE/
        //   AWPROT/AWQOS/AWID/WLAST/BID/ARLEN/ARSIZE/ARBURST/ARLOCK/ARCACHE/
        //   ARPROT/ARQOS/ARID/RLAST —— 接常量会被综合器丢掉（Synth 8-2900），
        //   而且寄存器块是 AXI4-Lite，本来也不需要这些。
        .M_AXI_GP1_ACLK     (fclk0_clk),
        .M_AXI_GP1_AWADDR   (m_awaddr),
        .M_AXI_GP1_AWVALID  (m_awvalid),
        .M_AXI_GP1_AWREADY  (m_awready),
        .M_AXI_GP1_WDATA    (m_wdata),
        .M_AXI_GP1_WSTRB    (m_wstrb),
        .M_AXI_GP1_WVALID   (m_wvalid),
        .M_AXI_GP1_WREADY   (m_wready),
        .M_AXI_GP1_BREADY   (m_bready),
        .M_AXI_GP1_BRESP    (m_bresp),
        .M_AXI_GP1_BVALID   (m_bvalid),
        .M_AXI_GP1_ARADDR   (m_araddr),
        .M_AXI_GP1_ARVALID  (m_arvalid),
        .M_AXI_GP1_ARREADY  (m_arready),
        .M_AXI_GP1_RREADY   (m_rready),
        .M_AXI_GP1_RDATA    (m_rdata),
        .M_AXI_GP1_RRESP    (m_rresp),
        .M_AXI_GP1_RVALID   (m_rvalid)
    );

    //--------------------------------------------------------------------------
    // 没有直通 assign
    //--------------------------------------------------------------------------
    // 两个 AXI 接口都在上面的例化里直接连到本模块的端口上了：
    // S_AXI_HP2（写帧器，PL 主机，64 bit）和 M_AXI_GP1（寄存器块，PS 主机）。
    // 第一版在这里用 assign 把输入端口往回接，正是那一版报
    // "Input port 'm_arready' has an internal driver" 的地方 —— 已经删掉，
    // 不要再加回来（见文件头 §6.20）。

endmodule