//============================================================================
// sdi_px_pack -- 4 个 16 bit 像素打包成 1 拍 64 bit，并带上帧标记（cam_clk 域）
//
// 为什么是 4 个像素：
//   HP 口的数据宽是 **64 bit**（读自 IP 生成的 HDL：S_AXI_HP2_WDATA[63:0]、
//   WSTRB[7:0]、AWSIZE=3'b011）。原来挂 GP0 时是 32 bit（2 像素/拍），
//   换到 HP 口就必须按 4 像素/拍打包。
//
// 字节序（小端，与 SDI 口进来的顺序逐字节一致）：
//   第 4n+0 个像素 -> [15:0]，4n+1 -> [31:16]，4n+2 -> [47:32]，4n+3 -> [63:48]
//
// 帧标记（word[64]）：
//   打包侧看到 frame_start（vsync 上升沿）就置一个粘滞位，落在**下一拍
//   写进 FIFO 的字**上。这样帧边界和数据在同一条通路上走，
//   FRAME_ADDR 与数据严格对齐 —— 如果拿一个单独的跨域脉冲去通知写帧器，
//   两者会差几个周期（= 几十字节），软件按 FRAME_ADDR 找帧首就会偏。
//   ★ 标记只是元数据：像素照写不误，不做任何门控。
//
// 丢字（FIFO 满）：
//   规则与原来一致 —— 丢就丢整拍，**指针不动**，置 drop 计数。
//   绝不反压 SDI 接收器（那是用户定的红线），丢了多少要让软件看得见。
//============================================================================
`timescale 1ns / 1ps

module sdi_px_pack (
    input  wire        clk,           // cam_clk
    input  wire        rst_n,
    input  wire        rearm,         // 与写帧器同一个 rearm（已同步到本域）

    // ---- 像素流：进来什么收什么，不判格式 ----
    input  wire        px_valid,
    input  wire [15:0] px_data,
    input  wire        frame_start,   // vsync 上升沿（cam_clk 域）

    // ---- 到异步 FIFO 的写口 ----
    output wire [64:0] w_data,        // {帧标记, 4 像素}
    output wire        w_en,
    input  wire        w_full,

    // ---- 状态 ----
    output reg  [31:0] drop_lo        // 因 FIFO 满丢掉的 64 bit 拍数
);

    reg [63:0] acc;          // 正在拼的 4 像素
    reg [1:0]  cnt;          // 已经收进 acc 的像素个数
    reg        vs_flag;      // 粘滞的帧标记，交给下一个成功写出的字
    reg        w_en_r;
    reg        w_marker_r;

    wire       emit = (cnt == 2'd3) && px_valid;   // 第 4 个像素正在进来

    always @(posedge clk) begin
        if (!rst_n || rearm) begin
            acc        <= 64'd0;
            cnt        <= 2'd0;
            vs_flag    <= 1'b0;
            w_en_r     <= 1'b0;
            w_marker_r <= 1'b0;
            drop_lo    <= 32'd0;
        end else begin
            w_en_r <= 1'b0;

            if (px_valid) begin
                acc[16*cnt +: 16] <= px_data;
                cnt               <= (cnt == 2'd3) ? 2'd0 : (cnt + 2'd1);
            end

            if (emit) begin
                if (!w_full) begin
                    // 这一拍 acc 刚好补齐，下一拍 FIFO 采样到完整的 4 像素。
                    // 帧标记也在这里定稿：包含"恰好在这一拍到达的 vsync"。
                    w_en_r     <= 1'b1;
                    w_marker_r <= vs_flag | frame_start;
                    vs_flag    <= 1'b0;
                end else begin
                    // FIFO 满：整拍丢掉，指针不动。标记不能丢，留给下一拍。
                    drop_lo <= drop_lo + 32'd1;
                    vs_flag <= vs_flag | frame_start;
                end
            end else if (frame_start) begin
                vs_flag <= 1'b1;
            end
        end
    end

    assign w_data = {w_marker_r, acc};
    assign w_en   = w_en_r;

endmodule
