#--------------------------------------------------------------------
# Gowin Build Script — Tang Nano 20K Silence (dead/idle)
#
# Minimal bitstream: all outputs tied to safe idle states.
# Synthesises in seconds — no I2S, no DSP, no CPU.
#--------------------------------------------------------------------

set_option -verilog_std sysv2017
set_option -top_module top_silence
set_device GW2AR-LV18QN88C8/I7 -device_version C

add_file src/top_silence.sv

add_file -type cst src/constraints.cst
add_file -type sdc src/constraints.sdc

set_option -use_sspi_as_gpio 1
run all
