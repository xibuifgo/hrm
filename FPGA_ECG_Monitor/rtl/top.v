`default_nettype none

// ============================================================
// MODULE: top
//
// The top of the design. Everything else hangs off this.
//
// It does two jobs:
//
//   1. Wires the blocks together:
//
//        sample_tick  ->  500 Hz timing for the whole design
//        xadc_reader  ->  one 12-bit ECG sample per tick
//        heart_pipeline -> filter, baseline, beats, BPM, serial
//        buzzer       ->  short beep on every beat
//        led_flash    ->  LED flash on every beat
//
//   2. Names its ports EXACTLY as the Digilent Cmod A7 master
//      .xdc file names them, so that file only needs its lines
//      uncommenting - no renaming.
//
// ------------------------------------------------------------
// XDC LINES TO UNCOMMENT
// ------------------------------------------------------------
//
//   sysclk         L17   plus the create_clock line below it
//   led[0]         A17   beat flash
//   led[1]         C16   slow "design is alive" blink
//   btn[0]         A18   reset
//   xa_n[0]        G2    ECG analog input, negative half
//   xa_p[0]        G3    ECG analog input, positive half
//   uart_rxd_out   J18   serial out to the laptop
//   pio1           M3    rename this one to "buzzer"
//
// BOTH led lines must be uncommented, because led is declared
// two bits wide below. Vivado refuses to place a design that
// has a port with no pin assigned to it.
//
// Leave pio15 and pio16 commented out. Those ARE the analog
// pins, and they cannot be digital and analog at once.
//
// ------------------------------------------------------------
// WHAT GOES OUT OVER THE SERIAL LINE
// ------------------------------------------------------------
//
//     S2048   one raw ECG sample, 500 times a second
//     B075    the heart rate, whenever a new one is worked out
//
// at 115200 baud. scripts/ecg_serial_monitor.py reads both.
//
// The raw samples are what let you see the waveform, which is
// how you choose THRESHOLD instead of guessing at it.
// ============================================================

module top #(

    // 12 MHz / 115200 baud = 104 clock cycles per serial bit.
    //
    // 115200 rather than 9600 because the raw sample stream
    // needs about 30,000 bits/second and 9600 cannot carry it.
    // See the note at the top of telemetry_uart.v.
    parameter integer CLKS_PER_BIT = 104,

    // 12 MHz / 24000 = 500 samples per second.
    // The testbench overrides this to keep simulations short.
    parameter integer SAMPLE_DIVIDE = 24000,

    // How far above the baseline counts as an R peak.
    //
    // 70 was picked against a synthetic waveform in simulation.
    // It is almost certainly wrong for a real ECG through the
    // AD8232 - expect to change it once you can see real numbers.
    parameter signed [15:0] THRESHOLD = 16'sd70,

    // Which bit of the free-running counter drives the "alive"
    // LED. Bit 22 flips about three times a second on real
    // hardware. Testbenches use a much lower bit so the blink
    // shows up without simulating millions of clock cycles.
    parameter integer ALIVE_BIT = 22

)(
    // 12 MHz crystal oscillator on the board.
    input  wire       sysclk,

    // btn[0] is the reset button.
    // Declared as a 1-bit vector so it matches "btn[0]" in the .xdc.
    input  wire [0:0] btn,

    // led[0] flashes on each beat.
    // led[1] blinks slowly to show the design is running at all.
    output wire [1:0] led,

    // ECG analog input, from the AD8232 OUTPUT pin.
    //
    // The XADC measures across a PAIR of pins, so both halves
    // are declared even though only one carries the signal.
    // The board grounds the negative half for you.
    input  wire [0:0] xa_p,
    input  wire [0:0] xa_n,

    // Serial line out to the laptop.
    //
    // The name looks backwards but is correct: it is the RXD
    // input of the USB-serial chip, so from the FPGA's side it
    // is an output. This is the pin that carries your BPM text.
    output wire       uart_rxd_out,

    // Square wave to the passive buzzer.
    output wire       buzzer
);


// ------------------------------------------------------------
// RESET
// ------------------------------------------------------------
//
// Two separate things force a reset:
//
//   1. Power-on. When the FPGA is first configured we hold
//      reset high for a short while, so every block starts
//      from a known state instead of from whatever the very
//      first clock edges happened to do.
//
//   2. The button.
//
// The button is a mechanical switch. It changes whenever a
// finger moves, with no relationship to the 12 MHz clock. A
// signal like that can arrive right on a clock edge and leave
// a flip-flop briefly undecided, which is called metastability.
//
// The fix is standard: pass it through two flip-flops first.
// The first one may go metastable, but it has a whole clock
// cycle to settle before the second one looks at it.

// --- power-on reset: high for the first 128 clock cycles ---
reg [7:0] por_counter = 8'd0;

always @(posedge sysclk) begin
    if (!por_counter[7])
        por_counter <= por_counter + 1'b1;
end

wire por_active = ~por_counter[7];


// --- two-stage synchroniser for the button ---
reg [1:0] btn_sync = 2'b00;

always @(posedge sysclk) begin
    btn_sync <= {btn_sync[0], btn[0]};
end


// Cmod A7 buttons read HIGH when pressed.
//
// If reset seems to be stuck on, or the button does nothing,
// invert btn_sync[1] here and rebuild - that is the one line
// this depends on.
wire reset = por_active | btn_sync[1];


// ------------------------------------------------------------
// 500 Hz SAMPLE TIMING
// ------------------------------------------------------------

wire tick;

sample_tick #(
    .DIVIDE (SAMPLE_DIVIDE)
) u_tick (
    .clk   (sysclk),
    .reset (reset),
    .tick  (tick)
);


// ------------------------------------------------------------
// READ THE ECG VOLTAGE
// ------------------------------------------------------------
//
// The XADC converts continuously in the background. This block
// hands over the most recent measurement once per tick, so the
// rest of the design sees a tidy 500 Hz stream.

wire [11:0] sample;
wire        sample_valid;

xadc_reader u_adc (
    .clk          (sysclk),
    .reset        (reset),
    .sample_tick  (tick),
    .vauxp        (xa_p[0]),
    .vauxn        (xa_n[0]),
    .sample       (sample),
    .sample_valid (sample_valid)
);


// ------------------------------------------------------------
// THE SIGNAL CHAIN
// ------------------------------------------------------------
//
// filter -> baseline removal -> beat detection -> BPM -> serial

wire       beat;
wire [7:0] bpm;
wire       bpm_valid;

// INCLUDE_BPM_UART is 0 because telemetry_uart below drives the
// serial line instead - it can carry the raw samples too, which
// the pipeline's own BPM-only UART cannot.

heart_pipeline #(
    .CLKS_PER_BIT     (CLKS_PER_BIT),
    .THRESHOLD        (THRESHOLD),
    .INCLUDE_BPM_UART (0)
) u_pipeline (
    .clk          (sysclk),
    .reset        (reset),
    .sample       (sample),
    .sample_valid (sample_valid),
    .beat         (beat),
    .bpm          (bpm),
    .bpm_valid    (bpm_valid),
    .tx           ()               // unused - see above
);


// ------------------------------------------------------------
// SEND SAMPLES AND HEART RATE TO THE LAPTOP
// ------------------------------------------------------------

wire [15:0] dropped_samples;

telemetry_uart #(
    .CLKS_PER_BIT (CLKS_PER_BIT)
) u_telemetry (
    .clk             (sysclk),
    .reset           (reset),
    .sample          (sample),
    .sample_valid    (sample_valid),
    .bpm             (bpm),
    .bpm_valid       (bpm_valid),
    .tx              (uart_rxd_out),
    .dropped_samples (dropped_samples)
);


// ------------------------------------------------------------
// BEEP ON EACH BEAT
// ------------------------------------------------------------

buzzer #(
    .CLOCK_HZ   (12_000_000),
    .TONE_HZ    (2000),
    .BEEP_TICKS (50)          // 50 ticks x 2 ms = 100 ms beep
) u_buzzer (
    .clk         (sysclk),
    .reset       (reset),
    .sample_tick (tick),
    .beat        (beat),
    .buzzer_out  (buzzer)
);


// ------------------------------------------------------------
// FLASH AN LED ON EACH BEAT
// ------------------------------------------------------------

led_flash #(
    .FLASH_TICKS (50)         // same 100 ms as the beep
) u_led (
    .clk         (sysclk),
    .reset       (reset),
    .sample_tick (tick),
    .beat        (beat),
    .led         (led[0])
);


// ------------------------------------------------------------
// "IS IT EVEN RUNNING?" BLINK
// ------------------------------------------------------------
//
// A free-running counter driving the second LED at roughly
// 1.4 Hz. It depends on nothing except the clock.
//
// This is the single most useful debugging signal on the board.
// If this LED blinks, then the bitstream loaded, the clock is
// arriving, and the pin constraints are right. Whatever else is
// broken, it is not those. If it does NOT blink, stop and fix
// that before looking at anything else.
//
// Bit 22 of the counter flips every 2^22 clock cycles:
//
//     4,194,304 / 12,000,000 = 0.35 seconds
//
// so the LED changes state about three times a second.

reg [23:0] alive_counter = 24'd0;

always @(posedge sysclk) begin
    alive_counter <= alive_counter + 1'b1;
end

assign led[1] = alive_counter[ALIVE_BIT];


endmodule

`default_nettype wire
