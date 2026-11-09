//============================================================================
// sdi_cap_top -- 悟净 FMQL30TAI 上的单路 HD-SDI 数据搬运通路。
//
// 做什么：SDI 口进来的像素流，连续写进 PS DDR，供 Linux 侧软件读取。
// 不做什么：**不做格式判断、不判制式、不按帧率门控、不丢帧、不缩放、
//          不转色彩空间。** 进来什么写什么，格式解释交给软件。
//
// 数据通路
//
//   BNC -> LMH0344(板载) -> GTX RX -> smpte_sdi IP -> frame_convertor
//        -> Y'CbCr 4:2:2 8bit, 16 bit/px, 74.25 MHz (HD-SDI)   [cam_clk]
//        -> sdi_cap_meas    只测量，不筛选
//        -> sdi_px_pack     4 像素拼 1 拍 64 bit + 帧标记
//        -> sdi_px_afifo    双时钟 FIFO（1024 拍 = 8 KB）        [跨域]
//        -> sdi_stream_wr   AXI4 连续写（64 bit，最多 8 个未完成突发）
//        -> S_AXI_HP2 -> PS DDR                                  [clk_100m]
//
//   帧边界只留一个记录：vsync 到达时记下当时的写地址（FRAME_ADDR）。
//   软件轮询它就知道新一帧从哪开始，帧长自己用 MEAS_W/MEAS_H 算。
//   帧标记跟着数据一起过 FIFO，所以 FRAME_ADDR 与数据严格对齐（±1 拍 = 8 B）。
//
// PS 侧三条路（理由见 sdi_cap_ps.v 的文件头）：
//   S_AXI_HP2 <- 写帧器（PL 当主机，只写，目标 PS DDR，64 bit）
//   M_AXI_GP1 -> 寄存器块（PS 当主机，AXI4-Lite，基址 0x8000_0000）
//   M_AXI_GP0 不用
//
// ★ 为什么 AXI 主机不在像素时钟域（2026-10-15 改）★
//   原来把 AXI 主机放在 cam_clk 上，图的是"没有跨域"。两个问题：
//     1. 方向错了：挂的是 M_AXI_GP0，那是 PS 的出口（PS 当主机），
//        PL 的主机信号根本没进网表（详见 sdi_stream_wr.v 的文件头）。
//     2. 就算挂对了口，cam_clk 也不是稳的：失锁时会切到 clk200 兜底，
//        频率会变；AXI 接口上压着在途事务时换时钟 = 厂商文档里
//        L3/L4 那类挂死。
//   现在 AXI 侧用常驻的 clk_100m（PS 的 FCLK0 派生），像素只跨一次域。
//   64 bit × 100 MHz = 800 MB/s 上限，1080p30 只要 124.4 MB/s。
//
// 时钟域
//   clk200     200 MHz，clk_wiz_0 从 FCLK0 生成。SDI 参考时钟链，
//              以及 cam_clk 未锁定时的兜底。
//   cam_clk    rx0_locked ? rx_usrclk : clk200（rx_sdi 内部 mux）
//              -> 像素、测量、打包
//   clk_100m   100 MHz，clk_wiz_0 从 FCLK0 生成 -> 异步 FIFO 读侧、
//              写帧器、S_AXI_HP2
//   fclk0_clk  50 MHz -> 寄存器组
//============================================================================
`timescale 1ns / 1ps

module sdi_cap_top (
    // ---- 板载晶振 ----
    input  wire        sys_clk_p,
    input  wire        sys_clk_n,

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

    // ---- SDI 输入（GT lane 0 差分对）----
    input  wire        FMC_HPC_DP0_M2C_P,
    input  wire        FMC_HPC_DP0_M2C_N,
    // SDI 参考时钟，148.5 MHz 由跳线 J27 选进 GT bank
    input  wire        FMC_HPC_GBTCLK0_M2C_C_P,
    input  wire        FMC_HPC_GBTCLK0_M2C_C_N,

    // ---- PL LED ----
    output wire [1:0]  led
);

    //--------------------------------------------------------------------------
    // PS7 + 时钟
    //--------------------------------------------------------------------------
    wire        fclk0_clk;
    wire        clk200;
    wire        clk_100m;
    wire        pl_reset_n;
    wire        sys_rst_n = pl_reset_n;

    // ---- 写帧器 <-> S_AXI_HP2（只写通道，64 bit）----
    // 2026-10-15：从 GP0（32 bit，PS 当主机）改到 HP2（64 bit，PL 当主机）。
    wire [31:0] wr_awaddr;
    wire [5:0]  wr_awid;
    wire [3:0]  wr_awlen;
    wire [2:0]  wr_awsize;
    wire [1:0]  wr_awburst;
    wire        wr_awlock;
    wire [3:0]  wr_awcache;
    wire [2:0]  wr_awprot;
    wire [3:0]  wr_awqos;
    wire        wr_awvalid, wr_awready;
    wire [63:0] wr_wdata;   // HP2 是 64 bit 主机
    wire [7:0]  wr_wstrb;
    wire [5:0]  wr_wid;
    wire        wr_wlast, wr_wvalid, wr_wready;
    wire [5:0]  wr_bid;
    wire [1:0]  wr_bresp;
    wire        wr_bvalid, wr_bready;

    // ---- 寄存器块 <-> GP1（AXI4-Lite）----
    wire [31:0] m_awaddr, m_araddr;
    wire        m_awvalid, m_awready;
    wire [31:0] m_wdata;
    wire [3:0]  m_wstrb;
    wire        m_wvalid, m_wready;
    wire [1:0]  m_bresp;
    wire        m_bvalid, m_bready;
    wire [31:0] m_rdata;
    wire [1:0]  m_rresp;
    wire        m_arvalid, m_arready;
    wire        m_rvalid, m_rready;
    wire        cap_intr;

    sdi_cap_ps u_ps (
        .DDR_addr            (DDR_addr),
        .DDR_ba              (DDR_ba),
        .DDR_cas_n           (DDR_cas_n),
        .DDR_ck_n            (DDR_ck_n),
        .DDR_ck_p            (DDR_ck_p),
        .DDR_cke             (DDR_cke),
        .DDR_cs_n            (DDR_cs_n),
        .DDR_dm              (DDR_dm),
        .DDR_dq              (DDR_dq),
        .DDR_dqs_n           (DDR_dqs_n),
        .DDR_dqs_p           (DDR_dqs_p),
        .DDR_odt             (DDR_odt),
        .DDR_ras_n           (DDR_ras_n),
        .DDR_reset_n         (DDR_reset_n),
        .DDR_we_n            (DDR_we_n),
        .FIXED_IO_ddr_vrn    (FIXED_IO_ddr_vrn),
        .FIXED_IO_ddr_vrp    (FIXED_IO_ddr_vrp),
        .FIXED_IO_mio        (FIXED_IO_mio),
        .FIXED_IO_ps_clk     (FIXED_IO_ps_clk),
        .FIXED_IO_ps_srstb   (FIXED_IO_ps_srstb),
        .sys_clk_p           (sys_clk_p),
        .sys_clk_n           (sys_clk_n),
        .fclk0_clk           (fclk0_clk),
        .clk200              (clk200),
        .clk_100m            (clk_100m),
        .pl_reset_n          (pl_reset_n),

        .wr_awaddr           (wr_awaddr),
        .wr_awid             (wr_awid),
        .wr_awlen            (wr_awlen),
        .wr_awsize           (wr_awsize),
        .wr_awburst          (wr_awburst),
        .wr_awlock           (wr_awlock),
        .wr_awcache          (wr_awcache),
        .wr_awprot           (wr_awprot),
        .wr_awqos            (wr_awqos),
        .wr_awvalid          (wr_awvalid),
        .wr_wdata            (wr_wdata),
        .wr_wstrb            (wr_wstrb),
        .wr_wlast            (wr_wlast),
        .wr_wvalid           (wr_wvalid),
        .wr_wid              (wr_wid),
        .wr_awready          (wr_awready),
        .wr_wready           (wr_wready),
        .wr_bvalid           (wr_bvalid),
        .wr_bresp            (wr_bresp),
        .wr_bid              (wr_bid),
        .wr_bready           (wr_bready),

        .m_awaddr            (m_awaddr),
        .m_awvalid           (m_awvalid),
        .m_awready           (m_awready),
        .m_wdata             (m_wdata),
        .m_wstrb             (m_wstrb),
        .m_wvalid            (m_wvalid),
        .m_wready            (m_wready),
        .m_bresp             (m_bresp),
        .m_bvalid            (m_bvalid),
        .m_bready            (m_bready),
        .m_araddr            (m_araddr),
        .m_arvalid           (m_arvalid),
        .m_arready           (m_arready),
        .m_rdata             (m_rdata),
        .m_rresp             (m_rresp),
        .m_rvalid            (m_rvalid),
        .m_rready            (m_rready),
        .cap_intr            (cap_intr)
    );

    //--------------------------------------------------------------------------
    // SDI 接收器
    //--------------------------------------------------------------------------
    wire        rx_gtx_full_reset_n = sys_rst_n;
    wire        rx_gtx_reset_n      = 1'b1;
    wire        cam_hs, cam_vs, cam_data_en, cam_clk;
    wire [23:0] cam_rgb;
    wire [15:0] y422_data;
    wire        y422_vs, y422_hs, y422_de;
    wire [159:0] sdi_status_bus;
    wire        led_lock, led_clk_alive, led_unused;

    rx_sdi u_rx (
        .FMC_HPC_DP0_C2M_N          (),
        .FMC_HPC_DP0_C2M_P          (),
        .FMC_HPC_DP0_M2C_N          (FMC_HPC_DP0_M2C_N),
        .FMC_HPC_DP0_M2C_P          (FMC_HPC_DP0_M2C_P),
        .FMC_HPC_GBTCLK0_M2C_C_N    (FMC_HPC_GBTCLK0_M2C_C_N),
        .FMC_HPC_GBTCLK0_M2C_C_P    (FMC_HPC_GBTCLK0_M2C_C_P),
        .sys_clk_200m               (clk200),
        .sys_clk_100m               (clk_100m),
        .led1                       (led_clk_alive),
        .led2                       (led_unused),
        .led3                       (led_lock),
        .cam_hs                     (cam_hs),
        .cam_vs                     (cam_vs),
        .cam_rgb                    (cam_rgb),
        .cam_clk                    (cam_clk),
        .cam_data_en                (cam_data_en),
        .rx_gtx_full_reset_n        (rx_gtx_full_reset_n),
        .rx_gtx_reset_n             (rx_gtx_reset_n),
        .sdi_status_bus             (sdi_status_bus),
        .y422_data                  (y422_data),
        .y422_vs                    (y422_vs),
        .y422_hs                    (y422_hs),
        .y422_de                    (y422_de)
    );

    // led = {锁定, 心跳}：M6(led[1]) = SDI 传输帧锁定(rx0_locked)，
    //                    J1(led[0]) = 恢复时钟在跑(rx_usrclk_cnt[25] 心跳)
    // 与厂商 ai7030_edif_top.v 的 LED_MON=1 同向（{led3, led1}，led3 在高位）。
    // 灭/灭 = GT 没锁；闪/灭 = GT 有恢复时钟但认不出格式（相机可能切到 CVBS 了）。
    // （2026-10-16 更正：此前注释把 J1/M6 写反，位序以这里为准。）
    assign led = {led_lock, led_clk_alive};

    //--------------------------------------------------------------------------
    // 配置下发（50 MHz -> clk_100m / cam_clk）
    //   写帧器现在在 clk_100m 域、打包器在 cam_clk 域，同一份配置要分别
    //   同步到两个域。多 bit 载荷沿用原约定：软件先写数据寄存器、再写
    //   触发位，中间留够时间（见 sdi_cap_cdc 的模块注释）。
    //--------------------------------------------------------------------------
    wire        cfg_enable, cfg_rearm;
    wire [63:0] cfg_buf_addr;
    wire [31:0] cfg_ring_bytes;
    wire        p_enable;                 // cam_clk 域（测量模块用）
    wire        p_rearm;                  // clk_100m 域（写帧器用）
    wire        p_rearm_cam;              // cam_clk 域（打包器用）
    wire [63:0] p_addr;
    wire [31:0] p_ring;
    wire        px_overflow_cam;          // cam_clk 域：FIFO 满丢过字
    wire        px_overflow;              // clk_100m 域

    // ★ 2026-10-15 修：这七处原来写的是
    //       sdi_cap_cdc #(.W(1)) u_cdc_en (..., .d_bus({31'd0, cfg_enable}),
    //                                          .q_bus({31'd0, p_enable}));
    //   位宽参数是 W，而实例给的是 W(1) —— 却按 32 位拼接去接。综合器怎么说：
    //       WARNING: [Synth 8-689] width (32) of port connection 'd_bus' does not
    //                match port width (1) of module 'sdi_cap_cdc'
    //       WARNING: [Synth 8-2900] ignoring illegal expression in output port
    //                connection [sdi_cap_top.v:262]
    //   **输出口不允许接拼接**，所以那一整条表达式被丢掉：p_enable / p_rearm /
    //   p_rearm_cam / px_overflow / wr_idle / starving 全部悬空 —— 软件写 ENABLE
    //   传不到像素域（一帧都写不出来），丢字也报不出来（err_stat[0] 永远 0）。
    //   网表里连"p_enable"这个网都没有，见 probe5 的 D|NET 行。
    //   正确写法就是 1 bit 对 1 bit：这个模块的端口本来就是 [W-1:0]。
    sdi_cap_cdc #(.W(1))  u_cdc_en   (.clk_dst(cam_clk), .rst_dst_n(sys_rst_n),
                                      .d_bus(cfg_enable),
                                      .q_bus(p_enable));
    // ★ 2026-11-10 修 ★ cfg_rearm 是寄存器块给的**单拍脉冲**（写 A_REARM 那拍
    //   拉高一下）。原来两个都走 sdi_cap_cdc 两级电平同步：
    //     - u_cdc_re -> clk_100m：50 MHz 的一拍在 100 MHz 上跨两拍，碰巧能采到；
    //     - u_cdc_re_c -> cam_clk：HD 74.25 MHz 勉强，SD 13.5 MHz 时 20 ns 的
    //       脉冲整个落在两个 74 ns 采样沿之间，**约七成概率直接丢掉** ——
    //       打包器收不到 rearm，重配后第一帧的帧标记就错位。
    //   电平同步器本来就管不了单拍脉冲，正确工具是库里现成的
    //   sdi_cap_cdc_pulse（源域翻转 + 目的域边沿检测，任何频率都不丢），
    //   之前一直没被例化，这里用上。两个目的域都用它，语义统一。
    sdi_cap_cdc_pulse u_cdc_re   (.clk_src(fclk0_clk), .rst_src_n(sys_rst_n),
                                  .pulse_src(cfg_rearm),
                                  .clk_dst(clk_100m), .rst_dst_n(sys_rst_n),
                                  .pulse_dst(p_rearm));
    sdi_cap_cdc #(.W(96)) u_cdc_addr (.clk_dst(clk_100m), .rst_dst_n(sys_rst_n),
                                      .d_bus({cfg_buf_addr, cfg_ring_bytes}),
                                      .q_bus({p_addr, p_ring}));
    sdi_cap_cdc_pulse u_cdc_re_c (.clk_src(fclk0_clk), .rst_src_n(sys_rst_n),
                                  .pulse_src(cfg_rearm),
                                  .clk_dst(cam_clk), .rst_dst_n(sys_rst_n),
                                  .pulse_dst(p_rearm_cam));
    // 丢字是"置上就一直挂着"的粘滞电平，不是脉冲，两级同步足够
    sdi_cap_cdc #(.W(1))  u_cdc_ovf  (.clk_dst(clk_100m), .rst_dst_n(sys_rst_n),
                                      .d_bus(px_overflow_cam),
                                      .q_bus(px_overflow));

    //--------------------------------------------------------------------------
    // 测量（只上报，不筛选）
    //--------------------------------------------------------------------------
    wire        px_valid, line_start, frame_start;
    wire [15:0] meas_w, meas_h;
    wire [31:0] meas_fperiod, line_cnt;
    wire        meas_valid;
    wire        sig_locked;
    wire [31:0] frame_cnt_w;

    sdi_cap_meas u_meas (
        .clk          (cam_clk),
        .rst_n        (sys_rst_n),
        .pix          (y422_data),
        .pix_de       (y422_de),
        .pix_hs       (y422_hs),
        .pix_vs       (y422_vs),
        .sig_locked   (sig_locked),
        .cfg_enable   (p_enable),
        .px_valid     (px_valid),
        // ★ 2026-11-10 修 ★ px_data 原来接着 y422_data。它是 meas 的输出端口
        //   （assign px_data = pix 的直通），再把同一根输入网接回输出端口，
        //   等于自驱网；打包器实际用的是下一级的 y422_data（u_pack.px_data），
        //   所以这个连接既冗余又制造多驱动的隐患，删掉。
        .px_data      (),
        .line_start   (line_start),
        .frame_start  (frame_start),
        .meas_w       (meas_w),
        .meas_h       (meas_h),
        .meas_fperiod (meas_fperiod),
        .meas_valid   (meas_valid),
        .line_cnt     (line_cnt)
    );

    // sig_locked 只用于上报（"GT 活着但认不出格式"的判据），不参与数据门控
    sdi_cap_cdc #(.W(1)) u_cdc_lock (.clk_dst(cam_clk), .rst_dst_n(sys_rst_n),
                                     .d_bus(sdi_status_bus[5]), .q_bus(sig_locked));

    //--------------------------------------------------------------------------
    // 像素流三级：打包（cam_clk）-> 异步 FIFO -> 写帧器（clk_100m）
    //
    //   sdi_px_pack   4 个 16 bit 像素拼成 1 拍 64 bit，并带上帧标记
    //   sdi_px_afifo  格雷码指针的双时钟 FIFO（1024 拍 × 65 bit = 8 KB）
    //   sdi_stream_wr AXI4 主机（S_AXI_HP2，64 bit）
    //
    // 这一级跨域是**必须**的：AXI 侧不能跑恢复出来的像素时钟 —— 失锁时它会
    // 切到 clk200 兜底（换频），接口上还压着在途事务时换时钟就是厂商文档里
    // L3/L4 那类挂死。所以 AXI 侧用常驻的 clk_100m，像素只跨一次域。
    //--------------------------------------------------------------------------
    wire [64:0] px_word;          // {帧标记, 4 像素}
    wire        px_wen, px_wfull;
    wire [64:0] px_rdata;         // FIFO 同步读输出（rd_en 后下一拍有效）
    wire        px_ren, px_rempty;
    wire [10:0] px_rcount;
    wire [31:0] drop_lo;

    // 丢过字（FIFO 满）= 粘滞电平，进写帧器的 err_stat[0]
    assign px_overflow_cam = (drop_lo != 32'd0);

    sdi_px_pack u_pack (
        .clk         (cam_clk),
        .rst_n       (sys_rst_n),
        .rearm       (p_rearm_cam),
        .px_valid    (px_valid),
        .px_data     (y422_data),
        .frame_start (frame_start),
        .w_data      (px_word),
        .w_en        (px_wen),
        .w_full      (px_wfull),
        .drop_lo     (drop_lo)
    );

    sdi_px_afifo #(.W(65), .FD(10)) u_px_fifo (
        .wr_clk    (cam_clk),
        .wr_rst_n  (sys_rst_n),
        .wr_en     (px_wen),
        .wr_data   (px_word),
        .wr_full   (px_wfull),
        .rd_clk    (clk_100m),
        .rd_rst_n  (sys_rst_n),
        .rd_en     (px_ren),
        .rd_data   (px_rdata),
        .rd_empty  (px_rempty),
        .rd_count  (px_rcount)
    );

    //--------------------------------------------------------------------------
    // 连续写帧器（clk_100m 域，AXI4 主机 -> S_AXI_HP2）
    //--------------------------------------------------------------------------
    wire        wr_busy, starving_axi;
    wire        wr_idle_axi;      // clk_100m 域
    wire        wr_idle;          // 同步到 fclk0，给寄存器组读
    wire        starving;         // 同步到 fclk0
    wire [31:0] frame_start_addr, wr_addr_lo, beats_written, wr_err;

    sdi_stream_wr #(.AW_ADDR_W(32), .ID_W(6), .FD(10), .MAX_OUT(8)) u_wr (
        .clk             (clk_100m),
        .rst_n           (sys_rst_n),
        .px_rd_en        (px_ren),
        .px_rd_data      (px_rdata),
        .px_rd_empty     (px_rempty),
        .px_rd_count     (px_rcount),
        .cfg_rearm       (p_rearm),
        .cfg_buf_addr    (p_addr),
        .cfg_ring_bytes  (p_ring),
        .px_overflow     (px_overflow),
        .m_axi_awaddr    (wr_awaddr),
        .m_axi_awvalid   (wr_awvalid),
        .m_axi_awready   (wr_awready),
        .m_axi_awid      (wr_awid),
        .m_axi_awlen     (wr_awlen),
        .m_axi_awsize    (wr_awsize),
        .m_axi_awburst   (wr_awburst),
        .m_axi_awlock    (wr_awlock),
        .m_axi_awcache   (wr_awcache),
        .m_axi_awprot    (wr_awprot),
        .m_axi_awqos     (wr_awqos),
        .m_axi_wvalid    (wr_wvalid),
        .m_axi_wready    (wr_wready),
        .m_axi_wdata     (wr_wdata),
        .m_axi_wstrb     (wr_wstrb),
        .m_axi_wlast     (wr_wlast),
        .m_axi_wid       (wr_wid),
        .m_axi_bvalid    (wr_bvalid),
        .m_axi_bready    (wr_bready),
        .m_axi_bresp     (wr_bresp),
        .busy            (wr_busy),
        .frame_cnt       (frame_cnt_w),
        .frame_start_addr(frame_start_addr),
        .wr_addr_lo      (wr_addr_lo),
        .beats_written   (beats_written),
        .err_stat        (wr_err),
        .inflight        (),
        .starving        (starving_axi),
        .idle            (wr_idle_axi)
    );

    // 写帧器的"已排空"状态。这颗芯片的 PS 侧**看不到** HP 口上的在途事务数
    // （厂商 2026-10-12 客户说明：不提供 S_AXI_HP*_RCOUNT/RACOUNT），
    // 所以复位 / 重配置 PL 之前判空只能靠 PL 自己报出来的这一位。
    // 单 bit 两级同步，跨域安全。
    sdi_cap_cdc #(.W(1))  u_cdc_idle (.clk_dst(fclk0_clk), .rst_dst_n(sys_rst_n),
                                      .d_bus(wr_idle_axi),
                                      .q_bus(wr_idle));
    sdi_cap_cdc #(.W(1))  u_cdc_star (.clk_dst(fclk0_clk), .rst_dst_n(sys_rst_n),
                                      .d_bus(starving_axi),
                                      .q_bus(starving));

    //--------------------------------------------------------------------------
    // 寄存器组
    //--------------------------------------------------------------------------
    sdi_cap_regs u_regs (
        .s_axi_aclk        (fclk0_clk),
        .s_axi_aresetn     (sys_rst_n),
        .s_axi_awaddr      (m_awaddr[11:0]),
        .s_axi_awvalid     (m_awvalid),
        .s_axi_awready     (m_awready),
        .s_axi_wdata       (m_wdata),
        .s_axi_wstrb       (m_wstrb),
        .s_axi_wvalid      (m_wvalid),
        .s_axi_wready      (m_wready),
        .s_axi_bresp       (m_bresp),
        .s_axi_bvalid      (m_bvalid),
        .s_axi_bready      (m_bready),
        .s_axi_araddr      (m_araddr[11:0]),
        .s_axi_arvalid     (m_arvalid),
        .s_axi_arready     (m_arready),
        .s_axi_rdata       (m_rdata),
        .s_axi_rresp       (m_rresp),
        .s_axi_rvalid      (m_rvalid),
        .s_axi_rready      (m_rready),
        .s_axi_intr        (cap_intr),
        .meas_w            (meas_w),
        .meas_h            (meas_h),
        .meas_fperiod      (meas_fperiod),
        .meas_valid        (meas_valid),
        .sig_locked        (sig_locked),
        .line_cnt          (line_cnt),
        .frame_cnt         (frame_cnt_w),
        .frame_start_addr  (frame_start_addr),
        .wr_addr           (wr_addr_lo),
        .beats_written     (beats_written),
        .wr_err            (wr_err),
        .starving          (starving),
        .wr_busy           (wr_busy),
        .wr_idle           (wr_idle),
        .sdi_status_bus    (sdi_status_bus),
        .cfg_enable        (cfg_enable),
        .cfg_rearm         (cfg_rearm),
        .cfg_buf_addr      (cfg_buf_addr),
        .cfg_ring_bytes    (cfg_ring_bytes)
    );

endmodule