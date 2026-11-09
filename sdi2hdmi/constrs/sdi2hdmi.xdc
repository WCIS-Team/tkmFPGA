#-----------------------------------------------------------------------------
# sdi2hdmi.xdc -- pin and timing constraints for sdi2hdmi_top
#
# Pin assignments are taken verbatim from the vendor design
# (fpai_demo_fpga/constrs_1/impl_constraints.xdc) so that the same board, the
# same SDI mezzanine and the same HDMI socket are driven exactly as the vendor
# drives them. Nothing here is invented.
#-----------------------------------------------------------------------------

#-----------------------------------------------------------------------------
# 200 MHz system reference, PL bank 35
#-----------------------------------------------------------------------------
create_clock -period 5.000 [get_ports sys_clk_p]
set_property IOSTANDARD DIFF_SSTL15 [get_ports sys_clk_p]
set_property IOSTANDARD DIFF_SSTL15 [get_ports sys_clk_n]
set_property PACKAGE_PIN C8 [get_ports sys_clk_p]
set_property PACKAGE_PIN C7 [get_ports sys_clk_n]

set_property PACKAGE_PIN F8 [get_ports sys_rst]
set_property IOSTANDARD LVCMOS15  [get_ports sys_rst]

#-----------------------------------------------------------------------------
# SDI mezzanine over FMC HPC
#
# AB4/AB3 are the GT receive pair. R6/R5 are the mezzanine's reference clock.
#
# The vendor package has TWO variants of that clock pair and only one active:
#   R6/R5  "WUJING LITE BOARD"  <- active in the vendor delivery
#   U6/U5  "WUJING BOARD"       <- commented out there
# A bitstream diff of the two vendor builds showed the only entity differences
# were a few IOB configuration words and the route, which is what switching a
# clock pin pair looks like. This design keeps the vendor's active choice.
# Wrong pair = the GT never gets a reference clock = the SDI receiver never
# locks, while HDMI and everything else keep working.
#-----------------------------------------------------------------------------
set_property PACKAGE_PIN AB4 [get_ports FMC_HPC_DP0_M2C_P]
set_property PACKAGE_PIN AB3 [get_ports FMC_HPC_DP0_M2C_N]

set_property PACKAGE_PIN R6 [get_ports FMC_HPC_GBTCLK0_M2C_C_P]
set_property PACKAGE_PIN R5 [get_ports FMC_HPC_GBTCLK0_M2C_C_N]
create_clock -period 6.734 [get_ports FMC_HPC_GBTCLK0_M2C_C_P]

set_property PACKAGE_PIN E7 [get_ports rx_gtx_full_reset]
set_property IOSTANDARD LVCMOS15 [get_ports rx_gtx_full_reset]
# E7 has no pull setting in the vendor xdc. A floating reset input holds the GT
# receiver in permanent reset, which looks exactly like "no SDI signal".
set_property PULLDOWN true [get_ports rx_gtx_full_reset]

#-----------------------------------------------------------------------------
# HDMI output, TMDS_33 in an HR bank
#
# Only the _P legs are constrained; the _N legs come out of the OBUFDS inside
# oserdese2_10to1 and the IOSTANDARD propagates through it.
#-----------------------------------------------------------------------------
set_property PACKAGE_PIN AC17 [get_ports HDMI_CLK_P]
set_property PACKAGE_PIN AA15 [get_ports {HDMI_TX_P[0]}]
set_property PACKAGE_PIN Y16  [get_ports {HDMI_TX_P[1]}]
set_property PACKAGE_PIN W16  [get_ports {HDMI_TX_P[2]}]
set_property IOSTANDARD TMDS_33 [get_ports HDMI_CLK_P]
set_property IOSTANDARD TMDS_33 [get_ports {HDMI_TX_P[*]}]

#-----------------------------------------------------------------------------
# LEDs, bank 13
#-----------------------------------------------------------------------------
set_property PACKAGE_PIN J1 [get_ports {led[0]}]
set_property PACKAGE_PIN M6 [get_ports {led[1]}]
set_property IOSTANDARD LVCMOS15 [get_ports {led[0]}]
set_property IOSTANDARD LVCMOS15 [get_ports {led[1]}]

