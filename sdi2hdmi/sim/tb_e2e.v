//=============================================================================
// tb_e2e.v -- end-to-end testbench: simulated SDI frame -> HDMI raster.
//
// This is the test that was missing. tb_scaler_720 and tb_hdmi_out each proved
// their own module, but the two had never been run against each other, and the
// contract BETWEEN them -- how many lines the producer emits per frame versus
// how many the consumer claims -- is exactly the kind of thing neither module
// can check on its own.
//
// Chain exercised:
//     2200x1125 raster @ cam_clk  ->  scaler_720  ->  hdmi_out  ->  capture
//     (1920x1080 active)              148.5 MHz       wclk        RGB888
//                                        |            rclk = wclk/2
//                                        |               |
//                                     pix_valid      720p60 raster
//                                     pix_last
//                                     pix_data[15:0]
//
// What is verified
//   1. CONTENT. Every captured pixel is compared against an independently
//      written golden box filter over the same source frame. Not "it looks
//      right" -- exact, pixel for pixel, for a whole frame.
//
//   2. LINE SEQUENCE. Because the source pattern has a per-row ramp, every
//      captured line matches exactly one golden row. Recording WHICH row each
//      output line came from turns the producer/consumer rate balance into a
//      number: a perfect 0,1,2,...,719 means the two sides are exactly matched,
//      and any stall or slip shows up as a repeated or skipped index.
//
//   3. RATE BALANCE. Lines produced per frame versus lines claimed per frame,
//      held pixels, and the write-port overflow counters.
//
// Clocks are the real relationship: hdmi_pix_clk period is exactly twice
// cam_clk, because the MMCM divides by two to make the HDMI pixel clock.
//
// NOTE ON SCOPE: this stops at the TMDS encoder input (hs/vs/de/rgb888). The
// TMDSEncoder is VHDL, the serializer is an OSERDESE2 primitive, and neither
// can be simulated here. Everything written for this project IS covered.
//=============================================================================
`timescale 1ns / 1ps
`default_nettype none

