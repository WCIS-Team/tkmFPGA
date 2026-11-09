//=============================================================================
// vlt_top.v -- Verilator wrapper for the school-machine test round.
//
// Wraps exactly the two modules the project ships (scaler_720 + hdmi_out) and
// exposes every port the C++ harness drives or samples. No stimulus logic lives
// here: clocks, the source raster, resets and all checking are in harness.cpp,
// so ONE C++ implementation covers real video, the extreme-case suite and
// long runs alike.
//
// Why a C++ harness instead of extending tb_e2e.v: the questions left are not
// "is this expression right" but "what happens over ten thousand frames, when
// the source unlocks, when the geometry changes mid-frame, when reset lands
// mid-line". Those are cheap in C++ (one eval per clock, no event queue) and
// painful in a Verilog testbench.
//
// Clock relationship: cam_clk is 148.5 MHz, the HDMI pixel clock is 74.25 MHz,
// and BOTH COME OUT OF THE SAME MMCM ON THE BOARD, so they are synchronous.
// The harness drives them with a fixed 2:1 relationship and offset edges; see
// the phase map in harness.cpp.
//=============================================================================

`timescale 1ns / 1ps

module vlt_top (
    input  wire        cam_clk,
    input  wire        hdmi_pix_clk,
    input  wire        rst_n,

    // source raster, driven by the harness
    input  wire [23:0] src_rgb,
    input  wire        src_de,
    input  wire        src_hs,      // horizontal-ACTIVE level
    input  wire        src_vs,      // vertical-ACTIVE level

    // scaler output side
    output wire        pix_valid,
    output wire        pix_last,
    output wire [15:0] pix_data,
    output wire        scaler_locked,
    output wire [15:0] src_w,
    output wire [15:0] src_h,
    output wire [31:0] scaler_lines,
    output wire        scaler_overflow,
    output wire        scaler_overrun,

    // HDMI raster side
    output wire        hs,
    output wire        vs,
    output wire        de,
    output wire [23:0] rgb,
    output wire        stalled,
    output wire [31:0] hdmi_frames,
    output wire [31:0] stat_dropped,
    output wire        overflow
);

    // Mirror the top level exactly: the HDMI write port is not fed until the
    // source geometry has been measured. See rtl/sdi2hdmi_top.v.
    wire pix_valid_gated = pix_valid && scaler_locked;

    wire pix_frame;      // scaler's frame marker, feeds the alignment loop

    scaler_720 #(.DST_W(1280), .DST_H(720)) u_scaler (
        .clk          (cam_clk),
        .rst_n        (rst_n),
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

    // CEA-861 720p60: 1650x750 total, 1280x720 active, positive syncs.
    hdmi_out #(
        .H_ACTIVE (1280), .H_FP (110), .H_SYNC (40), .H_BP (220),
        .V_ACTIVE (720),  .V_FP (5),   .V_SYNC (5),  .V_BP (20),
        .HS_POL   (1),    .VS_POL (1)
    ) u_hdmi_out (
        .wclk         (cam_clk),
        .wrst_n       (rst_n),
        .w_en         (pix_valid_gated),
        .w_last       (pix_last),
        .w_frame      (pix_frame),
        .w_data       (pix_data),
        .rclk         (hdmi_pix_clk),
        .rrst_n       (rst_n),
        .hs           (hs),
        .vs           (vs),
        .de           (de),
        .rgb          (rgb),
        .stalled      (stalled),
        .stat_frames  (hdmi_frames),
        .stat_dropped (stat_dropped),
        .overflow     (overflow)
    );

endmodule
