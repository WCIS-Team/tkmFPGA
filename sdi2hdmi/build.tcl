#=============================================================================
# build.tcl -- one-shot synth + implement + bitstream for sdi2hdmi
#
# Driven by compile.ps1, or by hand:
#   S:\apps\Xilinx\Vivado\2018.3\bin\vivado.bat -mode batch -nojournal ^
#       -source build.tcl
#
# This is a non-project flow on purpose. The vendor delivery is a .xpr with a
# prebuilt block design and a 71 MB EDIF NPU netlist that cannot be elaborated
# by an unlicensed Vivado; there is nothing here worth inheriting. A plain
# read_verilog / read_edif / synth_design / opt / place / route keeps the run
# short, the log readable, and every source file visible in one place.
#
# The smpte_sdi decoder is EDIF-only (rtl/sdi/ip/smpte_sdi/smpte_sdi.edif, no
# RTL), read the same way the vendor project reads it, with a stub supplying
# the port declaration for elaboration.
#
# Requires the vendor device-library patch to be installed, the same one the
# fpai_demo_fpga flow needs:
#   scripts\rt\data\unisim_comp.v and unisim_comp.lib, from
#   S:\work\WCIS\fdw\20260916\JFM_Kits\ip_patch\100ai\
# Without it, synthesis reports the PS7 IP's AI_IN ports as nonexistent. This
# design has no PS7, so it may well not be needed -- build.tcl reports whether
# unisim_comp.v is visible so the answer is recorded rather than guessed.
#=============================================================================

set SCRIPT_DIR [file dirname [file normalize [info script]]]
set ROOT       $SCRIPT_DIR
set RTL        [file join $ROOT rtl]
set CONSTR     [file join $ROOT constrs sdi2hdmi.xdc]
set DIST       [file join $ROOT dist]
set OUTDIR     [file join $ROOT .build]

file mkdir $DIST
file mkdir $OUTDIR

set JOBS 4
if {[info exists ::env(JOBS)] && $::env(JOBS) ne ""} { set JOBS $::env(JOBS) }

puts "BUILD: vivado = [version -short]"
puts "BUILD: root    = $ROOT"
puts "BUILD: jobs    = $JOBS"

#-----------------------------------------------------------------------------
# Which device-library patch is visible. Recorded, not assumed.
#-----------------------------------------------------------------------------
set have_unisim 0
set unisim_at ""
set unisim_candidates {}
if {[info exists ::env(XILINX_VIVADO)] && $::env(XILINX_VIVADO) ne ""} {
    lappend unisim_candidates \
        [file join $::env(XILINX_VIVADO) scripts rt data unisim_comp.v] \
        [file join $::env(XILINX_VIVADO) data unisim_comp.v]
}
lappend unisim_candidates \
    "C:/Xilinx/Vivado/2018.3/scripts/rt/data/unisim_comp.v" \
    "C:/Xilinx/Vivado/2018.3/data/unisim_comp.v" \
    "S:/apps/Xilinx/Vivado/2018.3/scripts/rt/data/unisim_comp.v" \
    "S:/apps/Xilinx/Vivado/2018.3/data/unisim_comp.v"

foreach p $unisim_candidates {
    if {!$have_unisim && [file exists $p]} {
        set have_unisim 1
        set unisim_at $p
    }
}
if {$have_unisim} {
    puts "BUILD: unisim_comp.v = $unisim_at"
} else {
    puts "BUILD: WARNING no unisim_comp.v found on the usual paths."
    puts "BUILD:          PS7-less design may not need it; the run will tell us."
}

#-----------------------------------------------------------------------------
# Sources
#
# The vendor tree is globbed rather than listed. k7_sdi_rxtx.v reaches into the
# test-pattern generators (multigenHD, vidgen_ntsc, vidgen_pal) even though
# this design never uses them, and enumerating by hand means discovering one
# missing module per build. Everything under vendor/sdi and vendor/display is
# cheap and self-contained.
#-----------------------------------------------------------------------------
set vlog {}

# our own modules first, so they elaborate before the vendor code
lappend vlog [file join $RTL sdi2hdmi_top.v]
lappend vlog [file join $RTL sdi2hdmi scaler_720.v]
lappend vlog [file join $RTL sdi2hdmi hdmi_out.v]

# vendor RTL, everything except the DRU set. The DRU instances were replaced
# by a tie-off in x7gtx_sdi_control.v (SD-SDI is out of scope; see the note
# there), so its stub and its helper RTL are no longer referenced and must not
# be read -- a black box in the netlist stops opt_design.
foreach f [lsort [glob -nocomplain -directory $RTL/vendor/sdi *.v]] {
    if {[string match "dru*.v" [file tail $f]]} { continue }
    lappend vlog $f
}

# display/: only the transmitter is used here. color_bar.v is the vendor demo's
# on-screen test pattern -- it is what that design shows when there is no SDI
# signal, not part of the picture path. It also pulls in video_define.v, whose
# active setting is VIDEO_1920_1080, i.e. exactly the 1080p60 / 742.5 MHz TMDS
# mode the board manual puts out of spec. Leaving it out keeps that out of this
# build by construction rather than by a comment.
foreach f [lsort [glob -nocomplain -directory $RTL/vendor/display *.v]] {
    if {[file tail $f] ne "color_bar.v"} { lappend vlog $f }
}

