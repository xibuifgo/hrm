"""
FPGA ECG Monitor - Python Front End

FIRST TEST MODE:
    Downloads a real ECG recording from PhysioNet.
    Displays the ECG as a scrolling waveform.
    Uses PhysioNet beat annotations to calculate/display BPM.

LATER:
    PhysioNet input will be replaced by UART data
    coming from the Cmod A7 FPGA.

This is a learning project and is not a clinical medical device.
"""

import sys
import argparse
from fractions import Fraction

import numpy as np
import wfdb

from scipy.signal import resample_poly

from PyQt6 import QtCore, QtWidgets
import pyqtgraph as pg


# ------------------------------------------------------------
# PROJECT SETTINGS
# ------------------------------------------------------------

# Our FPGA ECG project works at 500 samples per second.
TARGET_FS = 500

# How many seconds of ECG should be visible on screen.
DISPLAY_SECONDS = 6

# Screen refresh interval.
#
# 20 ms means:
#
#     1000 ms / 20 ms
#     = 50 screen updates per second
#
# This is only the GUI refresh speed.
# ECG samples themselves are still 500 Hz.
UPDATE_MS = 20


# ------------------------------------------------------------
# PHYSIONET BEAT SYMBOLS
# ------------------------------------------------------------
#
# PhysioNet annotation files contain several kinds of markers.
#
# We only want annotations corresponding to heartbeats.
#
# These include normal beats and several abnormal beat types.

BEAT_SYMBOLS = {
    "N",    # normal beat
    "L",    # left bundle branch block beat
    "R",    # right bundle branch block beat
    "A",    # atrial premature beat
    "a",    # aberrated atrial premature beat
    "J",    # nodal premature beat
    "S",    # supraventricular premature beat
    "V",    # premature ventricular contraction
    "F",    # fusion beat
    "e",    # atrial escape beat
    "j",    # nodal escape beat
    "E",    # ventricular escape beat
    "/",    # paced beat
    "f",    # fusion of paced and normal beat
    "Q",    # unclassifiable beat
}


# ------------------------------------------------------------
# LOAD PHYSIONET ECG
# ------------------------------------------------------------

def load_physionet_record(
    database,
    record_name,
    lead_number,
    duration_seconds,
):
    """
    Download/load one PhysioNet ECG recording.

    Returns:

        ecg_500
            ECG samples resampled to 500 Hz.

        beat_samples_500
            Locations of annotated heartbeats,
            also converted to the 500 Hz timeline.

        lead_name
            Name of the ECG lead being displayed.

        original_fs
            Original PhysioNet sample rate.
    """

    print()
    print("----------------------------------------")
    print("LOADING PHYSIONET ECG")
    print("----------------------------------------")
    print()

    print(f"Database : {database}")
    print(f"Record   : {record_name}")

    print()
    print("Downloading/loading ECG...")
    print()


    # --------------------------------------------------------
    # DOWNLOAD THE ECG SIGNAL
    # --------------------------------------------------------
    #
    # Example:
    #
    #     database = mitdb
    #     record   = 100
    #
    # This corresponds to a record from the
    # MIT-BIH Arrhythmia Database.

    record = wfdb.rdrecord(
        record_name,
        pn_dir=database
    )


    # --------------------------------------------------------
    # DOWNLOAD THE BEAT ANNOTATIONS
    # --------------------------------------------------------

    annotation = wfdb.rdann(
        record_name,
        "atr",
        pn_dir=database
    )


    # --------------------------------------------------------
    # ORIGINAL SAMPLE RATE
    # --------------------------------------------------------

    original_fs = float(record.fs)

    print(f"Original sample rate : {original_fs:.1f} Hz")


    # --------------------------------------------------------
    # CHOOSE ECG LEAD
    # --------------------------------------------------------

    if lead_number >= record.p_signal.shape[1]:

        raise ValueError(
            f"Lead {lead_number} does not exist. "
            f"This record has {record.p_signal.shape[1]} lead(s)."
        )


    ecg = record.p_signal[:, lead_number]

    lead_name = record.sig_name[lead_number]

    print(f"ECG lead             : {lead_name}")


    # --------------------------------------------------------
    # KEEP ONLY REAL BEAT ANNOTATIONS
    # --------------------------------------------------------

    beat_samples = np.array(
        [
            sample
            for sample, symbol
            in zip(annotation.sample, annotation.symbol)
            if symbol in BEAT_SYMBOLS
        ],
        dtype=np.int64
    )


    # --------------------------------------------------------
    # RESAMPLE ECG TO 500 Hz
    # --------------------------------------------------------
    #
    # Many PhysioNet databases do NOT use 500 Hz.
    #
    # For example, MIT-BIH uses 360 Hz.
    #
    # Our FPGA project uses:
    #
    #     500 Hz
    #
    # So we convert the waveform.
    #
    # Example:
    #
    #     360 Hz -> 500 Hz
    #
    # ratio:
    #
    #     500 / 360
    #     = 25 / 18

    ratio = Fraction(
        TARGET_FS / original_fs
    ).limit_denominator(1000)

    up = ratio.numerator
    down = ratio.denominator

    ecg_500 = resample_poly(
        ecg,
        up,
        down
    )


    # --------------------------------------------------------
    # MOVE BEAT LOCATIONS TO THE NEW 500 Hz TIMELINE
    # --------------------------------------------------------

    beat_samples_500 = np.rint(
        beat_samples
        * TARGET_FS
        / original_fs
    ).astype(np.int64)


    # --------------------------------------------------------
    # OPTIONAL SHORT TEST DURATION
    # --------------------------------------------------------

    if duration_seconds > 0:

        maximum_samples = int(
            duration_seconds * TARGET_FS
        )

        ecg_500 = ecg_500[:maximum_samples]

        beat_samples_500 = beat_samples_500[
            beat_samples_500 < maximum_samples
        ]


    print(f"Project sample rate  : {TARGET_FS} Hz")
    print(f"Loaded ECG samples   : {len(ecg_500)}")
    print(f"Annotated beats      : {len(beat_samples_500)}")

    print()
    print("PhysioNet ECG ready.")
    print()


    return (
        ecg_500,
        beat_samples_500,
        lead_name,
        original_fs,
    )


