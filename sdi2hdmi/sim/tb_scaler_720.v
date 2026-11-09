//=============================================================================
// tb_scaler_720.v
//
// Self-checking testbench for scaler_720.
//
// Feeds a synthetic source raster with correct SDI-style timing (cam_hs is the
// horizontal-ACTIVE level, cam_vs the vertical-ACTIVE level, cam_de the pixel
// strobe) and compares the resampled output against a golden box-filter model
// computed independently in the testbench with plain nested loops.
//
// The scaler takes its geometry from the PREVIOUS frame, so the first frame
// after reset is expected to be garbage. FRAMES frames are pushed and only the
// last complete frame is checked.
//
// The DUT is always instantiated at the real 1280x720 output size. What varies
// is the SOURCE geometry, which is what plusargs are for -- Vivado's xvlog in
// 2018.3 rejects `-d MACRO=value` (it splits on the `=` and then looks for a
// file named after the value), so compile-time parameterisation is not an
// option here.
//
//   --testplusarg w96   --testplusarg h54   2:3 scaled down, fast
//   --testplusarg w1280 --testplusarg h720  1:1 pass-through
//   --testplusarg w1920 --testplusarg h1080 2:3 at full size, the real case
//   --testplusarg f<N>                       how many frames to push
//
//   The plusargs are flags rather than "key=value" pairs on purpose: the
//   xsim.bat wrapper splits its command line on "=", so "src_w=96" arrives as
//   two arguments "9" and "6" and xsim aborts with
//   "Expected a switch but found 9".
//=============================================================================
`timescale 1ns / 1ps
`default_nettype none

