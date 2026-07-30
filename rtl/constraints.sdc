#--------------------------------------------------------------------
# Timing Constraints — Tang Nano 20K Synthesizer
#--------------------------------------------------------------------

# Primary clock: 98.304 MHz from MS5351 on pin 10
create_clock -name clk_98m -period 10.172 [get_ports {clk}]

# False paths: asynchronous resets / slow inputs
set_false_path -from [get_ports {rst}]
set_false_path -from [get_ports {midi_rx}]
set_false_path -from [get_ports {uart_rx}]
