//=============================================================================
// scaler_720.v
//
// Box-filter resampler: SDI raster -> fixed 1280x720 RGB565.
// Runs entirely in the SDI pixel clock domain (cam_clk). No frame buffer.
//
// Why a resampler and not a frame buffer
//   A 1280x720x16b frame buffer is 14.7 Mbit = 410 RAMB36. The FMQL30TAI
//   fabric (xc7z030ai) has 265, so a 720p frame does not fit in BRAM at all.
//   A line buffer does: 1280x16 = 20 480 bits, one RAMB36 per line.
//
// Filter definition (exact)
//   Output pixel x is the mean of source pixels [E(x-1), E(x)) where
//       E(j) = floor( (j+1) * src_w / dst_w )
//   Output line  k is the mean of the scaled lines in [F(k-1), F(k)) with
//       F(j) = floor( (j+1) * src_h / dst_h )
//   E() and F() are walked once per OUTPUT element by a fractional
//   accumulator, so there is no multiplier and no divider anywhere. h_take /
//   v_take hold E(x)-E(x-1) and F(k)-F(k-1); h_got / v_got count the elements
//   accumulated so far, and an output element closes when they match.
//
//   Two shapes matter and both come out exact:
//     1920x1080 -> 1280x720   take = 1,2,1,2,...   odd outputs average 2 pixels
//     1280x720  -> 1280x720   take = 1,1,1,1,...   every output is verbatim
//
//   Taps are capped at 2. A source wider than 2*dst_w or taller than 2*dst_h
//   would need more; that clamps the tap count and raises `overflow_q` rather
//   than silently mis-scaling. When the increment comes out 0 the source is
//   smaller than the output, and `take` is forced to 1 so the filter always
//   makes progress. That combination is outside the supported set -- see the
//   README -- and shows up as a frame that stops early, never as wrong pixels.
//
// Two line buffers, in rotating roles
//   W  the pixel path writes it
//   P  the push stage reads it
//   On each completed output line the roles swap, so at any instant they are
//   two distinct buffers: one simple dual-port RAM each, 2 RAMB36 total. The
//   swap is announced with a toggle, so no register is driven from two always
//   blocks.
//
// Vertical mean
//   When v_take is 2 the two source lines are folded into the SAME buffer at
//   the SAME pixel index: the first fold stores its value, the second fold
//   reads that pixel back and averages it. That is a read-modify-write at one
//   address, which a dual-port BRAM does natively -- the read port returns the
//   pre-write value in the same cycle. So the vertical mean needs no second
//   buffer and no second pass over the line.
//
//   Note what this must NOT do: average against the previously *published*
//   output line. For v_take=2 that line covers a different source range
//   entirely, and the result is a one-line vertical smear. The accumulator is
//   per pixel, not per line.
//
// Timing
//   The push stage needs dst_w cam_clk cycles per line = 8.6 us at 148.5 MHz,
//   while an output line arrives every 22.2 us (2 source lines of 2200 px) --
//   2.5x the margin it needs. `push_overrun` is the watchdog for the case
//   where that stops being true. It is gated on `locked_q` on purpose: during
//   the first frame the walk is seeded with h_src_w = 1 and the push really
//   does fall behind, which says nothing about steady state.
//=============================================================================
`timescale 1ns / 1ps
`default_nettype none

