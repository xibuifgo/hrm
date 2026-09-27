module heart_pipeline #(
    parameter CLKS_PER_BIT = 1250,
    parameter signed [15:0] THRESHOLD = 16'sd70
)(
    input  wire        clk,
    input  wire        reset,
    input  wire [11:0] sample,
    input  wire        sample_valid,
    output wire        beat,
    output wire [7:0]  bpm,
    output wire        tx
);
    // wires between the blocks
    wire [11:0]        filt_sample;  wire filt_valid;
    wire signed [15:0] cent_sample;  wire cent_valid;
    wire [9:0]         period;       wire period_valid;
    wire               bpm_valid;

    ecg_filter u_filter (
        .clk(clk), .in_valid(sample_valid), .in_sample(sample),
        .out_valid(filt_valid), .out_sample(filt_sample));

    // your turn: u_base, u_beat, u_calc, u_div, u_uart
    baseline_remove u_base (
        clk,
        sample_valid, 
        sample,
        cent_valid,
        cent_sample
    );

    beat_detect #(THRESHOLD) u_beat (
        clk,
        reset,
        cent_sample,
        cent_valid,
        beat
    );

    bpm_calc u_calc (
        clk,
        cent_valid,
        beat,
        period,
        period_valid
    );

    bpm_div u_div (
        clk,
        period_valid,
        period,
        bpm,
        bpm_valid
    );

    bpm_uart #(CLKS_PER_BIT) u_uart (
        clk,
        bpm,
        bpm_valid,
        tx
    );

endmodule