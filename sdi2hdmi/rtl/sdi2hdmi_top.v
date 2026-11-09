//=============================================================================
// sdi2hdmi_top.v
//
// SDI in, HDMI out. Pure PL: no PS, no NPU, no AXI, no MIG, no DDR.
//
//   SDI mezzanine ──GT──> smpte_sdi ──> YCbCr422 ─> RGB888
//                                            │
//                                    scaler_720 (box resample to 1280x720)
//                                            │  line-slot CDC
//                                     hdmi_out (720p60 raster)
//                                            │
//                            TMDSEncoder + OSERDESE2 ──> HDMI socket
//
// Why this is not the vendor demo
//   fdw/20260916/fpai_demo_fpga already does SDI -> HDMI, but it routes the
//   picture out through PS: SDI -> AXI -> PS DDR -> PS -> display BRAM ->
//   HDMI. For a converter that is a full round trip through the CPU for
//   nothing, and it is what drives that design to MMCM 5/5 and WNS +0.072 ns.
//   Keeping the whole path in PL leaves the clocking budget comfortable and
//   makes the block simulatable.
//
// Why 720p60 and not 1080p60
//   The vendor design runs its HDMI raster at cam_clk = 148.5 MHz, which is
//   742.5 MHz of TMDS. The board manual gives the HR bank a 710 MHz ceiling
//   and says 1080p60 makes some monitors flicker for exactly that reason. This
//   design drives 720p60 instead: 74.25 MHz pixel clock, 371.25 MHz TMDS.
//
// Clocks and how many of them this costs
//   sys_clk_p/n  200 MHz    -> IBUFDS/BUFG. The PS reference, also the GT
//                              management clock and the reset source.
//   mgtclk       156.25MHz  -> 148.5 MHz, from the mezzanine. Vendor clk_wiz.
//   hdmi_clk     148.5MHz   -> 74.25 MHz + 371.25 MHz, this design's one MMCM.
//   BUFIO        371.25MHz  -> OSERDESE2 high-performance clock lane.
//
//   Total: 3 clocking primitives against the device's 5. The vendor demo uses
//   all 5 and that is why nothing can be added to it.
//=============================================================================
`timescale 1ns / 1ps
`default_nettype none

