`default_nettype none

// ============================================================
// MODULE: telemetry_uart
//
// PURPOSE:
//
// Sends BOTH the raw ECG samples and the heart rate out over
// the one serial line, in a form the Python monitor can read.
//
// Two kinds of message, each tagged with a letter so the
// receiving end always knows which is which:
//
//     S2048\n     one ECG sample, 0 to 4095
//     B075\n      the current heart rate
//
// The digits are always the same width, padded with zeros.
// Fixed-width messages are much easier to parse at the other
// end than ones that change length.
//
// ------------------------------------------------------------
// WHY THE SAMPLES MATTER
// ------------------------------------------------------------
//
// Without them, all you can see is a number. With them you can
// plot the waveform, which is how you:
//
//   * confirm the AD8232 and the XADC are working at all
//   * see how big the R peak actually is
//   * choose a sensible THRESHOLD instead of guessing
//
// ------------------------------------------------------------
// BANDWIDTH - WHY 9600 BAUD IS NOT ENOUGH
// ------------------------------------------------------------
//
// One sample message is 6 characters. Each character costs 10
// bits on the wire (1 start bit, 8 data bits, 1 stop bit).
//
//     500 samples/second x 6 chars x 10 bits = 30,000 bits/sec
//
// 9600 baud carries 9,600 bits/sec. Nowhere near enough - the
// messages would pile up and most samples would be thrown away.
//
// 115,200 baud carries 115,200 bits/sec, so the sample stream
// uses about a quarter of the line and the heart rate messages
// fit in the gaps.
//
//     CLKS_PER_BIT = 12,000,000 / 115,200 = 104.17  ->  104
//
// 104 gives 115,385 baud, which is 0.16% off. UART tolerates
// roughly 2%, so that is fine.
//
// ------------------------------------------------------------
// WHAT HAPPENS IF A SAMPLE ARRIVES WHILE BUSY
// ------------------------------------------------------------
//
// The newest one wins and the older one is dropped. At 500 Hz
// with a message taking about half a millisecond, this should
// never happen - but if the baud rate were ever lowered it
// would, and dropping the stale sample is better than sending
// data that is already out of date.
//
// dropped_samples counts them, so the Python monitor can show
// a drop rate the way a real instrument does.
// ============================================================

module telemetry_uart #(

    // 12 MHz / 115200 baud.
    parameter integer CLKS_PER_BIT = 104

)(
    input  wire        clk,
    input  wire        reset,

    // Raw ECG sample straight from the ADC.
    input  wire [11:0] sample,
    input  wire        sample_valid,

    // Heart rate, whenever a new one is worked out.
    input  wire [7:0]  bpm,
    input  wire        bpm_valid,

    output wire        tx,

    // How many samples were thrown away because the line was
    // still busy. Should stay at zero at 115200 baud.
    output reg  [15:0] dropped_samples
);


// ------------------------------------------------------------
// THE UART ITSELF
// ------------------------------------------------------------

reg        uart_start;
reg  [7:0] uart_data;
wire       uart_busy;

uart_tx #(
    .CLKS_PER_BIT (CLKS_PER_BIT)
) u_tx (
    .clk   (clk),
    .start (uart_start),
    .data  (uart_data),
    .tx    (tx),
    .busy  (uart_busy)
);


// ------------------------------------------------------------
// WHAT IS WAITING TO BE SENT
// ------------------------------------------------------------

reg [11:0] sample_hold;
reg        sample_pending;

reg [7:0]  bpm_hold;
reg        bpm_pending;

// Which kind of message is being sent right now.
// 0 = sample, 1 = heart rate.
reg        sending_bpm;

// Which character of the message we are up to.
reg [2:0]  char_index;


// ------------------------------------------------------------
// SPLIT THE NUMBERS INTO DIGITS
// ------------------------------------------------------------
//
// A 12-bit sample needs four digits (0000 to 4095).
// The heart rate needs three (000 to 255).
//
// Adding 48 turns a digit into its ASCII character, because
// '0' is 48, '1' is 49, and so on.

wire [3:0] s_thousands =  sample_hold / 1000;
wire [3:0] s_hundreds  = (sample_hold % 1000) / 100;
wire [3:0] s_tens      = (sample_hold % 100)  / 10;
wire [3:0] s_units     =  sample_hold % 10;

wire [3:0] b_hundreds  =  bpm_hold / 100;
wire [3:0] b_tens      = (bpm_hold % 100) / 10;
wire [3:0] b_units     =  bpm_hold % 10;


// ------------------------------------------------------------
// PICK THE CHARACTER FOR THE CURRENT POSITION
// ------------------------------------------------------------
//
// Combinational: given which message and which position, this
// says which character to send. Leading zeros are kept, so
// every message is exactly the same length.

reg [7:0] current_char;

always @(*) begin
    if (sending_bpm) begin
        // "B075\n"
        case (char_index)
            3'd0:    current_char = "B";
            3'd1:    current_char = b_hundreds + 8'd48;
            3'd2:    current_char = b_tens     + 8'd48;
            3'd3:    current_char = b_units    + 8'd48;
            3'd4:    current_char = 8'd10;            // newline
            default: current_char = 8'd10;
        endcase
    end
    else begin
        // "S2048\n"
        case (char_index)
            3'd0:    current_char = "S";
            3'd1:    current_char = s_thousands + 8'd48;
            3'd2:    current_char = s_hundreds  + 8'd48;
            3'd3:    current_char = s_tens      + 8'd48;
            3'd4:    current_char = s_units     + 8'd48;
            3'd5:    current_char = 8'd10;            // newline
            default: current_char = 8'd10;
        endcase
    end
end


// Last character position of each message type.
wire [2:0] last_index = sending_bpm ? 3'd4 : 3'd5;


// ------------------------------------------------------------
// THE SENDING STATE MACHINE
// ------------------------------------------------------------
//
//   IDLE       nothing to send. Pick a message if one is waiting.
//   SEND       hand one character to the UART.
//   WAIT_START wait for the UART to say it has started.
//   WAIT_DONE  wait for it to finish, then move to the next
//              character or back to IDLE.
//
// WAIT_START matters: the UART takes a clock cycle to raise
// busy. Without it we would look at busy too early, see it
// still low, and think the character had already been sent.

localparam [1:0] IDLE       = 2'd0,
                 SEND       = 2'd1,
                 WAIT_START = 2'd2,
                 WAIT_DONE  = 2'd3;

reg [1:0] state;


always @(posedge clk) begin

    if (reset) begin
        state           <= IDLE;
        uart_start      <= 1'b0;
        uart_data       <= 8'd0;
        sample_hold     <= 12'd0;
        sample_pending  <= 1'b0;
        bpm_hold        <= 8'd0;
        bpm_pending     <= 1'b0;
        sending_bpm     <= 1'b0;
        char_index      <= 3'd0;
        dropped_samples <= 16'd0;
    end

    else begin

        // start is a one-clock pulse.
        uart_start <= 1'b0;


        // ----------------------------------------------------
        // TAKE IN NEW DATA
        // ----------------------------------------------------
        //
        // This happens regardless of what the state machine is
        // doing, so nothing is missed while a message is going
        // out.

        if (sample_valid) begin
            // If one is already waiting, it is now out of date.
            if (sample_pending)
                dropped_samples <= dropped_samples + 1'b1;

            sample_hold    <= sample;
            sample_pending <= 1'b1;
        end

        if (bpm_valid) begin
            bpm_hold    <= bpm;
            bpm_pending <= 1'b1;
        end


        // ----------------------------------------------------
        // SEND
        // ----------------------------------------------------

        case (state)

            IDLE: begin
                // Heart rate first. It is rare and it is the
                // number a person actually reads, so it should
                // not sit behind a sample.
                if (bpm_pending) begin
                    bpm_pending <= 1'b0;
                    sending_bpm <= 1'b1;
                    char_index  <= 3'd0;
                    state       <= SEND;
                end
                else if (sample_pending) begin
                    sample_pending <= 1'b0;
                    sending_bpm    <= 1'b0;
                    char_index     <= 3'd0;
                    state          <= SEND;
                end
            end

            SEND: begin
                uart_data  <= current_char;
                uart_start <= 1'b1;
                state      <= WAIT_START;
            end

            WAIT_START: begin
                if (uart_busy)
                    state <= WAIT_DONE;
            end

            WAIT_DONE: begin
                if (!uart_busy) begin
                    if (char_index == last_index)
                        state <= IDLE;
                    else begin
                        char_index <= char_index + 1'b1;
                        state      <= SEND;
                    end
                end
            end

            default: state <= IDLE;

        endcase

    end

end


endmodule

`default_nettype wire
