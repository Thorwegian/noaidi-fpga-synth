#--------------------------------------------------------------------
# Gowin Build Script — Tang Nano 20K Synthesizer
#--------------------------------------------------------------------

set_option -verilog_std sysv2017
# Gowin's gw_sh only accepts "sysv2017" — rejects sv2012/sysv/sv2009.
# This is Synplify's SV 2012+ parser, same feature set as iverilog -g2012.
set_option -top_module top
set_device GW2AR-LV18QN88C8/I7 -device_version C

#--------------------------------------------------------------------
# NEORV32 RTL (VHDL)
#--------------------------------------------------------------------
foreach file [lsort [glob ../../neorv32/rtl/core/*.vhd]] {
    add_file $file
    set_file_prop -lib neorv32 $file
}

#--------------------------------------------------------------------
# Project HDL sources (SystemVerilog)
#--------------------------------------------------------------------

# Top level
add_file src/top.sv

# I2S
add_file src/i2s/i2s_tx.sv
add_file src/i2s_clock_gen.sv

# Synthesizer core — voice pipeline
add_file src/voice/phase_accumulator.sv
add_file src/voice/osc_bank.sv
add_file src/voice/svf.sv

# Coefficient computer
add_file src/voice/k_lut.sv
add_file src/voice/nr_reciprocal.sv
add_file src/voice/coeff_computer.sv

# Future modules (uncomment when ready)
# add_file src/voice/envelope.sv
# add_file src/voice/vca.sv
# add_file src/voice/voice_top.sv

#--------------------------------------------------------------------
# Constraints
#--------------------------------------------------------------------
add_file -type cst src/constraints.cst
add_file -type sdc src/constraints.sdc

#--------------------------------------------------------------------
# Run
#--------------------------------------------------------------------
# Use SSPI pins as regular GPIO (Tang Nano 20K uses BL616 for config)
set_option -use_sspi_as_gpio 1
run all
