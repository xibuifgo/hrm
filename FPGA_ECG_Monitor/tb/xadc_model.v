`timescale 1ns / 1ps

// ============================================================
//  SIMULATION ONLY - DO NOT ADD THIS FILE TO VIVADO SYNTHESIS
// ============================================================
//
// This file defines a module called XADC.
//
// On the real FPGA, XADC is a piece of hardware physically built
// into the Artix-7 chip. Vivado knows about it automatically.
//
// Icarus Verilog does not, which is why xadc_reader.v could never
// be simulated before. This file is a stand-in: a simplified
// Verilog description that behaves enough like the real XADC for
// xadc_reader.v to be tested against it.
//
// It models:
//
//   * continuous conversion, with EOC pulsing when each one finishes
//   * the DRP read handshake (DEN in, DRDY + DO back a few clocks later)
//   * the 12-bit result sitting in the top bits of DO, i.e. DO[15:4]
//   * the channel number appearing on CHANNEL
//
// It also CHECKS that xadc_reader asks for the right DRP address,
// and complains loudly if it does not.
//
// It does NOT model: analog voltages, the alarms, the temperature
// sensor, JTAG, or the exact number of clocks the real part takes.
// None of those matter to xadc_reader.
//
// ------------------------------------------------------------
// HOW THE TESTBENCH FEEDS IN AN "ANALOG" VALUE
// ------------------------------------------------------------
//
// Real analog voltages cannot be simulated here, so instead this
// model holds a plain 12-bit register called analog_code, which
// the testbench writes to directly:
//
//     dut.xadc_inst.analog_code = 12'd2048;
//
// Each conversion latches whatever analog_code holds at that moment,
// exactly as a real ADC latches whatever voltage is on the pin.
// ============================================================

`default_nettype none

module XADC #(

    // The real primitive has INIT_40 through INIT_5F.
    // Only the ones xadc_reader actually sets are listed here,
    // plus a few spares so adding one later does not break this model.
    parameter [15:0] INIT_40 = 16'h0000,   // config reg 0: channel select
    parameter [15:0] INIT_41 = 16'h0000,   // config reg 1: sequencer mode
    parameter [15:0] INIT_42 = 16'h0800,   // config reg 2: clock divider
    parameter [15:0] INIT_43 = 16'h0000,
    parameter [15:0] INIT_44 = 16'h0000,
    parameter [15:0] INIT_45 = 16'h0000,
    parameter [15:0] INIT_46 = 16'h0000,
    parameter [15:0] INIT_47 = 16'h0000,
    parameter [15:0] INIT_48 = 16'h0000,
    parameter [15:0] INIT_49 = 16'h0000,
    parameter [15:0] INIT_4A = 16'h0000,
    parameter [15:0] INIT_4B = 16'h0000,
    parameter [15:0] INIT_4C = 16'h0000,
    parameter [15:0] INIT_4D = 16'h0000,
    parameter [15:0] INIT_4E = 16'h0000,
    parameter [15:0] INIT_4F = 16'h0000,

    parameter SIM_DEVICE = "7SERIES",
    parameter SIM_MONITOR_FILE = "design.txt",

    // ---- knobs that exist only in this model ----

    // How many DCLK cycles one conversion takes.
    //
    // The real part at ADCCLK = DCLK/2 takes roughly 26 ADCCLK,
    // which is about 52 DCLK. The exact number does not matter to
    // xadc_reader, which just waits for EOC.
    parameter integer MODEL_CONV_DCLKS = 52,

    // How many DCLK cycles after DEN before DRDY comes back.
    // Deliberately not 1, so the reader cannot accidentally rely
    // on the result arriving immediately.
    parameter integer MODEL_DRDY_DCLKS = 3

)(
    output reg  [7:0]  ALM,
    output reg         BUSY,
    output reg  [4:0]  CHANNEL,
    output reg  [15:0] DO,
    output reg         DRDY,
    output reg         EOC,
    output reg         EOS,
    output reg         JTAGBUSY,
    output reg         JTAGLOCKED,
    output reg         JTAGMODIFIED,
    output reg  [4:0]  MUXADDR,
    output reg         OT,

    input  wire        CONVST,
    input  wire        CONVSTCLK,
    input  wire        DCLK,
    input  wire        RESET,
    input  wire [6:0]  DADDR,
    input  wire        DEN,
    input  wire        DWE,
    input  wire [15:0] DI,
    input  wire [15:0] VAUXN,
    input  wire [15:0] VAUXP,
    input  wire        VN,
    input  wire        VP
);


