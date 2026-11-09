//============================================================================
// sdi_cap_meas -- SDI 接收器的观测模块：只测量，不筛选。
//
// 设计原则（这一条是后来才纠正过来的，重要）：
//   PL 端**不做任何格式判断，不按制式门控，不丢帧**。
//   SDI 口进来什么像素，这里就如实上报什么；认不认得出是 1080p25/30 是软件的事。
//   接收器没锁定（t_locked = 0）时也照样上报和计数——那正是排障时最需要看到的信息。
//
// 上报的量：
//   meas_w     实测有效像素/行（取所有行里的最大值，不假设 1920）
//   meas_h     实测有效行/帧
//   meas_fper  实测帧周期，单位 = 像素时钟（这是判定 25 还是 30 的唯一依据）
//
// 帧率换算在寄存器组里做（fps_x100 = pixclk_hz*100 / meas_fper），
// 这里不重复算一遍。
//============================================================================
`timescale 1ns / 1ps

module sdi_cap_meas #(
    parameter integer PIXW = 16
)(
    input  wire                  clk,
    input  wire                  rst_n,

    // ---- 像素与同步（frame_convertor 的 4:2:2 直出）----
    input  wire [PIXW-1:0]       pix,        // {img_CbCr, img_Y}
    input  wire                  pix_de,     // 有效像素
    input  wire                  pix_hs,     // 水平有效（行电平）
    input  wire                  pix_vs,     // 垂直有效（帧电平）

    // ---- 接收器状态，只上报，不参与门控 ----
    input  wire                  sig_locked,

    // ---- 使能（唯一会挡住像素的条件）----
    input  wire                  cfg_enable,

    // ---- 输出 ----
    output wire                  px_valid,      // 直接送写帧器，不筛选
    output wire [PIXW-1:0]       px_data,
    output reg                   line_start,
    output reg                   frame_start,

    // ---- 状态上报 ----
    output reg  [15:0]           meas_w,
    output reg  [15:0]           meas_h,
    output reg  [31:0]           meas_fperiod,
    output reg                   meas_valid,
    output reg  [31:0]           line_cnt
    // 帧计数由 sdi_stream_wr 在 vsync 时数，不在这里重复数一份——
    // 两处都声明同名寄存器会被 Vivado 判成多驱动。
);

    //--------------------------------------------------------------------------
    // 边沿检测
    //--------------------------------------------------------------------------
    reg hs_d, vs_d;
    always @(posedge clk) begin
        hs_d <= pix_hs;
        vs_d <= pix_vs;
    end
    wire hs_rise = pix_hs & ~hs_d;
    wire vs_rise = pix_vs & ~vs_d;

    //--------------------------------------------------------------------------
    // 像素直通：唯一的门是 cfg_enable。没有制式判断，没有帧率门控。
    //--------------------------------------------------------------------------
    assign px_valid = cfg_enable & pix_de;
    assign px_data  = pix;

    always @(posedge clk) begin
        if (!rst_n) begin
            line_start  <= 1'b0;
            frame_start <= 1'b0;
        end else begin
            line_start  <= hs_rise;
            frame_start <= vs_rise;
        end
    end

    //--------------------------------------------------------------------------
    // 有效幅面测量（取最大值，不假设）
    //
    // ★ 2026-11-10 修 ★ 这一整块原来数不出东西，MEAS_W/MEAS_H/GEOM_VALID
    //   全是 0，demo 永远等不到幅面有效。两个根因：
    //   1. pix_de = pix_vs & pix_hs（rx_sdi 的 YCbCr422_data_en 就是这么拼的），
    //      即 de ⊆ hs。原来写的是"hs 高时清零、de 时累加"——累加分支是
    //      死代码，pix_in_line 恒 0，w_max 永远锁不进 1920。
    //   2. lines_in_frame 只累加从不清零，h_max 锁进来的是跨帧累计值
    //      （1080、2160、3240…），MEAS_H 是垃圾。
    //   正确语义照抄已验证的 vendor sdi_status.v:156-209：
    //   hs 上升沿发布**上一行**的宽度、给新行播下第一个像素的种子
    //   （hs 上升这拍本身就是本行第一个有效像素——de 与 hs 同拍起来）；
    //   vs 上升沿发布**上一帧**的行数，且首行的 hs 上升与 vs 上升同拍，
    //   要在同一拍给行计数播种子，否则高度少一行。
    //--------------------------------------------------------------------------
    reg [15:0] pix_in_line;
    reg [15:0] lines_in_frame;
    reg [15:0] w_max, h_max;

    always @(posedge clk) begin
        if (!rst_n) begin
            pix_in_line    <= 16'd0;
            lines_in_frame <= 16'd0;
            w_max          <= 16'd0;
            h_max          <= 16'd0;
        end else begin
            if (hs_rise) begin
                // 发布的是刚结束那行的旧值；新行从这拍开始数
                if (pix_in_line > w_max) w_max <= pix_in_line;
                pix_in_line <= 16'd1;
            end else if (pix_de) begin
                pix_in_line <= pix_in_line + 16'd1;
            end

            if (pix_vs) begin
                if (vs_rise) begin
                    h_max          <= lines_in_frame;             // 发布刚结束的帧
                    lines_in_frame <= hs_rise ? 16'd1 : 16'd0;    // 首行 hs 与 vs 同拍
                end else if (hs_rise) begin
                    lines_in_frame <= lines_in_frame + 16'd1;
                end
            end
        end
    end

    always @(posedge clk) begin
        if (!rst_n) begin
            meas_w     <= 16'd0;
            meas_h     <= 16'd0;
            meas_valid <= 1'b0;
        end else begin
            meas_w     <= w_max;
            meas_h     <= h_max;
            meas_valid <= (w_max != 16'd0) && (h_max != 16'd0);
        end
    end

    //--------------------------------------------------------------------------
    // 帧周期：两次 vsync 之间累计多少个像素时钟
    //
    // ★ 2026-11-10 修 ★ 原来经 fperiod_q（fcount 的一拍延迟副本）发布，
    //   发布的是 P-1：vs_rise 那拍 fcount 已经停在最后一拍，fperiod_q 又
    //   慢一拍，FPS_X100 系统性偏小。vendor sdi_status.v:217-229 的做法是
    //   vs 上升当拍直接发布 fcount 本身，这里改成一致。
    //--------------------------------------------------------------------------
    reg [31:0] fcount;
    reg        period_valid;

    always @(posedge clk) begin
        if (!rst_n) begin
            fcount       <= 32'd0;
            period_valid <= 1'b0;
            meas_fperiod <= 32'd0;
            line_cnt     <= 32'd0;
        end else begin
            if (hs_rise) line_cnt <= line_cnt + 32'd1;

            if (!sig_locked) begin
                // 失锁期间不累计也不发布：fcount 保持 0，period_valid 撤掉，
                // meas_fperiod 冻结在最后一次发布的值（period_valid 挡住了
                // 重锁后第一帧的半截周期）。行/帧脉冲（line_start/frame_start/
                // line_cnt）不受这里影响，照常上报——那才是"GT 活着但认不出
                // 格式"时还能看到的东西。
                fcount       <= 32'd0;
                period_valid <= 1'b0;
            end else if (vs_rise) begin
                if (period_valid) meas_fperiod <= fcount;   // 当拍直接发布，不是 P-1
                period_valid <= 1'b1;
                fcount       <= 32'd1;   // vs 上升这拍算周期的第 1 个时钟
            end else if (fcount != 32'hFFFFFFFF) begin
                fcount <= fcount + 32'd1;
            end
        end
    end


endmodule