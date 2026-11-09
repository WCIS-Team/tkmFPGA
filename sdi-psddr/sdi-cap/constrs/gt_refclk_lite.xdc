# GT reference clock, "lite" board variant.
#
# These two lines decide WHICH GT reference-clock input the SDI deserializer's
# 148.5 MHz recovered clock reaches. The wrong pair means the GT never gets a
# reference clock and the SDI input stays at zero frames forever, while HDMI
# and the NPU keep working -- which makes it easy to misdiagnose as a bitstream
# problem.
#
# This is the pair the vendor's delivered package had ACTIVE, which is the
# reason it is the default. Build the other one with:  build.bat full

set_property PACKAGE_PIN R6 [get_ports FMC_HPC_GBTCLK0_M2C_C_P]
# WUJING LITE BOARD
set_property PACKAGE_PIN R5 [get_ports FMC_HPC_GBTCLK0_M2C_C_N]

create_clock -period 6.734 [get_ports FMC_HPC_GBTCLK0_M2C_C_P]
