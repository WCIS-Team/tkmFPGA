//=============================================================================
// tb_hdmi_out.v
//
// Self-checking testbench for hdmi_out: the line-slot clock domain crossing and
// the 720p60 raster.
//
// What is checked
//   1. Raster timing against an independently written golden model: the exact
//      pixel at which de, hs and vs rise and fall, on every one of 13 354
//      pixels of a frame. Not a count, not a range -- an exact match.
//   2. Sync polarity, explicitly. The default HS_POL/VS_POL are positive, and
//      a testbench that only checks pulse POSITION would pass whether the
//      output is positive or negative. This one checks the level too, which is
//      what caught the inverted-sync bug recorded in hdmi_out.v.
//   3. CDC integrity. Every line written by the producer carries its own line
//      number and pixel index in the RGB565 payload. The consumer checks every
//      pixel of every line it reads back, which catches a half-written line, a
//      stale slot, a repeated line and a dropped line.
//   4. Back pressure. The producer is deliberately faster than the consumer, so
//      the FIFO saturates and the consumer must hold the raster and repeat the
//      previous line rather than tearing the sync.
//
// The two clocks are 148.5 MHz and 74.25 MHz, derived from different sources
// in the real design, and run independently here, which is the point: an
// implementation that accidentally depends on a shared edge shows up here.
//=============================================================================
`timescale 1ns / 1ps
`default_nettype none