module tb_e2e;

    //-------------------------------------------------------------------------
    // Source raster: real 3G-SDI 1080p60 timing
    //-------------------------------------------------------------------------
    localparam integer SRC_TOTAL_W = 2200;   // 1920 active + blanking
    localparam integer SRC_ACTIVE_W = 1920;
    localparam integer SRC_TOTAL_H = 1125;   // 1080 active + blanking
    localparam integer SRC_ACTIVE_H = 1080;

    localparam integer DST_W = 1280;
    localparam integer DST_H = 720;

    //-------------------------------------------------------------------------
    // Source start phase -- the one thing a board cannot choose
    //-------------------------------------------------------------------------
    //
    // On the board the HDMI raster is already running when the SDI receiver
    // locks, so the phase between the source's frame boundary and the raster's
    // is ARBITRARY. Here both counters leave reset together, which is phase 0:
    // the one phase that is always clean, and the phase every earlier run of
    // this bench happened to use. SRC_HOLD_LINES holds the source in blanking
    // for that many source lines before its frame 0. That is a PHASE shift and
    // nothing else -- the source still runs 1125 x 2200 with no inserted time
    // afterwards -- so it is not the stall that a "wait for the output frame"
    // loop used to inject into the school harness (see doc/03-flow.md pitfall 32).
    //
    //   1 source line = 2200 cam_clk = 2/3 of a raster row, so N lines of hold
    //   move the phase by 2N/3 raster rows:
    //     -generic_top "SRC_HOLD_LINES=1091"   ->  phase ~727 rows (add = 731)
    //     -generic_top "SRC_HOLD_LINES=1113"   ->  phase ~742 rows (add = 746)
    //   Those two are the phases the school harness could not settle until its
    //   own pacing was fixed. Both ask the alignment loop to lengthen ONE frame
    //   to 1481 / 1496 lines, nearly twice normal.
    //
    //     xsim e2e_sweep --R --testplusarg "hold=1091"  <- effective override
    //
    //   The plusarg wins when it is present. It is a plusarg and not a generic
    //   because PowerShell rewrites quoted arguments on the way to a .bat file
    //   ("SRC_HOLD_LINES=1091" reaches xelab as two arguments, doc/03-flow.md
    //   pitfall 6). The plusarg itself must ALSO be quoted when it reaches xsim:
    //   unquoted, the loader splits at '=' and dies with "Expected a switch but
    //   found 1091"; and PowerShell strips inner quotes on the way to a .bat,
    //   so put the command in a .cmd file (measured, same pitfall).
    parameter integer SRC_HOLD_LINES = 0;

    //-------------------------------------------------------------------------
    // Clocks. hdmi_pix_clk is exactly cam_clk/2, as the MMCM produces it.
    //-------------------------------------------------------------------------
    reg cam_clk = 1'b0;
    reg hdmi_pix_clk = 1'b0;
    always #3.367    cam_clk       = ~cam_clk;      // 148.5 MHz
    always #6.734    hdmi_pix_clk  = ~hdmi_pix_clk; //  74.25 MHz

    reg cam_rst_n = 1'b0;
    reg hdmi_rst_n = 1'b0;

    //-------------------------------------------------------------------------
    // Source stimulus
    //-------------------------------------------------------------------------
    reg  [23:0] src_rgb;
    reg         src_de, src_hs, src_vs;

    integer s_h = 0;
    integer s_v = 0;
    integer hold_left = SRC_HOLD_LINES;   // start-phase hold, in source lines
    integer src_hold  = SRC_HOLD_LINES;   // effective value (+hold=<lines> wins)

    // A pattern with structure on both axes and a per-row ramp, so that
    // neither a horizontal shift nor a vertical slip can pass unnoticed, and
    // so every output line is distinguishable from every other.
    function [23:0] src_pixel(input integer x, input integer y);
        reg [7:0] r, g, b;
        begin
            r = (x * 255) / (SRC_ACTIVE_W - 1);
            g = (y * 255) / (SRC_ACTIVE_H - 1);
            b = ((x + y) * 255) / (SRC_ACTIVE_W + SRC_ACTIVE_H - 2);
            src_pixel = {r, g, b};
        end
    endfunction

    // The source raster has to be one the hardware can actually produce, on two
    // counts that this bench used to get wrong.
    //
    // (a) cam_hs is high for the data window of EVERY line, vertical-blanking
    //     lines included: frame_convertor restarts its horizontal counter at
    //     each SAV, and a blanking line carries a SAV like any other. This bench
    //     used to gate src_hs by the active height as well, which kept in_hs off
    //     the blanking lines -- a raster that cannot occur here. It hid two
    //     defects, both of which stop the picture:
    //       * scaler_720 counted lines on the rising edge of in_hs, so the
    //         gated raster measured 1080 while the real one measures 1125 --
    //         1125/720 is a 4% vertical stretch -- and no test could tell;
    //       * px_in_line is reloaded to 0 by the first blanking-line in_hs, so
    //         latching src_w from it at the frame boundary reads 0 and locked_q
    //         never asserts.
    //     Both are fixed in scaler_720.v; this bench now exercises them.
    //
    // (b) cam_vs is the vertical-ACTIVE level and its rising edge coincides with
    //     the first active line's in_hs rise. That is forced, not chosen:
    //     rx_sdi.v:357 derives cam_data_en = cam_vs & cam_hs, so "active pixels
    //     while vs is low" is not representable on this source -- such a line
    //     would carry no data_en, and the frame would be short a line forever.
    //
    //     This bench used to park the edge at s_h = 2000 -- inside line 0's
    //     horizontal BLANKING, i.e. after its active pixels -- purely to keep
    //     frame_start off line_start, because those two used to collide in
    //     scaler_720 (measured then: lines_in_frame = 6479 after six frames,
    //     locked_q stuck). Dodging the collision in the bench hid a genuine
    //     defect: with the edge behind line 0, the scaler restarted its vertical
    //     walk one source line late, so output row k came from source row k+1
    //     for the whole frame.
    //
    //     The collision is fixed in the DUT, where it belongs, and the bench now
    //     drives the real phase. Positive skew is harmless by construction: the
    //     stale v_got at a frame boundary is 0 and out_y is already at DST_H, so
    //     the pixels processed before frame_start cannot be published. See
    //     scaler_720.v.
    //
    // de is the AND of the two, which is what rx_sdi does -- so src_de needs no
    // separate expression.
    always @(posedge cam_clk) begin
        if (!cam_rst_n) begin
            s_h     <= 0;
            s_v     <= 0;
            src_de  <= 1'b0;
            src_hs  <= 1'b0;
            src_vs  <= 1'b0;
            src_rgb <= 24'd0;
            // hold_left counts CAM_CLK CYCLES (the blanked branch below burns
            // one per cycle); src_hold is in source LINES. One line is
            // SRC_TOTAL_W = 2200 cam_clk, so convert here. Measured trap: an
            // earlier version loaded src_hold raw, so "hold=1091" held for 1091
            // cam_clk ~ 1/3 of a raster row and every phase tested phase 0 --
            // three different inputs, byte-identical output, all green.
            hold_left <= src_hold * SRC_TOTAL_W;
        end else if (hold_left != 0) begin
            // Start-phase hold: blank video, counters parked. No line starts and
            // no pixels are pushed, so this only delays the source's frame 0 by
            // that many lines -- the phase shift the board always has.
            hold_left <= hold_left - 1;
            src_de  <= 1'b0;
            src_hs  <= 1'b0;
            src_vs  <= 1'b0;
            src_rgb <= 24'd0;
        end else begin
            src_hs  <= (s_h < SRC_ACTIVE_W);
            src_vs  <= (s_v < SRC_ACTIVE_H);
            src_de  <= (s_h < SRC_ACTIVE_W) && (s_v < SRC_ACTIVE_H);
            if (s_h < SRC_ACTIVE_W)
                src_rgb <= src_pixel(s_h, s_v);
            else
                src_rgb <= 24'd0;

            if (s_h == SRC_TOTAL_W - 1) begin
                s_h <= 0;
                s_v <= (s_v == SRC_TOTAL_H - 1) ? 0 : s_v + 1;
            end else begin
                s_h <= s_h + 1;
            end
        end
    end

    //-------------------------------------------------------------------------
    // scaler_720
    //-------------------------------------------------------------------------
    wire        pix_valid, pix_last;
    wire [15:0] pix_data;
    wire [15:0] src_w, src_h;
    wire [31:0] scaler_lines;
    wire        scaler_locked, scaler_overflow, scaler_overrun;
    wire        pix_frame;   // scaler frame marker -> hdmi_out alignment loop

    scaler_720 #(.DST_W(DST_W), .DST_H(DST_H)) u_scaler (
        .clk          (cam_clk),
        .rst_n        (cam_rst_n),
        .in_rgb       (src_rgb),
        .in_de        (src_de),
        .in_hs        (src_hs),
        .in_vs        (src_vs),
        .out_valid    (pix_valid),
        .out_last     (pix_last),
        .out_frame    (pix_frame),
        .out_rgb      (pix_data),
        .src_w        (src_w),
        .src_h        (src_h),
        .stat_lines   (scaler_lines),
        .locked_q     (scaler_locked),
        .overflow_q   (scaler_overflow),
        .push_overrun (scaler_overrun)
    );

    //-------------------------------------------------------------------------
    // hdmi_out
    //-------------------------------------------------------------------------
    wire        hs, vs, de;
    wire [23:0] rgb;
    wire        stalled;
    wire [31:0] hdmi_frames;
    wire [31:0] stat_dropped;
    wire        overflow;

    // Mirror the top level: do not feed the HDMI side until the geometry is
    // measured. See rtl/sdi2hdmi_top.v for why.
    wire pix_valid_gated = pix_valid && scaler_locked;

    hdmi_out #(
        .H_ACTIVE (1280), .H_FP (110), .H_SYNC (40), .H_BP (220),
        .V_ACTIVE (720),  .V_FP (5),   .V_SYNC (5),  .V_BP (20),
        .HS_POL   (1),    .VS_POL (1)
    ) u_hdmi_out (
        .wclk         (cam_clk),
        .wrst_n       (cam_rst_n),
        .w_en         (pix_valid_gated),
        .w_last       (pix_last),
        .w_frame      (pix_frame),
        .w_data       (pix_data),
        .rclk         (hdmi_pix_clk),
        .rrst_n       (hdmi_rst_n),
        .hs           (hs),
        .vs           (vs),
        .de           (de),
        .rgb          (rgb),
        .stalled      (stalled),
        .stat_frames  (hdmi_frames),
        .stat_dropped (stat_dropped),
        .overflow     (overflow)
    );

    //-------------------------------------------------------------------------
    // Golden model: an independent box filter over the same source frame.
    //
    // Written the longhand way, E(j) = (j+1)*SRC_W/DST_W, F(k) likewise, in two
    // passes, so it is obviously the specification and not a copy of the DUT.
    //-------------------------------------------------------------------------
    reg [15:0] g565   [0:SRC_ACTIVE_H-1][0:SRC_ACTIVE_W-1];
    reg [15:0] ghs    [0:SRC_ACTIVE_H-1][0:DST_W-1];
    reg [15:0] gold   [0:DST_H-1][0:DST_W-1];

    task build_golden;
        integer j, k, x, y, e_prev, e_cur, f_prev, f_cur, nh, nv;
        reg [23:0] p;
        reg [31:0] acc;
        begin
            for (y = 0; y < SRC_ACTIVE_H; y = y + 1)
                for (x = 0; x < SRC_ACTIVE_W; x = x + 1) begin
                    p = src_pixel(x, y);
                    g565[y][x] = {p[23:19], p[15:10], p[7:3]};   // as the DUT truncates
                end

            e_prev = 0;
            for (j = 0; j < DST_W; j = j + 1) begin
                e_cur = ((j + 1) * SRC_ACTIVE_W) / DST_W;
                nh    = e_cur - e_prev;
                for (y = 0; y < SRC_ACTIVE_H; y = y + 1) begin
                    if (nh == 1)
                        ghs[y][j] = g565[y][e_prev];
                    else if (nh == 2)
                        ghs[y][j] = (g565[y][e_prev] + g565[y][e_prev+1]) >> 1;
                    else begin
                        acc = 0;
                        for (x = 0; x < nh; x = x + 1) acc = acc + g565[y][e_prev + x];
                        ghs[y][j] = acc >> 2;
                    end
                end
                e_prev = e_cur;
            end

            f_prev = 0;
            for (k = 0; k < DST_H; k = k + 1) begin
                f_cur = ((k + 1) * SRC_ACTIVE_H) / DST_H;
                nv    = f_cur - f_prev;
                for (j = 0; j < DST_W; j = j + 1) begin
                    if (nv == 1)
                        gold[k][j] = ghs[f_prev][j];
                    else if (nv == 2)
                        gold[k][j] = (ghs[f_prev][j] + ghs[f_prev+1][j]) >> 1;
                    else begin
                        acc = 0;
                        for (y = 0; y < nv; y = y + 1) acc = acc + ghs[f_prev + y][j];
                        gold[k][j] = acc >> 2;
                    end
                end
                f_prev = f_cur;
            end
        end
    endtask

    //-------------------------------------------------------------------------
    // Capture. RGB888 back to RGB565 is exact: the encoder replicates bits, so
    // rgb[23:19]/rgb[15:10]/rgb[7:3] recover the original 5/6/5 fields.
    //-------------------------------------------------------------------------
    reg [15:0] cap [0:DST_H-1][0:DST_W-1];

    integer c_px   = 0;
    integer c_row  = 0;
    integer frames_captured = 0;
    integer hold_px = 0;

    // Freeze handshake. cap is coherent only at the instant c_row wraps back to
    // 0; at every other instant it holds the tail of one frame and the head of
    // the next. Comparing cap without proving it is coherent makes the content
    // check a coin flip, and it was one: the old code waited a fixed 1.5 frame
    // times and then compared, which lands mid-frame about 75% of the time.
    // xsim happened to land clean, Verilator happened to land dirty, and the
    // two simulators disagreed about a design that was never wrong -- the check
    // was. So do not guess when cap is complete; let the capture say so.
    reg cap_freeze_req = 0;   // raised by the checker
    reg cap_frozen     = 0;   // raised here, only on a frame boundary

    always @(posedge hdmi_pix_clk) begin
        if (!hdmi_rst_n) begin
            c_px  <= 0;
            c_row <= 0;
            cap_frozen <= 0;
        end else begin
            if (stalled) hold_px = hold_px + 1;

            if (de && !cap_frozen) begin
                cap[c_row][c_px] <= {rgb[23:19], rgb[15:10], rgb[7:3]};
                if (c_px == DST_W - 1) begin
                    c_px  <= 0;
                    if (c_row == DST_H - 1) begin
                        c_row <= 0;
                        frames_captured = frames_captured + 1;
                        if (cap_freeze_req) cap_frozen <= 1'b1;
                    end else begin
                        c_row <= c_row + 1;
                    end
                end else begin
                    c_px <= c_px + 1;
                end
            end else if (!cap_frozen) begin
                c_px <= 0;
            end
        end
    end

    //-------------------------------------------------------------------------
    // Producer cadence and the real claim count.
    //
    // The claim count must be MEASURED. An earlier version printed
    // hdmi_frames * 750 / frames, which is an assumption dressed up as a
    // reading, and it kept reporting 750 even after the claim was gated on
    // in_vact and could only happen 720 times.
    //-------------------------------------------------------------------------
    integer gap_sum = 0;
    integer gap_n   = 0;
    integer gap_last = -1;
    integer gap_min = 1000000;
    integer gap_max = 0;

    always @(posedge cam_clk) begin
        if (cam_rst_n && pix_last) begin
            if (gap_last >= 0) begin
                gap_sum = gap_sum + ($time/1000 - gap_last);   // ps -> ns
                gap_n   = gap_n + 1;
                if (($time/1000 - gap_last) < gap_min) gap_min = ($time/1000 - gap_last);
                if (($time/1000 - gap_last) > gap_max) gap_max = ($time/1000 - gap_last);
            end
            gap_last = $time/1000;
        end
    end

    // Count the claims the DUT actually performs, not the ones it could do.
    integer claim_count = 0;
    always @(posedge hdmi_pix_clk) begin
        if (hdmi_rst_n && u_hdmi_out.claim_now && !u_hdmi_out.r_empty)
            claim_count = claim_count + 1;
    end

    // Track the line-slot occupancy so a saturating FIFO is visible as a shape
    // rather than inferred from a counter.
    integer depth_min = 99;
    integer depth_max = 0;
    always @(posedge cam_clk) begin
        if (cam_rst_n) begin
            if ((u_hdmi_out.w_bin - u_hdmi_out.r_bin & 15) < depth_min)
                depth_min = (u_hdmi_out.w_bin - u_hdmi_out.r_bin & 15);
            if ((u_hdmi_out.w_bin - u_hdmi_out.r_bin & 15) > depth_max)
                depth_max = (u_hdmi_out.w_bin - u_hdmi_out.r_bin & 15);
        end
    end

    //-------------------------------------------------------------------------
    // Frame-phase alignment activity.
    //
    // The loop is only worth having if the marker reaches it, so this counts
    // marker edges as seen in the read domain, how many frames were stretched,
    // what the first correction was, and what the marker phase was at the last
    // point the loop could act on -- the deadband's own evidence. A bench where
    // nothing is driven can look exactly like a bench where the loop works,
    // otherwise.
    //-------------------------------------------------------------------------
    integer mk_rises = 0;
    integer stretch_armed = 0;
    integer first_add = -1;            // -1 = no correction was taken
    integer last_want = -1;            // align_want at the last marker the loop could act on
    integer markers_at_stretch = 0;    // mk_rises when the most recent stretch began
    integer overflow_at_settle = 0;   // sampled after the settle window
    integer armed_at_settle    = 0;   // ditto: the loop must go quiet after it
    reg     wf_d2 = 1'b0;
    reg     ext_d = 1'b0;
    always @(posedge hdmi_pix_clk) begin
        if (hdmi_rst_n) begin
            wf_d2 <= u_hdmi_out.wf_rise;
            if (u_hdmi_out.wf_rise && !wf_d2) begin
                mk_rises = mk_rises + 1;
                if (first_add < 0 && u_hdmi_out.align_take)
                    first_add = u_hdmi_out.align_want;
                // The marker phase, sampled only when the loop could act on it:
                // markers arriving during a stretch (v_extra != 0) are ignored
                // by the loop and their p is meaningless. NOTE: this used to
                // print u_hdmi_out.align_want at print time instead -- a
                // free-running value at an arbitrary instant, i.e. a monitor
                // that lied. It must be sampled at the marker.
                if (u_hdmi_out.v_extra == 12'd0)
                    last_want = u_hdmi_out.align_want;
            end
            ext_d <= (u_hdmi_out.v_extra != 0);
            if ((u_hdmi_out.v_extra != 0) && !ext_d) begin
                stretch_armed = stretch_armed + 1;
                markers_at_stretch = mk_rises;
            end
        end
    end

    //-------------------------------------------------------------------------
    // Scaler-side capture.
    //
    // Needed to bisect a content mismatch: if the scaler's own output already
    // differs from the golden model, the fault is in the resampler; if it
    // matches, the fault is between scaler and the HDMI side.
    //-------------------------------------------------------------------------
    reg [15:0] scap [0:DST_H-1][0:DST_W-1];
    integer s_px = 0;
    integer s_row = 0;
    integer s_frames = 0;

    always @(posedge cam_clk) begin
        if (!cam_rst_n) begin
            s_px  <= 0;
            s_row <= 0;
        end else if (pix_valid) begin
            scap[s_row][s_px] <= pix_data;
            if (pix_last) begin
                s_px   <= 0;
                s_row  <= (s_row == DST_H - 1) ? 0 : s_row + 1;
                if (s_row == DST_H - 1) s_frames = s_frames + 1;
            end else begin
                s_px <= s_px + 1;
            end
        end
    end

    // NOTE: this does NOT compare scaler rows against golden rows by index, and an
    // earlier version did. That is wrong: scap's row index only advances on
    // pix_last and is never re-aligned to a frame boundary, while the scaler
    // emits a different number of lines in its measurement frame than in
    // steady state. The index therefore drifts, and the check reported all 720
    // rows as differing while the HDMI side -- which is checked against golden
    // properly, in compare_frame -- was exact.
    //
    // What is worth asserting here is only that the resampler is producing
    // something. Row-level correctness of the resampler is the job of
    // tb_scaler_720.v, which compares it against the golden model with its own
    // capture that IS frame-aligned.
    task bisect_content;
        integer rr, cc, nz, mism;
        begin
            nz = 0;
            mism = 0;
            for (rr = 0; rr < DST_H; rr = rr + 1)
                for (cc = 0; cc < DST_W; cc = cc + 1)
                    if (scap[rr][cc] !== 16'h0000 && scap[rr][cc] !== 16'hxxxx) nz = nz + 1;
            $display("BISECT  scaler non-zero captured pixels: %0d of %0d", nz, DST_H * DST_W);
            if (nz == 0)
                $display("BISECT  FAIL scaler produced nothing");
            else
                $display("BISECT  OK resampler is producing data (row-level check is tb_scaler_720's job)");
        end
    endtask

    //-------------------------------------------------------------------------
    // Occupancy trace. min=0 and max=8 in the same run means the FIFO is both
    // starving and saturating, which is oscillation rather than a steady offset.
    // Only the shape distinguishes them, so record it.
    //-------------------------------------------------------------------------
    integer trace_n = 0;
    always @(posedge cam_clk) begin
        if (cam_rst_n && trace_n < 240) begin
            if (trace_n % 20 == 0)
                $display("TRACE   t=%0t depth=%0d w_bin=%0d r_bin=%0d w_en=%0b full=%0b pushed=%0d claims=%0d",
                         $time,
                         (u_hdmi_out.w_bin - u_hdmi_out.r_bin) & 15,
                         u_hdmi_out.w_bin, u_hdmi_out.r_bin,
                         pix_valid, u_hdmi_out.w_full,
                         scaler_lines, claim_count);
            trace_n = trace_n + 1;
        end
    end

    //-------------------------------------------------------------------------
    // Main
    //-------------------------------------------------------------------------
    integer f, r, c, k, matched, err_px, err_line;
    integer seq_bad;

    // line_miss is module level, not local to compare_frame, and that is the
    // point. It used to be a local, so the "FAIL ... matches NO golden row"
    // lines were printed by a counter that nothing ever read back: the verdict
    // below tested pre_fail and seq_bad only. A run could print 720 content
    // failures and still print "PASS: content exact on every frame". That is
    // the same defect class as the all-zero capture that once passed -- a check
    // whose failure cannot reach the verdict is not a check. Verilator found it
    // by making the content check fail for a testbench reason; the missing
    // wiring is what let the contradiction stand instead of being reported.
    integer line_miss;
    integer rows_exact;
    // The capture is a ROTATION of the golden frame, not a copy of it: hdmi_out
    // is a ring of line slots and the reader's frame boundary is its own vsync,
    // so the displayed frame sits at a constant offset of (ring occupancy) lines
    // from the producer's line 0. Measured: 2 lines. A constant rotation is a
    // fixed vertical position -- invisible -- so it is not a failure.
    //
    // What IS a failure, and what this used to conflate: no row matching any
    // golden row (wrong data), and rows sitting at DIFFERENT phases within one
    // frame (a rolling picture). The old verdict counted the second as
    // "line-order slips ... producer/consumer rate mismatch" and failed on it,
    // which is both the wrong diagnosis and the wrong verdict for a rotation.
    integer phase_off;      // golden row for capture row 0, this frame
    integer cap_frame;
    integer dropped_prev = 0;
    integer lines_prev   = 0;
    integer claims_prev  = 0;
    integer steady_dropped = 0;
    integer steady_lines   = 0;
    integer steady_claims  = 0;

    // NOTE: no `break` here. xvlog compiles this as Verilog-2001, where `break`
    // is a SystemVerilog keyword and elaboration fails with
    //   [VRFC 10-2989] 'break' is not declared
    // Early-exit is done with a flag and a while loop instead.
    task compare_frame(input integer frame_index);
        integer line_ok, got_row, want_row;
        begin
            line_miss  = 0;
            rows_exact = 0;

            // ---- the frame's vertical phase, from row 0 alone ----------------
            // The phase is constant across the frame by construction, so finding
            // it from one row keeps this at O(2*DST_H*DST_W). Testing every row
            // against every golden row is O(DST_H^2 * DST_W) = 6.6e8 compares,
            // which xsim takes minutes over and which is why the old version
            // only did the full search for rows that already mismatched.
            phase_off = -1;
            k = 0;
            while (k < DST_H && phase_off < 0) begin
                line_ok = 1;
                c = 0;
                while (c < DST_W && line_ok == 1) begin
                    if (cap[0][c] !== gold[k][c]) line_ok = 0;
                    c = c + 1;
                end
                if (line_ok == 1) phase_off = k;
                k = k + 1;
            end

            if (phase_off < 0) begin
                line_miss = DST_H;
                $display("FAIL   frame %0d: capture row 0 matches NO golden row -- content is wrong",
                         frame_index);
            end else begin
                for (r = 0; r < DST_H; r = r + 1) begin
                    want_row = (phase_off + r) % DST_H;

                    // does this row sit where the frame phase says it should?
                    line_ok = 1;
                    c = 0;
                    while (c < DST_W && line_ok == 1) begin
                        if (cap[r][c] !== gold[want_row][c]) line_ok = 0;
                        c = c + 1;
                    end

                    if (line_ok == 1) begin
                        rows_exact = rows_exact + 1;
                    end else begin
                        // which golden row does it actually come from?
                        got_row = -1;
                        k = 0;
                        while (k < DST_H && got_row < 0) begin
                            line_ok = 1;
                            c = 0;
                            while (c < DST_W && line_ok == 1) begin
                                if (cap[r][c] !== gold[k][c]) line_ok = 0;
                                c = c + 1;
                            end
                            if (line_ok == 1) got_row = k;
                            k = k + 1;
                        end

                        if (got_row < 0) begin
                            line_miss = line_miss + 1;
                            if (line_miss <= 3)
                                $display("FAIL   frame %0d row %0d: matches NO golden row (content wrong)",
                                         frame_index, r);
                        end else begin
                            seq_bad = seq_bad + 1;
                            if (seq_bad <= 6)
                                $display({"SEQ    frame %0d row %0d came from golden row %0d, but the",
                                          " frame phase says %0d"},
                                         frame_index, r, got_row, want_row);
                        end
                    end
                end
            end

            if (line_miss != 0)
                $display("FAIL   frame %0d: %0d rows matched no golden row at all",
                         frame_index, line_miss);
        end
    endtask

    //=========================================================================
    // Preconditions.
    //
    // This block exists because the first run of this testbench reported PASS
    // while the DUT was emitting nothing at all. scaler_720 had produced zero
    // lines, locked_q was 0, and the capture buffer was all zeros -- and the
    // content check still passed, because gold[0][0] is also zero. Comparing
    // two buffers of zeros is a pass that verifies nothing.
    //
    // So before any content comparison, prove the stimulus actually moved:
    // the geometry locked, lines came out, the capture is not uniform, and the
    // golden model is not uniform. Any of these failing means the comparison
    // below is meaningless and must not be allowed to print PASS.
    //=========================================================================
    integer pre_fail = 0;

    task check_preconditions;
        integer g, h, nz_gold, nz_cap, n;
        begin
            if (scaler_locked !== 1'b1) begin
                $display("PRE    FAIL scaler_locked=%0b -- geometry never measured", scaler_locked);
                pre_fail = pre_fail + 1;
            end
            if (scaler_lines == 0) begin
                $display("PRE    FAIL scaler emitted 0 lines -- nothing reached hdmi_out");
                pre_fail = pre_fail + 1;
            end
            if (src_w != SRC_ACTIVE_W || src_h != SRC_ACTIVE_H) begin
                $display("PRE    FAIL geometry %0dx%0d, expected %0dx%0d",
                         src_w, src_h, SRC_ACTIVE_W, SRC_ACTIVE_H);
                pre_fail = pre_fail + 1;
            end

            nz_gold = 0;
            for (g = 0; g < DST_H; g = g + 1)
                for (h = 0; h < DST_W; h = h + 1)
                    if (gold[g][h] !== 16'h0000) nz_gold = nz_gold + 1;
            if (nz_gold == 0) begin
                $display("PRE    FAIL golden model is all zero -- the reference is worthless");
                pre_fail = pre_fail + 1;
            end

            nz_cap = 0;
            for (g = 0; g < DST_H; g = g + 1)
                for (h = 0; h < DST_W; h = h + 1)
                    if (cap[g][h] !== 16'h0000) nz_cap = nz_cap + 1;
            if (nz_cap == 0) begin
                $display("PRE    FAIL capture is all zero -- HDMI side received nothing");
                pre_fail = pre_fail + 1;
            end

            $display("PRE    golden non-zero pixels=%0d  capture non-zero pixels=%0d",
                     nz_gold, nz_cap);
        end
    endtask

    initial begin
        $display("=== tb_e2e: SDI frame -> scaler_720 -> hdmi_out -> 720p60 raster ===");
        // +hold=<lines> overrides the parameter. Read here, before reset is
        // released, because the source generator samples it on release.
        if ($value$plusargs("hold=%d", src_hold))
            $display("    (+hold plusarg overrides SRC_HOLD_LINES=%0d)", SRC_HOLD_LINES);
        $display("    source raster %0dx%0d (active %0dx%0d) @ 148.5 MHz",
                 SRC_TOTAL_W, SRC_TOTAL_H, SRC_ACTIVE_W, SRC_ACTIVE_H);
        $display("    hdmi_pix_clk = cam_clk/2, as the MMCM divides it");
        $display("    source start hold: %0d lines (0 = both boundaries start together)",
                 src_hold);
        $display("    scope ends at the TMDS encoder input (hs/vs/de/rgb888)");

        $display("");
        $display("--- building golden box filter ---");
        build_golden;
        $display("--- golden built, e.g. gold[0][0]=%04h gold[0][1]=%04h gold[719][1279]=%04h",
                 gold[0][0], gold[0][1], gold[719][1279]);

        repeat (20) @(posedge cam_clk);
        cam_rst_n   <= 1'b1;
        hdmi_rst_n  <= 1'b1;
        repeat (20) @(posedge hdmi_pix_clk);

        // Enough frames for geometry to lock plus several steady-state frames.
        repeat (SRC_TOTAL_W * SRC_TOTAL_H * 6) @(posedge cam_clk);

        // Settled state of the alignment loop, sampled after the settling
        // window. A large start phase (SRC_HOLD_LINES) is corrected exactly
        // once, inside that window; anything that moves after it -- another
        // stretch, a new overflow -- is a loop that never settled. This is the
        // steady-state form of the same rule the per-frame accounting below
        // uses for stat_dropped.
        overflow_at_settle = overflow;
        armed_at_settle    = stretch_armed;

        $display("");
        $display("--- line cadence (cam_clk ns between scaler output lines) ---");
        if (gap_n > 0)
            $display("=== cadence mean=%0d min=%0d max=%0d samples=%0d cam_clk",
                     gap_sum / gap_n, gap_min, gap_max, gap_n);
        $display("    HDMI consumer needs one line per 1650 hdmi_pix_clk = 22.2 us = 3300 cam_clk");

        $display("");
        $display("=== producer / consumer balance ===");
        $display("=== scaler lines emitted   : %0d  (src geometry %0dx%0d, locked=%0b)",
                 scaler_lines, src_w, src_h, scaler_locked);
        $display("=== scaler_lines / frame   : %0d", scaler_lines / 6);
        $display("=== hdmi_out frames        : %0d", hdmi_frames);
        $display("=== claims actually made   : %0d  (%0d per frame)",
                 claim_count, (hdmi_frames > 0) ? claim_count / hdmi_frames : 0);
        $display("=== line-slot depth        : min=%0d max=%0d (of 8)", depth_min, depth_max);
        $display("=== held pixels (stalled) : %0d", hold_px);
        $display("=== stat_dropped          : %0d", stat_dropped);
        $display("=== overflow               : %0b", overflow);
        $display("=== scaler overflow_q      : %0b  push_overrun=%0b",
                 scaler_overflow, scaler_overrun);
        $display("=== alignment loop         : %0d markers seen, %0d frames stretched (%0d of them after the settle window), first add=%0d, want at last clean marker=%0d",
                 mk_rises, stretch_armed, stretch_armed - armed_at_settle, first_add, last_want);
        $display("=== start phase            : +hold=%0d source lines = %0d cam_clk (1 line = 2/3 raster row)",
                 src_hold, src_hold * SRC_TOTAL_W);

        $display("");
        $display("--- preconditions ---");
        check_preconditions;

        $display("");
        $display("--- bisect: scaler output vs golden ---");
        bisect_content;

        // Per-frame accounting. Whether stat_dropped KEEPS GROWING is the only
        // thing that separates a start-up transient from a steady-state rate
        // imbalance, and a single end-of-run total cannot tell them apart.
        $display("");
        $display("=== per-frame accounting (dropped is cumulative) ===");
        for (f = 1; f <= 5; f = f + 1) begin
            dropped_prev = stat_dropped;
            lines_prev   = scaler_lines;
            claims_prev  = claim_count;
            repeat (SRC_TOTAL_W * SRC_TOTAL_H) @(posedge cam_clk);
            $display("=== frame %0d: scaler_lines +%0d  claims +%0d  dropped +%0d  (cum dropped %0d)",
                     f, scaler_lines - lines_prev, claim_count - claims_prev,
                     stat_dropped - dropped_prev, stat_dropped);
            if (f >= 2) begin
                steady_dropped = steady_dropped + (stat_dropped - dropped_prev);
                steady_lines   = steady_lines   + (scaler_lines  - lines_prev);
                steady_claims  = steady_claims  + (claim_count  - claims_prev);
            end
        end
        $display("=== steady-state totals over frames 2..6: lines=%0d claims=%0d dropped=%0d",
                 steady_lines, steady_claims, steady_dropped);

        $display("");
        $display("=== captured frames         : %0d", frames_captured);

        // NOTE: cap is a single frame buffer that the capture stage cycles
        // through, so compare_frame() compares ONE captured frame. Running it in
        // a loop over frame indices, as an earlier version did, compares the
        // same buffer six times and looks like six frames of evidence.
        //
        // Ask the capture to freeze on its next frame boundary and wait for it.
        // Do NOT wait a fixed number of cycles: a fixed wait lands mid-frame
        // most of the time, and the comparison then reports a mix of two frames
        // as a content failure. The freeze makes the snapshot coherent by
        // construction instead of by luck.
        cap_freeze_req = 1;
        while (!cap_frozen) @(posedge hdmi_pix_clk);
        repeat (4) @(posedge hdmi_pix_clk);   // let the last NBA land
        $display("--- content check, one frozen frame ---");
        seq_bad = 0;
        compare_frame(frames_captured - 1);
        $display("=== frame phase (golden row for capture row 0) : %0d", phase_off);
        $display("=== rows exact at that frame phase             : %0d of %0d",
                 rows_exact, DST_H);
        $display("=== rows at an inconsistent phase              : %0d", seq_bad);

        // Content and phase consistency must both reach the verdict, or the FAIL
        // lines above are decoration.
        if (line_miss != 0 || rows_exact != DST_H) begin
            $display("=== FAIL: %0d rows matched no golden row, %0d of %0d rows exact at the phase",
                     line_miss, rows_exact, DST_H);
            pre_fail = pre_fail + 1;
        end
        if (seq_bad != 0) begin
            $display({"=== FAIL: %0d rows sit at a different phase than the rest",
                      " -- the picture is ROLLING"}, seq_bad);
            pre_fail = pre_fail + 1;
        end

        // The overflow assertion has to judge the STEADY STATE. A cumulative
        // total cannot distinguish a start-up transient from a running rate
        // imbalance, and demanding a lifetime total of zero would have sent me
        // hunting a bug that was already fixed.
        if (steady_dropped != 0) begin
            $display("=== FAIL: %0d pixels discarded during the 5 steady-state frames", steady_dropped);
            $display("===       producer and consumer are not balanced");
            pre_fail = pre_fail + 1;
        end
        if (overflow !== overflow_at_settle) begin
            $display("=== FAIL: overflow latched during the steady-state frames (a start-up");
            $display("===       transient is allowed and was already there; a new one is not)");
            pre_fail = pre_fail + 1;
        end
        if (stretch_armed != armed_at_settle) begin
            $display("=== FAIL: the alignment loop stretched %0d more frame(s) after the settle window",
                     stretch_armed - armed_at_settle);
            $display("===       -- it is still correcting, so it never settled");
            pre_fail = pre_fail + 1;
        end
        if (steady_lines != 4 * DST_H || steady_claims != 4 * DST_H) begin
            $display("=== FAIL: steady state moved %0d lines and %0d claims over 4 frames, expected %0d each",
                     steady_lines, steady_claims, 4 * DST_H);
            pre_fail = pre_fail + 1;
        end

        // The alignment loop's own evidence. The sweep's holds put the source
        // hundreds of rows out of phase, so a loop that did nothing would show
        // first add=0 -- instead the load-bearing claims are: markers reached
        // the loop, it corrected exactly once, and the NEXT marker it could act
        // on already sat inside the deadband (align_want 0/1/749 is skipped).
        if (mk_rises < 2) begin
            $display("=== FAIL: only %0d frame markers reached the alignment loop", mk_rises);
            pre_fail = pre_fail + 1;
        end
        if (u_hdmi_out.align_add != 12'd0) begin
            $display("=== FAIL: the loop asked for another %0d-line correction at the last marker",
                     u_hdmi_out.align_add);
            pre_fail = pre_fail + 1;
        end
        if (mk_rises > markers_at_stretch &&
            last_want != 0 && last_want != 1 && last_want != 749) begin
            $display("=== FAIL: after the last stretch the marker landed at want=%0d, outside the",
                     last_want);
            $display("===       deadband -- the loop did not settle where it should");
            pre_fail = pre_fail + 1;
        end

        if (pre_fail != 0)
            $display("=== FAIL: %0d problem(s) -- see above", pre_fail);
        else
            $display("=== PASS: %0d of %0d captured rows exact against golden, line order exact, no data lost",
                     rows_exact, DST_H);

        $finish;
    end

    initial begin
        #2_000_000_000;
        $display("FAIL: timeout");
        $finish;
    end

endmodule
`default_nettype wire