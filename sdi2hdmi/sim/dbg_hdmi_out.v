//=============================================================================
// dbg_hdmi_out.v -- throwaway diagnostic, not part of the regression.
//
// Question being asked: does the DUT ever DISCARD a pixel? The write port is
// `mem[w_addr] <= w_data` under `w_en && !w_full`. The producer cannot stall --
// in the real design it is the SDI pixel stream -- so every pixel the producer
// offers must land. If w_full ever gates a write, the producer's pixel counter
// runs ahead of the DUT's w_x for ever after, and every subsequent line carries
// the wrong line number.
//
// Two counters answer it directly, from testbench signals only:
//   drop_wr  : cycles where the producer offered a pixel and w_full blocked it
//   desync    : producer w_line vs DUT w_bin, sampled at each line start
//=============================================================================
`timescale 1ns / 1ps
module dbg_hdmi_out;

    reg wclk = 0, rclk = 0;
    always #3.367 wclk = ~wclk;    // 148.5 MHz
    always #6.734 rclk = ~rclk;    //  74.25 MHz

    reg wrst_n = 0, rrst_n = 0;
    reg w_en = 0, w_last = 0;
    reg [15:0] w_data = 16'd0;

    wire hs, vs, de;
    wire [23:0] rgb;
    wire stalled;
    wire [31:0] stat_frames;

    hdmi_out #(.SLOTS(8)) dut (
        .wclk(wclk), .wrst_n(wrst_n), .w_en(w_en), .w_last(w_last),
        .w_frame(1'b0), .w_data(w_data),
        .rclk(rclk), .rrst_n(rrst_n), .hs(hs), .vs(vs), .de(de), .rgb(rgb),
        .stalled(stalled), .stat_frames(stat_frames));

    //-------------------------------------------------------------------------
    // Producer: identical to tb_hdmi_out.v stage 1 -- rate matched.
    //-------------------------------------------------------------------------
    integer w_px = 0, w_line = 0, w_idle = 0;
    parameter integer THROTTLE = 2020;

    always @(posedge wclk) begin
        if (!wrst_n) begin
            w_en <= 0; w_last <= 0; w_data <= 0;
            w_px <= 0; w_line <= 0; w_idle <= 0;
        end else begin
            if (w_px == 1279 && w_idle == 0) w_idle <= THROTTLE;
            if (w_idle != 0) begin
                w_en   <= 1'b0;
                w_idle <= w_idle - 1;
            end else begin
                w_en   <= 1'b1;
                w_data <= {w_line[4:0], w_px[5:0], w_px[10:6]};
                w_last <= (w_px == 1279);
                if (w_px == 1279) begin
                    w_px   <= 0;
                    w_line <= w_line + 1;
                end else begin
                    w_px <= w_px + 1;
                end
            end
        end
    end

    //-------------------------------------------------------------------------
    // Dropped writes, and the producer/DUT counter relationship
    //-------------------------------------------------------------------------
    integer drop_wr = 0;
    integer first_drop = -1;
    integer nslow = 0;
    integer last_rbin = -1;
    integer rbin_stall = 0;

    always @(posedge wclk) begin
        if (wrst_n && w_en && dut.w_full) begin
            if (first_drop < 0) begin
                first_drop = $time;
                $display("DROP   first dropped write at %0t", $time);
                $display("       w_bin=%0d w_gray=%0d w_x=%0d w_full=%0b",
                         dut.w_bin, dut.w_gray, dut.w_x, dut.w_full);
                $display("       r_bin=%0d r_gray=%0d r_gray_sync=%0b r_empty=%0b",
                         dut.r_bin, dut.r_gray, dut.r_gray_sync, dut.r_empty);
                $display("       w_gray_sync=%0d  producer_w_line=%0d producer_w_px=%0d",
                         dut.w_gray_sync, w_line, w_px);
            end
            drop_wr = drop_wr + 1;
        end
    end

    // Unambiguous rates: cycles, w_en duty cycle, and who advanced how many lines.
    integer nwin = 0;
    integer c_cyc = 0, c_wen = 0, c_off = 0;
    integer c_offer = 0, c_accept = 0;
    reg prev_x0b = 1'b0;
    always @(posedge wclk) begin
        if (wrst_n) begin
            c_cyc = c_cyc + 1;
            if (w_en) c_wen = c_wen + 1;
            if (w_en && dut.w_full) c_off = c_off + 1;
            if (w_px == 1279 && w_idle == 0) c_offer = c_offer + 1;
            if (dut.w_x == 0 && !prev_x0b) c_accept = c_accept + 1;
            prev_x0b <= (dut.w_x == 0);
            if (c_cyc == 132000) begin
                $display("RATE   window %0d: wclk=%0d w_en=%0d (duty %0d%%) blocked=%0d  producer_lines=%0d  dut_line_starts=%0d  depth=%0d",
                         nwin, c_cyc, c_wen, (c_wen * 100) / c_cyc, c_off,
                         c_offer, c_accept, (dut.w_bin - dut.r_bin) & 15);
                nwin = nwin + 1;
                c_cyc = 0; c_wen = 0; c_off = 0; c_offer = 0; c_accept = 0;
            end
        end
    end

    // Track the read side: is the consumer still advancing its read pointer?
    always @(posedge wclk) begin
        if (wrst_n) begin
            if (dut.r_bin == last_rbin) rbin_stall = rbin_stall + 1;
            else begin
                if (rbin_stall > 20000 && nslow < 4) begin
                    $display("STALL  r_bin stuck at %0d for %0d wclk at %0t  (w_bin=%0d w_full=%0b r_empty=%0b)",
                             dut.r_bin, rbin_stall, $time, dut.w_bin, dut.w_full, dut.r_empty);
                    nslow = nslow + 1;
                end
                rbin_stall = 0;
            end
            last_rbin = dut.r_bin;
        end
    end

    // Sample the two counters whenever the DUT starts a fresh line.
    integer nsamp = 0;
    reg prev_x0 = 1'b0;
    always @(posedge wclk) begin
        if (wrst_n && dut.w_x == 0 && !prev_x0 && nsamp < 20) begin
            $display("LINE   t=%0t  dut_w_bin=%0d  producer_w_line=%0d  %0s",
                     $time, dut.w_bin, w_line,
                     (dut.w_bin == w_line[3:0]) ? "ok" : "DESYNC");
            nsamp = nsamp + 1;
        end
        prev_x0 <= (dut.w_x == 0);
    end

    //-------------------------------------------------------------------------
    // Reader: check line-number consistency within a line
    //-------------------------------------------------------------------------
    integer r_px = 0, torn = 0, lines = 0;
    reg [4:0] hold_line = 5'd0;

    always @(posedge rclk) begin
        if (!rrst_n) r_px <= 0;
        else if (de) begin
            if (r_px == 1) hold_line <= rgb[23:19];
            if (r_px >= 2 && rgb[23:19] !== hold_line) begin
                if (torn < 6)
                    $display("TORN   line %0d px %0d: 0x%02x -> 0x%02x slot=%0d r_bin=%0d armed=%0b",
                             lines, r_px, hold_line, rgb[23:19], dut.slot_q, dut.r_bin, dut.armed_q);
                torn = torn + 1;
            end
            if (r_px == 0) lines = lines + 1;
            r_px <= (r_px == 1279) ? 0 : r_px + 1;
        end else begin
            r_px <= 0;
        end
    end

    initial begin
        $display("=== dbg_hdmi_out: dropped-write / desync probe ===");
        repeat (20) @(posedge wclk);
        wrst_n <= 1; rrst_n <= 1;
        repeat (1650 * 750 * 6) @(posedge rclk);
        $display("");
        $display("=== frames run            : %0d", stat_frames);
        $display("=== lines read            : %0d", lines);
        $display("=== torn lines            : %0d", torn);
        $display("=== dropped writes        : %0d", drop_wr);
        $display("=== first drop at (ns)    : %0d", first_drop);
        $display("=== dut w_bin final       : %0d", dut.w_bin);
        $display("=== producer w_line final : %0d", w_line);
        $display("=== final pointer state   : w_bin=%0d w_gray=%0d r_bin=%0d r_gray=%0d",
                 dut.w_bin, dut.w_gray, dut.r_bin, dut.r_gray);
        $display("=== final flags           : w_full=%0b r_empty=%0b overflow=%0b stat_dropped=%0d",
                 dut.w_full, dut.r_empty, dut.overflow, dut.stat_dropped);
        $finish;
    end

    initial begin
        #500_000_000;
        $display("FAIL: timeout");
        $finish;
    end
endmodule