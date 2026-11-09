//=============================================================================
// hdmi_out.v
//
// Clock-domain crossing plus the 720p60 raster.
//
// The scaler runs in the SDI pixel clock domain (rx_usrclk: 148.5 MHz for 3G,
// 74.25 MHz for HD). The HDMI side needs the 720p60 pixel clock, 74.25 MHz.
// Those are separate domains and are not merged by pretending otherwise.
//
// Why 74.25 MHz and not 148.5
//   The TMDS character rate is 5x the pixel clock. At 148.5 MHz pixel clock
//   that is 742.5 MHz, which is exactly the case the board manual flags as
//   out of spec: the HR bank tops out at 710 MHz, so 1080p60 makes some
//   monitors flicker. 720p60 at 74.25 MHz is 371.25 MHz TMDS, comfortably
//   inside it. See doc/01-architecture.md.
//
// What crosses
//   A whole video line, not a pixel. 1280x16 = 20 480 bits is one RAMB36, so
//   a small ring of line slots is cheap, and a line is a natural unit: the
//   writer publishes a slot only after all 1280 pixels are in it, so the
//   reader can never latch a half-written line. Pointers cross as Gray codes,
//   one bit per increment, so the receiving domain samples a consistent value
//   wherever the edge falls.
//
// Back pressure
//   1080p60 -> 720p60 is rate matched: 2200x1125 at 148.5 MHz and 1650x750
//   at 74.25 MHz are both 16.667 ms, so the reader does not really starve.
//   When it does -- a 30 fps source, say -- the raster keeps its timing and
//   holds the previous line, so the sync stays valid and the picture freezes
//   instead of tearing. `stalled` reports it.
//
// Frame-phase alignment
//   The producer's frame boundary and the raster's are free-running and
//   unrelated: the SDI source starts whenever it starts, the raster starts when
//   rst_n releases. The slot ring absorbs about +/-SLOTS lines of that offset,
//   and an arbitrary source phase is usually hundreds of lines away from any
//   of it -- measured on the school machine, a source phase as ordinary as
//   +30 lines already costs 23 damaged rows per frame, permanently.
//
//   So the raster is genlocked to the producer's `w_frame` marker: the loop in
//   the read domain measures where the producer's frame boundary lands and
//   lengthens ONE frame's vertical blanking to bring the two boundaries into
//   step, then stops. Lengthening is the only direction used, so the visible
//   raster is never cut; the single lengthened frame is up to ~2x long, and the
//   rows produced while it is stretched are drained and discarded during
//   blanking. Both frame periods are exactly equal (1125 x 2200 = 750 x 1650
//   rclk off one MMCM), so one correction holds until the next re-lock.
//
//   Without this the board lights up with a stable band: doc/02-verification.md
//   section 4.3 has the window measurement that made this a bring-up blocker.
//
// Output pipeline
//   The line slots are block RAM, which has one cycle of read latency. The
//   pixel path is therefore one stage deep: the address is issued from the
//   counters, and hs/vs/de/rgb are registered from the counters of the cycle
//   before, so data and control stay aligned.
//=============================================================================
`timescale 1ns / 1ps
`default_nettype none

