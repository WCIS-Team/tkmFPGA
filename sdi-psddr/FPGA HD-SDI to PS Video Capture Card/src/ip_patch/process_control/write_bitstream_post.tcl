# Runs inside the impl_1 write_bitstream step, right after the .bit is written,
# with the placed/routed design still open in this Tcl session.
# Purpose: also emit the .bin that the board's FPGA Manager (/dev/fpga0) loads,
# because this Vivado install has no bootgen.
if {[catch {write_bitstream -force -bin_file} err]} {
    puts "HOOK: write_bitstream -bin_file FAILED: $err"
} else {
    puts "HOOK: wrote .bit and .bin (bin is what the board loads)"
}
