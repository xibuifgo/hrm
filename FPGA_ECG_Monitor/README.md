# FPGA ECG Monitor

A heart monitor built on an FPGA. An AD8232 picks the ECG off skin
electrodes; everything after that — filtering, baseline removal,
beat detection, heart-rate calculation, the display drivers and the
serial link — is Verilog running on a Digilent Cmod A7-35T.

The detector is scored against cardiologist annotations from the
PhysioNet MIT-BIH Arrhythmia Database, so its accuracy is a measured
figure rather than an impression.

> **Not a medical device.** Hobby and education only. Do not use it
> for diagnosis or treatment.

---

## The signal chain

```
  electrodes
      |
  AD8232            amplifier + filters   (bought module)
      |
  XADC              analogue to 12-bit numbers, 500 Hz
      |
  ecg_filter        8-point moving average
      |
  baseline_remove   subtract the slow DC level
      |
  beat_detect       threshold crossing + 250 ms refractory window
      |
  bpm_calc          samples between beats
      |
  bpm_div           30000 / period  ->  beats per minute
      |
  telemetry_uart    S#### and B### out at 115200 baud
```

`buzzer` and `led_flash` hang off the `beat` pulse.

---

## Hardware

| Part | Notes |
|---|---|
| Digilent Cmod A7-35T | 48-pin DIP, has the XADC built in |
| AD8232 breakout | run it at **3.3 V**, not 5 V |
| ECG electrode pads | disposable, 3-lead cable |
| Passive buzzer | through a resistor; magnetic types need a transistor |
| Breadboard + jumpers | the Cmod plugs straight in |

### Wiring

| AD8232 | Cmod A7 |
|---|---|
| 3.3V | 3V3 |
| GND | GND |
| OUTPUT | pin 15 (`xa_p[0]`, package pin G3) |

Buzzer to pin 1 (`buzzer`, package pin M3), through a resistor.

### Safety

Electrodes on your chest is a different risk category from a sensor
clipped on a finger.

- **Unplug the laptop charger while electrodes are attached.** USB to
  a mains-powered laptop puts you indirectly on mains equipment.
- Battery power (3×AA) is safer still.
- Use proper single-use ECG pads.

---

## Software

| Tool | For |
|---|---|
| Vivado (free Standard edition) | building the bitstream |
| Icarus Verilog + GTKWave | simulation |
| Python 3 + `pyserial`, `pyqtgraph`, `PyQt6` | the live monitor |
| `wfdb`, `numpy`, `scipy` | PhysioNet validation |

```
pip install pyserial pyqtgraph PyQt6 wfdb numpy scipy
```

---

## Simulating (no board needed)

```
python scripts/run_all_sims.py
```

Builds and runs all 14 testbenches, about 35 seconds. Run it after
changing anything in `rtl/`.

To look at one in detail:

```
iverilog -g2012 -o build/top_sim tb/top_tb.v tb/xadc_model.v rtl/*.v
vvp build/top_sim
gtkwave top_tb.vcd
```

`tb/xadc_model.v` is a stand-in for the Xilinx XADC primitive, which
Icarus does not know about. **It must never be added to a Vivado
synthesis fileset** — it defines a module called `XADC` and would
shadow the real hardware block.

---

## Building for the board

1. New Vivado RTL project, part **xc7a35tcpg236-1**.
2. Add every file in `rtl/`. Do **not** add anything from `tb/`.
3. Add `constraints/ecg_monitor.xdc`. Do not also add
   `Cmod-A7-Master.xdc` — the two together give duplicate-constraint
   errors. The master file is kept only for reference.
4. Set `top` as the top module.
5. Generate bitstream, then program the device.

---

## Bring-up, in order

Each step assumes the one before it worked. That way a failure tells
you where the problem is.

**1. Does it run at all?**
`led[1]` should blink about three times a second. It depends on
nothing but the clock, so if it blinks the bitstream loaded, the
clock arrives and the pin constraints are right. If it does not,
stop and fix that before anything else.

**2. Is the serial line working?**

```
python scripts/ecg_serial_monitor.py --list-ports
python scripts/ecg_serial_monitor.py --port COM3 --dump
```

Expect a sample rate near 500 Hz.

- *Nothing at all* — wrong port, or the design is not running.
- *Garbage* — baud mismatch. Both ends must be 115200.
- *Access denied* — PuTTY or another terminal has the port open.

**3. Can you see the waveform?**

```
python scripts/ecg_serial_monitor.py --port COM3
```

Attach the electrodes, sit still. You are looking for a recognisable
trace, not a good heart rate yet.

**4. Set the threshold.**
Read the R-peak height off the plot. `THRESHOLD` in `rtl/top.v` is
the height above baseline that counts as a beat — put it somewhere
between the T wave and the R peak, then rebuild.

**The default of 70 is a placeholder** chosen against a simulated
waveform. On real hardware it will be wrong. The validation sweep
below is the honest way to pick it.

**5. Buzzer and LED** should now follow your pulse.

---

## Validation against PhysioNet

This is what makes the accuracy figure meaningful, and it needs no
hardware.

```
python scripts/make_ecg_hex.py --record 100 --seconds 60

iverilog -g2012 -o build/val_sim tb/validation_tb.v \
         rtl/heart_pipeline.v rtl/ecg_filter.v rtl/baseline_remove.v \
         rtl/beat_detect.v rtl/bpm_calc.v rtl/bpm_div.v \
         rtl/bpm_uart.v rtl/uart.v

vvp build/val_sim +samples=data/100_samples.hex +count=30000

python scripts/score_detection.py --record 100
```

Reports sensitivity, PPV and F1 against the cardiologist markings.

To choose the threshold from measurements rather than by eye:

```
python scripts/score_detection.py --record 100 --sweep 50 400 25
```

That rebuilds and re-runs at each threshold and prints a table —
which is the table that belongs in the write-up.

No internet? `python scripts/make_ecg_hex.py --synthetic` makes a
file with the same layout so the flow can be tested offline. It is
not a substitute for real data in the report.

---

## Layout

```
rtl/          the design. Everything here goes into Vivado.
tb/           testbenches and the XADC simulation model. None of
              this goes into synthesis.
constraints/  ecg_monitor.xdc is the one to use.
scripts/      Python: live monitor, PhysioNet tooling, sim runner.
data/         generated ECG and detection files.
build/        generated simulation binaries.
```

`rtl/practice_*.v` are the exercises written while learning Verilog —
a counter, a shift register and a state machine. Kept because they
are where the patterns in the real modules came from.

---

## Known limitations

- The analogue front end is a bought module, so this project is
  about the digital design, not analogue circuit design.
- Single lead. Not pulse oximetry — one measurement, no SpO₂.
- No leads-off detection yet; the AD8232 provides `LO+`/`LO-` but
  nothing reads them.
- No PCB. Breadboard only.
- `xadc_reader` is verified against a behavioural model, not against
  silicon. Its register configuration is the least-tested part of
  the design.