# ------------------------------------------------------------
# ECG MONITOR WINDOW
# ------------------------------------------------------------

class ECGMonitor(QtWidgets.QMainWindow):

    def __init__(
        self,
        ecg,
        beat_samples,
        lead_name
    ):

        super().__init__()


        # ----------------------------------------------------
        # STORE ECG DATA
        # ----------------------------------------------------

        self.ecg = ecg

        self.beat_samples = beat_samples

        self.lead_name = lead_name


        # Current location in the ECG recording.
        self.position = 0


        # Previous screen-update position.
        self.previous_position = 0


        # Number of ECG samples displayed at once.
        self.window_samples = (
            DISPLAY_SECONDS * TARGET_FS
        )


        # At 500 Hz and a 20 ms GUI update:
        #
        #     500 × 0.020
        #     = 10 samples per screen update

        self.samples_per_update = max(
            1,
            int(
                TARGET_FS
                * UPDATE_MS
                / 1000
            )
        )


        # Used for calculating BPM.
        self.last_beat_sample = None


        # Index into our PhysioNet heartbeat list.
        self.next_beat_index = 0


        # ----------------------------------------------------
        # WINDOW SETTINGS
        # ----------------------------------------------------

        self.setWindowTitle(
            "FPGA ECG Monitor - PhysioNet Test"
        )

        self.resize(
            1300,
            700
        )


        # ----------------------------------------------------
        # MAIN WIDGET
        # ----------------------------------------------------

        central_widget = QtWidgets.QWidget()

        self.setCentralWidget(
            central_widget
        )


        main_layout = QtWidgets.QHBoxLayout(
            central_widget
        )


        # ----------------------------------------------------
        # ECG GRAPH
        # ----------------------------------------------------

        self.plot = pg.PlotWidget()

        self.plot.setBackground(
            "#050805"
        )


        # Green ECG grid.
        self.plot.showGrid(
            x=True,
            y=True,
            alpha=0.22
        )


        self.plot.setLabel(
            "left",
            "ECG",
            units="mV",
            color="#80ff9a"
        )

        self.plot.setLabel(
            "bottom",
            "Time",
            units="s",
            color="#80ff9a"
        )


        self.plot.setXRange(
            -DISPLAY_SECONDS,
            0,
            padding=0
        )


        # ECG line.
        self.curve = self.plot.plot(
            pen=pg.mkPen(
                color="#00ff55",
                width=2
            )
        )


        # Work out a sensible fixed vertical range.
        finite_ecg = self.ecg[
            np.isfinite(self.ecg)
        ]

        low, high = np.percentile(
            finite_ecg,
            [1, 99]
        )

        amplitude = high - low

        if amplitude <= 0:
            amplitude = 1

        margin = amplitude * 0.25

        self.plot.setYRange(
            low - margin,
            high + margin,
            padding=0
        )


        main_layout.addWidget(
            self.plot,
            stretch=5
        )


        # ----------------------------------------------------
        # RIGHT-HAND MONITOR PANEL
        # ----------------------------------------------------

        side_panel = QtWidgets.QWidget()

        side_layout = QtWidgets.QVBoxLayout(
            side_panel
        )


        # ----------------------------------------------------
        # TITLE
        # ----------------------------------------------------

        title = QtWidgets.QLabel(
            "ECG MONITOR"
        )

        title.setAlignment(
            QtCore.Qt.AlignmentFlag.AlignCenter
        )

        title.setStyleSheet(
            """
            color: #00ff55;
            font-size: 30px;
            font-weight: bold;
            """
        )

        side_layout.addWidget(title)


        # ----------------------------------------------------
        # LEAD NAME
        # ----------------------------------------------------

        self.lead_label = QtWidgets.QLabel(
            f"Lead: {lead_name}"
        )

        self.lead_label.setAlignment(
            QtCore.Qt.AlignmentFlag.AlignCenter
        )

        self.lead_label.setStyleSheet(
            """
            color: #aaaaaa;
            font-size: 18px;
            """
        )

        side_layout.addWidget(
            self.lead_label
        )


        side_layout.addStretch()


        # ----------------------------------------------------
        # HEART RATE LABEL
        # ----------------------------------------------------

        hr_title = QtWidgets.QLabel(
            "HEART RATE"
        )

        hr_title.setAlignment(
            QtCore.Qt.AlignmentFlag.AlignCenter
        )

        hr_title.setStyleSheet(
            """
            color: #aaaaaa;
            font-size: 20px;
            """
        )

        side_layout.addWidget(
            hr_title
        )


        self.hr_label = QtWidgets.QLabel(
            "---"
        )

        self.hr_label.setAlignment(
            QtCore.Qt.AlignmentFlag.AlignCenter
        )

        self.hr_label.setStyleSheet(
            """
            color: #00ff55;
            font-size: 90px;
            font-weight: bold;
            """
        )

        side_layout.addWidget(
            self.hr_label
        )


        bpm_text = QtWidgets.QLabel(
            "BPM"
        )

        bpm_text.setAlignment(
            QtCore.Qt.AlignmentFlag.AlignCenter
        )

        bpm_text.setStyleSheet(
            """
            color: #00ff55;
            font-size: 24px;
            """
        )

        side_layout.addWidget(
            bpm_text
        )


        side_layout.addStretch()


        # ----------------------------------------------------
        # BEAT INDICATOR
        # ----------------------------------------------------

        self.beat_indicator = QtWidgets.QLabel(
            "♥"
        )

        self.beat_indicator.setAlignment(
            QtCore.Qt.AlignmentFlag.AlignCenter
        )

        self.beat_indicator.setStyleSheet(
            """
            color: #174d25;
            font-size: 70px;
            """
        )

        side_layout.addWidget(
            self.beat_indicator
        )


        # ----------------------------------------------------
        # MODE LABEL
        # ----------------------------------------------------

        mode_label = QtWidgets.QLabel(
            "PHYSIONET PLAYBACK"
        )

        mode_label.setAlignment(
            QtCore.Qt.AlignmentFlag.AlignCenter
        )

        mode_label.setStyleSheet(
            """
            color: #808080;
            font-size: 14px;
            """
        )

        side_layout.addWidget(
            mode_label
        )


        main_layout.addWidget(
            side_panel,
            stretch=1
        )


        # ----------------------------------------------------
        # DARK WINDOW BACKGROUND
        # ----------------------------------------------------

        central_widget.setStyleSheet(
            """
            background-color: #020402;
            """
        )


        # ----------------------------------------------------
        # CREATE TIMER
        # ----------------------------------------------------

        self.timer = QtCore.QTimer(self)

        self.timer.timeout.connect(
            self.update_monitor
        )

        self.timer.start(
            UPDATE_MS
        )


    # --------------------------------------------------------
    # UPDATE ECG DISPLAY
    # --------------------------------------------------------

    def update_monitor(self):

        self.previous_position = self.position


        # Move forward through the ECG.
        self.position += self.samples_per_update


        # Have we reached the end?
        if self.position >= len(self.ecg):

            self.position = len(self.ecg)

            self.timer.stop()


        # ----------------------------------------------------
        # CREATE 6-SECOND DISPLAY WINDOW
        # ----------------------------------------------------

        start = max(
            0,
            self.position - self.window_samples
        )

        segment = self.ecg[
            start:self.position
        ]


        # Pad the beginning with NaN values
        # until we have a full six-second window.
        display_data = np.full(
            self.window_samples,
            np.nan
        )

        display_data[
            -len(segment):
        ] = segment


        # Time axis:
        #
        #     -6 seconds ... 0 seconds

        x = np.linspace(
            -DISPLAY_SECONDS,
            0,
            self.window_samples,
            endpoint=False
        )


        self.curve.setData(
            x,
            display_data
        )


        # ----------------------------------------------------
        # CHECK FOR HEARTBEATS
        # ----------------------------------------------------

        while (
            self.next_beat_index
            < len(self.beat_samples)
        ):

            beat_sample = self.beat_samples[
                self.next_beat_index
            ]


            # Beat hasn't happened yet.
            if beat_sample > self.position:
                break


            # Ignore beats that occurred before the
            # previous screen update.
            if beat_sample > self.previous_position:

                self.handle_beat(
                    beat_sample
                )


            self.next_beat_index += 1


    # --------------------------------------------------------
    # HEARTBEAT EVENT
    # --------------------------------------------------------

    def handle_beat(
        self,
        beat_sample
    ):

        # ----------------------------------------------------
        # CALCULATE BPM
        # ----------------------------------------------------

        if self.last_beat_sample is not None:

            samples_between_beats = (
                beat_sample
                - self.last_beat_sample
            )


            if samples_between_beats > 0:

                bpm = (
                    60
                    * TARGET_FS
                    / samples_between_beats
                )


                self.hr_label.setText(
                    f"{bpm:.0f}"
                )


        self.last_beat_sample = beat_sample


        # ----------------------------------------------------
        # FLASH HEART SYMBOL
        # ----------------------------------------------------

        self.beat_indicator.setStyleSheet(
            """
            color: #00ff55;
            font-size: 70px;
            """
        )


        # Turn the heart dark again after 120 ms.
        QtCore.QTimer.singleShot(
            120,
            self.clear_beat_flash
        )


    # --------------------------------------------------------
    # END HEART FLASH
    # --------------------------------------------------------

    def clear_beat_flash(self):

        self.beat_indicator.setStyleSheet(
            """
            color: #174d25;
            font-size: 70px;
            """
        )


