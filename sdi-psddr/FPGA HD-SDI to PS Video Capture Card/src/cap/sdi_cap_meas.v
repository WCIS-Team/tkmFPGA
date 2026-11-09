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
    //--------------------------------------------------------------------------
    reg [15:0] pix_in_line;
    reg [15:0] lines_in_frame;

    always @(posedge clk) begin
        if (!rst_n) begin
            pix_in_line    <= 16'd0;
            lines_in_frame <= 16'd0;
        end else if (pix_vs) begin
            if (pix_hs) pix_in_line <= 16'd0;
            else if (pix_de) pix_in_line <= pix_in_line + 16'd1;
            if (hs_rise) lines_in_frame <= lines_in_frame + 16'd1;
        end else begin
            pix_in_line <= 16'd0;
        end
    end

    reg [15:0] w_max, h_max;
    always @(posedge clk) begin
        if (!rst_n) begin
            w_max <= 16'd0;
            h_max <= 16'd0;
        end else if (pix_vs && pix_de && (pix_in_line > w_max)) begin
            w_max <= pix_in_line;
        end else if (vs_rise && pix_vs) begin
            h_max <= lines_in_frame;
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
    //--------------------------------------------------------------------------
    reg [31:0] fcount;
    reg [31:0] fperiod_q;
    reg        period_valid;

    always @(posedge clk) begin
        if (!rst_n) begin
            fcount       <= 32'd0;
            fperiod_q    <= 32'd0;
            period_valid <= 1'b0;
            meas_fperiod <= 32'd0;
            line_cnt     <= 32'd0;
        end else begin
            if (hs_rise) line_cnt <= line_cnt + 32'd1;
            // fcount 的一拍延迟副本：vsync 到达时要用上一拍的计数值当帧周期。
            // （之前把这条更新删掉过，结果 meas_fperiod 一直读一个只被复位过的
            //   寄存器 —— FPS_X100 永远是 0，而且 Vivado 报 fperiod_q 多驱动。
            //   这个寄存器有真实用途，不是死代码。）
            fperiod_q <= fcount;

            if (!sig_locked) begin
                // 没锁定时周期没有意义，但不停止计数：软件能看到计数在动，
                // 这正是"GT 活着但认不出格式"的判据。
                fcount       <= 32'd0;
                period_valid <= 1'b0;
            end else if (vs_rise) begin
                if (period_valid) meas_fperiod <= fperiod_q;
                period_valid <= 1'b1;
                fcount       <= 32'd1;
            end else if (fcount != 32'hFFFFFFFF) begin
                fcount <= fcount + 32'd1;
            end
        end
    end


endmodule