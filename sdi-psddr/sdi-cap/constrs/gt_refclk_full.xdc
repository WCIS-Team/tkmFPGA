# GT reference clock, "full" board variant.
#
# See gt_refclk_lite.xdc for why this pair matters. Only use this if the
# physical board really has the 148.5 MHz on U6/U5 -- nothing in the software
# can tell you that; it is a continuity check with a meter.
#
# Build with:  build.bat full

set_property PACKAGE_PIN U6 [get_ports FMC_HPC_GBTCLK0_M2C_C_P]
# WUJING BOARD
set_property PACKAGE_PIN U5 [get_ports FMC_HPC_GBTCLK0_M2C_C_N]

create_clock -period 6.734 [get_ports FMC_HPC_GBTCLK0_M2C_C_P]
