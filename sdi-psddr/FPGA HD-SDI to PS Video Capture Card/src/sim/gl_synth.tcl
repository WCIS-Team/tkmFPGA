# ============================================================================
# gl_synth.tcl -- synthesise sdi_stream_wr and export a funcsim netlist.
#
# ASCII ONLY on purpose. Vivado's Tcl reads the system ANSI codepage, so
# inline non-ASCII comments get mangled into bogus option arguments.
#
# Invoked by run_gl_bench.bat. Not meant to be run by hand.
# ============================================================================

set top      sdi_stream_wr
set part     xc7z030ffg676-2
set rtl      S:/apps/llm/agentwork/sdi-cap/rtl/cap/sdi_stream_wr.v
set outdir   C:/Users/takomi/AppData/Local/Temp/opencode/glsim

file mkdir $outdir

create_project -in_memory -part $part
read_verilog $rtl
synth_design -top $top -part $part

report_utilization -file [file join $outdir util.rpt]

# Record every memory primitive so a change in inference cannot pass unnoticed.
set fh [open [file join $outdir mem.txt] w]
puts $fh [get_cells -hierarchical -filter {NAME =~ *mem_reg* || PRIMITIVE_TYPE =~ RAMB*}]
close $fh

write_verilog -mode funcsim -force [file join $outdir sw.v]

puts "GL: netlist written to [file join $outdir sw.v]"
exit