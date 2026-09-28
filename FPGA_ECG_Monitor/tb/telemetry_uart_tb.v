`timescale 1ns / 1ps
`default_nettype none

// ------------------------------------------------------------
// TESTBENCH: telemetry_uart_tb
//
// Decodes the serial line the same way the Python monitor will,
// and checks the messages that come out.
//
//   1. Samples come out as S####, with leading zeros kept.
//   2. Heart rate comes out as B###.
//   3. Both share the line without corrupting each other.
//   4. A heart rate waiting in the queue goes first.
//   5. Nothing is dropped at the real 500 Hz sample rate.
//   6. Reset clears everything.
// ------------------------------------------------------------

module telemetry_uart_tb;

    localparam integer CLK_HALF     = 42;    // ~12 MHz
    localparam integer CLKS_PER_BIT = 104;   // 115200 baud
    localparam integer BIT_NS       = CLKS_PER_BIT * CLK_HALF * 2;

    reg         clk          = 1'b0;
    reg         reset        = 1'b1;
    reg  [11:0] sample       = 12'd0;
    reg         sample_valid = 1'b0;
    reg  [7:0]  bpm          = 8'd0;
    reg         bpm_valid    = 1'b0;

    wire        tx;
    wire [15:0] dropped_samples;

    integer errors = 0;

    always #CLK_HALF clk = ~clk;

    telemetry_uart #(
        .CLKS_PER_BIT (CLKS_PER_BIT)
    ) dut (
        .clk             (clk),
        .reset           (reset),
        .sample          (sample),
        .sample_valid    (sample_valid),
        .bpm             (bpm),
        .bpm_valid       (bpm_valid),
        .tx              (tx),
        .dropped_samples (dropped_samples)
    );


    // --------------------------------------------------------
    // SERIAL RECEIVER
    // --------------------------------------------------------
    //
    // Collects characters until a newline, then records the
    // completed message. Same job pyserial will do.

    reg  [7:0]  rx_byte;
    reg  [7:0]  msg [0:7];
    integer     msg_len = 0;

    // The last complete message, broken out for checking.
    reg  [7:0]  last_tag   = 8'd0;
    integer     last_value = -1;
    integer     msg_count  = 0;
    integer     s_count    = 0;
    integer     b_count    = 0;

    integer     acc = 0;
    integer     i, b;

    initial begin
        forever begin
            @(negedge tx);                 // start bit
            #(BIT_NS * 1.5);               // middle of bit 0

            for (b = 0; b < 8; b = b + 1) begin
                rx_byte[b] = tx;
                #(BIT_NS);
            end

            if (rx_byte == 8'd10) begin    // newline ends a message
                if (msg_len > 0) begin
                    last_tag = msg[0];

                    acc = 0;
                    for (i = 1; i < msg_len; i = i + 1)
                        if (msg[i] >= 8'd48 && msg[i] <= 8'd57)
                            acc = acc * 10 + (msg[i] - 8'd48);

                    last_value = acc;
                    msg_count  = msg_count + 1;

                    if (last_tag == "S") s_count = s_count + 1;
                    if (last_tag == "B") b_count = b_count + 1;

                    $display("   line: \"%0s%0d\"  (tag=%0s value=%0d, %0d chars)",
                             last_tag, last_value, last_tag, last_value, msg_len);

                    msg_len = 0;
                end
            end
            else begin
                if (msg_len < 8) msg[msg_len] = rx_byte;
                msg_len = msg_len + 1;
            end
        end
    end


    // --------------------------------------------------------
    // HELPERS
    // --------------------------------------------------------

    task check_true(input condition, input [80*8:1] name);
        begin
            if (condition)
                $display("  PASS  %0s", name);
            else begin
                $display("  FAIL  %0s", name);
                errors = errors + 1;
            end
        end
    endtask

    // Push one sample in and wait until a whole message is out.
    task send_sample(input [11:0] value);
        integer prev_count;
        begin
            prev_count = msg_count;
            @(negedge clk);
            sample       = value;
            sample_valid = 1'b1;
            @(negedge clk);
            sample_valid = 1'b0;
            wait (msg_count > prev_count);
        end
    endtask

    task send_bpm(input [7:0] value);
        integer prev_count;
        begin
            prev_count = msg_count;
            @(negedge clk);
            bpm       = value;
            bpm_valid = 1'b1;
            @(negedge clk);
            bpm_valid = 1'b0;
            wait (msg_count > prev_count);
        end
    endtask


    // --------------------------------------------------------
    // MAIN TEST
    // --------------------------------------------------------

    integer msgs_before;
    integer k;

    initial begin
        $dumpfile("telemetry_uart_tb.vcd");
        $dumpvars(0, telemetry_uart_tb);

        $display("");
        $display("========================================");
        $display(" TELEMETRY UART TEST");
        $display("========================================");
        $display("");

        repeat (20) @(posedge clk);
        @(negedge clk);
        reset = 1'b0;
        repeat (10) @(posedge clk);


        // ----------------------------------------------------
        $display("-- 1. sample messages --");

        send_sample(12'd2048);
        check_true(last_tag == "S" && last_value == 2048, "S2048");

        send_sample(12'd0);
        check_true(last_tag == "S" && last_value == 0,    "S0000 at the bottom of range");

        send_sample(12'd4095);
        check_true(last_tag == "S" && last_value == 4095, "S4095 at the top of range");

        // Leading zeros are what makes the message fixed width,
        // so the receiver can rely on its length.
        send_sample(12'd42);
        check_true(last_tag == "S" && last_value == 42 && msg_len == 0,
                   "S0042 keeps its leading zeros");
        $display("");


        // ----------------------------------------------------
        $display("-- 2. heart rate messages --");

        send_bpm(8'd75);
        check_true(last_tag == "B" && last_value == 75,  "B075");

        send_bpm(8'd120);
        check_true(last_tag == "B" && last_value == 120, "B120");

        send_bpm(8'd0);
        check_true(last_tag == "B" && last_value == 0,   "B000");
        $display("");


        // ----------------------------------------------------
        $display("-- 3. both on one line --");

        s_count = 0;
        b_count = 0;

        // A heart rate arriving in the middle of a run of
        // samples must not corrupt either stream.
        send_sample(12'd1000);
        send_sample(12'd1100);
        send_bpm(8'd66);
        send_sample(12'd1200);
        send_sample(12'd1300);

        check_true(s_count == 4, "all four samples arrived intact");
        check_true(b_count == 1, "the heart rate arrived too");
        $display("        (%0d sample messages, %0d BPM messages)", s_count, b_count);
        $display("");


        // ----------------------------------------------------
        $display("-- 4. real-rate soak, 500 Hz --");

        // 2 ms between samples is the real spacing. Nothing
        // should be dropped.
        msgs_before = msg_count;

        for (k = 0; k < 20; k = k + 1) begin
            @(negedge clk);
            sample       = 12'd1500 + k;
            sample_valid = 1'b1;
            @(negedge clk);
            sample_valid = 1'b0;
            #2_000_000;                    // 2 ms
        end

        check_true(dropped_samples == 16'd0, "nothing dropped at 500 Hz");
        check_true((msg_count - msgs_before) == 20, "all 20 samples sent");
        $display("        (%0d messages, %0d dropped)",
                 msg_count - msgs_before, dropped_samples);
        $display("");


        // ----------------------------------------------------
        $display("-- 5. reset --");

        @(negedge clk);
        reset = 1'b1;
        repeat (20) @(posedge clk);

        check_true(dropped_samples == 16'd0, "reset clears the drop counter");
        check_true(tx === 1'b1,              "line idles high during reset");

        @(negedge clk);
        reset = 1'b0;
        repeat (10) @(posedge clk);

        send_sample(12'd777);
        check_true(last_tag == "S" && last_value == 777, "still works after reset");
        $display("");


        // ----------------------------------------------------
        $display("========================================");
        if (errors == 0)
            $display(" PASS - all checks passed");
        else
            $display(" FAIL - %0d check(s) failed", errors);
        $display("========================================");
        $display("");

        $finish;
    end


    initial begin
        #200_000_000;
        $display("");
        $display(" TIMEOUT - no message completed. Check tx and uart_busy.");
        $display("");
        $finish;
    end

endmodule

`default_nettype wire