#-----------------------------------------------------------------------------
# PJTAG, bank 14
#-----------------------------------------------------------------------------
set_property PACKAGE_PIN AB15 [get_ports PJTAG_TCK]
set_property PACKAGE_PIN AB14 [get_ports PJTAG_TMS]
set_property PACKAGE_PIN AD15 [get_ports PJTAG_TDI]
set_property PACKAGE_PIN AD16 [get_ports PJTAG_TDO]
set_property IOSTANDARD LVCMOS33 [get_ports PJTAG_TCK]
set_property IOSTANDARD LVCMOS33 [get_ports PJTAG_TMS]
set_property IOSTANDARD LVCMOS33 [get_ports PJTAG_TDI]
set_property IOSTANDARD LVCMOS33 [get_ports PJTAG_TDO]
set_property PULLUP true [get_ports PJTAG_TDO]
create_clock -period 20.000 -name jtag_clk -waveform {0.000 10.000} [get_ports PJTAG_TCK]

#-----------------------------------------------------------------------------
# Timing exceptions
#
# sys_rst is asynchronous to every clock in the design and is resynchronised by
# rst_sync in the top level, so it must not be timed as a data path.
#-----------------------------------------------------------------------------
set_false_path -from [get_ports sys_rst]
set_false_path -to   [get_ports {led[0]}]
set_false_path -to   [get_ports {led[1]}]

#-----------------------------------------------------------------------------
# REQP-52 / REQP-56 downgrades
#
#   [DRC REQP-52] connects_GTGREFCLK_ACTIVE: GTXE2_CHANNEL cell ... Use of the
#                  GTGREFCLK is reserved for test purposes only ...
#   [DRC REQP-56] connects_GTGREFCLK_ACTIVE: GTXE2_COMMON cell ... same text
#
# The design routes the mezzanine reference clock through a BUFG before the
# GT, which is exactly what trips these: GTGREFCLK is the GT's test clock input
# and a BUFG-driven reference is the low-performance path.
#
# This is not a workaround invented here. The vendor's own top-level
# (fpai_demo_fpga/constrs_1/ai7030.xdc) carries the same four downgrades,
# REQP-44/46/52/56, for the same reason, and its bitstreams are the ones that
# run on this board. Downgrading the same pair is what "matching the known-good
# build" actually means; see [[官方demo时序基线与器件库补丁]] for the vendor's
# handling.
#
# If the SDI receiver ever fails to lock, this is the first thing to revisit:
# the check is advisory, but it is advisory about something real.
#-----------------------------------------------------------------------------
set_property SEVERITY {WARNING} [get_drc_checks {REQP-44}]
set_property SEVERITY {WARNING} [get_drc_checks {REQP-46}]
set_property SEVERITY {WARNING} [get_drc_checks {REQP-52}]
set_property SEVERITY {WARNING} [get_drc_checks {REQP-56}]

# The line-slot CDC in hdmi_out is the only crossing between the SDI pixel
# clock and the HDMI pixel clock, and it carries whole video lines: the write
# side releases a slot only after its 1280th pixel lands, so the reader can
# never latch a half-written line.
#
# One synchroniser chain per DIRECTION, each clocked by the domain that
# consumes it:
#   r_gray  (rclk domain) -> r_gray_s1/r_gray_s2 (wclk domain)   feeds `full`
#   w_gray  (wclk domain) -> w_gray_r1/w_gray_r2 (rclk domain)   feeds `empty`
#
# The path INTO the first flier of each chain sees an asynchronous signal and
# is a false path. Both cuts are needed: covering only one of the two directions
# leaves the report showing
#   u_hdmi_out/w_gray_reg[0]/C -> u_hdmi_out/w_gray_r1_reg[0]/D   -2.788 ns
# which is a clock domain crossing being timed as if it were synchronous.
#
# The picture data itself crosses through the line-slot BRAM, and that is not a
# timing path: a memory is not timed from one clock domain into another, each
# side is timed against its own clock, and BRAM read latency is one cycle in
# both directions.
#
# The cuts are made CELL to CELL, not pin to pin. The first attempt filtered on
# pins with a `/Q` suffix and matched nothing, because the paths the report
# shows start at the source register's CLOCK pin:
#   Source:      u_hdmi_out/w_gray_reg[0]/C
#   Destination: u_hdmi_out/w_gray_r1_reg[0]/D
# so the false path never applied and the -2.788 ns violation stayed in the
# report. Filtering on the register cells covers every pin of both ends, which
# is also the right scope for a synchroniser: nothing inside one should be
# timed.
set_false_path -from [get_cells -hier -filter {NAME =~ *u_hdmi_out/w_gray_reg*}] \
               -to   [get_cells -hier -filter {NAME =~ *u_hdmi_out/w_gray_r1_reg*}]