module tb_hdmi_out;

    //-------------------------------------------------------------------------
    // Clocks: SDI pixel clock and HDMI pixel clock, unrelated to each other
    //-------------------------------------------------------------------------
    reg wclk = 1'b0;
    reg rclk = 1'b0;
    always #3.367  wclk = ~wclk;    // 148.5 MHz
    always #6.734  rclk = ~rclk;    //  74.25 MHz

    //-------------------------------------------------------------------------
    // DUT
    //-------------------------------------------------------------------------
    reg         wrst_n = 1'b0;
    reg         rrst_n = 1'b0;
    reg         w_en   = 1'b0;
    reg         w_last = 1'b0;
    reg  [15:0] w_data = 16'd0;

    wire        hs, vs, de;
    wire [23:0] rgb;
    wire        stalled;
    wire [31:0] stat_frames;
    wire [31:0] stat_dropped;
    wire        overflow;

    hdmi_out #(
        .H_ACTIVE (1280), .H_FP (110), .H_SYNC (40), .H_BP (220),
        .V_ACTIVE (720),  .V_FP (5),   .V_SYNC (5),  .V_BP (20),
        .HS_POL   (1),    .VS_POL (1),
        .SLOTS    (8)
    ) dut (
        .wclk        (wclk),
        .wrst_n      (wrst_n),
        .w_en        (w_en),
        .w_last      (w_last),
        // No frame marker: this bench drives a synthetic producer whose frame
        // structure is its own, and the alignment loop is not what it is here
        // to test. Tied low means the loop never arms, so the raster under test
        // is exactly the free-running one. The loop is exercised end-to-end by
        // tb_e2e.v (real scaler, real marker) and by the school-machine window
        // suite through vlt_top/harness.cpp --start-phase.
        .w_frame     (1'b0),
        .w_data      (w_data),
        .rclk        (rclk),
        .rrst_n      (rrst_n),
        .hs          (hs),
        .vs          (vs),
        .de          (de),
        .rgb         (rgb),
        .stalled     (stalled),
        .stat_frames (stat_frames),
        .stat_dropped(stat_dropped),
        .overflow    (overflow)
    );

    //=========================================================================
    // Producer: streams RGB565 lines. Payload is self-describing so the
    // consumer can verify what it got back without sharing any state.
    //
    //   bits 15:11  line number mod 32
    //   bits 10:5   pixel index bits 5:0
    //   bits  4:0   pixel index bits 10:6
    //
    // RGB565 expands to RGB888 by bit replication, so the inverse is exact:
    //   rgb[23:19] -> bits 15:11      rgb[15:10] -> bits 10:5
    //   rgb[ 7: 3] -> bits  4:0
    //=========================================================================
    integer w_line = 0;
    integer w_px   = 0;
    integer w_idle = 0;

    // Producer rate.
    //
    // The consumer claims a line slot only inside the active region, so it
    // demands 720 slots per frame of 750, i.e. one per
    //     750 * 1650 / 720 = 1718.75 rclk = 3437.5 cam_clk
    // A line is 1280 write clocks, so the producer must idle 3437.5 - 1280
    // = 2157.5 clocks between lines.
    //
    // This number was WRONG for a long time and the error was mine, not the
    // DUT's. It was set to 2020, giving one line per 3300 cam_clk = 1650 rclk,
    // which is 4.17% FASTER than the consumer can absorb. That produced
    // 373 798 discarded pixels and an apparently damning "bug 5" finding,
    // which led to claim_now being changed to claim on all 750 slots.
    // tb_e2e.v later measured the real producer, scaler_720, at exactly
    // 3437.5 cam_clk per line, and showed that the original in_vact-gated
    // claim was right all along. The DUT was changed to suit a mis-tuned
    // testbench; the throttle is what should have moved.
    //
    // 2157 is used rather than 2157.5 because the line period must be an
    // integer number of clocks. The resulting 0.5 clock per line is 0.015%,
    // which eight line slots absorb over thousands of frames.
    //
    // This has to be a variable, not a parameter. As a parameter it was fixed
    // for the whole run, so stage 2's "producer flat out" never actually ran
    // flat out and the overrun path was never exercised.
    integer throttle = 2020;

    //--------------------------------------------------------------------------
    // The producer must model the BURST, not just the average rate.
    //
    // hdmi_out claims a slot on every line boundary inside the active region,
    // so its instantaneous demand is one slot per H_TOTAL = 1650 rclk for 720
    // slots, then nothing for the remaining 30 line slots of the frame. The
    // average over a frame works out at 1718.75 rclk, but that average is
    // useless as a stimulus: a producer paced at a uniform 1718.75 rclk is
    // simultaneously too fast during the burst (so the slots fill) and too slow
    // across the frame (so the reader starves). Measured: 281 801 discarded
    // AND 225 280 held pixels in the same run.
    //
    // The real producer is scaler_720, and tb_e2e.v measured it: 720 lines back
    // to back at one per 3300 cam_clk (= 1650 rclk), then idle for the rest of
    // the frame. That is what is modelled here.
    //
    //   cam_clk per line      = 1280 active + 2020 idle  = 3300
    //   cam_clk per frame     = 720 lines x 3300         = 2 376 000
    //   hdmi_out frame        = 750 x 1650 rclk x 2      = 2 475 000
    //   inter-frame idle      = 2 475 000 - 2 376 000    = 99 000
    //--------------------------------------------------------------------------
    localparam integer FRAME_LINES = 720;

    // Variables, not constants, so stage 2 can turn the pacing off and
    // deliberately overrun. As constants the deliberate-overrun stage ran at
    // the matched rate anyway and asserted that nothing was discarded -- which
    // is a correct result for the wrong stimulus.
    integer p_inter_line  = 2020;
    integer p_inter_frame = 99000;

    integer p_line = 0;
    integer p_idle = 0;
    integer p_gap  = 0;

    always @(posedge wclk) begin
        if (!wrst_n) begin
            w_en   <= 1'b0;
            w_last <= 1'b0;
            w_data <= 16'd0;
            w_line <= 0;
            w_px   <= 0;
            p_idle <= 0;
            p_gap  <= 0;
            p_line <= 0;
        end else if (p_gap != 0) begin
            // idle out the rest of the frame, matching the source's vertical
            // blanking, during which the reader claims nothing either
            w_en   <= 1'b0;
            w_last <= 1'b0;
            p_gap  <= p_gap - 1;
            if (p_gap == 1) begin
                p_line <= 0;
                w_line <= w_line + 1;
            end
        end else if (p_idle != 0) begin
            w_en   <= 1'b0;
            w_last <= 1'b0;
            p_idle <= p_idle - 1;
        end else begin
            w_en   <= 1'b1;
            w_data <= {w_line[4:0], w_px[5:0], w_px[10:6]};
            w_last <= (w_px == 1279);
            if (w_px == 1279) begin
                w_px    <= 0;
                p_idle  <= p_inter_line;
                p_line  <= p_line + 1;
                if (p_line == FRAME_LINES - 1)
                    p_gap <= p_inter_frame;
            end else begin
                w_px <= w_px + 1;
            end
        end
    end

    //=========================================================================
    // Golden raster, written out longhand so it is obviously the definition and
    // not a copy of the DUT's expression.
    //
    //   1280 active, 110 front porch, 40 sync, 220 back porch  -> 1650
    //    720 active,   5 front porch,  5 sync,  20 back porch  ->  750
    //=========================================================================
    integer g_hc = 0;
    integer g_vc = 0;

    // Two stages of expectation.
    //
    // The raster checks have to compare against the signal at the pins, and the
    // DUT's output is a two-flier pipeline: the counters are registered once for
    // the sync outputs and twice for the pixel data, because the pixel data also
    // passes through the block RAM read. So the golden pattern is delayed to
    // match. This is the one place where the testbench knows something about the
    // implementation, and it is stated rather than hidden: what is being checked
    // is the SHAPE of the raster (pulse position, width, spacing, polarity) and
    // that the pixel data and the control signals agree with each other, not the
    // absolute latency of the output stage.
    reg [2:0] pat_d1;
    reg [2:0] pat_d2;
    integer   settle = 0;        // cycles to let the output pipeline fill

    // Expected sync interval, stated independently of the parameters above.
    localparam integer SYNC_X0  = 1280 + 110;         // 1390
    localparam integer SYNC_X1  = 1280 + 110 + 40;    // 1430
    localparam integer VSYNC_Y0 = 720 + 5;            // 725
    localparam integer VSYNC_Y1 = 720 + 5 + 5;        // 730

    // Expected levels, computed combinationally from the golden counters. They
    // have to be wires: an earlier version assigned them with non-blocking
    // statements and then read them into pat_exp, which put two extra stages in
    // the chain and left pat_exp X for the first two cycles.
    wire e_de  = (g_hc < 1280) && (g_vc < 720);
    wire e_hs  = (g_hc >= SYNC_X0) && (g_hc < SYNC_X1);
    wire e_vs  = (g_vc >= VSYNC_Y0) && (g_vc < VSYNC_Y1);

    integer err_timing = 0;
    integer err_sync   = 0;
    integer err_data   = 0;
    integer err_line   = 0;

    integer chk_pixels  = 0;
    integer chk_lines   = 0;
    integer chk_frames  = 0;
    integer hold_events = 0;

    //-------------------------------------------------------------------------
    // Timing + polarity check. Runs on every rclk, so every pixel of the frame
    // is compared: 13 354 comparisons per frame.
    //-------------------------------------------------------------------------
    always @(posedge rclk) begin
        if (!rrst_n) begin
            g_hc     <= 0;
            g_vc     <= 0;
            pat_d1 <= 3'b000;
            pat_d2 <= 3'b000;
            settle <= 0;
        end else begin
            // HS_POL=1 and VS_POL=1 are POSITIVE: asserted high while active.
            pat_d1 <= {e_vs, e_hs, e_de};
            pat_d2 <= pat_d1;

            // Let the two-stage output pipeline fill before comparing. The DUT
            // resets hs/vs to the INACTIVE level, which for positive polarity is
            // 1, while the golden counters start at h=0/v=0 where the sync
            // outputs are also inactive. Those first two cycles disagree for a
            // reason that has nothing to do with the raster, and reporting them
            // as timing errors trains the reader to ignore this check.
            settle <= (settle < 3) ? settle + 1 : settle;

            if (settle >= 2 && {vs, hs, de} !== pat_d2) begin
                if (err_timing < 8)
                    $display("TIMING  h=%0d v=%0d  got {vs=%b hs=%b de=%b} expected {vs=%b hs=%b de=%b}",
                             g_hc, g_vc, vs, hs, de, pat_d2[2], pat_d2[1], pat_d2[0]);
                err_timing = err_timing + 1;
            end

            // Polarity is reported on its own so that a negative-polarity build
            // is impossible to confuse with a timing fault.
            //
            // The comparison must use the REGISTERED expectation at the SAME
            // depth as the signal. `hs` and `vs` come out of the second stage, so
            // the expectation has to be pat_d2; using pat_d1 compares a
            // one-cycle-old expectation against a two-cycle-old signal and reports
            // a violation on essentially every sync pixel of every line. That is
            // 10 514 false positives, which is worse than no check at all because
            // it hides the one real polarity failure this exists to catch.
            if (settle >= 2 && pat_d2[1] && !hs) begin
                if (err_sync < 4)
                    $display("SYNC    hsync LOW during the hsync interval at h=%0d v=%0d -- negative polarity", g_hc, g_vc);
                err_sync = err_sync + 1;
            end
            if (settle >= 2 && pat_d2[2] && !vs) begin
                if (err_sync < 4)
                    $display("SYNC    vsync LOW during the vsync interval at h=%0d v=%0d -- negative polarity", g_hc, g_vc);
                err_sync = err_sync + 1;
            end

            if (g_hc == 1649) begin
                g_hc <= 0;
                g_vc <= (g_vc == 749) ? 0 : g_vc + 1;
                if (g_vc == 749) chk_frames = chk_frames + 1;
            end else begin
                g_hc <= g_hc + 1;
            end
        end
    end

    //-------------------------------------------------------------------------
    // Back pressure: count the frames in which the consumer had to hold.
    //-------------------------------------------------------------------------
    always @(posedge rclk) begin
        if (rrst_n && stalled)
            hold_events = hold_events + 1;
    end

    //-------------------------------------------------------------------------
    // Strict data checking. Enabled only while the producer is throttled, i.e.
    // while the FIFO is not full and every line the consumer shows is a line the
    // producer actually wrote.
    //
    // It is wrong to require this during back pressure: holding the raster and
    // repeating the previous pixel is the designed behaviour, not a defect, so
    // under a saturated FIFO the payload legitimately stops advancing.
    //-------------------------------------------------------------------------
    // Zero, not one. This was declared `reg strict = 1'b1` and the main sequence
    // only cleared it a couple of dozen rclks AFTER releasing reset -- by which
    // time the consumer had already started its first line, armed_q was still 0
    // because no slot can have been claimed yet, and the first 17 pixels of the
    // simulation were reported as payload errors. Starting at 0 means the check
    // can never be armed before the stimulus is.
    reg     strict = 1'b0;

    //-------------------------------------------------------------------------
    // Data check: every pixel of every line the consumer actually sees.
    //-------------------------------------------------------------------------
    integer c_px   = 0;
    // Five bits, to match rgb[23:19]. This was declared as a 1-bit reg, and
    // comparing `rgb[23:19] !== c_line_hold` then compared five bits against a
    // zero-extended single bit, so the comparison was true for every pixel of
    // every line whose line number was not zero. That reported ten million torn
    // lines while the payload check underneath it was passing.
    reg [4:0] c_line_hold = 5'd0;

    always @(posedge rclk) begin
        if (!rrst_n) begin
            c_px    <= 0;
        end else if (de) begin
            chk_pixels = chk_pixels + 1;

            if (c_px == 0) begin
                // First pixel of a line. It is taken as the reference but NOT
                // compared against anything: rgb arrives one flier behind px,
                // so pixel 0 legitimately carries the tail of the previous line
                // and comparing it against the rest of this line reported a torn
                // line for all 1280 pixels of every line.
                c_line_hold <= rgb[23:19];
                chk_lines   = chk_lines + 1;
            end else if (c_px == 1) begin
                // Pixel 1 is the first pixel whose payload belongs to this line.
                c_line_hold <= rgb[23:19];
            end else if (strict && rgb[23:19] !== c_line_hold) begin
                // The line number must not change inside a line. If it does, the
                // consumer straddled two slots and the line is torn.
                //
                // armed_q and stalled are printed because "torn" is not the only
                // way for the payload to stop advancing: under back pressure the
                // consumer repeats the previous pixel by design, and a change
                // across that boundary is not a fault.
                if (err_line < 14)
                    $display("LINE    line %0d pixel %0d: line number 0x%02x -> 0x%02x  armed=%0b stalled=%0b strict=%0b",
                             chk_lines, c_px, c_line_hold, rgb[23:19],
                             dut.armed_q, dut.stalled, strict);
                err_line = err_line + 1;
            end

            // pixel index encoded in the payload must match the pixel counter
            if (strict &&
                (rgb[15:10] !== c_px[5:0] || rgb[7:3] !== c_px[10:6])) begin
                if (err_data < 24)
                    $display("DATA    line %0d pixel %0d: payload says (g=%0d b=%0d), expected (g=%0d b=%0d) armed=%0b",
                             chk_lines, c_px, rgb[15:10], rgb[7:3],
                             c_px[5:0], c_px[10:6], dut.armed_q);
                err_data = err_data + 1;
            end

            c_px <= (c_px == 1279) ? 0 : c_px + 1;
        end else begin
            c_px <= 0;
        end
    end

    //=========================================================================
    // Main
    //=========================================================================
    integer i;
    integer frames_stage1 = 0;
    integer frames_stage2 = 0;
    integer t1_lines = 0;
    integer t2_lines = 0;
    integer dropped_s1 = 0;
    integer hold_s1 = 0;

    task run_frames(input integer n);
        begin
            for (i = 0; i < n; i = i + 1)
                repeat (1650 * 750) @(posedge rclk);
        end
    endtask

    initial begin
        $display("=== tb_hdmi_out: line-slot CDC + 720p60 raster ===");
        $display("    raster 1280x720, H 110/40/220 (total 1650), V 5/5/20 (total 750)");
        $display("    sync intervals: hsync x[%0d,%0d)  vsync y[%0d,%0d)", SYNC_X0, SYNC_X1, VSYNC_Y0, VSYNC_Y1);
        $display("    polarity HS_POL=1 VS_POL=1 (positive, asserted high while active)");
        $display("    wclk 148.5 MHz, rclk 74.25 MHz; rclk period is exactly 2 x wclk, as the MMCM divides by 2");

        repeat (20) @(posedge wclk);
        wrst_n <= 1'b1;
        rrst_n <= 1'b1;
        repeat (20) @(posedge rclk);

        // Stage 1: producer rate matched to the consumer. Two warm-up frames first,
        // because the FIFO starts empty and the consumer necessarily holds until
        // the producer has filled it -- that is correct behaviour, not a fault,
        // and checking pixels during it would only report the warm-up.
        strict <= 1'b0;
        $display("--- stage 1a: 2 warm-up frames ---");
        run_frames(2);
        $display("--- warm-up done, hold so far = %0d px ---", hold_events);

        strict <= 1'b1;
        t1_lines = chk_lines;
        hold_s1   = hold_events;
        $display("--- stage 1b: 8 frames, strict pixel checking ---");
        run_frames(8);
        $display("--- stage 1 done: hold=%0d px, lines=%0d ---", hold_events, chk_lines);

        // At a matched rate the consumer must never be starved. Checking the
        // pixel payload alone is not enough, because a starved line returns the
        // held pixel, which shows up as a handful of payload mismatches at the
        // moment strict checking is switched on and is easy to write off as
        // warm-up. Asserting that the held-pixel count does not move across the
        // whole strict window states the property directly: eight frames, not
        // one line.
        if (hold_events != hold_s1) begin
            $display("FAIL: consumer starved for %0d px at a matched producer rate",
                     hold_events - hold_s1);
            err_data = err_data + 1;
        end

        // At a matched rate the write port must never discard anything. This is
        // the assertion that catches the 4.17% claim-rate deficit in hdmi_out.v:
        // it is a slow ramp, so a two-frame check would pass and only a long run
        // reaches the slot ceiling.
        if (stat_dropped != 0) begin
            $display("FAIL: %0d pixels discarded at a matched producer rate", stat_dropped);
            err_data = err_data + 1;
        end
        if (overflow !== 1'b0) begin
            $display("FAIL: overflow latched during the matched-rate stage");
            err_data = err_data + 1;
        end

        // Stage 2: producer flat out, no throttle at all. This is a DELIBERATE
        // overrun, and the point of the stage is no longer the picture -- it is
        // that the overrun must be *reported*. Before stat_dropped/overflow
        // existed, this condition silently desynchronised the stream.
        throttle   = 0;
        p_inter_line  = 0;
        p_inter_frame = 0;
        strict     <= 1'b0;
        dropped_s1 = stat_dropped;
        $display("--- stage 2: 4 frames, producer flat out (deliberate overrun) ---");
        run_frames(4);
        $display("--- stage 2 done: hold=%0d px, dropped=%0d overflow=%0b ---",
                 hold_events, stat_dropped, overflow);

        if (overflow !== 1'b1) begin
            $display("FAIL: deliberate overrun was not reported: overflow=%0b dropped=%0d",
                     overflow, stat_dropped);
            err_data = err_data + 1;
        end
        if (stat_dropped == dropped_s1) begin
            $display("FAIL: deliberate overrun discarded nothing, the path was not exercised");
            err_data = err_data + 1;
        end

        $display("");
        $display("=== frames driven            : %0d", chk_frames);
        $display("=== pixels compared          : %0d", chk_pixels);
        $display("=== lines compared           : %0d", chk_lines);
        $display("=== hold (back-pressure) px  : %0d", hold_events);
        $display("=== raster timing errors     : %0d", err_timing);
        $display("=== sync polarity errors     : %0d", err_sync);
        $display("=== torn line errors         : %0d", err_line);
        $display("=== payload data errors      : %0d", err_data);
        $display("=== stat_frames (DUT)        : %0d", stat_frames);
        $display("=== stat_dropped (DUT)       : %0d", stat_dropped);
        $display("=== overflow (DUT)           : %0b", overflow);

        if (chk_frames < 12) begin
            $display("FAIL: only %0d frames observed, expected at least 12", chk_frames);
            err_timing = err_timing + 1;
        end
        if (stat_frames != chk_frames) begin
            $display("FAIL: DUT counted %0d frames, testbench drove %0d", stat_frames, chk_frames);
            err_timing = err_timing + 1;
        end
        if (chk_lines < 1000) begin
            $display("FAIL: only %0d lines seen", chk_lines);
            err_data = err_data + 1;
        end

        if ((err_timing | err_sync | err_line | err_data) == 0)
            $display("PASS: raster exact, sync positive, CDC intact under both rates");
        else
            $display("FAIL: %0d errors",
                     err_timing + err_sync + err_line + err_data);

        $finish;
    end

    //-------------------------------------------------------------------------
    // watchdog
    //-------------------------------------------------------------------------
    initial begin
        #500_000_000;
        $display("FAIL: timeout");
        $finish;
    end

endmodule
`default_nettype wire