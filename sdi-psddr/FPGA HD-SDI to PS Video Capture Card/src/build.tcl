#=============================================================================
# build.tcl -- one-shot compile of the SDI capture card.
#
#   S:\apps\Xilinx\Vivado\2018.3\bin\vivado.bat -mode batch -nojournal ^
#       -source build.tcl
#
# or just:  build.bat
#
# Env knobs
#   BOARD_VARIANT  lite (default) | full
#                  lite -> FMC_HPC_GBTCLK0_M2C_C_P/N = R6/R5, the pair the
#                  vendor's own delivered package had active.
#                  full -> U6/U5.
#                  Getting this wrong means the GT never sees a reference
#                  clock and the SDI input stays at zero frames forever.
#   JOBS           parallel jobs (default 4)
#   SYNTH_ONLY     1 -> stop after synth_1 (fast sanity check, ~15 min)
#
# The script is deliberately linear and loud: every step prints BUILD: <what>
# so a failed run says which step died rather than just "SYNTHESIS FAILED".
#=============================================================================

set SCRIPT_DIR [file dirname [file normalize [info script]]]
set ROOT       $SCRIPT_DIR
set PROJ_FILE  [file join $ROOT "sdi_cap.xpr"]
set XDC        [file join $ROOT "constrs" "sdi_cap.xdc"]
set DIST       [file join $ROOT "dist"]
set RTL        [file join $ROOT "rtl"]
set VENDOR_SDI [file join $RTL "vendor" "sdi"]
set VENDOR_IP  [file join $RTL "vendor" "ip"]

set BOARD_VARIANT "lite"
set JOBS "4"
set SYNTH_ONLY "0"
foreach {k v} [array get ::env] {
    switch -- $k {
        BOARD_VARIANT { set BOARD_VARIANT $v }
        JOBS          { set JOBS $v }
        SYNTH_ONLY    { set SYNTH_ONLY $v }
    }
}
if {$BOARD_VARIANT ni {lite full}} {
    puts "BUILD: BOARD_VARIANT must be lite or full, got '$BOARD_VARIANT'"
    exit 1
}
proc readfile  {p} { set f [open $p r]; set t [read $f]; close $f; return $t }

file mkdir $DIST
puts "BUILD: dir      = $ROOT"
puts "BUILD: variant  = $BOARD_VARIANT"
puts "BUILD: jobs     = $JOBS"
puts "BUILD: synth_only = $SYNTH_ONLY"
puts "BUILD: vivado   = [version -short]"

#--------------------------------------------------------------- device library
# The PS7 IP here is a FMSH-patched processing_system7: its model library
# carries the AI_* interfaces the stock xc7z030 device does not have. Without
# the patch, synthesis dies with ~104 "named port connection 'AI_IN...' does not
# exist". Verified here rather than assumed, because a silent fallback would
# cost a 40-minute build.
set UNI ""
foreach cand [list \
        [file join $::env(XILINX_VIVADO) "data" "verilog" "src" "unisim_comp.v"] \
        [file join [file dirname [file dirname [info nameofexecutable]]] "data" "verilog" "src" "unisim_comp.v"]] {
    if {$cand ne "" && [file exists $cand]} { set UNI $cand; break }
}
if {$UNI ne ""} {
    set fh [open $UNI r]; set txt [read $fh]; close $fh
    if {[regexp {AI_IN} $txt]} {
        puts "BUILD: device library OK (AI_* interfaces present in $UNI)"
    } else {
        puts "BUILD: ABORT -- $UNI has no AI_IN ports."
        puts "BUILD:         install the 100ai patch from JFM_Kits/ip_patch/100ai/"
        puts "BUILD:         (the full 3.4 MB unisim_comp.v, not the 410 KB one)"
        exit 1
    }
} else {
    puts "BUILD: WARNING -- could not locate unisim_comp.v, skipping the"
    puts "BUILD:          device-library check. If synthesis fails with"
    puts "BUILD:          \"named port connection 'AI_IN...' does not exist\","
    puts "BUILD:          that is this."
}

#--------------------------------------------------------- pick the GT clock pins
# Two complete fragments, one picked. An earlier version rewrote the XDC in
# place with Tcl string substitution and corrupted it: `split $t ""` on a
# non-matching needle expands the file by the replacement length every run
# (4 KB -> 13 MB over two runs) and then Vivado dies with an access violation.
# Do not reintroduce in-place constraint editing. Two files is cheap.
set GT_XDC [file join $ROOT "constrs" "gt_refclk_${BOARD_VARIANT}.xdc"]
if {![file exists $GT_XDC]} { puts "BUILD: ABORT -- no $GT_XDC"; exit 1 }
puts "BUILD: GT reference clock variant = $BOARD_VARIANT ($GT_XDC)"