// ------------------------------------------------------------
// WHICH CHANNEL ARE WE SUPPOSED TO BE CONVERTING?
// ------------------------------------------------------------
//
// The bottom 5 bits of config register 0 select the channel.
//
// xadc_reader sets INIT_40 = 16'h0014, so:
//
//     channel = 5'h14 = 20 decimal = VAUX4
//
// The DRP address for a channel's result register is just the
// channel number padded out to 7 bits.

localparam [4:0] SEL_CHANNEL    = INIT_40[4:0];
localparam [6:0] EXPECTED_DADDR = {2'b00, SEL_CHANNEL};


// ------------------------------------------------------------
// MODEL STATE
// ------------------------------------------------------------

// The "analog voltage" on the selected pin, as a 12-bit code.
// The testbench writes to this directly. See the header comment.
reg [11:0] analog_code;

// The XADC's internal result register for this channel.
// A conversion copies analog_code into here; a DRP read returns it.
reg [11:0] result_reg;

integer conv_count;

// Shift register used to delay DRDY after DEN.
reg [7:0]  drp_pipe;
reg [6:0]  daddr_latched;

// Counts how many times xadc_reader asked for the wrong address.
// The testbench checks this is still zero at the end.
integer daddr_errors;


// ------------------------------------------------------------
// STARTING STATE
// ------------------------------------------------------------

initial begin
    ALM          = 8'd0;
    BUSY         = 1'b0;
    CHANNEL      = SEL_CHANNEL;
    DO           = 16'd0;
    DRDY         = 1'b0;
    EOC          = 1'b0;
    EOS          = 1'b0;
    JTAGBUSY     = 1'b0;
    JTAGLOCKED   = 1'b0;
    JTAGMODIFIED = 1'b0;
    MUXADDR      = 5'd0;
    OT           = 1'b0;

    analog_code   = 12'd0;
    result_reg    = 12'd0;
    conv_count    = 0;
    drp_pipe      = 8'd0;
    daddr_latched = 7'd0;
    daddr_errors  = 0;
end


// ------------------------------------------------------------
// CONTINUOUS CONVERSION
// ------------------------------------------------------------
//
// Round and round forever: count MODEL_CONV_DCLKS clocks, latch
// the analog value, pulse EOC for exactly one clock, repeat.

always @(posedge DCLK) begin

    if (RESET) begin
        conv_count <= 0;
        EOC        <= 1'b0;
        BUSY       <= 1'b0;
        result_reg <= 12'd0;
        CHANNEL    <= SEL_CHANNEL;
    end
    else begin

        // EOC is a one-clock pulse, so default it low every cycle.
        EOC <= 1'b0;

        if (conv_count >= MODEL_CONV_DCLKS - 1) begin
            conv_count <= 0;

            // This is the moment the ADC "samples the pin".
            result_reg <= analog_code;

            EOC  <= 1'b1;
            BUSY <= 1'b0;
        end
        else begin
            conv_count <= conv_count + 1;
            BUSY       <= 1'b1;
        end

    end

end


// ------------------------------------------------------------
// DRP READ HANDSHAKE
// ------------------------------------------------------------
//
// xadc_reader ties DEN to EOC, so every finished conversion
// automatically kicks off a read of that channel's result register.
//
// Here we take note of the address, wait a few clocks, then put
// the result on DO and raise DRDY for one clock.

always @(posedge DCLK) begin

    if (RESET) begin
        DRDY          <= 1'b0;
        DO            <= 16'd0;
        drp_pipe      <= 8'd0;
        daddr_latched <= 7'd0;
    end
    else begin

        // Push a marker into the delay line whenever a READ starts.
        // (DWE high would mean a write, which this model ignores.)
        drp_pipe <= {drp_pipe[6:0], (DEN && !DWE)};

        if (DEN && !DWE) begin
            daddr_latched <= DADDR;

            if (DADDR !== EXPECTED_DADDR) begin
                daddr_errors = daddr_errors + 1;
                $display("  XADC MODEL: wrong DRP address 0x%02h (expected 0x%02h) at t=%0t",
                         DADDR, EXPECTED_DADDR, $time);
            end
        end

        // Default low, so DRDY is a one-clock pulse.
        DRDY <= 1'b0;

        if (drp_pipe[MODEL_DRDY_DCLKS-1]) begin
            DRDY <= 1'b1;

            // The 12-bit result sits in the TOP bits of the 16-bit
            // word, with the bottom 4 bits unused. That is why
            // xadc_reader takes DO[15:4].
            //
            // Reading any other address returns junk, so a wrong
            // address shows up as obviously wrong data rather than
            // quietly working anyway.
            if (daddr_latched == EXPECTED_DADDR)
                DO <= {result_reg, 4'b0000};
            else
                DO <= 16'hDEAD;
        end

    end

end


endmodule

`default_nettype wire
