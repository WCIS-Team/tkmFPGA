#=============================================================================
# impl_only.tcl -- opt/place/route/bitstream starting from the post-synthesis
# checkpoint produced by build_synth.tcl.
#
# Why this exists
#   The Vivado install on this machine intermittently loses visibility of its own
#   runtime scripts. It shows up as a build that dies with exit code -1 and a
#   truncated log, at a different phase on every run:
#     couldn't read file ".../scripts/rt/data/unimacro/unimacro_verilog.tcl"
#     couldn't read file ".../scripts/rt/fpga_tcl/rtSynthCleanup.tcl"
#     (silent death during "Cross Boundary and Area Optimization")
#   PowerShell reads those same files every time, so it is not a missing file and
#   not anything in the design. Synthesis is the longest phase and therefore the
#   most likely place to hit it, so it is done once by build_synth.tcl and the
#   result is reused here.
#
# Run synth first:
#   powershell -NoProfile -ExecutionPolicy Bypass -File .\compile.ps1 -SynthOnly
# then:
#   powershell -NoProfile -ExecutionPolicy Bypass -File .\compile_impl.ps1
#=============================================================================

set SCRIPT_DIR [file dirname [file normalize [info script]]]
set ROOT       $SCRIPT_DIR
set DIST       [file join $ROOT dist]
set OUTDIR     [file join $ROOT .build]
set DCP        [file join $OUTDIR post_synth.dcp]

file mkdir $DIST

if {![file exists $DCP]} {
    puts "IMPL: ABORT, no checkpoint at $DCP"
    puts "IMPL:      run compile.ps1 -SynthOnly first."
    exit 1
}

set_param general.maxThreads 1

puts "IMPL: opening $DCP"
open_checkpoint $DCP

# open_checkpoint does NOT re-read constraints. The checkpoint carries the
# pin placements and the clock definitions, but the XDC is a build input and
# has to be replayed here.
#
# This was found the hard way: the CDC false paths in sdi2hdmi.xdc were present
# during the synthesis run and had no effect at all during implementation, so
# the report kept showing
#   u_hdmi_out/w_gray_reg[0]/C -> u_hdmi_out/w_gray_r1_reg[0]/D   -2.788 ns
# as if it were a real setup violation. An earlier version of this script
# re-applied only the REQP severity downgrades by hand and missed this; reading
# the whole XDC back in is both less code and less surprising.
read_xdc [file join $ROOT constrs sdi2hdmi.xdc]

opt_design
place_design
phys_opt_design
route_design

report_timing_summary -file [file join $DIST timing_routed.rpt]
report_utilization  -file [file join $DIST utilization_routed.rpt]
report_drc          -file [file join $DIST drc_routed.rpt]

write_checkpoint -force [file join $OUTDIR post_route.dcp]
set stamp [clock format [clock seconds] -format "%Y%m%d_%H%M%S"]
write_bitstream -force [file join $DIST "sdi2hdmi_${stamp}.bit"]
puts "IMPL: done, bitstream in $DIST"