# Generated clk_wiz wrappers. The IP directories carry simulation netlists and
# black-box stubs alongside the two files synthesis actually wants:
#   <ip>.v          the IP wrapper (clk_in1, clk_out1, locked)
#   <ip>_clk_wiz.v  the clk_wiz implementation it instantiates
# The stub is rejected outright -- "source file was generated for simulation and
# is not permitted as input to synthesis" -- and the sim netlist would shadow
# the real module. The mmcm_*.vh helpers come in through `include, so they do
# not need to be listed.
foreach ip [list sys_clk mgtclk] {
    foreach f [lsort [glob -nocomplain -directory [file join $RTL vendor ip $ip] *.v]] {
        set t [file tail $f]
        if {[string match "*_sim_netlist.v" $t]} { continue }
        if {[string match "*_stub.v"       $t]} { continue }
        lappend vlog $f
    }
}

set missing {}
foreach f $vlog { if {![file exists $f]} { lappend missing $f } }
if {[llength $missing]} {
    puts "BUILD: ABORT, these sources are listed but absent:"
    foreach f $missing { puts "   $f" }
    exit 1
}
puts "BUILD: [llength $vlog] verilog sources"

read_vhdl    -vhdl2008 [file join $RTL vendor display TMDSEncoder.vhd]
read_verilog $vlog

# The SDI decoder: EDIF implementation plus the Verilog port stub, the same
# pairing the vendor project uses. The stub is not optional -- remove it and
# elaboration fails with "module smpte_sdi not found".
#
# Note the extension: the file is smpte_sdi.edf, NOT .edif. `cmd dir` shows the
# real name, but a wrong guess fails silently -- Tcl `file exists` returns 0,
# PowerShell Test-Path returns False, and Vivado only says "does not exist",
# which reads like "the copy went wrong" rather than "you spelled it wrong".
# The reliable check is [System.IO.Directory]::GetFiles, which enumerates the
# true directory entries.
read_verilog [file join $RTL vendor ip smpte_sdi smpte_sdi_stub.v]
read_edif    [file join $RTL vendor ip smpte_sdi smpte_sdi.edf]

#-----------------------------------------------------------------------------
# Elaborate
#-----------------------------------------------------------------------------
read_xdc $CONSTR

#-----------------------------------------------------------------------------
# Part
#
# xc7z030ffg676-2, not "xc7z030ai". The board silkscreen reads JFMQL30TAI676H
# (FCBGA676), which is this Xilinx part; the vendor's own project is built for
# exactly this string, and it is the one this Vivado install knows. Asking for
# "xc7z030ai" fails at set_part with
#   Invalid part specified: 'xc7z030ai'. Use the get_parts command...
# The device-library patch that the PS7 path needs (JFM_Kits/ip_patch/100ai/)
# is therefore not required here, because there is no PS7 in this design.
#-----------------------------------------------------------------------------
set_part xc7z030ffg676-2

# Synthesis runs single-threaded on purpose.
#
# With the default parallel jobs, Vivado spawns helper processes that race each
# other on its own internal macro files and one of them comes back with
#   couldn't read file ".../unimacro/unimacro_verilog.tcl": No error
# The file is present and readable, and reading it by hand works; the run dies
# at synth_design before any real work, and which of the two macro files it
# names changes from run to run. That is a concurrency artefact, not a missing
# file, so the fix is to stop the race rather than to go looking for the file.
# Synthesis is slower, and that is the correct trade for a reproducible build.
set_param general.maxThreads $JOBS
synth_design -top sdi2hdmi_top -part xc7z030ffg676-2 -flatten_hierarchy rebuilt
puts "BUILD: synth_design finished"

write_checkpoint -force [file join $OUTDIR post_synth.dcp]
report_utilization -file [file join $DIST utilization_synth.rpt]
report_timing_summary -file [file join $DIST timing_synth.rpt]

#-----------------------------------------------------------------------------
# Implement
#
# No severity overrides are needed here. Earlier drafts carried
# `set_msg_config -id {INBB-3} -new_severity {WARNING}` plus Opt 31-30/31-236
# downgrades to carry the DRU black box through implementation. That was a
# workaround for the wrong thing: the DRU instances are now a tie-off in
# x7gtx_sdi_control.v and the DRU sources are excluded, so there is no black
# box in the netlist at all. Leaving the overrides out keeps the run honest --
# a warning that is actually hiding a defect should be visible.
#
# Worth keeping in mind for the future, because both forms were tried:
#   set_msg_config is IGNORED for DRC checks (Vivado says so, and then aborts
#   opt_design anyway); DRC checks need
#     set_property SEVERITY {WARNING} [get_drc_checks {INBB-3}]
#   which is the form the vendor's own ai7030.xdc uses for REQP-44/46/52/56.
#-----------------------------------------------------------------------------
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
puts "BUILD: done, bitstream in $DIST"