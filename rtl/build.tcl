set_option -verilog_std sysv2017
set_option -top_module top
set_device GW2AR-LV18QN88C8/I7 -device_version C

# Add NEORV32 files
foreach file [lsort [glob ../../neorv32/rtl/core/*.vhd]] {
    add_file $file
    set_file_prop -lib neorv32 $file
}

# Add project HDL files
add_file src/top.v

# Add physical constraints (pin mapping)
add_file -type cst src/constraints.cst

# Add timing constraints
add_file -type sdc src/constraints.sdc

# Run synthesis and Place & Route (P&R)
run all