#------------------------------------------------------------- device library path
# Vivado reads <install>/data/verilog/src/unisim_comp.v. If the PS7 xci names a
# different library directory, honour it; otherwise leave the default.

#------------------------------------------------------------------- create project
# -force so the build is re-runnable: the .xpr and sdi_cap.srcs are generated
# artefacts, and everything hand-written lives in rtl/, constrs/ and ps/.
create_project -force sdi_cap $ROOT -part xc7z030ffg676-2
puts "BUILD: project created, part = [get_property PART [current_project]]"

#------------------------------------------------------------------------ sources
# The vendor SDI receiver chain, unmodified except for the four y422_* output
# ports that were added to rx_sdi.v for this project.
foreach f [lsort [glob -nocomplain [file join $VENDOR_SDI "*.v"]]] {
    add_files -norecurse $f
}
puts "BUILD: vendor SDI RTL files = [llength [glob -nocomplain [file join $VENDOR_SDI *.v]]]"
# dru.edf is the encrypted implementation of the Data Recovery Unit that the
# smpte_sdi core instantiates for SD-rate (270 Mb/s) de-stutter. Without it,
# opt_design stops with:
#   [DRC INBB-3] Black Box Instances: Cell '.../GTX_CTRL/NIDRU' of type 'dru'
#         has undefined contents and is considered a black box
# The dru.v next to it is only the port stub.
set DRU_EDF [file join $VENDOR_SDI "dru.edf"]
if {[file exists $DRU_EDF]} {
    add_files -norecurse $DRU_EDF
    set_property file_type {EDIF} [get_files $DRU_EDF]
    puts "BUILD: dru.edf added (SD-rate DRU implementation)"
} else {
    puts "BUILD: ABORT -- $DRU_EDF not found"
    exit 1
}

# our own capture card
foreach f [lsort [glob -nocomplain [file join $RTL "*.v"]]] { add_files -norecurse $f }
foreach f [lsort [glob -nocomplain [file join $RTL "cap" "*.v"]]] { add_files -norecurse $f }
set n_top [llength [glob -nocomplain [file join $RTL "*.v"]]]
set n_cap [llength [glob -nocomplain [file join $RTL "cap" "*.v"]]]
puts "BUILD: sdi_cap RTL files = $n_top (top) + $n_cap (cap)"

# IP
foreach ipdir [list [file join $VENDOR_IP "ps7"] [file join $VENDOR_IP "clk_wiz_0"] \
                   [file join $VENDOR_SDI "ip" "smpte_sdi"] [file join $VENDOR_SDI "ip" "mgtclk"] \
                   [file join $VENDOR_SDI "ip" "sys_clk"]] {
    if {![file exists $ipdir]} { puts "BUILD: ABORT -- missing IP dir $ipdir"; exit 1 }
    add_files -norecurse [glob -nocomplain [file join $ipdir "*.xci"]]
}
puts "BUILD: IP added = [llength [get_ips -quiet]]"

# the smpte_sdi core ships as an encrypted EDIF netlist inside its .xci, so no
# separate .edif file has to be added to the project.

set_property top sdi_cap_top [current_fileset]

#-------------------------------------------------------------------- filesets
add_files -fileset constrs_1 -norecurse $XDC
add_files -fileset constrs_1 -norecurse $GT_XDC
foreach f [get_files -quiet $XDC] { set_property PROCESSING_ORDER LATE $f }
foreach f [get_files -quiet $GT_XDC] { set_property PROCESSING_ORDER LATE $f }

#--------------------------------------------------------------------- generate
puts "BUILD: ---- generate_target ----"
# Order matters: BD-free design, but the PS7 IP is an out-of-context design, so
# Order matters: BD-free design, but the PS7 IP is an out-of-context design, so
# generate_target must run before synth_1 or synth refuses to launch.
foreach ip [get_ips -quiet] {
    if {[catch {generate_target all $ip} err]} {
        puts "BUILD: generate_target on [get_property NAME $ip] FAILED: $err"
        exit 1
    }
    puts "BUILD:   generated [get_property NAME $ip]"
}

# This used to query get_ips ... -filter {FILE_TYPE == "DCP"} and print
# "PS7 DCP not found among IP outputs; synth may fail" on every single run.
# That was a false alarm: the vendor ships PS7 as a PRE-SYNTHESISED DCP sitting
# in rtl/vendor/ip/ps7/, unrelated to whatever generate_target produces.
# Synthesis and implementation always succeeded, which is exactly why the
# warning was worthless -- it kept claiming a file was missing that was there.
set PS7_DCP [file join $ROOT "rtl" "vendor" "ip" "ps7" "ps_ai_processing_system7_0_0.dcp"]
if {[file exists $PS7_DCP]} {
    puts "BUILD:   PS7 pre-synthesised DCP: $PS7_DCP ([file size $PS7_DCP] bytes)"
} else {
    puts "BUILD: WARNING -- PS7 DCP missing at $PS7_DCP"
    puts "BUILD:          synth may fail or fall back to re-synthesising PS7"
}

