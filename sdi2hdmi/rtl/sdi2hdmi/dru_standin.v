//=============================================================================
// dru_standin.v
//
// Behavioural stand-in for the Xilinx Data Recovery Unit.
//
// Why this exists
//   The vendor tree ships the DRU two ways: dru.v is a black-box stub carrying
//   `syn_black_box, and dru.edf is the implementation. But that EDIF is an
//   ENCRYPTED pre-generated netlist -- its header is the Xilinx "XlxV80EB"
//   marker, not EDIF text -- and reading it in a non-project flow makes Vivado
//   2018.3 die during RTL optimisation, with no error message, just a truncated
//   log and a -1 exit code. Leaving the EDIF out instead gets as far as
//   opt_design and then stops at
//     [DRC INBB-3] Black Box Instances: Cell 'rx_sdi_inst/SDI0/SDI/GTX_CTRL/
//     NIDRU' of type 'dru' has undefined contents ...
//
// What is actually lost
//   The DRU sits on the SD-SDI path: x7gtx_sdi_control.v:202 instantiates it,
//   its output becomes sd_data / sd_data_strobe, and that pair is the SD-rate
//   input of the smpte_sdi core. SD-SDI is 270 Mb/s composite video.
//
//   This design targets HD-SDI (1.485 Gbps) and 3G-SDI (2.97 Gbps). At those
//   rates smpte_sdi recovers from the GTX recovered clock and never looks at
//   its SD input, so holding the SD strobe low removes a path nothing was using.
//
//   The price is that SD-SDI (576i/480i analog formats) will not lock. That
//   is a scope decision, recorded in doc/01-architecture.md section 9, not an
//   accident.
//
// If this ever has to support SD-SDI, the DRU netlist has to come in through
// project mode (where the vendor reads it successfully) rather than
// read_edif in a batch script.
//=============================================================================
`timescale 1ns / 1ps
`default_nettype none

module dru (
    input  wire [19:0] DT_IN,
    input  wire [36:0] CENTER_F,
    input  wire [4:0]  G1,
    input  wire [4:0]  G1_P,
    input  wire [4:0]  G2,
    input  wire        CLK,
    input  wire        RST,
    input  wire        RST_FREQ,
    output wire [7:0]  VER,
    input  wire        EN,
    output wire [31:0] INTEG,
    output wire [31:0] DIRECT,
    output wire [31:0] CTRL,
    output wire [20:0] PH_OUT,
    output wire [19:0] RECLK,
    output wire [3:0]  SAMV,
    output wire [9:0]  SAM
);

    // Never assert the valid strobe: that is what makes the SD path idle.
    assign SAMV   = 4'b0000;
    assign SAM    = 10'd0;
    assign RECLK  = 20'd0;
    assign PH_OUT = 21'd0;
    assign VER    = 8'h00;
    assign INTEG  = 32'd0;
    assign DIRECT = 32'd0;
    assign CTRL   = 32'd0;

    // The unused inputs are tied off explicitly. Leaving a floating input on a
    // module this large produces a spray of Synth 8-3295 warnings that hide the
    // ones that matter.
    wire _unused_ok = &{1'b0, DT_IN, CENTER_F, G1, G1_P, G2, CLK, RST, RST_FREQ, EN, 1'b0};

endmodule
`default_nettype wire