//============================================================================
// sdi_px_afifo -- 跨时钟域像素 FIFO（写侧 cam_clk，读侧 AXI 时钟）
//
// 为什么需要它：
//   原来整个写帧器都在 cam_clk（恢复出来的像素时钟）上，AXI 主机也挂在那里。
//   改用 HP 口之后 AXI 侧必须有一个**常驻**时钟：
//     - cam_clk 在失锁时会切到 clk200 兜底（频率会变），AXI 接口上跑着
//       在途事务时换时钟 = 厂商《PS-PL AXI HP 接口：事务计数与复位语义》
//       里 L3/L4 那类挂死；
//     - 所以 AXI 侧改用 PM 侧派生的 clk_100m（常驻、恒定），
//       像素进 FIFO 之前的一次跨域就由本模块负责。
//
// 语义（标准格雷码指针异步 FIFO，Cummings 那套）：
//   写侧：wr_en 且 !wr_full 时写入一拍；wr_full 用**读指针同步过来**算。
//   读侧：rd_en 后**下一拍** rd_data 有效（同步读，方便推断块 RAM）。
//         rd_count = 读域里能看到的当前存量（0..DEPTH）。
//
//   ⚠ 只用 rd_en 弹数据、并用 rd_count 判断"还有几拍"，
//     不要把 rd_data 当组合读用 —— 块 RAM 没有异步读口，
//     组合读在仿真里对、落成 RAMB 就晚一拍（本项目踩过这个坑）。
//
// 复位：两个域各自同步复位（rst_n 在各自时钟沿上采样）。指针对是
//       "整个域一起清零"，不会出现半清状态。
//============================================================================
`timescale 1ns / 1ps

module sdi_px_afifo #(
    parameter integer W  = 65,        // 64 bit 数据 + 1 bit 帧标记
    parameter integer FD = 10         // 深 2^FD = 1024 拍 = 8 KB
)(
    // ---- 写侧（cam_clk，像素域）----
    input  wire         wr_clk,
    input  wire         wr_rst_n,
    input  wire         wr_en,
    input  wire [W-1:0] wr_data,
    output wire         wr_full,

    // ---- 读侧（AXI 时钟域）----
    input  wire         rd_clk,
    input  wire         rd_rst_n,
    input  wire         rd_en,
    output reg  [W-1:0] rd_data,
    output wire         rd_empty,
    output wire [FD:0]  rd_count
);

    localparam integer DEPTH = (1 << FD);

    reg [W-1:0] mem [0:DEPTH-1];

    reg [FD:0] wbin, wgray;      // 写侧
    reg [FD:0] rbin, rgray;      // 读侧
    reg [FD:0] rgray_ws1, rgray_ws2;   // 读指针 -> 写域
    reg [FD:0] wgray_rs1, wgray_rs2;   // 写指针 -> 读域

    function [FD:0] bin2gray (input [FD:0] b);
        bin2gray = b ^ (b >> 1);
    endfunction

    function [FD:0] gray2bin (input [FD:0] g);
        integer i;
        begin
            gray2bin[FD] = g[FD];
            for (i = FD-1; i >= 0; i = i - 1)
                gray2bin[i] = gray2bin[i+1] ^ g[i];
        end
    endfunction

    wire [FD:0] wbin_n    = wbin + 1'b1;
    wire [FD:0] rbin_n    = rbin + 1'b1;
    wire [FD:0] wgray_n   = bin2gray(wbin_n);
    wire [FD:0] rgray_n   = bin2gray(rbin_n);

    // 满：写指针再多一格就撞上读指针（格雷码上两位取反）
    assign wr_full  = (wgray_n == {~rgray_ws2[FD:FD-1], rgray_ws2[FD-2:0]});
    // 空：读指针追上写指针
    assign rd_empty = (rgray == wgray_rs2);

    // ---- 写侧 ----
    always @(posedge wr_clk) begin
        if (!wr_rst_n) begin
            wbin  <= {(FD+1){1'b0}};
            wgray <= {(FD+1){1'b0}};
        end else if (wr_en && !wr_full) begin
            mem[wbin[FD-1:0]] <= wr_data;
            wbin              <= wbin_n;
            wgray             <= wgray_n;
        end
    end

    // ---- 读侧：同步读，rd_en 后下一拍 rd_data 有效 ----
    always @(posedge rd_clk) begin
        if (!rd_rst_n) begin
            rbin    <= {(FD+1){1'b0}};
            rgray   <= {(FD+1){1'b0}};
            rd_data <= {W{1'b0}};
        end else if (rd_en) begin
            rd_data <= mem[rbin[FD-1:0]];
            rbin    <= rbin_n;
            rgray   <= rgray_n;
        end
    end

    // ---- 指针同步（各自两级）----
    always @(posedge wr_clk) begin
        if (!wr_rst_n) begin
            rgray_ws1 <= {(FD+1){1'b0}};
            rgray_ws2 <= {(FD+1){1'b0}};
        end else begin
            rgray_ws1 <= rgray;
            rgray_ws2 <= rgray_ws1;
        end
    end

    always @(posedge rd_clk) begin
        if (!rd_rst_n) begin
            wgray_rs1 <= {(FD+1){1'b0}};
            wgray_rs2 <= {(FD+1){1'b0}};
        end else begin
            wgray_rs1 <= wgray;
            wgray_rs2 <= wgray_rs1;
        end
    end

    // ---- 读域里的存量 ----
    //   wgray_rs2 是写指针的同步副本；折回二进制做模 2^(FD+1) 减法，
    //   结果天然落在 0..DEPTH。组合深度 = FD 级异或 + 一条减法链，
    //   都在同一个时钟域内，不涉及跨域路径。
    wire [FD:0] wbin_rd = gray2bin(wgray_rs2);
    assign rd_count = wbin_rd - rbin;

endmodule
