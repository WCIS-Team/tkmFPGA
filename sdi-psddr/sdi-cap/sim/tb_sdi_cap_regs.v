//============================================================================
// tb_sdi_cap_regs -- sdi_cap_regs（AXI4-Lite 控制/状态块）的回归
//
// 为什么要有它：**这个块此前一行仿真都没有**。
//   像素链有 tb_sdi_stream_wr 覆盖，但 PS 唯一直接接触的接口就是这里。
//   2026-10-15 一天里在它身上挖出三个 bug：
//     - 应答方向写反（GP1 整条路死）        -> 见 设计说明.md §6.20
//     - 读通道 ARREADY 写成 ~ARVALID（死锁） -> §6.24
//     - 帧率除法取错寄存器（FPS_X100 恒 0）  -> §6.23
//   三个都不影响位流生成、DRC、时序。能抓住它们的只有这一层仿真。
//
// 被测接口：真实的 AXI4-Lite 主模型（AW/W 分开、VALID 举两拍、
//           READY 等 BVALID/RVALID 回来才撤），不是理想化的 task。
//
// 检查项：
//   1) ID/VERSION 魔数；RO 寄存器写不进去
//   2) BUF_ADDR / RING_BYTES / CTRL 下发到 cfg_* 端口对不对；REARM 是 1 拍脉冲
//   3) FPS_X100 = PIXCLK_HZ*100/MEAS_FPER（25/30/未知三档），EXP_FPS 对比
//   4) 状态位映射（STATUS 每一位）、WR_IDLE
//   5) INT_STATUS 写 1 清零；ERR_STAT **写不进去**（清零靠 REARM，见寄存器手册）
//   6) IRQ 输出 = |(INT_STATUS & INT_ENABLE) & IRQ_EN
//   7) MEAS_W/H -> ROW_BYTES/FRAME_BYTES 的乘法（1920x1080 -> 0x3F4800）
//
// 参数：无（不走 bench.txt）。运行：run_bench.ps1 的最后一段。
//============================================================================
`timescale 1ns / 1ps

module tb_sdi_cap_regs;

    //--------------------------------------------------------------------------
    // 时钟 / 复位：FCLK0 = 50 MHz
    //--------------------------------------------------------------------------
    reg clk = 1'b0;
    always #10 clk = ~clk;

    reg rst_n = 1'b0;
    integer gcyc = 0;
    always @(posedge clk) gcyc <= gcyc + 1;

    //--------------------------------------------------------------------------
    // AXI4-Lite 主模型
    //--------------------------------------------------------------------------
    reg  [11:0] awaddr  = 12'd0;
    reg         awvalid = 1'b0;
    reg  [31:0] wdata   = 32'd0;
    reg  [3:0]  wstrb   = 4'hF;
    reg         wvalid  = 1'b0;
    wire        awready, wready;
    wire        bvalid;
    wire [1:0]  bresp;
    reg         bready  = 1'b0;

    reg  [11:0] araddr  = 12'd0;
    reg         arvalid = 1'b0;
    wire        arready;
    wire        rvalid;
    wire [31:0] rdata;
    wire [1:0]  rresp;
    reg         rready  = 1'b0;
    wire        intr;

    //--------------------------------------------------------------------------
    // 像素域状态（TB 直驱）
    //--------------------------------------------------------------------------
    reg  [15:0] meas_w        = 16'd0;
    reg  [15:0] meas_h        = 16'd0;
    reg  [31:0] meas_fperiod  = 32'd0;
    reg         meas_valid    = 1'b0;
    reg         sig_locked    = 1'b0;
    reg  [31:0] line_cnt      = 32'd0;
    reg  [31:0] frame_cnt     = 32'd0;
    reg  [31:0] frame_start_addr = 32'd0;
    reg  [31:0] wr_addr       = 32'd0;
    reg  [31:0] beats_written = 32'd0;
    reg  [31:0] wr_err        = 32'd0;
    reg         starving      = 1'b0;
    reg         wr_busy       = 1'b0;
    reg         wr_idle       = 1'b0;
    reg  [159:0] sdi_status_bus = 160'd0;

    wire        cfg_enable;
    wire        cfg_rearm;
    wire [63:0] cfg_buf_addr;
    wire [31:0] cfg_ring_bytes;

    sdi_cap_regs #(.C_S_AXI_ADDR_WIDTH(12)) dut (
        .s_axi_aclk    (clk),
        .s_axi_aresetn (rst_n),
        .s_axi_awaddr  (awaddr),
        .s_axi_awvalid (awvalid),
        .s_axi_awready (awready),
        .s_axi_wdata   (wdata),
        .s_axi_wstrb   (wstrb),
        .s_axi_wvalid  (wvalid),
        .s_axi_wready  (wready),
        .s_axi_bresp   (bresp),
        .s_axi_bvalid  (bvalid),
        .s_axi_bready  (bready),
        .s_axi_araddr  (araddr),
        .s_axi_arvalid (arvalid),
        .s_axi_arready (arready),
        .s_axi_rdata   (rdata),
        .s_axi_rresp   (rresp),
        .s_axi_rvalid  (rvalid),
        .s_axi_rready  (rready),
        .s_axi_intr    (intr),
        .meas_w        (meas_w),
        .meas_h        (meas_h),
        .meas_fperiod  (meas_fperiod),
        .meas_valid    (meas_valid),
        .sig_locked    (sig_locked),
        .line_cnt      (line_cnt),
        .frame_cnt     (frame_cnt),
        .frame_start_addr (frame_start_addr),
        .wr_addr       (wr_addr),
        .beats_written (beats_written),
        .wr_err        (wr_err),
        .starving      (starving),
        .wr_busy       (wr_busy),
        .wr_idle       (wr_idle),
        .sdi_status_bus(sdi_status_bus),
        .cfg_enable    (cfg_enable),
        .cfg_rearm     (cfg_rearm),
        .cfg_buf_addr  (cfg_buf_addr),
        .cfg_ring_bytes(cfg_ring_bytes)
    );

    //--------------------------------------------------------------------------
    // 寄存器偏移（低 12 位；PS 侧真实地址是 0x8000_0000 + 偏移）
    //--------------------------------------------------------------------------
    localparam [11:0] R_ID         = 12'h000;
    localparam [11:0] R_VERSION    = 12'h004;
    localparam [11:0] R_CTRL       = 12'h008;
    localparam [11:0] R_STATUS     = 12'h00C;
    localparam [11:0] R_MEAS_W     = 12'h010;
    localparam [11:0] R_MEAS_H     = 12'h014;
    localparam [11:0] R_MEAS_FPER  = 12'h018;
    localparam [11:0] R_FPS_X100   = 12'h01C;
    localparam [11:0] R_RX_MODE    = 12'h020;
    localparam [11:0] R_RX_FAMILY  = 12'h024;
    localparam [11:0] R_RX_RATE    = 12'h028;
    localparam [11:0] R_EXP_FPS    = 12'h02C;
    localparam [11:0] R_FPS_CLASS  = 12'h030;
    localparam [11:0] R_FPS_MATCH  = 12'h034;
    localparam [11:0] R_ROW_BYTES  = 12'h038;
    localparam [11:0] R_FRAME_BYTES= 12'h03C;
    localparam [11:0] R_BUF_ADDR_L = 12'h040;
    localparam [11:0] R_BUF_ADDR_H = 12'h044;
    localparam [11:0] R_REARM      = 12'h048;
    localparam [11:0] R_FRAME_CNT  = 12'h04C;
    localparam [11:0] R_FRAME_ADDR = 12'h050;
    localparam [11:0] R_WR_ADDR    = 12'h054;
    localparam [11:0] R_BEATS      = 12'h058;
    localparam [11:0] R_ERR_STAT   = 12'h05C;
    localparam [11:0] R_INT_STATUS = 12'h060;
    localparam [11:0] R_INT_ENABLE = 12'h064;
    localparam [11:0] R_PIXCLK_HZ  = 12'h068;
    localparam [11:0] R_RING_BYTES = 12'h06C;
    localparam [11:0] R_LINE_CNT   = 12'h070;
    localparam [11:0] R_WR_IDLE    = 12'h074;

    integer errs = 0;
    integer to_cnt;

    //--------------------------------------------------------------------------
    // AXI4-Lite 主模型：写
    //   VALID 举两拍（从设备在第二拍采样），再等 BVALID 回来才撤 BREADY。
    //   每个等待都有超时，坏掉时报告 FAIL 而不是把仿真挂住。
    //--------------------------------------------------------------------------
    task axi_wr(input [11:0] a, input [31:0] d);
        begin
            @(posedge clk);
            awaddr  <= a;
            awvalid <= 1'b1;
            wdata   <= d;
            wstrb   <= 4'hF;
            wvalid  <= 1'b1;
            @(posedge clk);                 // 握手在这一拍被从设备采样
            awvalid <= 1'b0;
            wvalid  <= 1'b0;

            to_cnt = 0;
            while (!bvalid && to_cnt < 200) begin
                @(posedge clk);
                to_cnt = to_cnt + 1;
            end
            if (!bvalid) begin
                errs = errs + 1;
                $display("  FAIL WR %03h: BVALID timeout", a);
            end else if (bresp !== 2'b00) begin
                errs = errs + 1;
                $display("  FAIL WR %03h: BRESP=%b", a, bresp);
            end
            bready <= 1'b1;
            @(posedge clk);
            bready <= 1'b0;
        end
    endtask

    //--------------------------------------------------------------------------
    // AXI4-Lite 主模型：读
    //--------------------------------------------------------------------------
    task axi_rd(input [11:0] a, output [31:0] d);
        begin
            @(posedge clk);
            araddr  <= a;
            arvalid <= 1'b1;
            @(posedge clk);                 // 握手在这一拍被从设备采样
            arvalid <= 1'b0;

            to_cnt = 0;
            while (!rvalid && to_cnt < 200) begin
                @(posedge clk);
                to_cnt = to_cnt + 1;
            end
            if (!rvalid) begin
                errs = errs + 1;
                $display("  FAIL RD %03h: RVALID timeout (ARREADY deadlock?)", a);
                d = 32'hxxxx_xxxx;
            end else begin
                d = rdata;
                if (rresp !== 2'b00) begin
                    errs = errs + 1;
                    $display("  FAIL RD %03h: RRESP=%b", a, rresp);
                end
            end
            rready <= 1'b1;
            @(posedge clk);
            rready <= 1'b0;
        end
    endtask

    // 等 n 拍
    task wait_cyc(input integer n);
        integer i;
        begin
            for (i = 0; i < n; i = i + 1) @(posedge clk);
        end
    endtask

    //--------------------------------------------------------------------------
    // 比较
    //--------------------------------------------------------------------------
`define CK32(nm, got, exp) \
        if ((got) !== (exp)) begin \
            errs = errs + 1; \
            $display("  FAIL %0s: got=%08h exp=%08h", nm, got, exp); \
        end else \
            $display("  ok   %0s = %08h", nm, got)

