module ecg_filter #(
    parameter W = 12,
    parameter LOG2N = 3
) (
    input clk,
    input in_valid, // just means device new sample came
    input [W-1:0] in_sample,
    output reg out_valid,
    output [W-1:0] out_sample // new average got calc'd
);

    reg [W-1:0] buffer [7:0];
    reg [14:0] sum;

    integer i, j;

    initial begin
        sum = 0;
        out_valid = 0;
        for (i=0; i<8; i=i+1) begin
            buffer[i] = 0;
        end
    end

    always @(posedge clk) begin

        out_valid <= 0;

        if (in_valid) begin

            sum <= sum + in_sample - buffer[7];

            buffer[0] <= in_sample;

            for (j=1; j<8; j=j+1) begin
                buffer[j] <= buffer[j-1];
            end

            out_valid <= 1;

        end

    end

    assign out_sample = sum >> LOG2N;

endmodule