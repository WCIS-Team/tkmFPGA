# probe_ramb.tcl -- where did the memory land in the final hp2d routed design?
# Read-only: open the routed checkpoint, list every RAMB / SRL cell by name.
open_checkpoint S:/apps/llm/agentwork/sdi-cap/sdi_cap.runs/impl_1/sdi_cap_top_routed.dcp

puts "PROBE: ---- RAMB cells ----"
set cells [get_cells -hierarchical -filter {REF_NAME =~ RAMB*}]
foreach c $cells {
    puts "PROBE: [get_property REF_NAME $c]  $c"
}
puts "PROBE: RAMB count = [llength $cells]"

puts "PROBE: ---- SRL cells ----"
set scells [get_cells -hierarchical -filter {REF_NAME =~ SRL*}]
foreach c $scells {
    puts "PROBE: [get_property REF_NAME $c]  $c"
}
puts "PROBE: SRL count = [llength $scells]"
exit 0