`define CK64(nm, got, exp) \
        if ((got) !== (exp)) begin \
            errs = errs + 1; \
            $display("  FAIL %0s: got=%016h exp=%016h", nm, got, exp); \
        end else \
            $display("  ok   %0s = %016h", nm, got)
// 注意：else 分支是单条语句，所以调用处写 `CK32(...); 时那个分号属于
// $display，而不是一个"空语句"（否则 xvlog 报 [VRFC 10-2096]）。

    //--------------------------------------------------------------------------
    // 主流程
    //--------------------------------------------------------------------------
    reg [31:0] d, d2;
    integer i, rearm_pulse;

    initial begin
        $display("=== tb_sdi_cap_regs ===");

        rst_n = 1'b0;
        wait_cyc(10);
        rst_n = 1'b1;
        wait_cyc(4);

        //----------------------------------------------------------------------
        $display("-- 1. magic ID / read-only --");
        //----------------------------------------------------------------------
        axi_rd(R_ID, d);
        `CK32("ID", d, 32'h53444943);
        axi_rd(R_VERSION, d);
        `CK32("VERSION", d, 32'h0001_0000);
        axi_wr(R_ID, 32'hDEAD_BEEF);          // RO 寄存器：写应当被忽略
        axi_rd(R_ID, d);
        `CK32("ID after write", d, 32'h53444943);
        axi_rd(R_CTRL, d);
        `CK32("CTRL reset", d, 32'h0);
        axi_rd(R_PIXCLK_HZ, d);
        `CK32("PIXCLK_HZ reset", d, 32'd74_250_000);

        //----------------------------------------------------------------------
        $display("-- 2. config / REARM / enable --");
        //----------------------------------------------------------------------
        axi_wr(R_BUF_ADDR_L, 32'h1000_0000);
        axi_wr(R_BUF_ADDR_H, 32'h0000_0002);
        wait_cyc(2);
        `CK64("cfg_buf_addr", cfg_buf_addr, 64'h0000_0002_1000_0000);
        axi_rd(R_BUF_ADDR_L, d);
        `CK32("BUF_ADDR_L rd", d, 32'h1000_0000);
        axi_rd(R_BUF_ADDR_H, d);
        `CK32("BUF_ADDR_H rd", d, 32'h0000_0002);

        axi_wr(R_RING_BYTES, 32'h0200_0000);
        wait_cyc(2);
        `CK32("cfg_ring_bytes", cfg_ring_bytes, 32'h0200_0000);
        axi_rd(R_RING_BYTES, d);
        `CK32("RING_BYTES rd", d, 32'h0200_0000);

        axi_wr(R_CTRL, 32'h0000_0003);        // ENABLE | IRQ_EN
        wait_cyc(2);
        `CK32("cfg_enable", {31'd0, cfg_enable}, 32'd1);
        axi_rd(R_CTRL, d);
        `CK32("CTRL rd", d, 32'h0000_0003);

        // REARM：从设备侧应当是一拍脉冲
        rearm_pulse = 0;
        fork
            begin : rearm_mon
                for (i = 0; i < 40; i = i + 1) begin
                    @(posedge clk);
                    if (cfg_rearm) rearm_pulse = rearm_pulse + 1;
                end
            end
            begin : rearm_do
                axi_wr(R_REARM, 32'd1);
            end
        join
        if (rearm_pulse == 1) $display("  ok   cfg_rearm = 1-cycle pulse");
        else begin errs = errs + 1; $display("  FAIL cfg_rearm pulses = %0d (expect 1)", rearm_pulse); end

        //----------------------------------------------------------------------
        $display("-- 3. FPS_X100 = PIXCLK_HZ*100/MEAS_FPER --");
        //----------------------------------------------------------------------
        axi_wr(R_PIXCLK_HZ, 32'd74_250_000);
        axi_rd(R_PIXCLK_HZ, d);
        `CK32("PIXCLK_HZ rd", d, 32'd74_250_000);

        // 1080p25：帧周期 74.25e6/25 = 2_970_000 像素时钟 -> 25.00 fps
        meas_fperiod = 32'd2_970_000;
        wait_cyc(120);                        // 除法 64 拍 + 余量
        axi_rd(R_MEAS_FPER, d);
        `CK32("MEAS_FPER rd", d, 32'd2_970_000);
        axi_rd(R_FPS_X100, d);
        `CK32("FPS_X100 @1080p25", d, 32'd2500);
        axi_rd(R_FPS_CLASS, d);
        `CK32("FPS_CLASS @1080p25", d, 32'd1);
        axi_rd(R_FPS_MATCH, d);
        `CK32("FPS_MATCH (EXP=unspec)", d, 32'd1);

        axi_wr(R_EXP_FPS, 32'd1);             // 软件声明 25
        wait_cyc(4);
        axi_rd(R_FPS_MATCH, d);
        `CK32("FPS_MATCH (EXP=25)", d, 32'd1);
        axi_wr(R_EXP_FPS, 32'd2);             // 软件声明 30 -> 应当不匹配
        wait_cyc(4);
        axi_rd(R_FPS_MATCH, d);
        `CK32("FPS_MATCH (EXP=30, measured 25)", d, 32'd0);

        // 1080p30：74.25e6/30 = 2_475_000 -> 30.00 fps
        meas_fperiod = 32'd2_475_000;
        wait_cyc(120);
        axi_rd(R_FPS_X100, d);
        `CK32("FPS_X100 @1080p30", d, 32'd3000);
        axi_rd(R_FPS_CLASS, d);
        `CK32("FPS_CLASS @1080p30", d, 32'd2);
        axi_rd(R_FPS_MATCH, d);
        `CK32("FPS_MATCH (EXP=30)", d, 32'd1);

        // 怪周期：74.25e6/1_500_000 = 49.5 fps -> 归到 50 那一档（不是"未知"）
        meas_fperiod = 32'd1_500_000;
        wait_cyc(120);
        axi_rd(R_FPS_X100, d);
        `CK32("FPS_X100 @49.5fps", d, 32'd4950);
        axi_rd(R_FPS_CLASS, d);
        `CK32("FPS_CLASS @49.5fps -> 50", d, 32'd3);

        //----------------------------------------------------------------------
        $display("-- 4. geometry / derived byte counts --");
        //----------------------------------------------------------------------
        meas_w = 16'd1920;
        meas_h = 16'd1080;
        meas_valid = 1'b1;
        wait_cyc(4);
        axi_rd(R_MEAS_W, d);
        `CK32("MEAS_W", d, 32'd1920);
        axi_rd(R_MEAS_H, d);
        `CK32("MEAS_H", d, 32'd1080);
        axi_rd(R_ROW_BYTES, d);
        `CK32("ROW_BYTES = W*2", d, 32'd3840);
        axi_rd(R_FRAME_BYTES, d);
        `CK32("FRAME_BYTES = H*W*2", d, 32'd4_147_200);   // 0x3F4800

        //----------------------------------------------------------------------
        $display("-- 5. STATUS / WR_IDLE / counter passthrough --");
        //----------------------------------------------------------------------
        starving      = 1'b1;
        sig_locked    = 1'b1;
        wr_busy       = 1'b1;
        wr_err        = 32'h0000_0002;        // bit1 = AXI_RESP
        frame_cnt     = 32'd7;
        frame_start_addr = 32'h0012_3400;
        wr_addr       = 32'h0012_3450;
        beats_written = 32'h0001_2345;
        line_cnt      = 32'h0000_0439;
        wr_idle       = 1'b1;
        wait_cyc(4);
        // bit13=wr_err, bit12=starving, bit11=meas_valid, bit10=sig_locked,
        // bit9=wr_busy, bit8=r_enable(=1)
        axi_rd(R_STATUS, d);
        `CK32("STATUS", d, 32'h0000_3F00);
        axi_rd(R_WR_IDLE, d);
        `CK32("WR_IDLE", d, 32'h0000_0001);
        axi_rd(R_FRAME_CNT, d);
        `CK32("FRAME_CNT", d, 32'd7);
        axi_rd(R_FRAME_ADDR, d);
        `CK32("FRAME_ADDR", d, 32'h0012_3400);
        axi_rd(R_WR_ADDR, d);
        `CK32("WR_ADDR", d, 32'h0012_3450);
        axi_rd(R_BEATS, d);
        `CK32("BEATS", d, 32'h0001_2345);
        axi_rd(R_LINE_CNT, d);
        `CK32("LINE_CNT", d, 32'h0000_0439);

        //----------------------------------------------------------------------
        $display("-- 6. INT_STATUS W1C / ERR_STAT RO / IRQ --");
        //----------------------------------------------------------------------
        axi_rd(R_INT_STATUS, d);
        // frame_cnt 从 0 -> 7 触发 bit0；wr_err!=0 触发 bit1；
        // starving 触发 bit2；!sig_locked 期间触发 bit3（这里 sig_locked 变了）
        `CK32("INT_STATUS bit0 frame", (d & 32'h1), 32'h1);
        `CK32("INT_STATUS bit1 wr_err", (d & 32'h2), 32'h2);

        axi_rd(R_ERR_STAT, d);
        `CK32("ERR_STAT = wr_err", d, 32'h0000_0002);
        axi_wr(R_ERR_STAT, 32'hFFFF_FFFF);    // 写它**没有**用（清零靠 REARM）
        wait_cyc(4);
        axi_rd(R_ERR_STAT, d);
        `CK32("ERR_STAT after write (unchanged)", d, 32'h0000_0002);

        axi_wr(R_INT_ENABLE, 32'h0000_0001);
        axi_wr(R_CTRL, 32'h0000_0003);        // IRQ_EN = 1
        wait_cyc(4);
        axi_rd(R_INT_STATUS, d2);
        if (d2[0] && intr === 1'b1) $display("  ok   IRQ = |(INT_STATUS & INT_ENABLE) & IRQ_EN");
        else begin errs = errs + 1; $display("  FAIL IRQ: INT_STATUS=%08h intr=%b", d2, intr); end

        // W1C 只能清掉"原因已经消失"的那些位：bit0（帧来过）当场就清，
        // bit1/bit2 因为 wr_err / starving 还举着，本拍又被置回。
        axi_wr(R_INT_STATUS, 32'hFFFF_FFFF);
        wait_cyc(4);
        axi_rd(R_INT_STATUS, d);
        `CK32("W1C cleared bit0", (d & 32'h1), 32'h0);
        `CK32("W1C left bit1|bit2 (cause alive)", (d & 32'h6), 32'h6);
        // INT_ENABLE 只开了 bit0，bit0 一清 IRQ 就掉；bit1/2 虽然还亮着，但被屏蔽
        if (intr === 1'b0) $display("  ok   IRQ low (bit0 cleared, bit1/2 masked)");
        else begin errs = errs + 1; $display("  FAIL IRQ high although bit0 cleared: %b", intr); end
        axi_wr(R_INT_ENABLE, 32'h0000_0006);   // 把 bit1/bit2 也放进来
        wait_cyc(4);
        if (intr === 1'b1) $display("  ok   IRQ high via bit1/2 (mask now open)");
        else begin errs = errs + 1; $display("  FAIL IRQ low although bit1/2 enabled: %b", intr); end

        // 原因消掉再 W1C -> 全 0，IRQ 归 0
        wr_err   = 32'd0;
        starving = 1'b0;
        wait_cyc(4);
        axi_wr(R_INT_STATUS, 32'hFFFF_FFFF);
        wait_cyc(4);
        axi_rd(R_INT_STATUS, d);
        `CK32("INT_STATUS after cause clear + W1C", d, 32'h0);
        if (intr === 1'b0) $display("  ok   IRQ low after clear");
        else begin errs = errs + 1; $display("  FAIL IRQ still %b after clear", intr); end

        //----------------------------------------------------------------------
        $display("-- 7. RX status bus mapping --");
        //----------------------------------------------------------------------
        sdi_status_bus = 160'd0;
        sdi_status_bus[6]  = 1'b1;            // mode[0]
        sdi_status_bus[9]  = 1'b1;            // mode[2]
        sdi_status_bus[11] = 1'b1;            // rate
        sdi_status_bus[15] = 1'b1;            // family
        sdi_status_bus[16] = 1'b1;
        wait_cyc(4);
        axi_rd(R_RX_MODE, d);
        `CK32("RX_MODE", d, 32'h0000_0005);   // {mode[2], mode[1:0]} = 101
        axi_rd(R_RX_RATE, d);
        `CK32("RX_RATE", d, 32'h0000_0001);
        axi_rd(R_RX_FAMILY, d);
        `CK32("RX_FAMILY", d, 32'h0000_0003);

        //----------------------------------------------------------------------
        $display("-- 8. after reset: bogus short period -> FPS_X100 stays 0 --");
        //----------------------------------------------------------------------
        meas_fperiod = 32'd297;               // 荒唐的小周期
        rst_n = 1'b0;
        wait_cyc(6);
        rst_n = 1'b1;
        wait_cyc(120);
        axi_rd(R_FPS_X100, d);
        `CK32("FPS_X100 (period 297)", d, 32'h0);
        axi_rd(R_FPS_CLASS, d);
        `CK32("FPS_CLASS (period 297)", d, 32'd0);
        // REARM 会清计数器（写帧器侧），这里只验证软件写 REARM 不报错

        //----------------------------------------------------------------------
        if (errs == 0) $display("REGS RESULT: PASS");
        else           $display("REGS RESULT: FAIL (%0d checks)", errs);
        $display("=== tb_sdi_cap_regs done ===");
        $finish;
    end

    // 总超时保护：正常跑完约 3~4 千拍
    initial begin
        #4_000_000;
        $display("REGS RESULT: FAIL (global timeout)");
        $finish;
    end

endmodule
