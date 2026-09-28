// Tell Verilog to report an error if we accidentally use a signal name that we never declared.
`default_nettype none

// Read the analog ECG voltage using the Artix-7's built-in XADC, and give the rest of our ECG project one 12-bit sample every time "sample_tick" occurs.
// XADC = Xilinx Analog-to-Digital Converter
// ADC  = Analog-to-Digital Converter

module xadc_reader (

    input wire clk,  // "clk" is the FPGA's main 12 MHz clock.
    input wire reset, // When reset = 1, we clear our stored values.

    // This is the one-clock pulse produced by sample_tick.v, 500 times per second.
    // We use it to decide WHEN the rest of the ECG system receives a new measurement.
    input wire sample_tick,


    // Positive side of our differential analog input.
    // VAUX = Auxiliary Analog Input
    // The AD8232 ECG signal ultimately enters the XADC here.
    input wire vauxp, // P    = Positive
    input wire vauxn, // N    = Negative
    
    output reg [11:0] sample, // The 12-bit ECG measurement that we give to the rest of our FPGA design.


    // This goes HIGH (1) for one clock cycle when "sample" is being presented as a new 500 Hz sample.
    // The other modules can use this as:"Hey! A new ECG sample is ready."
    output reg sample_valid
);


// ------------------------------------------------------------
// INTERNAL XADC SIGNALS
// ------------------------------------------------------------

// The XADC gives us a 16-bit digital output.
// DO = Data Output
// The actual 12-bit ADC measurement is stored in bits [15:4].
wire [15:0] xadc_do; 


// This becomes HIGH when a DRP (Dynamic Reconfiguration Port) operation has completed and xadc_do contains the result of our read.
wire xadc_drdy;// DRDY = Data Ready


// This pulses HIGH when the XADC finishes a conversion.
wire xadc_eoc; // EOC = End Of Conversion


// This tells us when the XADC is busy performing a conversion.
// We do not actually need to use it in our logic, but we connect it because it is an XADC output.
// BUSY = XADC is busy converting.
wire xadc_busy;


// The XADC tells us which analog channel was converted.
// CHANNEL is 5 bits wide.
wire [4:0] xadc_channel;

// Think of the DRP as a small communication interface that lets our Verilog read registers inside the XADC.
// DADDR = Dynamic Reconfiguration Port Address
wire [6:0] xadc_address; // The DRP requires a 7-bit address.

// The XADC converts much faster than our desired 500-samples-per-second ECG rate.
// Therefore: XADC ---> latest_sample ---> sample
// latest_sample is continually refreshed.
// "sample" is updated only when sample_tick occurs.
reg [11:0] latest_sample; // Store the most recent 12-bit ADC measurement here.


// ------------------------------------------------------------
// CREATE THE XADC REGISTER ADDRESS
// ------------------------------------------------------------


// xadc_channel is 5 bits:
//
//     XXXXX
//
// xadc_address must be 7 bits:
//
//     00XXXXX
//
// Therefore we place two zeros in front.
//
// { } means concatenate — join bits together.
//
// Example:
//
// xadc_channel = 10100
//
// becomes:
//
// xadc_address = 0010100
//
// For VAUX4, that corresponds to address 0x14.
assign xadc_address = {2'b00, xadc_channel};


// ------------------------------------------------------------
// CREATE / INSTANTIATE THE PHYSICAL XADC HARDWARE
// ------------------------------------------------------------


// "XADC" is NOT another module that we wrote.
// It is a special hardware block already physically built inside the Xilinx Artix-7 FPGA.
// This code tells the FPGA tools how we want that built-in hardware configured.
// The #(...) section contains configuration parameters.
XADC #(

    // INIT = Initialization
    //
    // INIT_40 configures XADC Configuration Register 0.
    //
    // 16'h0014 means:
    //
    // 16  = the value is 16 bits wide
    // 'h  = the number is written in hexadecimal
    // 0014 = hexadecimal value
    //
    // 0x14 = decimal 20 = binary 10100.
    //
    // Channel 20 is VAUX4.
    //
    // We also leave the XADC in continuous conversion mode and unipolar input mode.
    .INIT_40(16'h0014),


    // INIT_41 configures XADC Configuration Register 1.
    // 0x3000 selects SINGLE-CHANNEL mode.
    // That means the XADC repeatedly measures the one channel selected above: VAUX4.
    .INIT_41(16'h3000),


    // INIT_42 configures XADC Configuration Register 2.
    // This controls, among other things, the XADC clock divider.
    // Our DCLK is 12 MHz.
    // Divider = 2
    // 12 MHz / 2 = 6 MHz
    // So the XADC's ADC clock runs at 6 MHz.
    // DCLK   = Dynamic Reconfiguration Port Clock
    // ADCCLK = Analog-to-Digital Converter Clock
    .INIT_42(16'h0200),
    
    // Our Cmod A7 contains an Artix-7.
    .SIM_DEVICE("7SERIES") // Tell the Xilinx simulation model that our FPGA belongs to the Xilinx 7-Series family.


// Give this particular XADC instance the name "xadc_inst".
) xadc_inst (


// ------------------------------------------------------------
// XADC CLOCK AND RESET
// ------------------------------------------------------------


    // DCLK = Dynamic Reconfiguration Port Clock
    //
    // Give the XADC our normal 12 MHz FPGA clock.
    .DCLK(clk),


    // Reset the XADC when our project's reset signal is HIGH.
    .RESET(reset),


// ------------------------------------------------------------
// CONVERSION TRIGGER INPUTS
// ------------------------------------------------------------


    // CONVST = Convert Start
    //
    // This input can manually tell the ADC exactly when to begin a conversion.
    // We are using CONTINUOUS conversion instead, so we permanently connect it to 0.

    .CONVST(1'b0),
    // CONVSTCLK = Convert Start Clock
    // This is another way of controlling conversion timing.
    // We are not using event-driven conversion,so this is also permanently connected to 0.
    .CONVSTCLK(1'b0),


// ------------------------------------------------------------
// VAUXP = AUXILIARY ANALOG INPUTS
// ------------------------------------------------------------

    // The XADC has 16 possible auxiliary positive inputs:
    // VAUXP[15:0]
    // We only want VAUX4.
    // This expression creates all 16 connections:
    // { 11 zeros, vauxp, 4 zeros }
    //
    //             |
    //             +---- lands at bit 4
    // Therefore our external "vauxp" signal connects
    // specifically to VAUXP[4].
    .VAUXP({11'b0, vauxp, 4'b0}),


    // VAUXN = Auxiliary Analog Input Negative
    // Same idea as above, except this is the negative half of the differential analog input.
    // Our vauxn signal connects to VAUXN[4].
    .VAUXN({11'b0, vauxn, 4'b0}),


// ------------------------------------------------------------
// DEDICATED ANALOG INPUT
// ------------------------------------------------------------

    // The XADC also has a separate dedicated analog pair called VP (Dedicated Analog Input Positive) and VN.
    // We are using VAUX4 instead, so VP is unused - connect it to zero.
    .VP(1'b0),
    .VN(1'b0),

// ------------------------------------------------------------
// DRP — DYNAMIC RECONFIGURATION PORT
// ------------------------------------------------------------

    // DADDR = DRP Address
    //
    // This tells the XADC which internal register we want to read.
    // xadc_address comes from the current channel number.
    .DADDR(xadc_address),


    // DEN = DRP Enable
    // DEN tells the XADC: "Start a DRP operation."
    // EOC pulses when a conversion has finished.
    // Therefore, each completed conversion automatically starts a read of that channel's result register.
    // DEN = Dynamic Reconfiguration Port Enable
    // EOC = End Of Conversion
    .DEN(xadc_eoc),

    // DI (Data Input) would contain data if we wanted to WRITE something through the DRP.
    // We only want to READ measurements. Therefore all 16 DI bits are zero.
    .DI(16'b0),


    // DWE = DRP Write Enable
    // DWE = 1 would mean WRITE.
    // DWE = 0 means READ.
    // We only read the ADC result, so this stays zero.
    // DWE = Dynamic Reconfiguration Port Write Enable
    .DWE(1'b0),


// ------------------------------------------------------------
// XADC DIGITAL OUTPUTS
// ------------------------------------------------------------


    // DO = Data Output
    // The 16-bit result of our DRP read appears here.
    .DO(xadc_do),


    // DRDY = Data Ready
    // Goes HIGH when the DRP operation has completed and DO contains valid data.
    .DRDY(xadc_drdy),


    // EOC goes HIGH for one DCLK cycle when a conversion's result has been transferred into its output register.
    .EOC(xadc_eoc),

    // EOS (End Of Sequence) is useful when the XADC automatically cycles through a sequence of several channels.
    // We are using one channel only.
    // Empty () means:"This output exists, but we do not need its value."
    .EOS(),


    // BUSY is HIGH while the ADC is carrying out a conversion.
    // We connect it to xadc_busy, although our current logic does not need to make decisions using it.
    .BUSY(xadc_busy),


    // CHANNEL gives the 5-bit number of the channel being converted.
    // For our selected VAUX4 channel, the relevant channel number is 20 decimal = 10100 binary.
    .CHANNEL(xadc_channel),


// ------------------------------------------------------------
// XADC FEATURES WE ARE NOT USING
// ------------------------------------------------------------


    // ALM = Alarm outputs
    // The XADC can generate hardware alarms for monitored values such as internal temperature and supply voltages.
    // Our ECG reader does not use these XADC alarm outputs.
    .ALM(),


    // OT (Over-Temperature) is a special XADC output related to FPGA temperature.
    .OT(),


    // MUXADDR = Multiplexer Address
    // MUX (Multiplexer) is used when controlling an external analog multiplexer.
    .MUXADDR(),


    // JTAGBUSY
    // JTAG (Joint Test Action Group) is a standard interface used for FPGA programming, debugging, and device access.
    // This signal indicates JTAG activity involving the XADC.
    // Our ECG logic does not need it.
    .JTAGBUSY(),


    // JTAGLOCKED indicates that the XADC's JTAG interface has locked access to the DRP.
    .JTAGLOCKED(),


    // JTAGMODIFIED indicates that JTAG has modified XADC configuration.
    .JTAGMODIFIED()

);

// ------------------------------------------------------------
// STORE AND RELEASE ECG SAMPLES
// ------------------------------------------------------------


// Everything inside this block happens in response to the rising edge of our main FPGA clock.

always @(posedge clk) begin


    // If reset is HIGH...
    if (reset) begin


        // Clear our stored ADC measurement.
        // <= is a NON-BLOCKING assignment.
        //
        // Non-blocking assignments are normally used for clocked/sequential FPGA logic.
        latest_sample <= 12'b0;

        // Clear the sample visible to the rest of the project.
        sample <= 12'b0;
        // Say that no valid sample is being produced.
        sample_valid <= 1'b0;

    end

    // Otherwise, run normally.
    else begin


        // By default, sample_valid is LOW.
        // Later in this same clocked block we set it HIGH only when sample_tick occurs.
        // This makes sample_valid a one-clock pulse.
        sample_valid <= 1'b0;

        // Has our DRP read finished?
        // If xadc_drdy = 1, the XADC says: "The data you requested is ready."
        if (xadc_drdy) begin


            // Save the newest ADC measurement.
            // xadc_do contains 16 bits:
            // [15 ....................... 0]
            // The 12-bit ADC result is left-justified in bits [15:4].
            // So we keep: xadc_do[15:4] and store those 12 bits in latest_sample.
            latest_sample <= xadc_do[15:4];
        end


        // Did our 500 Hz sampling pulse occur?
        if (sample_tick) begin

            // Give the rest of the ECG project the newest ADC measurement that we have stored.
            sample <= latest_sample;


            // Raise this flag for one clock cycle to say:"sample now contains a new 500 Hz ECG sample."
            sample_valid <= 1'b1;

        end

    end

end


// End of our xadc_reader module.
endmodule


// Return Verilog to its normal/default automatic-wire behavior.
//
// This prevents `default_nettype none from accidentally affecting
// another Verilog file that might be compiled after this one.
`default_nettype wire