puts "BUILD: ---- ip status ----"
catch {report_ip_status}

#--------------------------------------------------------------------- synthesis
puts "BUILD: ---- synth_1 ----"
reset_run synth_1
launch_runs synth_1 -jobs $JOBS
wait_on_run synth_1
set sstat [get_property STATUS [get_runs synth_1]]
puts "BUILD: synth_1 status = $sstat"
if {[string match "*Complete*" $sstat] eq 0} {
    puts "BUILD: ABORT -- synthesis did not complete"
    exit 1
}

if {$SYNTH_ONLY eq "1"} {
    puts "BUILD: SYNTH_ONLY=1, stopping after synth_1"
    exit 0
}

#-------------------------------------------------------------------- implementation
puts "BUILD: ---- impl_1 ----"
catch {reset_run impl_1}

launch_runs impl_1 -to_step write_bitstream -jobs $JOBS
wait_on_run impl_1
set istat [get_property STATUS [get_runs impl_1]]
puts "BUILD: impl_1 status = $istat"
if {[string match "*Complete*" $istat] eq 0} {
    puts "BUILD: ABORT -- implementation did not complete"
    exit 1
}

#------------------------------------------------------------------- collect output
set stamp [clock format [clock seconds] -format %Y%m%d_%H%M%S]
set bit [get_property DIRECTORY [get_runs impl_1]]
set out [file join $bit "sdi_cap_top.bit"]
if {[file exists $out]} {
    file copy -force $out [file join $DIST "sdi_cap_${BOARD_VARIANT}_${stamp}.bit"]
    puts "BUILD: BITSTREAM -> dist/sdi_cap_${BOARD_VARIANT}_${stamp}.bit"
}

foreach rpt {timing_summary utilization_hierarchical} {
    set f [file join $bit "${rpt}.rpt"]
    if {[file exists $f]} {
        file copy -force $f [file join $DIST "${rpt}_${BOARD_VARIANT}_${stamp}.rpt"]
        puts "BUILD: report -> dist/${rpt}_${BOARD_VARIANT}_${stamp}.rpt"
    }
}

# headline numbers, because the previous rounds of this project repeatedly
# forgot to look at them
set trpt [file join $bit "timing_summary.rpt"]
if {[file exists $trpt]} {
    set fh [open $trpt r]; set tt [read $fh]; close $fh
    if {[regexp {WNS\(ns\).*\n.*?([-\d.]+)} $tt -> wns]} { puts "BUILD: WNS = $wns ns" }
}
# ------------------------------------------------------------------
# Report where the pixel FIFO actually ended up.
#
# An earlier version of this file asserted "LUT as Distributed RAM >= 32"
# and errored out below that. That criterion was WRONG on both counts:
#   1. the report filename had no top-module prefix, so the check silently
#      skipped (reported as "not found") -- a guard that never fires
#   2. pinning the FIFO to distributed RAM turned out not to be reliable.
#      Standalone synthesis honours (* ram_style = "distributed" *), but in
#      the full design the attribute is ignored again (the vendor SDI chain
#      has its own RAMB18E1 and Vivado merges memories).
#
# sdi_stream_wr no longer relies on any inference result: the FIFO read port
# is an explicit register (q <= mem[rp]), so block RAM, LUTRAM or plain
# registers all behave identically and behave the same as the RTL model.
# So this step now only REPORTS the numbers instead of asserting on them.
set _uprep [file join $bit "sdi_cap_top_utilization_placed.rpt"]
if {[file exists $_uprep]} {
    set fh [open $_uprep r]; set _ut [read $fh]; close $fh
    set _dluts 0; set _ram18 0
    if {[regexp {\|\s+LUT as Distributed RAM\s+\|\s+(\d+)} $_ut -> _dluts]} { }
    if {[regexp {\|\s+RAMB18\s+\|\s+(\d+)}            $_ut -> _ram18]} { }
    puts "BUILD: memory placement -- LUT as Distributed RAM = $_dluts, RAMB18 = $_ram18"
    puts "BUILD:   (the design is inference-agnostic; see the design notes, section 6.12)"
} else {
    puts "BUILD: WARNING -- $_uprep not found; memory placement not reported"
}
# ------------------------------------------------------------------
set urpt [file join $bit "utilization_hierarchical.rpt"]
if {[file exists $urpt]} {
    set fh [open $urpt r]; set ut [read $fh]; close $fh
    puts "BUILD: utilisation report copied to dist/"
}

puts "BUILD: DONE"
exit 0