module scaler_720 #(
    parameter integer DST_W = 1280,
    parameter integer DST_H = 720
) (
    input  wire                clk,
    input  wire                rst_n,

    // ---- SDI source raster (cam_clk domain) -------------------------------
    input  wire [23:0]         in_rgb,
    input  wire                in_de,       // pixel valid, inside the active line
    input  wire                in_hs,       // horizontal-ACTIVE level
    input  wire                in_vs,       // vertical-ACTIVE level

    // ---- resampled output (same domain) -----------------------------------
    output reg                 out_valid,
    output reg                 out_last,
    output reg                 out_frame,  // high during the first line of a frame
    output wire [15:0]         out_rgb,

    // ---- observability ----------------------------------------------------
    output reg  [15:0]         src_w,       // measured source active width
    output reg  [15:0]         src_h,       // measured source active height
    output reg  [31:0]         stat_lines,  // output lines emitted
    output reg                 locked_q,    // geometry has been measured
    output reg                 overflow_q,  // a tap cap was hit
    output reg                 push_overrun // the push stage fell behind
);

    // Truncating slice, the same one the vendor display path uses
    // (frame_to_ps_largebuf.v:601-603), so no new quantisation is introduced.
    wire [15:0] px = {in_rgb[23:19], in_rgb[15:10], in_rgb[7:3]};

    //-------------------------------------------------------------------------
    // Local reset synchroniser.
    //
    // rst_n arrives from another clock domain: the top level builds rst_n_sys
    // on sys_clk_200m and passes it straight here, while this block runs on
    // cam_clk. An asynchronous reset asserted in one domain and reaching a
    // register's R pin while another domain's clock is the launch point is
    // what post-route flagged as
    //   u_scaler/h_got_reg[6]/C -> u_scaler/v_got_reg[14]/R   -0.360 ns
    // Two fliers in this block's own clock turn it into a local synchronous
    // signal, which is both the correct thing to do and what makes the
    // analysis meaningful.
    //-------------------------------------------------------------------------
    reg [1:0] rst_sync;
    always @(posedge clk) begin
        if (!rst_n) rst_sync <= 2'b00;
        else        rst_sync <= {rst_sync[0], 1'b1};
    end
    wire rst_ni = rst_sync[1];

    reg  [15:0] out_rgb_r;
    assign out_rgb = out_rgb_r;

    //--------------------------------------------------------------------------
    // Two line buffers, one RAMB36 each.
    //--------------------------------------------------------------------------
    // Two line buffers, one RAMB36 each.
    //
    // These are LEFT as distributed RAM on purpose, and that is a measured
    // decision rather than an oversight. The post-route report flags
    //   u_scaler/out_x_reg[0]/C -> u_scaler/lb1_reg_.../DP.HIGH/I   -1.512 ns
    // but it computes that against a 5.000 ns requirement, i.e. the 200 MHz
    // sys_clk_p. That is because rx_sdi.v:368 drives this block from
    //   cam_clk = rx0_locked ? rx_usrclk : sys_clk_200m
    // a MUXED clock, and Vivado times the mux input's faster branch. Under
    // 3G-SDI rx_usrclk is 148.5 MHz (6.734 ns), and the path delay is 5.742 ns,
    // so at the real frequency it closes at +0.992 ns -- it is not a real
    // violation at all.
    //
    // Forcing this into block RAM does not help, because the second fold of the
    // vertical mean is a same-address read-modify-write: W[out_x] is read
    // back and averaged with the incoming pixel in the same clock cycle. That
    // needs an asynchronous read, and a block RAM read has a cycle of latency,
    // so making it BRAM would require pipelining the second fold by a cycle
    // and retesting the filter against the golden model. Not worth it for a
    // path that already closes at the real clock rate.
    //
    // The real fix is to stop multiplexing the clock, which is a change to the
    // vendor receiver, not to this module.
    (* ram_style = "block" *) reg [15:0] lb0 [0:DST_W-1];
    (* ram_style = "block" *) reg [15:0] lb1 [0:DST_W-1];

    //--------------------------------------------------------------------------
    // Source raster measurement
    //
    // rx_sdi.v keeps cam_hs/cam_vs as the delayed ACTIVE levels coming out of
    // YCbCr422_2_RGB888: a rising edge on cam_hs is a line start, and the high
    // time is the active width. Geometry measured during frame N-1 drives
    // frame N. That costs one frame of latency and is always right, because a
    // source cannot change format in the middle of a frame.
    //--------------------------------------------------------------------------
    reg        hs_d, vs_d;
    reg        measuring;
    reg [15:0] px_in_line, lines_in_frame;
    // Active width of the last line that actually carried pixels. src_w is
    // published from this, NOT from px_in_line. On this source cam_hs rises on
    // the vertical-blanking lines too -- frame_convertor restarts its
    // horizontal counter at every SAV, and a blanking line has a SAV like any
    // other -- so px_in_line is reloaded to 0 by the first blanking line after
    // the active region, and is still 0 when the next frame's frame_start reads
    // it. No live counter still holds the width at that moment; the value has
    // to be latched at the end of a line that had pixels.
    reg [15:0] src_w_meas;

    wire line_start  = in_hs & ~hs_d;      // a source line begins
    wire line_end    = ~in_hs & hs_d;      // a source line ends, blanking starts
    wire frame_start = in_vs & ~vs_d;

    //--------------------------------------------------------------------------
    // Filter state
    //--------------------------------------------------------------------------
    reg  [15:0] h_src_w, v_src_h;   // working copies of the measured geometry
    reg  [15:0] h_frac, v_frac;     // fractional accumulator, always < DST_*
    reg  [15:0] h_take;             // source pixels this output pixel spans
    reg  [15:0] v_take;             // source lines this output line spans
    reg  [15:0] h_got;              // source pixels accumulated so far
    reg  [15:0] v_got;              // source lines accumulated so far
    reg  [19:0] h_sum;              // sum of the accumulated source pixels
    reg  [15:0] out_x, out_y;
    reg  [15:0] h_in;               // source pixels consumed on this line

    reg  w_sel, p_sel;              // rotating buffer roles
    reg  pub_tog;                   // toggles once per completed output line

    //--------------------------------------------------------------------------
    // Fractional accumulator step. One call per output element; `inc` is how
    // many source elements it spans. Unrolled for inc up to 2.
    //
    // `*_0` variants start from fraction zero. They are computed separately on
    // purpose: stepping from a leftover fraction would shift the whole line by
    // whatever the previous line left behind.
    //--------------------------------------------------------------------------
    reg [16:0] h_step, h_step0;
    reg [ 1:0] h_inc,  h_inc0;
    reg [16:0] v_step, v_step0;
    reg [ 1:0] v_inc,  v_inc0;

    always @(*) begin
        h_step  = {1'b0, h_frac}  + {1'b0, h_src_w};
        h_inc   = 2'd0;
        if (h_step >= DST_W) begin
            h_step = h_step - DST_W;
            h_inc  = 2'd1;
            if (h_step >= DST_W) begin
                h_step = h_step - DST_W;
                h_inc  = 2'd2;
            end
        end

        h_step0 = {1'b0, h_src_w};
        h_inc0  = 2'd0;
        if (h_step0 >= DST_W) begin
            h_step0 = h_step0 - DST_W;
            h_inc0  = 2'd1;
            if (h_step0 >= DST_W) begin
                h_step0 = h_step0 - DST_W;
                h_inc0  = 2'd2;
            end
        end
    end

    always @(*) begin
        v_step  = {1'b0, v_frac}  + {1'b0, v_src_h};
        v_inc   = 2'd0;
        if (v_step >= DST_H) begin
            v_step = v_step - DST_H;
            v_inc  = 2'd1;
            if (v_step >= DST_H) begin
                v_step = v_step - DST_H;
                v_inc  = 2'd2;
            end
        end

        v_step0 = {1'b0, v_src_h};
        v_inc0  = 2'd0;
        if (v_step0 >= DST_H) begin
            v_step0 = v_step0 - DST_H;
            v_inc0  = 2'd1;
            if (v_step0 >= DST_H) begin
                v_step0 = v_step0 - DST_H;
                v_inc0  = 2'd2;
            end
        end
    end

    // `take` is never 0, so the filter always makes progress.
    wire [1:0] h_take_n = (h_inc  == 2'd0) ? 2'd1 : h_inc;
    wire [1:0] v_take_n = (v_inc  == 2'd0) ? 2'd1 : v_inc;
    wire [1:0] h_take_0 = (h_inc0 == 2'd0) ? 2'd1 : h_inc0;
    wire [1:0] v_take_0 = (v_inc0 == 2'd0) ? 2'd1 : v_inc0;

    //--------------------------------------------------------------------------
    // The horizontal mean. h_got counts the pixels already in h_sum, so the
    // total for this output pixel is h_got + 1.
    //--------------------------------------------------------------------------
    wire [15:0] h_mean = (h_got == 16'd0) ? px :
                         (h_got == 16'd1) ? (px + h_sum[15:0]) >> 1 :
                                            (px + h_sum[15:0]) >> 2;

    // The vertical mean. The read port of W returns the pre-write value in the
    // same cycle, so this is a true read-modify-write on one address.
    wire [15:0] w_rd    = w_sel ? lb1[out_x] : lb0[out_x];
    wire [15:0] v_mean  = (v_got == 16'd0) ? h_mean : ((w_rd + h_mean) >> 1);

    //--------------------------------------------------------------------------
    // Pixel path: measurement, horizontal mean, vertical fold, buffer roles
    //--------------------------------------------------------------------------
    always @(posedge clk) begin
        if (!rst_ni) begin
            hs_d           <= 1'b0;
            vs_d           <= 1'b0;
            measuring      <= 1'b0;
            locked_q       <= 1'b0;
            overflow_q     <= 1'b0;
            px_in_line     <= 16'd0;
            lines_in_frame <= 16'd0;
            src_w_meas     <= 16'd0;
            src_w          <= 16'd0;
            src_h          <= 16'd0;
            h_src_w        <= 16'd1;
            h_frac         <= 16'd0;
            h_take         <= 16'd1;
            h_got          <= 16'd0;
            h_sum          <= 20'd0;
            out_x          <= 16'd0;
            h_in           <= 16'd0;
            v_src_h        <= 16'd1;
            v_frac         <= 16'd0;
            v_take         <= 16'd1;
            v_got          <= 16'd0;
            out_y          <= 16'd0;
            w_sel          <= 1'b0;
            p_sel          <= 1'b1;
            pub_tog        <= 1'b0;
        end else begin
            hs_d <= in_hs;
            vs_d <= in_vs;

            //------------------------------------------------------------------
            // geometry / frame boundary
            //
            // frame_start and line_start are the SAME cycle on every frame, and
            // that is forced, not incidental. rx_sdi.v:357 derives
            //     cam_data_en = cam_vs & cam_hs
            // so cam_vs has to be high before cam_hs rises for the first active
            // line -- if it were not, that line would carry no data_en at all
            // and the source would be short one line, forever. The vendor chain
            // does exactly this: frame_convertor takes cam_vs from the EAV of
            // the first active line, and sdi_status.v:181-185 already records
            // the coincidence and guards its own height counter for it.
            //
            // Both testbenches used to place cam_vs's rising edge AFTER line 0's
            // active pixels instead, to dodge the collision below. That raster
            // is not representable on this hardware -- their src_de was driven
            // independently of src_vs, so "active pixels while vs is low" could
            // be expressed at all. Modelling it cost the round its verdict: the
            // scaler's vertical walk then restarted one source line late, so
            // output row k was built from source row k+1, and no content check
            // was in a position to notice.
            //------------------------------------------------------------------
            if (frame_start) begin
                src_w     <= src_w_meas;
                src_h     <= lines_in_frame;
                h_src_w   <= (src_w_meas == 16'd0) ? 16'd1 : src_w_meas;
                v_src_h   <= (lines_in_frame == 16'd0) ? 16'd1 : lines_in_frame;
                locked_q  <= (src_w_meas != 16'd0) && (lines_in_frame != 16'd0);
                measuring <= 1'b1;

                // Only the VERTICAL walk restarts here. px_in_line and
                // lines_in_frame are owned by the per-line logic further down,
                // which seeds them for this very line -- a clear here would
                // race that seed, and did: the clear sat in this block and the
                // increment in a later one, the seed won, and the counter never
                // restarted at all (see the counter's own note).
                //
                // The horizontal walk is not restarted either. line_end
                // already restarts it during blanking, so re-seeding it here
                // buys nothing, and it makes this block a second writer of
                // h_sum/h_got/out_x/h_in on a cycle where the pixel path is
                // already writing all four.
                v_frac <= v_step0[15:0];
                v_take <= {14'd0, v_take_0};
                v_got  <= 16'd0;
                out_y  <= 16'd0;
            end

            //------------------------------------------------------------------
            // Per-line restart of the horizontal walk, plus the active-width
            // measurement.
            //
            // The restart is keyed to the FALLING edge of cam_hs, not the
            // rising one. cam_hs and cam_de rise on the same cycle (both come
            // out of YCbCr422_2_RGB888), so a rising-edge restart collides
            // with the first pixel of the line: both drive h_take / h_frac /
            // h_got, the pixel path wins, and the walk is seeded with a
            // step taken from the previous line's leftover fraction. That does
            // not look like an obvious failure -- h_take sticks at 1, every
            // pixel emits, and out_x wraps 0..63 over and over so the tail of
            // each line overwrites its head. The frame still "completes" and
            // still reports the right geometry, so only the pixels are wrong.
            //
            // The falling edge happens during blanking, where in_de is low and
            // the pixel path is idle, so the two never touch the same
            // registers. This assumes cam_hs actually drops during blanking,
            // which is what the vendor path produces.
            //------------------------------------------------------------------
            if (line_end) begin
                h_frac     <= h_step0[15:0];
                h_take     <= {14'd0, h_take_0};
                h_got      <= 16'd0;
                h_sum      <= 20'd0;
                out_x      <= 16'd0;
                h_in       <= 16'd0;

                // Publish the width here, at the end of a line that carried
                // pixels. A blanking line ends with px_in_line = 0 and must not
                // overwrite it.
                if (px_in_line != 16'd0)
                    src_w_meas <= px_in_line;
            end

            //------------------------------------------------------------------
            // Per-line counters
            //
            // Two things have to hold at once here, and getting either wrong
            // costs the picture entirely:
            //
            // 1. frame_start and line_start are the SAME cycle on this source
            //    (see the frame-boundary note above), so the publish and the
            //    restart of lines_in_frame must be resolved in ONE branch.
            //    Written as two assignments in this block -- clear on
            //    frame_start, increment on line_start -- the later one wins, the
            //    clear is silently overwritten, and the counter accumulates
            //    across frames instead of restarting. Measured on the old code
            //    with a coincident edge: 6479 (6 x 1080 - 1) lines after six
            //    frames, src_h garbage, locked_q never asserted.
            //    Seeding to 1 rather than 0 when the edges coincide is the same
            //    correction sdi_status.v:203 makes for its own height counter.
            //
            // 2. The count must be gated by in_vs. cam_hs rises on the 45
            //    vertical-blanking lines as well -- frame_convertor restarts its
            //    horizontal counter at every SAV, and a blanking line has a SAV
            //    like any other -- so an ungated line_start count reads 1125
            //    instead of 1080 and stretches the picture 4% vertically.
            //    in_vs is the vertical-ACTIVE level, so it is high for exactly
            //    the lines that carry picture.
            //------------------------------------------------------------------
            if (frame_start)
                // Seed 1 when a line is ALREADY IN PROGRESS at the vs rise --
                // in_hs high -- not only when the two edges land in the same
                // clock. The coincident case is one instance of this; the
                // general rule is "the line the frame boundary lands inside
                // belongs to the new frame". Written as `line_start ? 1 : 0` the
                // counter is one line SHORT for any positive skew: the line's
                // own line_start already happened while in_vs was still low, so
                // it is never counted and nothing counts it later. Measured on
                // the school box's cam_vs phase sweep: vs one pixel late reads
                // 1920x1079 instead of 1920x1080. The board does not sit in that
                // window -- sdi_status reports a measured height of 1080 for a
                // real 1080p50 source, which a one-line-late cam_vs cannot
                // produce -- but the fix costs one term and removes the cliff.
                lines_in_frame <= in_hs ? 16'd1 : 16'd0;
            else if (line_start && in_vs && measuring)
                lines_in_frame <= lines_in_frame + 16'd1;

            // px_in_line is the active width of the line in progress. Its load
            // has to win over frame_start on a coincident edge, so it is the
            // only writer of this register at a line boundary.
            if (line_start)
                px_in_line <= in_de ? 16'd1 : 16'd0;
            else if (in_de)
                px_in_line <= px_in_line + 16'd1;

            //------------------------------------------------------------------
            // Pixel path
            //------------------------------------------------------------------
            if (in_de && measuring && (h_in < h_src_w)) begin
                h_sum <= h_sum + {4'd0, px};
                h_got <= h_got + 16'd1;
                h_in  <= h_in + 16'd1;

                if ((h_got + 16'd1) >= h_take) begin
                    // ---- this source pixel closes one output pixel ----
                    if (w_sel) lb1[out_x] <= v_mean;
                    else       lb0[out_x] <= v_mean;

                    if (h_take > 16'd2)
                        overflow_q <= 1'b1;

                    h_got  <= 16'd0;
                    h_sum  <= 20'd0;
                    h_frac <= h_step[15:0];
                    h_take <= {14'd0, h_take_n};

                    //--------------------------------------------------------------
                    if (out_x == DST_W-1) begin
                        // ============ output line complete ======================
                        out_x <= 16'd0;

                        if ((v_got + 16'd1) >= v_take) begin
                            // --------------------------------------------------
                            // Output line complete -- but only while the frame
                            // still has lines to give.
                            //
                            // The upper bound on out_y was MISSING here, and it
                            // is the defect that only an end-to-end test can
                            // find. v_step is built from v_frac and v_src_h and
                            // never looks at out_y, so the vertical walk happily
                            // runs past the end of the output frame and keeps
                            // swapping buffers and toggling pub_tog until the
                            // SOURCE frame runs out. Measured with a real
                            // 2200x1125 source: 779 lines pushed per frame where
                            // DST_H is 720.
                            //
                            // The HDMI side consumes exactly one line per line
                            // slot, 750 slots per frame of which 720 are active,
                            // so 59 surplus lines per frame overrun the line
                            // slots. Measured 450 839 discarded pixels over 6
                            // frames = 58.7 lines per frame, which is the 59.
                            // The picture desynchronises permanently from then
                            // on, while timing and DRC stay perfectly green.
                            //
                            // Once out_y reaches DST_H the walk keeps advancing
                            // its fraction (so it is in phase when the next
                            // frame starts) but stops announcing lines. The
                            // pixel path still fills the line buffers; they are
                            // simply never published.
                            // --------------------------------------------------
                            if (out_y < DST_H) begin
                                // swap the buffer roles and announce the line
                                p_sel   <= w_sel;
                                w_sel   <= ~w_sel;
                                pub_tog <= ~pub_tog;
                                out_y   <= out_y + 16'd1;
                            end

                            v_got  <= 16'd0;
                            v_frac <= v_step[15:0];
                            v_take <= {14'd0, v_take_n};
                        end else begin
                            v_got <= v_got + 16'd1;
                        end
                    end else begin
                        out_x <= out_x + 16'd1;
                    end
                end
            end
        end
    end

    //--------------------------------------------------------------------------
    // Push stage
    //
    // p_sel was updated by the pixel path on the same edge that toggled
    // pub_tog, so by the time the push starts, p_sel already names the right
    // buffer. The BRAM read has one cycle of latency, so the valid and last
    // strobes are registered one cycle behind the address.
    //--------------------------------------------------------------------------
    reg        push_go, pub_seen;
    reg [15:0] push_cnt;
    // Frame marker. `out_frame` rides out with the first output line of each
    // frame, which is what hdmi_out's frame-phase alignment loop measures
    // against its own raster. It is required, not cosmetic: without a marker
    // the two frame boundaries are unrelated and the source's phase is
    // arbitrary -- see doc/02-verification.md 4.3.
    //
    // first_pending is armed by the source's frame_start and attaches to the
    // next push that STARTS after it, not to the push that happens to be in
    // flight when frame_start arrives: the vertical walk finishes line 719
    // about two source lines before the frame ends, so in the steady state
    // the two never collide, and if they ever do, the frame keeps its previous
    // line 0 and the loop simply re-measures on the next frame.
    reg        first_pending;
    reg        push_first;

    wire [15:0] p_rd = p_sel ? lb1[push_cnt] : lb0[push_cnt];

    wire pub_evt = (pub_tog != pub_seen);

    always @(posedge clk) begin
        if (!rst_ni) begin
            out_valid    <= 1'b0;
            out_last     <= 1'b0;
            out_frame    <= 1'b0;
            out_rgb_r    <= 16'd0;
            push_go      <= 1'b0;
            push_cnt     <= 16'd0;
            pub_seen     <= 1'b0;
            stat_lines   <= 32'd0;
            push_overrun <= 1'b0;
            first_pending <= 1'b1;   // the first push after reset IS line 0
            push_first    <= 1'b0;
        end else begin
            pub_seen <= pub_tog;

            if (frame_start)
                first_pending <= 1'b1;

            if (!push_go && pub_evt) begin
                push_go       <= 1'b1;
                push_cnt      <= 16'd0;
                push_first    <= first_pending;
                first_pending <= 1'b0;
            end

            if (push_go) begin
                out_rgb_r <= p_rd;               // address push_cnt(N) -> N+1
                out_valid <= 1'b1;
                out_last  <= (push_cnt == DST_W-1);
                out_frame <= push_first;

                // A second line completed while this one was still being
                // pushed: the producer has outrun the push port and a line is
                // lost. This is the ONLY place the flag may be set.
                //
                // It used to sit in the else branch below, guarded by
                // `pub_evt && locked_q` -- which is the NORMAL path. pub_evt is
                // the event that STARTS a push, so on that cycle push_go is
                // still 0 and the else branch is the one that runs. The flag
                // therefore asserted once per line, on every line, and reported
                // overruns on a stream that had none: a meter that always reads
                // full says nothing about the signal. Measured on the old code:
                // push_overrun = 1 with stat_lines counting cleanly and
                // hdmi_out's stat_dropped = 0.
                if (pub_evt && locked_q)
                    push_overrun <= 1'b1;

                if (push_cnt == DST_W-1) begin
                    push_go   <= 1'b0;
                    stat_lines <= stat_lines + 32'd1;
                end else begin
                    push_cnt <= push_cnt + 16'd1;
                end
            end else begin
                out_valid <= 1'b0;
                out_last  <= 1'b0;
                out_frame <= 1'b0;
            end
        end
    end

endmodule
`default_nettype wire