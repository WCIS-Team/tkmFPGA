//============================================================================
// tb_sdi_cap_meas -- sdi_cap_meas 幅面/帧周期测量回归
//
// 为什么要有这个 TB：meas 是 MEAS_W/MEAS_H/MEAS_FPERIOD/GEOM_VALID 的唯一
// 来源，demo 抓帧的门槛就是 GEOM_VALID。2026-11-10 之前它没有任何回归，
// 三个 bug（行内累加分支死代码、行数跨帧累计、帧周期少一拍）全是靠
// 审计读代码发现的——现在把"读出来的语义"钉进可复跑的检查。
//
// 激励模型（与 vendor frame_convertor 的电平语义一致，见 sdi_status.v）：
//   pix_hs  行电平：每行的前 W 拍为高（每行都起一次，含消隐行）
//   pix_vs  帧电平：每帧前 H 行为高；第一个有效行的 hs 上升与 vs 上升同拍
//   pix_de  = pix_vs & pix_hs
//   帧长 = H_TOT * W_TOT 拍（1080p30 是 2200*1125 = 2475000，这里 400*300
//   = 120000 等比缩小，跑得快，判据不变）
//
// 时间线（cyc = 复位释放后的拍数；帧 k 的有效区起于 F0+(k-1)*P）：
//   F0+P/2     帧一中段，sig_locked=0：meas_fperiod 必须还是 0
//   F0+P/2+10  置 sig_locked=1
//   F0+2P+100  帧 3 已开头：meas_w/h/valid/fperiod 全部就位，行宽还是旧值
//   F0+3P+50..150  关掉 cfg_enable 一小段：px_valid 必须跟着变 0
//   F0+4P+100  帧 5 已开头：行宽 360 的 max 已被锁进 meas_w，
//              行数重播种（不是累计 480/720…），周期不变
//
// 检查项：
//   1. meas_w / meas_h / meas_valid：第二帧结束后给出 W/H 且 GEOM_VALID=1
//   2. meas_fperiod == H_TOT*W_TOT（正好一帧的拍数，不是 P-1）
//   3. 行宽改宽后 w_max 跟着走（取最大值语义）；meas_h 不跨帧累计
//   4. line_cnt == 激励里 hs 上升沿个数（逐拍对拍，不写死数字）
//   5. line_start/frame_start 脉冲个数 == 对应沿个数（脉冲不丢）
//   6. px_valid = cfg_enable & pix_de 门控；px_data 直通不变形
//   7. 失锁期间 meas_fperiod 保持 0；重锁后第二个 vsync 起才有真值
//============================================================================
`timescale 1ns / 1ps

module tb_sdi_cap_meas;

    //--------------------------------------------------------------------------
    // 被测格式：1080p30 等比缩小（2200x1125 -> 400x300），判据等价
    //--------------------------------------------------------------------------
    localparam integer W     = 320;   // 帧 1-2 的有效像素/行
    localparam integer W2    = 360;   // 帧 3 起改宽（测 max 语义）
    localparam integer W_TOT = 400;
    localparam integer H     = 240;
    localparam integer H_TOT = 300;
    localparam integer P     = W_TOT * H_TOT;   // 帧周期（拍）= 120000

    reg clk = 1'b0;
    always #5 clk = ~clk;             // 100 MHz

    reg  rst_n      = 1'b0;
    reg  sig_locked = 1'b0;
    reg  cfg_enable = 1'b1;

    //--------------------------------------------------------------------------
    // 激励：位置计数器 + 电平同步生成
    //
    // ★ 复位释放时必须停在消隐里（hs=vs=0），否则 DUT 出复位看到的第一个
    //   hs/vs 已经是高电平，第一个上升沿永远错过，"帧 1"变成半帧——
    //   这是激励的错，不是 DUT 的错（真硬件上电也常从信号中间开始，
    //   第一帧本来就允许缺斤少两，帧 2 起必须全对）。
    //--------------------------------------------------------------------------
    integer px_cnt = W;               // 从行消隐里起步：hs=0
    integer ln_cnt = H;               // 从帧消隐里起步：vs=0
    integer cyc    = 0;               // 复位释放后的拍数
    reg [15:0] pix = 16'h0000;
    integer    act_w = W;             // 当前行有效像素数（帧 3 起变 W2）

    // 帧 1 起点：走完 (H_TOT-H) 行帧消隐 + (W_TOT-W) 拍行消隐之后
    localparam integer F0 = (H_TOT - H) * W_TOT + (W_TOT - W);

    wire pix_hs = (px_cnt < act_w);               // 每行都起一次
    wire pix_vs = (ln_cnt < H);                   // 只盖住有效行
    wire pix_de = pix_hs & pix_vs;

    always @(posedge clk) begin
        if (rst_n) cyc <= cyc + 1;
    end

    always @(posedge clk) begin
        if (!rst_n) begin
            px_cnt <= W;
            ln_cnt <= H;
        end else begin
            if (px_cnt == W_TOT-1) begin
                px_cnt <= 0;
                if (ln_cnt == H_TOT-1) ln_cnt <= 0;
                else                   ln_cnt <= ln_cnt + 1;
            end else px_cnt <= px_cnt + 1;
            if (pix_de) pix <= pix + 16'd1;
        end
    end

    // 帧 3（cyc=F0+2P 起）行宽改宽，验证"取最大值"
    always @(posedge clk) begin
        if (rst_n && (cyc == F0 + 2*P)) act_w <= W2;
    end

    //--------------------------------------------------------------------------
    // 被测模块
    //--------------------------------------------------------------------------
    wire        px_valid;
    wire [15:0] px_data;
    wire        line_start, frame_start;
    wire [15:0] meas_w, meas_h;
    wire [31:0] meas_fperiod, line_cnt;
    wire        meas_valid;

    sdi_cap_meas u_dut (
        .clk          (clk),
        .rst_n        (rst_n),
        .pix          (pix),
        .pix_de       (pix_de),
        .pix_hs       (pix_hs),
        .pix_vs       (pix_vs),
        .sig_locked   (sig_locked),
        .cfg_enable   (cfg_enable),
        .px_valid     (px_valid),
        .px_data      (px_data),
        .line_start   (line_start),
        .frame_start  (frame_start),
        .meas_w       (meas_w),
        .meas_h       (meas_h),
        .meas_fperiod (meas_fperiod),
        .meas_valid   (meas_valid),
        .line_cnt     (line_cnt)
    );

    //--------------------------------------------------------------------------
    // 逐拍检查：px_valid 门控 + px_data 直通
    //--------------------------------------------------------------------------
    integer errors = 0;
    integer gate_bad = 0, data_bad = 0;

    always @(posedge clk) begin
        if (rst_n) begin
            if (px_valid !== (cfg_enable & pix_de)) begin
                if (gate_bad < 8)
                    $display("GATE-ERROR: cyc=%0d px_valid=%b, enable=%b de=%b",
                             cyc, px_valid, cfg_enable, pix_de);
                gate_bad <= gate_bad + 1;
            end
            if (px_valid && (px_data !== pix)) begin
                if (data_bad < 8)
                    $display("DATA-ERROR: cyc=%0d px_data=%h pix=%h",
                             cyc, px_data, pix);
                data_bad <= data_bad + 1;
            end
        end
    end

    //--------------------------------------------------------------------------
    // 沿计数（激励侧）与脉冲计数（DUT 侧）对拍
    //--------------------------------------------------------------------------
    integer n_hs_rise = 0, n_vs_rise = 0;
    integer n_ls      = 0, n_fs      = 0;
    reg     hs_q = 1'b0, vs_q = 1'b0;

    always @(posedge clk) begin
        hs_q <= pix_hs;
        vs_q <= pix_vs;
        if (pix_hs && !hs_q) n_hs_rise <= n_hs_rise + 1;
        if (pix_vs && !vs_q) n_vs_rise <= n_vs_rise + 1;
    end
    always @(posedge clk) begin
        if (rst_n) begin
            if (line_start)  n_ls <= n_ls + 1;
            if (frame_start) n_fs <= n_fs + 1;
        end
    end

    //--------------------------------------------------------------------------
    // 检查与报告
    //--------------------------------------------------------------------------
    task chk32(input [31:0] got, input [31:0] want, input [8*32:1] name);
        begin
            if (got === want) $display("    ok %0s = %0d", name, got);
            else begin
                $display("    FAIL %0s: got %0d, want %0d", name, got, want);
                errors = errors + 1;
            end
        end
    endtask

    task chk1(input got, input want, input [8*32:1] name);
        begin
            if (got === want) $display("    ok %0s = %b", name, got);
            else begin
                $display("    FAIL %0s: got %b, want %b", name, got, want);
                errors = errors + 1;
            end
        end
    endtask

    initial begin
        // 复位释放在 negedge 上做，避免与 posedge 采样竞争：
        // 释放后第一个 posedge 所有进程看到的 rst_n/电平是一致的，
        // 沿计数（n_hs_rise）和 DUT 脉冲（line_start）才可能逐个对上。
        repeat (8) @(negedge clk);
        rst_n = 1'b1;

        // ---- 帧一中段：还没锁，meas_fperiod 必须保持 0 ----
        wait (cyc == F0 + P/2);
        $display("---- 帧一中段（cyc=%0d，sig_locked=%b）----", cyc, sig_locked);
        chk32(meas_fperiod, 32'd0, "fperiod_while_unlocked");

        @(negedge clk);               // 信号翻转避开 posedge 采样
        sig_locked = 1'b1;            // 帧 2 起点 vsync 播种，帧 3 起发布

        // ---- 帧 3 开头：几何 + 周期全部就位，行宽还是旧格式 ----
        wait (cyc == F0 + 2*P + 100);
        $display("---- 帧 3 开头（cyc=%0d，行宽 %0d）----", cyc, act_w);
        chk32(meas_w,       W,          "meas_w_frame12");
        chk32(meas_h,       H,          "meas_h");
        chk1 (meas_valid,   1'b1,       "meas_valid");
        chk32(meas_fperiod, P,          "meas_fperiod");
        chk1 (line_cnt == n_hs_rise, 1'b1, "line_cnt==hs_rises");
        chk1 (n_ls == n_hs_rise,     1'b1, "line_start_count");
        chk1 (n_fs == n_vs_rise,     1'b1, "frame_start_count");

        // ---- 帧 4 中段：关一小段使能，门控必须立刻生效 ----
        @(negedge clk); cfg_enable = 1'b0;
        wait (cyc == F0 + 3*P + 150);
        @(negedge clk); cfg_enable = 1'b1;

        // ---- 帧 5 开头：行宽改宽后的 max、行数重播种、周期不变 ----
        wait (cyc == F0 + 4*P + 100);
        $display("---- 帧 5 开头（cyc=%0d，行宽 %0d）----", cyc, act_w);
        chk32(meas_w,       W2,         "meas_w_after_wider");
        chk32(meas_h,       H,          "meas_h_not_cumulative");
        chk32(meas_fperiod, P,          "meas_fperiod_stable");
        chk1 (meas_valid,   1'b1,       "meas_valid_still");
        chk1 (line_cnt == n_hs_rise, 1'b1, "line_cnt==hs_rises");

        $display("----------------------------------------------------------------");
        if (gate_bad != 0) begin
            $display("    FAIL px_valid gate: %0d bad cycles", gate_bad);
            errors = errors + 1;
        end else $display("    ok px_valid_gate");
        if (data_bad != 0) begin
            $display("    FAIL px_data passthrough: %0d bad beats", data_bad);
            errors = errors + 1;
        end else $display("    ok px_data_passthrough");
        $display("================================================================");
        $display(" sdi_cap_meas: %0d/%0d/%0d format, fperiod=%0d, 4+ frames",
                 W, W2, H, P);
        $display("MEAS RESULT: %s", (errors == 0) ? "PASS" : "FAIL");
        $display("================================================================");
        $finish;
    end

    initial begin
        #20_000_000;                  // 20 ms 上限（全程约 4.8 ms）
        $display("TIMEOUT");
        $display("MEAS RESULT: FAIL (timeout)");
        $finish;
    end

endmodule