module hdmi_out #(
    parameter integer H_ACTIVE = 1280,
    parameter integer H_FP     = 110,
    parameter integer H_SYNC   = 40,
    parameter integer H_BP     = 220,
    parameter integer V_ACTIVE = 720,
    parameter integer V_FP     = 5,
    parameter integer V_SYNC   = 5,
    parameter integer V_BP     = 20,
    parameter integer HS_POL   = 1,
    parameter integer VS_POL   = 1,
    parameter integer SLOTS    = 8,          // line slots, MUST be a power of two; AW below is derived from it
    parameter integer ALIGN_EPS = 4          // alignment target, see below
) (
    // ---- write side: scaler output, SDI pixel clock ----------------------
    input  wire               wclk,
    input  wire               wrst_n,
    input  wire               w_en,        // pixel strobe
    input  wire               w_last,      // high on the final pixel of a line
    input  wire               w_frame,     // high during the first line of a frame
    input  wire [15:0]        w_data,      // RGB565

    // ---- read side: HDMI pixel clock -------------------------------------
    input  wire               rclk,
    input  wire               rrst_n,
    output reg                hs,
    output reg                vs,
    output reg                de,
    output reg  [23:0]        rgb,
    output wire               stalled,     // no line was ready, holding
    output wire  [31:0]       stat_frames,

    // ---- write-side overrun reporting -------------------------------------
    //
    // The write port has NO back pressure. `w_en` comes from a free-running
    // pixel stream that cannot be paused, so when the slots are full the write
    // is dropped rather than stalled. That is a deliberate choice -- stalling
    // the producer would tear the upstream frame -- but it means an overrun is
    // not self-announcing.
    //
    // What an overrun damages is confined to whole lines. `w_last` -- the
    // producer's line end, not a local count of 1280 -- is what releases a
    // slot, so a line that lost any pixel is discarded entire and the next
    // line starts at x = 0. The stream can therefore lose a LINE, but it can
    // never splice two source lines into one, and the line phase re-syncs at
    // the very next line. With a local count instead, one overrun left the
    // pixel count and the producer's line phase permanently offset and every
    // line from then on carried two half-lines stitched together.
    //
    // dbg_hdmi_out.v measured the original failure: with a producer whose
    // average rate matched the consumer's to within a rounding error, the slot
    // occupancy performed a bounded random walk (the synchroniser delay
    // jitter), the walk reached the 8-slot ceiling after 728 lines, and from
    // that point 220 160 pixels were discarded.
    //
    // So the overrun is counted and latched here, to be driven to a LED. The
    // contract for the producer is: pace itself to at most one line per
    // H_TOTAL rclks and never present more than SLOTS lines of backlog.
    output reg  [31:0]        stat_dropped, // pixels discarded with the line they were in
    output reg                overflow      // sticky: stat_dropped was ever > 0
);

    localparam integer H_TOTAL = H_ACTIVE + H_FP + H_SYNC + H_BP;   // 1650
    localparam integer V_TOTAL = V_ACTIVE + V_FP + V_SYNC + V_BP;   // 750
    localparam integer AW      = $clog2(SLOTS);                    // 3 for SLOTS=8; keep SLOTS a power of two

    //--------------------------------------------------------------------------
    // Line slots. One RAMB36 each.
    //--------------------------------------------------------------------------
    // One array holding all eight line slots, addressed as {slot, x}.
    //
    // Why one array and not eight: with eight separate declarations and a
    // `case (w_slot)` around the write, Vivado infers distributed RAM --
    // RAM64M => RAMD64E, 800 instances -- and the post-route setup path
    // u_hdmi_out/mem3_.../RAMA/CLK -> ram_q_reg[9]/D comes out at
    // WNS -5.278 ns, with 77.08% of the 5.742 ns data delay in routing rather
    // than logic. A 1280-deep LUTRAM lives in the fabric and the routes to and
    // from it are long. ram_style="block" on the eight declarations is
    // IGNORED: synthesis still reports distributed RAM.
    //
    // What does get inferred as block RAM is the textbook shape: one array,
    // one write always block on wclk, one read always block on rclk, plain
    // concatenation for the address. That is what this is.
    //
    // Size: 2^14 x 16 = 262 144 bit, which is 8 RAMB36. The design only ever
    // touches slots 0..7 at x = 0..1279, i.e. the low 10 240 rows, so the
    // rounding wastes a little. That is not worth a multiplier to avoid, and
    // 8 of 265 tiles is 3%.
    localparam integer MEM_AW = 14;
    localparam integer X_AW   = 11;   // 1280 needs 11 bits, not 12

    (* ram_style = "block" *) reg [15:0] mem [0:(1 << MEM_AW) - 1];

    //--------------------------------------------------------------------------
    // Pointer crossing
    //--------------------------------------------------------------------------
    reg  [AW:0] w_bin, w_gray, r_bin, r_gray;

    (* ASYNC_REG = "TRUE" *) reg [AW:0] w_gray_s1, w_gray_s2;
    (* ASYNC_REG = "TRUE" *) reg [AW:0] r_gray_s1, r_gray_s2;

    // w_gray synchronised INTO the read domain. This has to be a separate
    // chain clocked by rclk, not a reuse of the wclk chain.
    //
    // The first version of this module had one synchroniser pair in wclk and
    // derived both `full` and `empty` from it, then used `empty` to enable
    // r_bin -- which is an rclk register. That is a real CDC bug, and it is
    // what the post-route report caught:
    //   Slack (VIOLATED) : -3.857 ns
    //   Source: u_hdmi_out/r_gray_s2_reg[1]/C
    //   Destination: u_hdmi_out/r_bin_reg[1]/CE
    // An asynchronous FIFO needs one chain per direction, each clocked by the
    // domain that CONSUMES it: the write pointer crosses into the read domain
    // for `empty`, and the read pointer crosses into the write domain for
    // `full`. Sharing one chain means the consumer is reading a signal that is
    // not yet stable in its own clock domain.
    (* ASYNC_REG = "TRUE" *) reg [AW:0] w_gray_r1, w_gray_r2;

    function [AW:0] bin2gray(input [AW:0] b);
        bin2gray = b ^ (b >> 1);
    endfunction

    // write pointer out, read pointer in -- both in the write domain
    //
    // The synchroniser fliers MUST be reset. Leaving them unreset makes them
    // power up as X, which propagates into w_full as X, which makes
    // `w_en && !w_full` false in simulation, which means the line slots are
    // never written at all. Synthesis is perfectly happy with this -- an
    // unreset flop is not a synthesis error -- so the failure only appears in
    // simulation, and the symptom is a blank picture with entirely plausible
    // timing and a clean bitstream. tb_hdmi_out.v found it: every payload read
    // back as zero.
    always @(posedge wclk) begin
        if (!wrst_n) begin
            w_gray_s2 <= 0;
            w_gray_s1 <= 0;
            r_gray_s2 <= 0;
            r_gray_s1 <= 0;
        end else begin
            w_gray_s2 <= w_gray_s1;
            w_gray_s1 <= w_gray;
            r_gray_s2 <= r_gray_s1;
            r_gray_s1 <= r_gray;
        end
    end

    // write pointer in -- in the read domain
    always @(posedge rclk) begin
        if (!rrst_n) begin
            w_gray_r2 <= 0;
            w_gray_r1 <= 0;
        end else begin
            w_gray_r2 <= w_gray_r1;
            w_gray_r1 <= w_gray;
        end
    end

    wire [AW:0] r_gray_sync = r_gray_s2;    // consumed by wclk
    wire [AW:0] w_gray_sync = w_gray_r2;    // consumed by rclk

    wire w_full  = (w_gray == {~r_gray_sync[AW:AW-1], r_gray_sync[AW-2:0]});
    wire r_empty = (r_gray == w_gray_sync);

    //--------------------------------------------------------------------------
    // Write side: one slot per source line
    //--------------------------------------------------------------------------
    reg [11:0] w_x;
    reg        line_bad;      // this line lost a pixel; discard it whole

    // Slot index concatenated with the pixel index. Both clocks address the
    // same array; that is the whole point of having one array.
    wire [MEM_AW-1:0] w_addr = {w_bin[AW-1:0], w_x[X_AW-1:0]};

    always @(posedge wclk) begin
        if (!wrst_n) begin
            w_bin        <= {(AW+1){1'b0}};
            w_gray       <= {(AW+1){1'b0}};
            w_x          <= 12'd0;
            line_bad     <= 1'b0;
            stat_dropped <= 32'd0;
            overflow     <= 1'b0;
        end else begin
            if (w_en) begin
                if (line_bad) begin
                    // This line is already abandoned. Keep counting its pixels
                    // as lost -- they are -- and resynchronise on its last
                    // pixel, so the next line starts at x = 0.
                    stat_dropped <= stat_dropped + 32'd1;
                    if (w_last) begin
                        line_bad <= 1'b0;
                        w_x      <= 12'd0;
                    end
                end else if (w_full) begin
                    // Overrun: this pixel is lost, and it takes its line with
                    // it. The slot is left unpublished -- w_bin does not move
                    // -- so the reader never sees a half-written line, and the
                    // next line is a clean 1280 pixels from a known line.
                    stat_dropped <= stat_dropped + 32'd1;
                    overflow     <= 1'b1;
                    if (w_last) begin
                        line_bad <= 1'b0;
                        w_x      <= 12'd0;
                    end else begin
                        line_bad <= 1'b1;
                    end
                end else begin
                    // Plain write, address is a concatenation, nothing else
                    // touches the array. This is the shape Vivado's RAM
                    // inference recognises.
                    mem[w_addr] <= w_data;

                    // Release on the PRODUCER's line end. The local count is
                    // kept as a fallback for a producer that never raises
                    // w_last, but it is not what defines a line: a local count
                    // would publish spliced "lines" after any overrun, and
                    // every line of every later frame would carry the wrong
                    // content.
                    if (w_last || w_x == H_ACTIVE-1) begin
                        w_bin  <= w_bin + 1'b1;
                        w_gray <= bin2gray(w_bin + 1'b1);
                        w_x    <= 12'd0;
                    end else begin
                        w_x <= w_x + 12'd1;
                    end
                end
            end
        end
    end

    //--------------------------------------------------------------------------
    // Read side: 720p60 raster
    //--------------------------------------------------------------------------
    reg  [11:0] hcnt, vcnt;
    reg  [11:0] px;           // pixel index inside the active line
    reg  [AW-1:0]  slot_q;   // slot being streamed this line
    reg         armed_q;      // a slot has been claimed for the coming line
    reg  [15:0] hold_q;       // last good pixel, held while starved
    reg         sync_d1, vs_d1, de_d1;   // output alignment, stage 1

    wire [MEM_AW-1:0] r_addr = {slot_q, px[X_AW-1:0]};

    wire in_hact  = (hcnt <  H_ACTIVE);
    wire in_vact  = (vcnt <  V_ACTIVE);
    wire in_hsync = (hcnt >= H_ACTIVE + H_FP) &&
                    (hcnt <  H_ACTIVE + H_FP + H_SYNC);
    wire in_vsync = (vcnt >= V_ACTIVE + V_FP) &&
                    (vcnt <  V_ACTIVE + V_FP + V_SYNC);

    // Claim a line ONLY during the active region of a line slot.
    //
    // HISTORY, because this was wrong once and the reason is not obvious:
    //
    // An intermediate version removed the `&& in_vact` and claimed on all 750
    // line slots per frame, on the reasoning that the reader should demand the
    // fastest rate the pixel clock can deliver. That was deduced from
    // dbg_hdmi_out.v, and the testbench driving it was wrong: its producer was
    // configured to emit a line every 3300 cam_clk (= 1650 rclk), which is
    // faster than the 1718.75 rclk an in_vact-gated reader actually needs. The
    // testbench's own rate error was read as a design defect, and the design was
    // changed to suit the testbench. tb_e2e.v later proved that version wrong:
    // 298 240 discarded pixels per 6 frames.
    //
    // The real contract, from tb_e2e.v's measurements:
    //
    //   source frame      1125 x 2200 cam_clk  = 1 237 500 rclk
    //   hdmi_out frame      750 x 1650 rclk     = 1 237 500 rclk   <- identical
    //   hdmi_out ACTIVE     720 x 1650 rclk     = 1 188 000 rclk   = 16.0 ms
    //   scaler output       720 lines across the 1080 active source lines
    //                        1080 x 2200 cam_clk = 1 188 000 rclk   <- identical
    //
    // So the producer's 720 lines occupy EXACTLY the reader's 720 active line
    // slots, at exactly one line per 1650 rclk, and both sit idle through the
    // 30-line vertical blanking. Claiming during blanking demands 30 lines per
    // frame that nobody produces, and the deficit accumulates until the line
    // slots overflow.
    //
    // in_vact keeps the reader's demand at exactly one line per 1650 rclk, which
    // is what the producer can sustain.
    //
    // ONE exception: while a frame is being stretched for frame-phase alignment
    // (v_extra, see the loop at the bottom of this file), a claim per extra
    // blanking line keeps draining the ring. Those lines sit outside the active
    // region, so their pixels are never displayed; draining them is what stops
    // the producer -- which cannot be paused and does not know about the
    // stretch -- from overflowing into a blanking pause it cannot see.
    reg [11:0] v_extra;                    // blanking lines still to append
    wire in_extend = (vcnt == V_TOTAL-1) && (v_extra != 12'd0);
    wire claim_now = (hcnt == H_TOTAL-1) && (in_vact || in_extend);

    // The read port. Registered, because block RAM has one cycle of read latency
    // and hs/vs/de are registered from the counters of the previous cycle, so
    // data and control stay aligned.
    reg  [15:0] ram_q;
    always @(posedge rclk) begin
        ram_q <= mem[r_addr];
    end

    assign stalled = in_hact && in_vact && !armed_q;

    //--------------------------------------------------------------------------
    // Frame-phase alignment loop -- declarations
    //
    // The mechanism is explained in the section at the end of this file. The
    // registers live up here because the raster block below loads v_extra from
    // them, and Vivado's analyser wants a name declared before it is read.
    //--------------------------------------------------------------------------
    (* ASYNC_REG = "TRUE" *) reg wf_s1, wf_s2;
    reg wf_s3;

    always @(posedge rclk) begin
        if (!rrst_n) begin
            wf_s1 <= 1'b0;
            wf_s2 <= 1'b0;
            wf_s3 <= 1'b0;
        end else begin
            wf_s1 <= w_frame;
            wf_s2 <= wf_s1;
            wf_s3 <= wf_s2;
        end
    end

    wire wf_rise = wf_s2 & ~wf_s3;

    wire [11:0] align_sum  = vcnt + ALIGN_EPS;
    wire [11:0] align_want = (align_sum >= V_TOTAL) ? align_sum - V_TOTAL
                                                    : align_sum;
    // Correct, and worth correcting. See DEADBAND in the loop's own section.
    wire align_take = wf_rise && (v_extra == 12'd0) &&
                      (align_want >= 12'd2) && (align_want <= V_TOTAL-2);

    // Loop state, readable through the flattened hierarchy for the probes.
    // Diagnostic only: v_extra is loaded in the raster block below.
    reg [11:0] align_pos;   // vcnt sampled at the last accepted marker
    reg [11:0] align_add;   // lines appended for it (0 = nothing to do)

    reg [31:0] frames;

    always @(posedge rclk) begin
        if (!rrst_n) begin
            hs      <= HS_POL[0];
            vs      <= VS_POL[0];
            de      <= 1'b0;
            sync_d1 <= HS_POL[0];
            vs_d1   <= VS_POL[0];
            de_d1   <= 1'b0;
            rgb     <= 24'd0;
            hcnt    <= 12'd0;
            vcnt    <= 12'd0;
            v_extra <= 12'd0;
            px      <= 12'd0;
            slot_q  <= 3'd0;
            armed_q <= 1'b0;
            hold_q  <= 16'd0;
            r_bin   <= {(AW+1){1'b0}};
            r_gray  <= {(AW+1){1'b0}};
            frames  <= 32'd0;
        end else begin
            //------------------------------------------------------------------
            // raster counters
            //
            // vcnt advances ONLY when hcnt wraps. The original code drove both
            // from their own terminal-count comparison:
            //     hcnt <= (hcnt == H_TOTAL-1) ? 0 : hcnt + 1;
            //     vcnt <= (vcnt == V_TOTAL-1) ? 0 : vcnt + 1;
            // which leaves vcnt free-running at its own rate, entirely
            // uncoupled from the line length. Over one 720p frame the DUT then
            // counted 13 200 "frames" where 8 had been driven
            // (9 900 000 / 13 200 = 750, i.e. vcnt wrapped every 750 clocks
            // instead of every 750 x 1650), vsync fired 1650 times too often,
            // and the raster was simply wrong.
            //
            // tb_hdmi_out.v caught it: the DUT reported stat_frames = 13 200
            // after 8 frames were driven. A sync signal wrong this badly is a
            // monitor that never locks.
            //------------------------------------------------------------------
            if (hcnt == H_TOTAL-1) begin
                hcnt <= 12'd0;
                if (vcnt == V_TOTAL-1 && v_extra != 12'd0) begin
                    // Frame-phase alignment: hold the frame open for one more
                    // blanking line. vcnt stays parked at V_TOTAL-1, which
                    // keeps de low and hs/vs inactive; v_extra is reloaded by
                    // the alignment loop below.
                    v_extra <= v_extra - 12'd1;
                end else begin
                    vcnt <= (vcnt == V_TOTAL-1) ? 12'd0 : vcnt + 12'd1;
                end
            end else begin
                hcnt <= hcnt + 12'd1;
            end

            // The frame counter counts REAL frames. Stretch lines are extra
            // vertical blanking, not another frame.
            if (hcnt == H_TOTAL-1 && vcnt == V_TOTAL-1 && v_extra == 12'd0)
                frames <= frames + 32'd1;

            // Frame-phase alignment, load side: see the loop at the bottom of
            // the file. The count-down lives in the counter block above, so
            // v_extra has exactly one driver pair and no priority hazard: a
            // load can only happen while v_extra == 0, a count-down only while
            // it is not.
            if (align_take)
                v_extra <= align_want;

            //------------------------------------------------------------------
            // line claim
            //------------------------------------------------------------------
            if (claim_now) begin
                // r_empty, not the old w_empty: this register is clocked by
                // rclk, so the flag has to be resolved in the read domain.
                if (!r_empty) begin
                    slot_q  <= r_bin[AW-1:0];
                    armed_q <= 1'b1;
                    r_bin   <= r_bin + 1'b1;
                    r_gray  <= bin2gray(r_bin + 1'b1);
                end else if (!in_extend) begin
                    // Genuinely no line available, in a row that will be shown:
                    // hold the previous line, as documented above.
                    armed_q <= 1'b0;
                end
                // An extension line that finds the ring empty consumes
                // nothing. It must NOT clear armed_q: the slot already claimed
                // is consecutive with what the next frame's first row needs,
                // and armed_q is still set from it, so the display keeps a
                // contiguous window. Clearing it would put a flat held row at
                // the top of the next visible frame.
            end

            //------------------------------------------------------------------
            // pixel index
            //------------------------------------------------------------------
            if (in_hact && in_vact) begin
                px <= (px == H_ACTIVE-1) ? 12'd0 : px + 12'd1;
            end else begin
                px <= 12'd0;
            end

            //------------------------------------------------------------------
            // Output stage. hs/vs/de and rgb are all registered from the SAME
            // cycle, and ram_q holds the data for the address issued in the
            // previous cycle, so data and control stay aligned.
            //------------------------------------------------------------------
            // Sync polarity.
            //
            // Output stage alignment.
            //
            // hs/vs/de must be delayed to match rgb, and rgb is two fliers deep:
            //     r_addr(n)      issued from px
            //     ram_q(n+1)     = mem[r_addr(n)]      block RAM read latency
            //     rgb(n+2)       = ram_q(n+1)          output register
            //
            // The counters used to be registered into hs/vs/de in ONE stage,
            // which left the sync and the pixel data a whole pixel out of step
            // with each other. tb_hdmi_out.v showed it directly: the payload's
            // embedded pixel index ran ahead of the testbench's pixel counter
            // and the two moved by different amounts, which is not something a
            // fixed one-pixel skew looks like.
            //
            // Both stages are explicit so the alignment is a property of the
            // code rather than something to be counted by hand.
            sync_d1 <= HS_POL[0] ? in_hsync : ~in_hsync;
            vs_d1   <= VS_POL[0] ? in_vsync : ~in_vsync;
            de_d1   <= in_hact && in_vact;

            hs <= sync_d1;
            vs <= vs_d1;
            de <= de_d1;
            // RGB565 -> RGB888 by bit replication.
            //
            // Widths: R 5 -> 5+3 = 8, G 6 -> 6+2 = 8, B 5 -> 5+3 = 8.
            //
            // The green replicate was written as ram_q[10:8], which is THREE
            // bits, making the concatenation 5+3+6+3+5+3 = 25 bits into a 24
            // bit output. Verilog truncates from the left, so every channel after
            // red landed one place out and the picture came out a completely
            // wrong colour. tb_hdmi_out.v caught it as an unreadable payload:
            // the decoded pixel index advanced by 2 per pixel instead of 1,
            // which is what a shifted field looks like and is not something a
            // synthesis or timing report would ever mention.
            if (armed_q) begin
                rgb    <= {ram_q[15:11], ram_q[15:13],
                           ram_q[10:5],  ram_q[10:9],
                           ram_q[4:0],   ram_q[4:2]};
                hold_q <= ram_q;
            end else begin
                rgb    <= {hold_q[15:11], hold_q[15:13],
                           hold_q[10:5],  hold_q[10:9],
                           hold_q[4:0],   hold_q[4:2]};
            end
        end
    end

    assign stat_frames = frames;

    //--------------------------------------------------------------------------
    // Frame-phase alignment loop -- mechanism
    //
    // THE PROBLEM
    //   The producer's frame boundary (marked by `w_frame`) and the raster's
    //   (vcnt wrapping) are free-running. The ring absorbs about +/-SLOTS lines
    //   of offset; the source's phase is arbitrary. Measured on the school
    //   machine (doc/02-verification.md 4.3): clean only inside ~7 lines, and
    //   beyond it every frame loses (offset - 7) rows and repeats as many --
    //   permanently, and not restored by re-lock. A board with a source phase
    //   outside that window shows a stable band, so this is a bring-up blocker,
    //   not a nicety.
    //
    // WHAT IT DOES
    //   On every frame marker, sample the raster's row counter. If the producer
    //   frame boundary sits `p` lines after the raster boundary, the NEXT
    //   raster boundary is stretched by (p + ALIGN_EPS) mod V_TOTAL blanking
    //   lines, which moves it to ALIGN_EPS lines after the producer's boundary
    //   -- i.e. the producer's frame starts ALIGN_EPS lines before the raster's
    //   and the ring settles at ~ALIGN_EPS lines of occupancy, well clear of
    //   both walls.
    //
    // WHY LENGTHEN AND NEVER SHORTEN
    //   Shortening would have to cut into the visible raster. Lengthening only
    //   adds blanking: one frame becomes up to ~2x long (<= 33 ms), the raster
    //   itself is never disturbed, and the saturation of the whole range is
    //   reachable by adding (V_TOTAL-1) lines at most.
    //
    // WHY IT IS A ONE-SHOT
    //   Both frame periods are exactly equal -- 1125x2200 cam_clk = 750x1650
    //   rclk, off the same MMCM -- so once corrected the two boundaries keep
    //   their distance until the source re-locks. A marker that arrives while a
    //   stretch is still in progress is ignored (vcnt is parked, so its sample
    //   would be meaningless); the next one re-measures. That also makes this
    //   loop self-starting at power-up and self-correcting after an unlock:
    //   a lost source simply stops producing markers.
    //
    // DEADBAND
    //   A correction of one line or less is not applied: with a 1-line sample
    //   resolution, spending a whole extra frame to gain one line is a bad
    //   trade. Skipped are add = 0 and 1 (the phase is already at the target or
    //   one line past it, so the loop would be chasing its own quantisation) and
    //   add = 749 (a 749-line stretch for a 1-line gain). add = 748 IS applied:
    //   it is the case where the phase is 2 lines early, and one double-length
    //   frame lands it exactly on the target. Settled phase is therefore 746
    //   (the target), or 745/747 when the correction that would fix the last
    //   line is the one being skipped.
    //--------------------------------------------------------------------------
    // The declarations and the marker synchroniser are up in the read-side
    // section, above the raster block that loads v_extra.
    always @(posedge rclk) begin
        if (!rrst_n) begin
            align_pos <= 12'd0;
            align_add <= 12'd0;
        end else if (wf_rise && v_extra == 12'd0) begin
            align_pos <= vcnt;
            align_add <= align_take ? align_want : 12'd0;
        end
    end

endmodule
`default_nettype wire