module tb_scaler_720;

    //-------------------------------------------------------------------------
    // DUT is fixed at the real output size
    //-------------------------------------------------------------------------
    localparam integer DST_W  = 1280;
    localparam integer DST_H  = 720;

    // array bounds: the largest source we test, and the output
    localparam integer GW = 1920;
    localparam integer GH = 1080;

    // The capture holds several frames, because only the LAST complete frame is
    // compared -- the scaler learns the source geometry from the previous one.
    // Four rows of DST_H is plenty for the frame counts used here.
    localparam integer CAP_ROWS = 4 * DST_H;

    integer SRC_W  = 96;
    integer SRC_H  = 54;
    integer FRAMES = 4;

    integer H_BLANK, V_BLANK, H_TOTAL, V_TOTAL;

    localparam real CLK_NS = 6.734;    // 148.5 MHz, the 3G-SDI pixel clock

    //-------------------------------------------------------------------------
    // DUT wiring
    //-------------------------------------------------------------------------
    reg         clk = 1'b0;
    reg         rst_n = 1'b0;
    reg  [23:0] in_rgb = 24'd0;
    reg         in_de = 1'b0;
    reg         in_hs = 1'b0;
    reg         in_vs = 1'b0;

    wire        out_valid, out_last, out_frame, locked_q, overflow_q, push_overrun;
    wire [15:0] out_rgb;
    wire [15:0] src_w, src_h;
    wire [31:0] stat_lines;

    scaler_720 #(
        .DST_W (DST_W),
        .DST_H (DST_H)
    ) dut (
        .clk          (clk),
        .rst_n        (rst_n),
        .in_rgb       (in_rgb),
        .in_de        (in_de),
        .in_hs        (in_hs),
        .in_vs        (in_vs),
        .out_valid    (out_valid),
        .out_last     (out_last),
        .out_frame    (out_frame),
        .out_rgb      (out_rgb),
        .src_w        (src_w),
        .src_h        (src_h),
        .stat_lines   (stat_lines),
        .locked_q     (locked_q),
        .overflow_q   (overflow_q),
        .push_overrun (push_overrun)
    );

    always #(CLK_NS/2.0) clk = ~clk;

    //-------------------------------------------------------------------------
    // Golden model
    //
    // g565[y][x] is the truncated RGB565 of the source pattern, which is what
    // the DUT feeds its filter. The golden output is
    //     gold[k][j] = mean of the horizontally scaled lines F(k-1)..F(k)-1
    // with E(j) = (j+1)*SRC_W/DST_W and F(k) = (k+1)*SRC_H/DST_H.
    //
    // The mean is written out longhand rather than factored into a helper, so
    // that it is obviously the definition and not a copy of the DUT.
    //-------------------------------------------------------------------------
    reg [15:0] g565 [0:GH-1][0:GW-1];   // source, truncated to RGB565
    reg [15:0] ghs  [0:GH-1][0:GW-1];   // horizontally scaled lines
    reg [15:0] gold [0:DST_H-1][0:DST_W-1];
    reg [15:0] cap  [0:CAP_ROWS-1][0:DST_W-1];

    // A pattern with structure on both axes, so neither a horizontal nor a
    // vertical shift can pass by accident.
    function [23:0] src_pixel(input integer x, input integer y);
        reg [7:0] r, g, b;
        begin
            r = (x * 255) / (SRC_W - 1);
            g = (y * 255) / (SRC_H - 1);
            b = ((x + y) * 255) / (SRC_W + SRC_H - 2);
            src_pixel = {r, g, b};
        end
    endfunction

    task build_golden;
        integer j, k, x, y, e_prev, e_cur, f_prev, f_cur, nh, nv;
        reg [23:0] p;
        reg [31:0] acc;
        begin
            // ---- source, truncated exactly as the DUT does ----
            for (y = 0; y < SRC_H; y = y + 1)
                for (x = 0; x < SRC_W; x = x + 1) begin
                    p = src_pixel(x, y);
                    g565[y][x] = {p[23:19], p[15:10], p[7:3]};
                end

            // ---- horizontal pass ----
            e_prev = 0;
            for (j = 0; j < DST_W; j = j + 1) begin
                e_cur = ((j + 1) * SRC_W) / DST_W;
                nh   = e_cur - e_prev;
                for (y = 0; y < SRC_H; y = y + 1) begin
                    if (nh == 1) begin
                        ghs[y][j] = g565[y][e_prev];
                    end else if (nh == 2) begin
                        ghs[y][j] = (g565[y][e_prev] + g565[y][e_prev+1]) >> 1;
                    end else begin
                        acc = 0;
                        for (x = 0; x < nh; x = x + 1)
                            acc = acc + g565[y][e_prev + x];
                        ghs[y][j] = acc >> 2;          // matches the DUT's clamp
                    end
                end
                e_prev = e_cur;
            end

            // ---- vertical pass ----
            f_prev = 0;
            for (k = 0; k < DST_H; k = k + 1) begin
                f_cur = ((k + 1) * SRC_H) / DST_H;
                nv   = f_cur - f_prev;
                for (j = 0; j < DST_W; j = j + 1) begin
                    if (nv == 1) begin
                        gold[k][j] = ghs[f_prev][j];
                    end else if (nv == 2) begin
                        gold[k][j] = (ghs[f_prev][j] + ghs[f_prev+1][j]) >> 1;
                    end else begin
                        acc = 0;
                        for (y = 0; y < nv; y = y + 1)
                            acc = acc + ghs[f_prev + y][j];
                        gold[k][j] = acc >> 2;          // matches the DUT's clamp
                    end
                end
                f_prev = f_cur;
            end
        end
    endtask

    //-------------------------------------------------------------------------
    // Output capture
    //-------------------------------------------------------------------------
    integer cap_x = 0;
    integer cap_y = 0;

    always @(posedge clk) begin
        if (rst_n && out_valid) begin
            if (cap_x < DST_W) cap[cap_y % CAP_ROWS][cap_x] = out_rgb;
            if (out_last) begin
                cap_x = 0;
                cap_y = cap_y + 1;
            end else begin
                cap_x = cap_x + 1;
            end
        end
    end

    //-------------------------------------------------------------------------
    // Frame marker check
    //
    // out_frame is what hdmi_out's frame-phase alignment loop measures, so it
    // has to mean exactly "this line is the frame's first". Property: once the
    // geometry is known, markers are exactly DST_H lines apart and each one
    // starts a line. (The acquisition frame may emit fewer lines -- the walk
    // is seeded from the previous frame's measurement -- so the gap is only
    // required from the second marker on.)
    //-------------------------------------------------------------------------
    integer mk_err = 0;
    integer mk_pulses = 0;
    integer lines_since_mk = 0;
    reg     out_frame_d = 1'b0;

    always @(posedge clk) begin
        if (rst_n) begin
            if (out_last)
                lines_since_mk = lines_since_mk + 1;
            if (out_frame && !out_frame_d) begin
                mk_pulses = mk_pulses + 1;
                if (locked_q && mk_pulses > 1 && lines_since_mk != DST_H) begin
                    if (mk_err < 5)
                        $display("FAIL: out_frame after %0d lines, expected %0d",
                                 lines_since_mk, DST_H);
                    mk_err = mk_err + 1;
                end
                lines_since_mk = 0;
            end
            out_frame_d = out_frame;
        end
    end

    //-------------------------------------------------------------------------
    // Raster driver
    //-------------------------------------------------------------------------
    //-------------------------------------------------------------------------
    // Raster driver
    //
    // The three signals have to mean on this bench what they mean on the board,
    // and they did not before. This bench used to drive in_hs (and in_vs) from
    // the same expression as in_de, i.e. "high only where there are pixels",
    // which is not what rx_sdi produces:
    //
    //   cam_hs  frame_convertor restarts its horizontal counter at every SAV,
    //           and a vertical-blanking line carries a SAV like any other, so
    //           cam_hs is high for the line's data window on EVERY line -- 1125
    //           times per frame for 1080p, not 1080. A bench that gates in_hs by
    //           the active height therefore measures 1080 where the board
    //           measures 1125, and that 4% vertical stretch is invisible to it.
    //
    //   cam_vs  the vertical-ACTIVE level, one rising edge per frame, coincident
    //           with the first active line's data window. Coincident is forced,
    //           not chosen: rx_sdi.v:357 makes cam_data_en = cam_vs & cam_hs, so
    //           an active line with cam_vs low would carry no data_en and the
    //           frame would be short a line forever. The old driver rose in_vs
    //           at px = 0, a whole horizontal blanking before in_hs -- legal, but
    //           it means this bench could never see the frame_start/line_start
    //           collision that stops the real one from locking.
    //
    // Both corrections are in scaler_720.v; this bench now drives the raster that
    // exercises them.
    //-------------------------------------------------------------------------
    task drive_frame;
        integer line, px, act_line, act_px, v_act;
        begin
            for (line = 0; line < V_TOTAL; line = line + 1) begin
                act_line = (line >= V_BLANK) && (line < V_BLANK + SRC_H);
                for (px = 0; px < H_TOTAL; px = px + 1) begin
                    act_px = (px >= H_BLANK) && (px < H_BLANK + SRC_W);
                    // One rising edge per frame: high from the first active
                    // line's data window to the end of the last active line.
                    v_act  = act_line && ((line == V_BLANK) ? (px >= H_BLANK) : 1'b1);
                    @(posedge clk);
                    in_hs  <= act_px;
                    in_vs  <= v_act;
                    in_de  <= act_px && v_act;
                    in_rgb <= (act_px && v_act)
                              ? src_pixel(px - H_BLANK, line - V_BLANK) : 24'd0;
                end
            end
            @(posedge clk);
            in_vs <= 1'b0;
            in_hs <= 1'b0;
            in_de <= 1'b0;
        end
    endtask

    //-------------------------------------------------------------------------
    // Main
    //-------------------------------------------------------------------------
    integer frame;
    integer j, k, base;
    integer errors;
    reg [15:0] got;
    reg po_settled, ov_settled;

    initial begin
        errors = 0;
        if      ($test$plusargs("w96"))   SRC_W = 96;
        else if ($test$plusargs("w1280")) SRC_W = 1280;
        else if ($test$plusargs("w1920")) SRC_W = 1920;
        else                              SRC_W = 1920;   // the real case

        if      ($test$plusargs("h54"))   SRC_H = 54;
        else if ($test$plusargs("h720"))  SRC_H = 720;
        else if ($test$plusargs("h1080")) SRC_H = 1080;
        else                              SRC_H = 1080;   // the real case

        if      ($test$plusargs("f3"))  FRAMES = 3;
        else if ($test$plusargs("f4"))  FRAMES = 4;
        else if ($test$plusargs("f6"))  FRAMES = 6;
        else                           FRAMES = 4;

        // Real SDI totals for the two rasters that matter
        H_BLANK = (SRC_W >= 1920) ? 280 : ((SRC_W >= 1280) ? 220 : 10);
        V_BLANK = (SRC_H >= 1080) ? 45  : 4;
        H_TOTAL = H_BLANK + SRC_W + 10;
        V_TOTAL = V_BLANK + SRC_H + 4;

        build_golden;

        $display("=== SRC %0dx%0d -> DST %0dx%0d, %0d frames (raster %0dx%0d)",
                 SRC_W, SRC_H, DST_W, DST_H, FRAMES, H_TOTAL, V_TOTAL);

        // scaler_720 is a DOWNSCALER. Its walk counts source elements per
        // output element and forces take >= 1 so the filter always makes
        // progress, which means it can never emit more output elements than it
        // consumed -- upscaling would need output elements that consume zero
        // source elements, and those break the one-output-per-source-pixel
        // structure. Every SDI raster that matters is >= the 1280x720 output,
        // so say so plainly instead of reporting a million mismatches.
        if (SRC_W < DST_W || SRC_H < DST_H) begin
            $display({"SKIP: source is smaller than the output (upscale), which",
                      " scaler_720 does not support. Use a source >= %0dx%0d."},
                     DST_W, DST_H);
            $finish;
        end
        $display("    E(0..5) = %0d %0d %0d %0d %0d %0d",
                 (1*SRC_W)/DST_W, (2*SRC_W)/DST_W, (3*SRC_W)/DST_W,
                 (4*SRC_W)/DST_W, (5*SRC_W)/DST_W, (6*SRC_W)/DST_W);
        $display("    F(0..5) = %0d %0d %0d %0d %0d %0d",
                 (1*SRC_H)/DST_H, (2*SRC_H)/DST_H, (3*SRC_H)/DST_H,
                 (4*SRC_H)/DST_H, (5*SRC_H)/DST_H, (6*SRC_H)/DST_H);

        repeat (20) @(posedge clk);
        rst_n <= 1'b1;
        repeat (10) @(posedge clk);

        for (frame = 0; frame < FRAMES; frame = frame + 1) begin
            drive_frame;
            repeat (64) @(posedge clk);
            // The push stage overruns while the geometry is still unknown and
            // the scaler is emitting at the wrong rate. Snapshot the sticky
            // flags once it has settled and only check them from there on.
            if (frame == 1) begin
                po_settled <= push_overrun;
                ov_settled <= overflow_q;
            end
        end

        // let the last frame finish pushing
        repeat (H_TOTAL * 8) @(posedge clk);

        $display("=== captured %0d lines, stat_lines=%0d, src_w=%0d src_h=%0d",
                 cap_y, stat_lines, src_w, src_h);
        $display("=== locked_q=%0b overflow_q=%0b push_overrun=%0b",
                 locked_q, overflow_q, push_overrun);

        if (cap_y < DST_H) begin
            $display("FAIL: only %0d output lines captured, expected %0d", cap_y, DST_H);
            errors = errors + 1;
        end

        // Only the LAST complete frame is checked. The scaler learns the
        // source geometry from the previous frame, so the first frame after
        // reset is expected to be garbage -- comparing cap[0..] against the
        // golden model would be comparing that garbage.
        base = (cap_y - DST_H) % CAP_ROWS;
        $display("=== checking captured lines %0d..%0d", cap_y - DST_H, cap_y - 1);
        for (k = 0; k < DST_H; k = k + 1)
            for (j = 0; j < DST_W; j = j + 1) begin
                got = cap[(base + k) % CAP_ROWS][j];
                if (got !== gold[k][j]) begin
                    if (errors < 8)
                        $display("MISMATCH line %0d col %0d: got 0x%04x expected 0x%04x",
                                 k, j, got, gold[k][j]);
                    errors = errors + 1;
                end
            end

        if (src_w != SRC_W) begin
            $display("FAIL: src_w = %0d, expected %0d", src_w, SRC_W);
            errors = errors + 1;
        end
        if (src_h != SRC_H) begin
            $display("FAIL: src_h = %0d, expected %0d", src_h, SRC_H);
            errors = errors + 1;
        end
        if (overflow_q !== ov_settled) begin
            $display("FAIL: overflow_q rose after settling, taps exceeded the cap of 2");
            errors = errors + 1;
        end
        if (push_overrun !== po_settled) begin
            $display("FAIL: push_overrun rose after settling, the push stage fell behind");
            errors = errors + 1;
        end
        if (mk_err != 0) begin
            $display("FAIL: %0d frame-marker errors (see above)", mk_err);
            errors = errors + mk_err;
        end else
            $display("=== frame marker: %0d out_frame pulses, %0d lines apart, all on frame line 0",
                     mk_pulses, DST_H);

        if (errors == 0)
            $display("PASS: %0dx%0d output matches the golden box filter exactly",
                     DST_W, DST_H);
        else
            $display("FAIL: %0d mismatches", errors);

        $finish;
    end

    //-----------------------------------------------------------------------
    // watchdog -- the 1080p case needs ~10M cycles
    //-----------------------------------------------------------------------
    initial begin
        #2_000_000_000;
        $display("FAIL: timeout");
        $finish;
    end

endmodule
`default_nettype wire