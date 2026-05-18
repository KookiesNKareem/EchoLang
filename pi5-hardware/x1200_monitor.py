#!/usr/bin/python3
"""X1200 UPS monitor — libgpiod v2 rewrite of Suptronics' merged.py.

The upstream script at https://github.com/suptronics/x120x targets libgpiod
v1, which Bookworm no longer ships. This rewrite uses the v2 API:
  - gpiod.request_lines() instead of chip.get_line() + line.request()
  - gpiod.LineSettings(direction=Direction.INPUT) instead of LINE_REQ_DIR_IN

Behavior: every SLEEP_TIME seconds, read AC state (GPIO 6) + battery
voltage/capacity (MAX17040 on I2C 0x36). If AC has been unplugged AND
battery is genuinely low (<20% capacity OR <3.20V) for SHUTDOWN_THRESHOLD
consecutive checks, halt the Pi cleanly. Pulling the AC alone on a full
battery does NOT trigger shutdown — the UPS does its job until the cells
are actually depleted.

Intended to run as a systemd service. See pi5-hardware/systemd/x1200.service.
"""
import os
import struct
import sys
import time
import smbus2
import gpiod
from gpiod.line import Direction, Value
from subprocess import call

SHUTDOWN_THRESHOLD = 3
SLEEP_TIME = 60
LOOP = True

I2C_ADDR = 0x36
PLD_PIN = 6
CHIP_PATH = "/dev/gpiochip0"


def read_voltage(bus):
    raw = bus.read_word_data(I2C_ADDR, 2)
    swapped = struct.unpack("<H", struct.pack(">H", raw))[0]
    return swapped * 1.25 / 1000 / 16


def read_capacity(bus):
    raw = bus.read_word_data(I2C_ADDR, 4)
    swapped = struct.unpack("<H", struct.pack(">H", raw))[0]
    return swapped / 256


def battery_status(voltage):
    if 3.87 <= voltage <= 4.2:
        return "Full"
    if 3.7 <= voltage < 3.87:
        return "High"
    if 3.55 <= voltage < 3.7:
        return "Medium"
    if 3.4 <= voltage < 3.55:
        return "Low"
    if voltage < 3.4:
        return "Critical"
    return "Unknown"


pidfile = "/var/run/X1200.pid"
if os.path.isfile(pidfile):
    print("Script already running", flush=True)
    sys.exit(1)
with open(pidfile, "w") as f:
    f.write(str(os.getpid()))

request = None
try:
    bus = smbus2.SMBus(1)
    request = gpiod.request_lines(
        CHIP_PATH,
        consumer="x1200-pld",
        config={PLD_PIN: gpiod.LineSettings(direction=Direction.INPUT)},
    )

    while True:
        failure_counter = 0
        for _ in range(SHUTDOWN_THRESHOLD):
            ac_ok = request.get_value(PLD_PIN) == Value.ACTIVE
            voltage = read_voltage(bus)
            capacity = read_capacity(bus)
            status = battery_status(voltage)
            print(
                f"Capacity: {capacity:.2f}% ({status}), "
                f"AC: {'Plugged in' if ac_ok else 'Unplugged'}, "
                f"Voltage: {voltage:.2f}V",
                flush=True,
            )
            if not ac_ok:
                if capacity < 20:
                    failure_counter += 1
                if voltage < 3.20:
                    failure_counter += 1
            else:
                failure_counter = 0
                break
            if failure_counter < SHUTDOWN_THRESHOLD:
                time.sleep(SLEEP_TIME)

        if failure_counter >= SHUTDOWN_THRESHOLD:
            print("Critical condition — shutting down.", flush=True)
            call("sudo nohup shutdown -h now", shell=True)
            break

        if LOOP:
            time.sleep(SLEEP_TIME)
        else:
            break

finally:
    if request is not None:
        try:
            request.release()
        except Exception:
            pass
    if os.path.isfile(pidfile):
        os.unlink(pidfile)