# ------------------------------------------------------------
# MAIN PROGRAM
# ------------------------------------------------------------

def main():

    parser = argparse.ArgumentParser(
        description=(
            "Hospital-style ECG monitor "
            "using PhysioNet test data."
        )
    )


    parser.add_argument(
        "--database",
        default="mitdb",
        help="PhysioNet database name"
    )


    parser.add_argument(
        "--record",
        default="100",
        help="PhysioNet record name"
    )


    parser.add_argument(
        "--lead",
        type=int,
        default=0,
        help="ECG lead number"
    )


    parser.add_argument(
        "--duration",
        type=float,
        default=60,
        help=(
            "Seconds of ECG to load. "
            "Use 0 for full record."
        )
    )


    args = parser.parse_args()


    # --------------------------------------------------------
    # LOAD ECG
    # --------------------------------------------------------

    try:

        (
            ecg,
            beat_samples,
            lead_name,
            original_fs,

        ) = load_physionet_record(

            args.database,
            args.record,
            args.lead,
            args.duration,

        )

    except Exception as error:

        print()
        print("Could not load PhysioNet data.")
        print()
        print(error)
        print()

        sys.exit(1)


    # --------------------------------------------------------
    # START GUI
    # --------------------------------------------------------

    app = QtWidgets.QApplication(
        sys.argv
    )


    monitor = ECGMonitor(
        ecg,
        beat_samples,
        lead_name
    )


    monitor.show()


    sys.exit(
        app.exec()
    )


if __name__ == "__main__":
    main()