//============================================================================
// sdi_cap_regs -- 数据搬运通路的 AXI4-Lite 控制/状态块。
//
// 设计原则（与 sdi_stream_wr 一致）：**PL 不做任何格式判断**。
//   寄存器里没有"目标幅面""目标帧率"这类会影响数据通路的配置。
//   软件想知道源是什么，读 MEAS_* / FPS_X100 / RX_* 即可；
//   写入侧只有三件事有意义：开/关、缓冲区在哪、环多大。
//
// 时钟域
//   s_axi_aclk  FCLK0 50 MHz。CSR 和状态在这里。
//   像素域的状态（帧计数、写地址、累计拍数）全部是**自由运行计数器**，
//   跨域过来只读不写，读者做差值，所以撕裂读最多丢/重一次增量，安全。
//============================================================================
`timescale 1ns / 1ps

module sdi_cap_regs #(
    parameter integer C_S_AXI_ADDR_WIDTH = 12
)(
    // ---- AXI4-Lite 从口（PS -> PL）----
    input  wire                              s_axi_aclk,
    input  wire                              s_axi_aresetn,
    input  wire [C_S_AXI_ADDR_WIDTH-1:0]     s_axi_awaddr,
    input  wire                              s_axi_awvalid,
    output wire                              s_axi_awready,
    input  wire [31:0]                       s_axi_wdata,
    input  wire [3:0]                        s_axi_wstrb,
    input  wire                              s_axi_wvalid,
    output wire                              s_axi_wready,
    output reg  [1:0]                        s_axi_bresp,
    output reg                               s_axi_bvalid,
    input  wire                              s_axi_bready,
    input  wire [C_S_AXI_ADDR_WIDTH-1:0]     s_axi_araddr,
    input  wire                              s_axi_arvalid,
    output wire                              s_axi_arready,
    output reg  [31:0]                       s_axi_rdata,
    output reg  [1:0]                        s_axi_rresp,
    output reg                               s_axi_rvalid,
    input  wire                              s_axi_rready,
    output wire                              s_axi_intr,

    // ---- 像素域状态（自由运行计数器，跨域只读）----
    input  wire  [15:0]                      meas_w,
    input  wire  [15:0]                      meas_h,
    input  wire  [31:0]                      meas_fperiod,
    input  wire                              meas_valid,
    input  wire                              sig_locked,
    input  wire  [31:0]                      line_cnt,
    input  wire  [31:0]                      frame_cnt,
    input  wire  [31:0]                      frame_start_addr,
    input  wire  [31:0]                      wr_addr,
    input  wire  [31:0]                      beats_written,
    input  wire  [31:0]                      wr_err,
    input  wire                              starving,
    input  wire                              wr_busy,
    input  wire                              wr_idle,

    // ---- SDI 接收器状态总线（sdi_status.v，已经 CDC 到 s_axi_aclk）----
    input  wire  [159:0]                     sdi_status_bus,

    // ---- 配置下发到像素域 ----
    output wire                              cfg_enable,
    output wire                              cfg_rearm,
    output wire  [63:0]                      cfg_buf_addr,
    output wire  [31:0]                      cfg_ring_bytes
);

    //--------------------------------------------------------------------------
    // 寄存器地址
    //--------------------------------------------------------------------------
    localparam [7:0] A_ID          = 8'h00;
    localparam [7:0] A_VERSION     = 8'h04;
    localparam [7:0] A_CTRL        = 8'h08;
    localparam [7:0] A_STATUS      = 8'h0C;
    localparam [7:0] A_MEAS_W      = 8'h10;
    localparam [7:0] A_MEAS_H      = 8'h14;
    localparam [7:0] A_MEAS_FPER   = 8'h18;
    localparam [7:0] A_FPS_X100    = 8'h1C;
    localparam [7:0] A_RX_MODE     = 8'h20;
    localparam [7:0] A_RX_FAMILY   = 8'h24;
    localparam [7:0] A_RX_RATE     = 8'h28;
    localparam [7:0] A_EXP_FPS     = 8'h2C;   // 软件声明的期望，仅供对比
    localparam [7:0] A_FPS_CLASS   = 8'h30;
    localparam [7:0] A_FPS_MATCH   = 8'h34;
    localparam [7:0] A_ROW_BYTES   = 8'h38;
    localparam [7:0] A_FRAME_BYTES = 8'h3C;
    localparam [7:0] A_BUF_ADDR_L  = 8'h40;
    localparam [7:0] A_BUF_ADDR_H  = 8'h44;
    localparam [7:0] A_REARM       = 8'h48;
    localparam [7:0] A_FRAME_CNT   = 8'h4C;
    localparam [7:0] A_FRAME_ADDR  = 8'h50;
    localparam [7:0] A_WR_ADDR     = 8'h54;
    localparam [7:0] A_BEATS       = 8'h58;
    localparam [7:0] A_ERR_STAT    = 8'h5C;
    localparam [7:0] A_INT_STATUS  = 8'h60;
    localparam [7:0] A_INT_ENABLE  = 8'h64;
    localparam [7:0] A_PIXCLK_HZ   = 8'h68;
    localparam [7:0] A_RING_BYTES  = 8'h6C;
    localparam [7:0] A_LINE_CNT    = 8'h70;
localparam [7:0] A_WR_IDLE     = 8'h74;   // bit0 = 写帧器已排空（可安全复位/重配置）

    localparam [31:0] MAGIC_ID  = 32'h53444943;   // 'SDIC'
    localparam [31:0] MAGIC_VER = 32'h0001_0000;

    //--------------------------------------------------------------------------
    // AXI4-Lite 写通道：地址和数据分别锁存，允许 AW/W 错拍
    //--------------------------------------------------------------------------
    reg        aw_hold_v;
    reg [7:0]  aw_hold_a;
    reg        w_hold_v;
    reg [31:0] w_hold_d;
    wire       w_commit = aw_hold_v & w_hold_v;

    assign s_axi_awready = ~aw_hold_v;
    assign s_axi_wready  = ~w_hold_v;

    always @(posedge s_axi_aclk) begin
        if (!s_axi_aresetn) begin
            aw_hold_v <= 1'b0;
            aw_hold_a <= 8'h00;
            w_hold_v  <= 1'b0;
            w_hold_d  <= 32'd0;
        end else begin
            if (s_axi_awvalid && s_axi_awready) begin
                aw_hold_v <= 1'b1;
                aw_hold_a <= s_axi_awaddr[7:0];
            end
            if (s_axi_wvalid && s_axi_wready) begin
                w_hold_v <= 1'b1;
                w_hold_d <= s_axi_wdata;
            end
            if (w_commit) begin
                aw_hold_v <= 1'b0;
                w_hold_v  <= 1'b0;
            end
        end
    end

    always @(posedge s_axi_aclk) begin
        if (!s_axi_aresetn) begin
            s_axi_bvalid <= 1'b0;
            s_axi_bresp  <= 2'b00;
        end else begin
            if (!s_axi_bvalid && w_commit) begin
                s_axi_bvalid <= 1'b1;
                s_axi_bresp  <= 2'b00;
            end else if (s_axi_bvalid && s_axi_bready) begin
                s_axi_bvalid <= 1'b0;
            end
        end
    end

    //--------------------------------------------------------------------------
    // CSR
    //--------------------------------------------------------------------------
    reg         r_enable;
    reg         r_irq_en;
    reg  [1:0]  r_exp_fps;
    reg  [63:0] r_buf_addr;
    reg  [31:0] r_ring_bytes;
    reg  [31:0] r_pixclk_hz;
    reg  [31:0] r_int_status;
    reg  [31:0] r_int_enable;
    reg  [31:0] r_last_frame_cnt;
    reg         r_rearm;

    assign cfg_enable     = r_enable;
    assign cfg_buf_addr   = r_buf_addr;
    assign cfg_ring_bytes = r_ring_bytes;
    assign cfg_rearm      = r_rearm;

    always @(posedge s_axi_aclk) begin
        if (!s_axi_aresetn) begin
            r_enable         <= 1'b0;
            r_irq_en         <= 1'b0;
            r_exp_fps        <= 2'd0;
            r_buf_addr       <= 64'd0;
            r_ring_bytes     <= 32'd0;
            r_pixclk_hz      <= 32'd74250000;   // HD-SDI 恒定值
            r_int_status     <= 32'd0;
            r_int_enable     <= 32'd0;
            r_rearm          <= 1'b0;
            r_last_frame_cnt <= 32'd0;
        end else begin
            r_rearm <= 1'b0;

            if (w_commit) begin
                case (aw_hold_a)
                A_CTRL: begin
                    r_enable <= w_hold_d[0];
                    r_irq_en <= w_hold_d[1];
                end
                A_EXP_FPS:    r_exp_fps   <= w_hold_d[1:0];
                A_BUF_ADDR_L: r_buf_addr[31:0]  <= w_hold_d;
                A_BUF_ADDR_H: r_buf_addr[63:32] <= w_hold_d;
                A_RING_BYTES: r_ring_bytes <= w_hold_d;
                A_REARM:      r_rearm      <= 1'b1;
                A_PIXCLK_HZ:  r_pixclk_hz  <= w_hold_d;
                A_INT_STATUS: r_int_status <= r_int_status & ~w_hold_d;   // W1C
                A_INT_ENABLE: r_int_enable <= w_hold_d;
                default: ;   // ID / VERSION / STATUS / 计数器是只读的
                endcase
            end

            // 粘滞状态位
            if (frame_cnt != r_last_frame_cnt) begin
                r_last_frame_cnt <= frame_cnt;
                r_int_status[0]  <= 1'b1;      // 收到一帧
            end
            if (wr_err != 32'd0) r_int_status[1] <= 1'b1;   // 写帧器出错
            if (starving)         r_int_status[2] <= 1'b1;   // 长时间没数据
            if (!sig_locked)     r_int_status[3] <= 1'b1;   // 没有 SDI 信号
        end
    end

    //--------------------------------------------------------------------------
    // fps_x100 = pixclk_hz * 100 / meas_fperiod
    //
    // 迭代恢复余数除法，64 拍一轮。组合除法器要 4k LUT 而且是多周期路径；
    // 这个除法不在任何时序关键路径上，代价几乎为零。
    //--------------------------------------------------------------------------
    wire [63:0] fps_divisor  = {32'd0, meas_fperiod};
    wire [63:0] fps_dividend = {2'd0, r_pixclk_hz} * 64'd100;  // 常数乘法，折成移位加法

    reg  [63:0] fps_rem;
    reg  [63:0] fps_quo;
    reg  [6:0]  fps_iter;
    reg         fps_busy;
    reg         fps_dirty;
    reg  [31:0] fps_x100;

    // ★ 2026-10-15 修 ★ 这两个中间量原来是 reg + 块内阻塞赋值，
    //   综合器把它们推断成寄存器又删掉（[Synth 8-6014] Unused sequential
    //   element 'fps_shifted_reg'/'fps_sub_reg' was removed）——
    //   它们本来就只是线，改成 wire 语义完全相同，警告消失。
    wire [64:0] fps_shifted = {1'b0, fps_rem[62:0], fps_quo[63]};
    wire [64:0] fps_sub     = fps_shifted - {1'b0, fps_divisor};
    wire        fps_ge      = (fps_shifted >= {1'b0, fps_divisor});

    always @(posedge s_axi_aclk) begin
        if (!s_axi_aresetn) begin
            fps_rem   <= 64'd0;
            fps_quo   <= 64'd0;
            fps_iter  <= 7'd0;
            fps_busy  <= 1'b0;
            fps_dirty <= 1'b0;
            fps_x100  <= 32'd0;
        end else begin
            // 帧周期小于 20000 个像素时钟（> 3.7 kHz）说明没测到真帧，
            // 除法不启动，FPS_X100 保持 0 = "未知"。上界防止商溢出 32 bit。
            if (fps_divisor >= 64'd20000 && fps_divisor < 64'h0000_7FFF_FFFF)
                fps_dirty <= 1'b1;

            if (!fps_busy && fps_dirty) begin
                fps_rem   <= 64'd0;
                fps_quo   <= fps_dividend;
                fps_iter  <= 7'd64;
                fps_busy  <= 1'b1;
                fps_dirty <= 1'b0;
            end else if (fps_busy) begin
                if (fps_ge) begin
                    fps_rem <= fps_sub[63:0];
                    fps_quo <= {fps_quo[62:0], 1'b1};
                end else begin
                    fps_rem <= fps_shifted[63:0];
                    fps_quo <= {fps_quo[62:0], 1'b0};
                end
                fps_iter <= fps_iter - 7'd1;
                if (fps_iter == 7'd1) begin
                    fps_busy <= 1'b0;
                    // ★ 2026-10-15 修 ★ 商累积在 fps_quo 里，每一位在本拍定，
                    //   所以结果是 {fps_quo[30:0], fps_ge}。
                    //   原写法取的是 fps_shifted / fps_sub 的高 32 位 ——
                    //   那个值恒 < 2*divisor，高 32 位永远是 0，
                    //   于是 FPS_X100 恒为 0、FPS_CLASS 恒为"未知"。
                    //   （这个 bug 能活下来，是因为帧率寄存器只是一条诊断通路：
                    //     数据通路不吃它，测试台又没有寄存器模型。见 §6.23。）
                    fps_x100 <= {fps_quo[30:0], fps_ge};
                end
            end
        end
    end

    // 实测帧率归类，容差 ±3%，29.97 归到 30
    reg [2:0] fps_class;
    always @(*) begin
        if      (fps_x100 >= 2350 && fps_x100 <= 2650) fps_class = 3'd1;  // ~25
        else if (fps_x100 >= 2850 && fps_x100 <= 3150) fps_class = 3'd2;  // ~30
        else if (fps_x100 >= 4750 && fps_x100 <= 5250) fps_class = 3'd3;  // ~50
        else if (fps_x100 >= 5650 && fps_x100 <= 6250) fps_class = 3'd4;  // ~60
        else                                            fps_class = 3'd0;  // 未知
    end

    // 实测值与软件声明的期望是否一致（只作提示，不影响数据通路）
    wire fps_match = (r_exp_fps == 2'd1 && fps_class == 3'd1) ||
                     (r_exp_fps == 2'd2 && fps_class == 3'd2) ||
                     (r_exp_fps == 2'd0);

    //--------------------------------------------------------------------------
    // 读通道
    //--------------------------------------------------------------------------
    // ★ 2026-10-15 修 ★ 原来是
    //       assign s_axi_arready = ~s_axi_arvalid;
    //   看起来像"没人来读时 ready"，实际是 **死锁**：
    //   ARREADY 只在 ARVALID=0 时为 1，而握手条件恰好要求两者同时为 1，
    //   所以 s_axi_rvalid 永远起不来；PS 侧遵守 AXI 协议会一直举着 ARVALID
    //   等 ARREADY —— 一读寄存器就挂死（读 ID 就挂，驱动第一句就卡住）。
    //   正确做法和写通道一样：ready 表示"上一条还没被取走之前不再接新的"。
    reg r_hold_v;
    always @(posedge s_axi_aclk) begin
        if (!s_axi_aresetn) r_hold_v <= 1'b0;
        else begin
            if (s_axi_arvalid && s_axi_arready)      r_hold_v <= 1'b1;
            else if (s_axi_rvalid && s_axi_rready)   r_hold_v <= 1'b0;
        end
    end
    assign s_axi_arready = ~r_hold_v;

    // ROW_BYTES = MEAS_W*2, FRAME_BYTES = MEAS_H*MEAS_W*2
    // ★ 2026-10-15 修 ★ 原来是
    //       wire [32:0] row_bytes_x   = {17'd0, meas_w} << 1;
    //       wire [32:0] frame_bytes_x = {hw_prod, 1'b0};
    //       A_ROW_BYTES:   rdata_c = row_bytes_x[32:1];
    //       A_FRAME_BYTES: rdata_c = frame_bytes_x[32:1];
    //   先左移再取 [32:1]，两次移位互相抵消 —— 读出来是 MEAS_W 本身
    //   （1920）而不是 2*MEAS_W（3840），FRAME_BYTES 同样少一半。
    //   软件按它分行分帧，少一半就是每行少 1920 字节。见 §6.25。
    // 宽度：meas_w ≤ 65535 -> W*2 ≤ 131070，17 位够；
    //       H*W ≤ 2^32-1 -> *2 需要 33 位，超出 32 位时截断（真实信号到不了）。
    wire [16:0] row_bytes_x   = {1'b0, meas_w} << 1;
    wire [31:0] hw_prod       = meas_h * meas_w;      // 16x16 -> 32
    wire [32:0] frame_bytes_x = {1'b0, hw_prod} << 1;

    reg [31:0] rdata_c;
    always @(*) begin
        case (s_axi_araddr[7:0])
        A_ID:          rdata_c = MAGIC_ID;
        A_VERSION:     rdata_c = MAGIC_VER;
        // ★ 2026-10-15 修 ★ 原来写成 {29'd0, r_irq_en, 1'b0, r_enable}，
        //   这样 IRQ_EN 在 bit2；而写通道是 w_hold_d[1] -> r_irq_en（bit1），
        //   手册也写 bit1。读回的位和写的位对不上（写 0x3 读回 0x5）。见 §6.25。
        A_CTRL:        rdata_c = {29'd0, 1'b0, r_irq_en, r_enable};
        A_STATUS:      rdata_c = {18'd0,
                                   (|wr_err),      // 13 写帧器有错
                                   starving,       // 12 长时间没数据
                                   meas_valid,     // 11 幅面已测出
                                   sig_locked,     // 10 SDI 传输格式已锁
                                   wr_busy,        // 9  正在写
                                   r_enable,       // 8  通路使能
                                   8'd0};
        A_MEAS_W:      rdata_c = {16'd0, meas_w};
        A_MEAS_H:      rdata_c = {16'd0, meas_h};
        A_MEAS_FPER:   rdata_c = meas_fperiod;
        A_FPS_X100:    rdata_c = fps_x100;
        A_RX_MODE:     rdata_c = {29'd0, sdi_status_bus[9], sdi_status_bus[7:6]};
        A_RX_FAMILY:   rdata_c = {28'd0, sdi_status_bus[18:15]};
        A_RX_RATE:     rdata_c = {28'd0, sdi_status_bus[14:11]};
        A_EXP_FPS:     rdata_c = {30'd0, r_exp_fps};
        A_FPS_CLASS:   rdata_c = {29'd0, fps_class};
        A_FPS_MATCH:   rdata_c = {31'd0, fps_match};
        A_ROW_BYTES:   rdata_c = {15'd0, row_bytes_x};            // w * 2
        A_FRAME_BYTES: rdata_c = frame_bytes_x[31:0];             // h * w * 2
        A_BUF_ADDR_L:  rdata_c = r_buf_addr[31:0];
        A_BUF_ADDR_H:  rdata_c = {r_buf_addr[63:32]};
        A_FRAME_CNT:   rdata_c = frame_cnt;
        A_FRAME_ADDR:  rdata_c = frame_start_addr;
        A_WR_ADDR:     rdata_c = wr_addr;
        A_BEATS:       rdata_c = beats_written;
        A_ERR_STAT:    rdata_c = wr_err;
        A_INT_STATUS:  rdata_c = r_int_status;
        A_INT_ENABLE:  rdata_c = r_int_enable;
        A_PIXCLK_HZ:   rdata_c = r_pixclk_hz;
        A_RING_BYTES:  rdata_c = r_ring_bytes;
        A_LINE_CNT:    rdata_c = line_cnt;
        A_WR_IDLE:     rdata_c = {31'd0, wr_idle};
        default:       rdata_c = 32'd0;
        endcase
    end

    always @(posedge s_axi_aclk) begin
        if (!s_axi_aresetn) begin
            s_axi_rvalid <= 1'b0;
            s_axi_rresp  <= 2'b00;
            s_axi_rdata  <= 32'd0;
        end else begin
            if (!s_axi_rvalid && s_axi_arvalid && s_axi_arready) begin
                s_axi_rvalid <= 1'b1;
                s_axi_rdata  <= rdata_c;
                s_axi_rresp  <= 2'b00;
            end else if (s_axi_rvalid && s_axi_rready) begin
                s_axi_rvalid <= 1'b0;
            end
        end
    end

    assign s_axi_intr = |(r_int_status & r_int_enable) & {32{r_irq_en}};

endmodule