set_false_path -from [get_cells -hier -filter {NAME =~ *u_hdmi_out/r_gray_reg*}] \
               -to   [get_cells -hier -filter {NAME =~ *u_hdmi_out/r_gray_s1_reg*}]

#----------------------------------------------------------------------------
# hdmi_out frame-phase alignment marker: scaler (cam_clk) -> raster (pix clk)
#----------------------------------------------------------------------------
# The scaler's frame boundary (out_frame_reg, one line wide) is sampled by
# hdmi_out's 3-stage synchroniser in the raster clock domain, so the alignment
# loop can measure where the producer's frame starts. Same treatment as the
# pointer CDC above and for the same reason: the two clocks come from different
# MMCMs with no phase relationship to time against, while it is the synchroniser
# structure -- ASYNC_REG on the first two stages -- that makes the sampling
# safe. Only the crossing itself is cut; wf_s1 -> wf_s2 -> wf_s3 is inside the
# raster domain and stays timed.
set_false_path -from [get_cells -hier -filter {NAME =~ *u_scaler/out_frame_reg*}] \
               -to   [get_cells -hier -filter {NAME =~ *u_hdmi_out/wf_s1_reg*}]

#----------------------------------------------------------------------------
# Vendor GT QPLL reset synchroniser: sys_clk_200m domain -> mgtclk domain
#----------------------------------------------------------------------------
#   Slack (VIOLATED) : -0.028 ns
#   Source:      rx_sdi_inst/SDI0/SDI/GTX_CTRL/RXRST/pll_reset_reg/C
#   Destination: rx_sdi_inst/gtxe2_common_0/qpll_reset_r_reg/D
#
# The two clocks are unrelated:
#
#   clk_out1_sys_clk   period 37.037 ns  (27 MHz, the sys_clk_200m MMCM output)
#   clk_out1_mgtclk    period  6.734 ns  (148.5 MHz, the mgtclk MMCM output)
#
# 27 MHz and 148.5 MHz have no rational ratio, so there is no phase relationship
# to time against and no amount of placement work makes this path meaningful.
# `qpll_reset_r_reg` is the reset synchroniser inside the vendor GTX common
# block wrapper -- asynchronous assertion, synchronous release -- which is
# exactly the structure that is not meant to be timed as a data path. This is
# vendor RTL (rtl/vendor/sdi/rx_sdi.v and the gtxe2_common wrapper) and is left
# as it shipped.
#
# Scoped to exactly the two registers in the report. The point is narrow on
# purpose: a blanket `set_false_path` across the whole SDI receiver would also
# stop the genuinely synchronous parts of the receiver from being checked, and
# this constraint exists to remove one crossing, not to excuse a region.
#
# Note this path was PASSING before, with positive slack, and only appeared once
# a placement change (the cam_clk reset synchroniser) moved the floorplan under
# it. That is worth stating plainly: it was always unconstrained, so its margin
# was never real, only incidental.
set_false_path -from [get_cells -hier -filter {NAME =~ *rx_sdi_inst/*/RXRST/pll_reset_reg*}] \
               -to   [get_cells -hier -filter {NAME =~ *rx_sdi_inst/gtxe2_common_*/qpll_reset_r_reg*}]