module sdi2hdmi_top (
    // ---- 200 MHz system reference (PL) -----------------------------------
    input  wire            sys_clk_p,
    input  wire            sys_clk_n,
    input  wire            sys_rst,

    // ---- SDI mezzanine over FMC HPC --------------------------------------
    input  wire            FMC_HPC_DP0_M2C_P,
    input  wire            FMC_HPC_DP0_M2C_N,
    // MGT REFCLKs -- 156.25 MHz from the mezzanine
    input  wire            FMC_HPC_GBTCLK0_M2C_C_P,
    input  wire            FMC_HPC_GBTCLK0_M2C_C_N,
    input  wire            rx_gtx_full_reset,

    // ---- HDMI output ------------------------------------------------------
    output wire            HDMI_CLK_P,
    output wire            HDMI_CLK_N,
    output wire [2:0]      HDMI_TX_P,
    output wire [2:0]      HDMI_TX_N,

    // ---- board LEDs -------------------------------------------------------
    // led[0] J1: SDI transport-frame lock (the vendor's own choice, LED_MON=1)
    // led[1] M6: HDMI pixel clock alive
    output wire [1:0]      led,

    // ---- JTAG -------------------------------------------------------------
    input  wire            PJTAG_TCK,
    input  wire            PJTAG_TMS,
    input  wire            PJTAG_TDI,
    output wire            PJTAG_TDO
);

    //==========================================================================
    // 200 MHz system clock
    //==========================================================================
    wire sys_clk_ibuf;
    wire sys_clk_200m;

    IBUFDS IBUFDS_sysclk (
        .I  (sys_clk_p),
        .IB (sys_clk_n),
        .O  (sys_clk_ibuf)
    );

    BUFG BUFG_sysclk (
        .I  (sys_clk_ibuf),
        .O  (sys_clk_200m)
    );

    //==========================================================================
    // Reset
    //
    // Asynchronous assert, synchronous release, three fliers. The fliers exist
    // so that a reset which is released close to a clock edge cannot produce a
    // short reset pulse, which on a design with GTs shows up much later as a
    // receiver that never locks.
    //==========================================================================
    reg [2:0] rst_sync;
    wire      rst_n_sys = rst_sync[2];

    always @(posedge sys_clk_200m) begin
        if (sys_rst)
            rst_sync <= 3'b111;
        else
            rst_sync <= {rst_sync[1:0], 1'b0};
    end

    //==========================================================================
    // SDI receiver (vendor RTL, one added output port)
    //==========================================================================
    wire        cam_hs, cam_vs, cam_data_en;
    wire [23:0] cam_rgb;
    wire        cam_clk;
    wire [159:0] sdi_status_bus;
    wire        mgtclk_148_5;
    wire        led_rx_locked, led_refclk_lk, led_usrclk_alive;

    rx_sdi rx_sdi_inst (
        .FMC_HPC_DP0_C2M_N       (),
        .FMC_HPC_DP0_C2M_P       (),
        .FMC_HPC_DP0_M2C_N       (FMC_HPC_DP0_M2C_N         ),
        .FMC_HPC_DP0_M2C_P       (FMC_HPC_DP0_M2C_P         ),
        .FMC_HPC_GBTCLK0_M2C_C_N (FMC_HPC_GBTCLK0_M2C_C_N   ),
        .FMC_HPC_GBTCLK0_M2C_C_P (FMC_HPC_GBTCLK0_M2C_C_P   ),
        .sys_clk_200m            (sys_clk_200m              ),
        .led1                    (led_usrclk_alive          ),
        .led2                    (led_refclk_lk             ),
        .led3                    (led_rx_locked             ),
        .cam_hs                  (cam_hs                    ),
        .cam_vs                  (cam_vs                    ),
        .cam_rgb                 (cam_rgb                   ),
        .cam_clk                 (cam_clk                   ),
        .cam_data_en             (cam_data_en               ),
        .rx_gtx_full_reset_n     (~rx_gtx_full_reset        ),
        .rx_gtx_reset_n          (~rx_gtx_full_reset        ),
        .sdi_status_bus          (sdi_status_bus            ),
        .mgtclk_148_5_o          (mgtclk_148_5              )
    );

    // The SDI pixel clock. rx_usrclk when locked (148.5 MHz for 3G, 74.25 MHz
    // for HD), sys_clk_200m otherwise so the fabric keeps a clock while the
    // receiver searches. That is exactly what the vendor module does; the
    // scaler tolerates either rate.
    //--------------------------------------------------------------------------
    // Reset for the cam_clk domain, re-synchronised locally.
    //
    // This used to be `wire cam_clk_rst_n = rst_n_sys;` -- the sys_clk_200m
    // domain's synchroniser output used directly as the reset for everything
    // clocked by cam_clk. That is a CDC (the reset changes asynchronously to
    // cam_clk) and it is also a high-fanout net: it reaches the resampler's
    // registers, the line-slot write pointer and, worst of all, the ENARDEN
    // input of the line-slot block RAM. Post-route that showed up as the only
    // failing path in the design:
    //
    //   Slack (VIOLATED) : -0.008 ns
    //   Source: rst_sync_reg[2]/C
    //   Destination: u_hdmi_out/mem_reg_1/ENARDEN
    //   Requirement 5.000 ns, data path 6.417 ns
    //   logic 0.266 ns (4.1%), route 6.151 ns (95.9%)
    //
    // i.e. it was almost entirely a routing problem on one net, not a logic
    // depth problem. Re-synchronising into cam_clk fixes both halves of it: the
    // output is a register sitting in the domain it resets, and only three flops
    // see the sys_clk-domain signal instead of the whole write side.
    //
    // Asynchronous assertion, synchronous release: the shift register is loaded
    // with all-ones when sys_rst is asserted, so the reset takes effect
    // immediately, and the all-ones state then walks out to the last stage over
    // three cam_clk edges, so release is synchronous to cam_clk.
    //--------------------------------------------------------------------------
    reg [2:0] cam_rst_sync;
    wire      cam_clk_rst_n = cam_rst_sync[2];

    always @(posedge cam_clk) begin
        if (sys_rst)
            cam_rst_sync <= 3'b111;
        else
            cam_rst_sync <= {cam_rst_sync[1:0], 1'b0};
    end

    //==========================================================================
    // Resampler: source raster -> 1280x720 RGB565
    //==========================================================================
    wire        pix_valid, pix_last, pix_frame;
    wire [15:0] pix_data;
    wire [15:0] meas_src_w, meas_src_h;
    wire [31:0] scaler_lines;
    wire        scaler_locked, scaler_overflow, scaler_overrun;

    //--------------------------------------------------------------------------
    // Hold the resampler output off the HDMI side until the geometry is known.
    //
    // scaler_720 needs one frame to measure the source. Until it has, its
    // horizontal walk is seeded with h_src_w = 1 (scaler_720.v:300), so it
    // emits lines that are numerically meaningless -- the module says so itself
    // at scaler_720.v:58-59.
    //
    // Those lines used to be pushed into the line slots anyway. Because the
    // line-slot FIFO cannot be back-pressured, feeding it garbage during the
    // measurement frame fills all 8 slots, the write port then discards
    // everything after it, and the producer's pixel counter is permanently
    // desynchronised from the write pointer. Measured by tb_e2e.v:
    //
    //   stat_dropped = 298 240   -- all of it inside the FIRST frame
    //   frames 1..5 after that:  dropped +0, scaler +720 lines, claims +720
    //
    // So the steady state is exactly balanced and the whole loss was a start-up
    // transient feeding an unbounded FIFO with data that was never going to be
    // displayed.
    //
    // Gating on scaler_locked removes it. scaler_locked only changes on
    // frame_start (scaler_720.v:302), never mid-frame, so this cannot truncate
    // a line. The visible consequence is that the monitor shows black from
    // power-up until the source locks -- which is the correct behaviour, and is
    // strictly better than showing a picture that is quietly corrupt.
    //--------------------------------------------------------------------------
    wire pix_valid_gated = pix_valid && scaler_locked;

    scaler_720 #(
        .DST_W (1280),
        .DST_H (720)
    ) u_scaler (
        .clk          (cam_clk),
        .rst_n        (cam_clk_rst_n),
        .in_rgb       (cam_rgb),
        .in_de        (cam_data_en),
        .in_hs        (cam_hs),
        .in_vs        (cam_vs),
        .out_valid    (pix_valid),
        .out_last     (pix_last),
        .out_frame    (pix_frame),
        .out_rgb      (pix_data),
        .src_w        (meas_src_w),
        .src_h        (meas_src_h),
        .stat_lines   (scaler_lines),
        .locked_q     (scaler_locked),
        .overflow_q   (scaler_overflow),
        .push_overrun (scaler_overrun)
    );

    //==========================================================================
    // HDMI clock generation
    //
    // 148.5 MHz in. VCO at 742.5 MHz, then divide by 10 for the 74.25 MHz
    // pixel clock and by 2 for the 371.25 MHz OSERDESE2 clock lane.
    //
    // 742.5 MHz sits inside the 7-series MMCM VCO range (600..1200 MHz for a
    // -1 speed grade). The vendor's own cmos_clkgen_742_5 runs the same VCO.
    //
    // The OSERDESE2 CLK input must come from a BUFIO, not a BUFG: it has to be
    // phase aligned with the fabric that feeds the serializer's parallel data.
    //=======================================================================*/
    wire hdmi_pix_clk;      // 74.25 MHz
    wire hdmi_ser_clk;      // 371.25 MHz, MMCM output
    wire hdmi_ser_clk_io;   // 371.25 MHz, BUFIO output
    wire hdmi_mmcm_locked;
    wire hdmi_vco, hdmi_fb;

    // MMCME2_ADV rather than MMCME2_BASE so the feedback path is explicit
    // and routed. With BASE and an unconnected CLKFBOUT/CLKFBIN, synthesis
    // reports
    //   [Timing 38-1] DLL output pin(s) used on clock modifying cell
    //   u_hdmi_mmcm without a feedback net: CLKOUT0 CLKOUT1
    // which is the tool telling us the phase relationship between the outputs
    // and the fabric is unverified. The loop below costs one BUFG out of 32.
    MMCME2_ADV #(
        .CLKIN1_PERIOD  (6.734),          // 148.5 MHz
        .CLKFBOUT_MULT_F(5.000),          // VCO = 742.5 MHz
        .DIVCLK_DIVIDE  (1),
        .CLKOUT0_DIVIDE_F(10.000),        // 74.25 MHz  pixel clock
        .CLKOUT1_DIVIDE (2),              // 371.25 MHz  serializer clock
        .CLKOUT0_PHASE  (0.000),
        .CLKOUT1_PHASE  (0.000),
        .BANDWIDTH      ("OPTIMIZED"),
        .STARTUP_WAIT   ("FALSE")
    ) u_hdmi_mmcm (
        .CLKIN1      (mgtclk_148_5),
        .CLKFBOUT    (hdmi_vco),
        .CLKFBIN     (hdmi_fb),
        .CLKOUT0     (hdmi_pix_clk),
        .CLKOUT1     (hdmi_ser_clk),
        .LOCKED      (hdmi_mmcm_locked)
    );

    BUFG u_hdmi_clkfb (
        .I  (hdmi_vco),
        .O  (hdmi_fb)
    );

    BUFIO u_hdmi_bufio (
        .I  (hdmi_ser_clk),
        .O  (hdmi_ser_clk_io)
    );

    //==========================================================================
    // CDC + 720p60 raster
    //==========================================================================
    wire        hs, vs, de;
    wire [23:0] rgb888;
    wire        hdmi_stalled;

    //==========================================================================
    // HDMI line-slot overrun status
    //==========================================================================
    // hdmi_overflow latches if the write side of the line-slot FIFO ever has to
    // discard a pixel. That matters because the write port cannot be
    // back-pressured -- it is fed by the SDI pixel stream -- so an overrun is
    // not a transient, it permanently desynchronises the picture and every line
    // after it carries the wrong line number. Measured in simulation before the
    // claim-rate fix: 220 160 pixels discarded over one run.
    //
    // NOT brought out to a pin yet, and deliberately so. This board exposes
    // exactly two LEDs at the top level (J1 and M6, the same two the vendor
    // demo constrains) and both already carry a meaning worth keeping, so there
    // is no free pin to promote this to without guessing at the pinout. Until
    // one is identified it is an internal status net only.
    //
    // Open item, recorded in doc/02-verification.md.
    wire [31:0] hdmi_dropped;
    wire        hdmi_overflow;
    wire [31:0] hdmi_frames;

    hdmi_out #(
        .SLOTS (8)
    ) u_hdmi_out (
        .wclk        (cam_clk),
        .wrst_n      (cam_clk_rst_n),
        .w_en        (pix_valid_gated),
        .w_last      (pix_last),
        .w_frame     (pix_frame),
        .w_data      (pix_data),

        .rclk        (hdmi_pix_clk),
        .rrst_n      (hdmi_mmcm_locked),
        .hs          (hs),
        .vs          (vs),
        .de          (de),
        .rgb         (rgb888),
        .stalled     (hdmi_stalled),
        .stat_frames (hdmi_frames),
        .stat_dropped(hdmi_dropped),
        .overflow    (hdmi_overflow)
    );

    //==========================================================================
    // HDMI transmitter (vendor RTL)
    //
    // PCLKX1 is the 74.25 MHz pixel clock and drives the TMDS encoder, one
    // 10-bit character per pixel. PCLKX5 is the 5x clock the OSERDESE2 10:1
    // serializer needs for its clock lane; in DATA_WIDTH=10 DDR mode the
    // primitive requires CLK to be exactly 5x CLKDIV. PCLKX2_5 is unused by the
    // 7-series path and is tied low, exactly as the vendor instantiation does.
    //==========================================================================
    uihdmitx #(.FAMILY("7FAMILY")) u_uihdmitx (
        .RSTn_i        (hdmi_mmcm_locked),
        .HS_i          (hs),
        .VS_i          (vs),
        .VDE_i         (de),
        .RGB_i         (rgb888),
        .PCLKX1_i      (hdmi_pix_clk),
        .PCLKX2_5_i    (1'b0),
        .PCLKX5_i      (hdmi_ser_clk_io),
        .TMDS_TX_CLK_P (HDMI_CLK_P),
        .TMDS_TX_CLK_N (HDMI_CLK_N),
        .TMDS_TX_P     (HDMI_TX_P),
        .TMDS_TX_N     (HDMI_TX_N)
    );

    //==========================================================================
    // Status LEDs
    //
    // J1 keeps the vendor's meaning: SDI transport-frame lock. That is the one
    // LED on this board that tells the truth about the receiver, and
    // LED_MON=1 in the vendor top-level was put there for exactly this reason.
    // M6 becomes the HDMI pixel clock, which is the other half of the
    // "is anything coming out" question.
    //==========================================================================
    reg [24:0] pix_clk_cnt;
    always @(posedge hdmi_pix_clk) begin
        if (!hdmi_mmcm_locked)
            pix_clk_cnt <= 25'd0;
        else
            pix_clk_cnt <= pix_clk_cnt + 25'd1;
    end

    assign led[0] = led_rx_locked;
    assign led[1] = hdmi_mmcm_locked & pix_clk_cnt[24];

endmodule
`default_nettype wire