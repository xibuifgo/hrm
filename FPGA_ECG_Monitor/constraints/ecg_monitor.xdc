## ===========================================================
## FPGA ECG MONITOR - pin constraints for the Digilent Cmod A7-35T
##
## Taken from Cmod-A7-Master.xdc, with only the lines this
## design uses left in. Port names match top.v exactly, so
## nothing here needs renaming.
##
## Add BOTH this file and Cmod-A7-Master.xdc to a Vivado
## project and you will get duplicate-constraint errors.
## Use this one.
## ===========================================================


## -----------------------------------------------------------
## 12 MHz CLOCK
## -----------------------------------------------------------
##
## The second line tells Vivado how fast the clock runs, so it
## can check every path in the design is fast enough to keep up.
## Leave it out and Vivado has no idea, and will not warn you
## when something is too slow.
##
## 83.33 ns is one period of 12 MHz.

set_property -dict { PACKAGE_PIN L17   IOSTANDARD LVCMOS33 } [get_ports { sysclk }];
create_clock -add -name sys_clk_pin -period 83.33 -waveform {0 41.66} [get_ports { sysclk }];


## -----------------------------------------------------------
## LEDs
## -----------------------------------------------------------
##
## led[0]  flashes on every detected heartbeat
## led[1]  slow blink showing the design is running at all
##
## Both are needed: led is declared two bits wide in top.v, and
## Vivado will not place a design that has a port with no pin.

set_property -dict { PACKAGE_PIN A17   IOSTANDARD LVCMOS33 } [get_ports { led[0] }];
set_property -dict { PACKAGE_PIN C16   IOSTANDARD LVCMOS33 } [get_ports { led[1] }];


## -----------------------------------------------------------
## RESET BUTTON
## -----------------------------------------------------------
##
## btn[0] is the button nearest the USB connector.
##
## top.v assumes the button reads HIGH when pressed. If reset
## seems stuck on, or the button does nothing, that assumption
## is the thing to check - see the note in top.v.

set_property -dict { PACKAGE_PIN A18   IOSTANDARD LVCMOS33 } [get_ports { btn[0] }];


## -----------------------------------------------------------
## ANALOG INPUT - the ECG signal from the AD8232
## -----------------------------------------------------------
##
## These are pins 15 and 16 on the board's DIP header.
##
## The XADC measures across a PAIR of pins, so both halves are
## declared even though only one carries your signal. The board
## grounds the negative half for you.
##
## Wire the AD8232 OUTPUT pin to xa_p[0], which is board pin 15.
##
##   xa_p[0] = G3 = ain_p[15] = VAUX4 positive
##   xa_n[0] = G2 = ain_n[15] = VAUX4 negative

set_property -dict { PACKAGE_PIN G3    IOSTANDARD LVCMOS33 } [get_ports { xa_p[0] }];
set_property -dict { PACKAGE_PIN G2    IOSTANDARD LVCMOS33 } [get_ports { xa_n[0] }];


## -----------------------------------------------------------
## SERIAL OUT TO THE LAPTOP
## -----------------------------------------------------------
##
## The name looks backwards but is right. It is the RXD input
## of the USB-serial chip on the board, so from the FPGA's side
## it is an output. This carries the S#### and B### messages.
##
## Open it at 115200 baud, 8 data bits, no parity, 1 stop bit.

set_property -dict { PACKAGE_PIN J18   IOSTANDARD LVCMOS33 } [get_ports { uart_rxd_out }];


## -----------------------------------------------------------
## BUZZER
## -----------------------------------------------------------
##
## This is the one line renamed from the master file. It was
## pio1 there; the design calls the signal "buzzer".
##
## M3 is pin 1 on the DIP header.
##
## Connect through a resistor. A piezo buzzer draws little
## enough to drive directly; a magnetic one needs a transistor
## and a flyback diode, so check what yours is first.

set_property -dict { PACKAGE_PIN M3    IOSTANDARD LVCMOS33 } [get_ports { buzzer }];


## -----------------------------------------------------------
## CONFIGURATION
## -----------------------------------------------------------
##
## Standard for the Cmod A7. These let the board load the
## design from its onboard flash at power-up, so it runs
## without a laptop attached - which is what you want once
## it is running from batteries.

set_property CONFIG_VOLTAGE 3.3 [current_design]
set_property CFGBVS VCCO [current_design]
set_property BITSTREAM.CONFIG.SPI_BUSWIDTH 4 [current_design]
set_property CONFIG_MODE SPIx4 [current_design]
set_property BITSTREAM.CONFIG.CONFIGRATE 33 [current_design]
