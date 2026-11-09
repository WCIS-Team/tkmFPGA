//============================================================================
// sdi_cap_cdc -- clock domain crossing helpers for the SDI capture card.
//
// Two idioms, both standard:
//
//   cdc_bus   multi-bit payload that is guaranteed stable before the matching
//             strobe arrives. Two register stages, no handshake. Correct as
//             long as the source does not change the payload while a
//             transaction is in flight -- the PS driver guarantees that by
//             writing the config registers and only then the start register.
//
//   cdc_pulse single-cycle strobe. Toggled in the source domain, resynchronised
//             through two flip-flops, edge-detected in the destination. This is
//             the only way to get a pulse across domains without either losing
//             it or stretching it.
//
// Source = s_axi_aclk (FCLK0, 50 MHz). Destination = cam_clk (SDI pixel clock
// or 200 MHz board clock while unlocked).
//============================================================================
`timescale 1ns / 1ps

module sdi_cap_cdc #(
    parameter integer W = 64
)(
    input  wire         clk_dst,
    input  wire         rst_dst_n,
    input  wire [W-1:0] d_bus,
    output wire [W-1:0] q_bus
);
    reg [W-1:0] s0, s1;
    always @(posedge clk_dst) begin
        if (!rst_dst_n) begin
            s0 <= {W{1'b0}};
            s1 <= {W{1'b0}};
        end else begin
            s0 <= d_bus;
            s1 <= s0;
        end
    end
    assign q_bus = s1;
endmodule


module sdi_cap_cdc_pulse (
    input  wire clk_src,
    input  wire rst_src_n,
    input  wire pulse_src,      // 1-cycle strobe in the source domain

    input  wire clk_dst,
    input  wire rst_dst_n,
    output reg  pulse_dst       // 1-cycle strobe in the destination domain
);
    reg toggle;
    always @(posedge clk_src) begin
        if (!rst_src_n)      toggle <= 1'b0;
        else if (pulse_src)  toggle <= ~toggle;
    end

    reg t0, t1, t1d;
    always @(posedge clk_dst) begin
        if (!rst_dst_n) begin
            t0 <= 1'b0; t1 <= 1'b0; t1d <= 1'b0;
        end else begin
            t0  <= toggle;
            t1  <= t0;
            t1d <= t1;
        end
    end

    always @(posedge clk_dst) begin
        if (!rst_dst_n) pulse_dst <= 1'b0;
        else            pulse_dst <= t1 ^ t1d;
    end
endmodule