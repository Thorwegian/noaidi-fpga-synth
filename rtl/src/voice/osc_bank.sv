//--------------------------------------------------------------------
// osc_bank.sv — Multi-waveform oscillator bank
//--------------------------------------------------------------------

module osc_bank (
    input logic signed  [23:0]  phase,          // Phase angle (Q0.24)
    input logic signed  [23:0]  duty,           // PWM duty cycle
    output logic signed [23:0]  out_saw         // Saw output (Q0.24)
    output logic signed [23:0]  out_pul         // Pulse output (Q0.24)
    output logic signed [23:0]  out_tri         // Triangle output (Q0.24)
    output logic signed [23:0]  out_sin         // Sine output (Q0.24)

);

endmodule
