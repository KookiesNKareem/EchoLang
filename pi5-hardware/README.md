# pi5-hardware — physical-classroom kit for EchoLang

Optional hardware integration that turns a Raspberry Pi 5 + two HATs + a
USB microphone into a self-contained EchoLang appliance: press a button to
start/stop a recording, watch a live timer on a tiny color display, save
the bundle to disk, and survive a wall-power loss without corrupting the
SD card.

Everything here is additive. The base `pi-server/` still runs fine without
any of this; this folder is for the people who actually want the box on a
classroom desk.

## Bill of materials

| Component | Purpose | Notes |
|---|---|---|
| Raspberry Pi 5 (8 GB) | Main board | 4 GB might work but Gemma is tight |
| Adafruit BrainCraft HAT (PID 4484) | 1.54" ST7789 display + two user buttons | We use the screen and the two buttons. Audio codec and joystick are present but unused. |
| Geekworm X1200 UPS HAT | Battery backup via 2× 18650 cells, pass-through USB-C power, MAX17040 fuel gauge, AC-loss detect on GPIO 6 | Mounts UNDER the Pi via pogo pins. |
| USB Audio Class 1.0/2.0 microphone | Speech capture | Any UAC mic; plug into a USB 2.0 (black) port to avoid USB 3.0 RF noise. |
| 2× 18650 lithium-ion cells | Power the X1200 | 3000+ mAh recommended for ~2 hr active runtime. |
| MicroSD ≥ 32 GB | OS + models | The whisper model + Gemma in Ollama is ~10 GB. |

## Pin mapping (confirmed-by-probe on this BrainCraft revision)

Adafruit's docs show button B on GPIO 22, but on the PID 4484 revision we
shipped against, the buttons are at GPIO 23 (lower) and GPIO 24 (upper).
Adafruit's docs also list D24 as the display reset pin; on this revision
reset is hard-tied to 3.3V instead, which is why `echolang_controller.py`
constructs `st7789.ST7789(..., rst=None, ...)`. If your board behaves
differently, run `pi5-hardware/probe_buttons.py` (see "Sanity checks"
below) — the script watches all candidate GPIOs and prints which ones
toggle when buttons are pressed.

| Pin | Use |
|---|---|
| GPIO 6 | X1200 AC-loss detect (PLD input) |
| GPIO 8 (CE0) | BrainCraft display SPI chip-select |
| GPIO 23 | BrainCraft lower button |
| GPIO 24 | BrainCraft upper button |
| GPIO 25 | BrainCraft display D/C |
| GPIO 26 | BrainCraft display backlight enable |
| I2C 0x36 | X1200 MAX17040 battery fuel gauge |

## What the controller does

`echolang_controller.py` runs as a systemd service and drives the
BrainCraft HAT. It talks to the EchoLang server over plain HTTP at
`http://<lan-ip>:8080`, so it's loosely coupled — if upstream changes the
API shape, you'll see an explicit error on the screen instead of a silent
break.

State machine:

```
IDLE (top button)
  ├─→ RECORDING  (live timer + class id)
  │     (top button)
  │     ├─→ STOPPING  (server runs the finalize() drain pass)
  │     │     └─→ REVIEW (caption count + save/discard prompt)
  │     │           ├─(top)→ SAVING → FLASH("Saved") → IDLE
  │     │           └─(bottom)→ FLASH("Discarded") → IDLE
```

Bundles save to `~/EchoLang/recordings/`. The ZIP contains
`transcript.txt`, `translation.txt`, `manifest.json`, `study_pack.json`,
and `confusions.json` — see `pi-server/app/bundle.py`.

## What the UPS monitor does

`x1200_monitor.py` polls AC state (GPIO 6) and battery voltage/capacity
(MAX17040 on I²C `0x36`) once a minute. If AC is unplugged AND the
battery is genuinely low (<20% capacity or <3.20V) for 3 consecutive
checks, it issues a clean `shutdown -h now`. Unplugging the wall on a
healthy battery does NOT trigger shutdown — the UPS does its job until
the cells are actually depleted.

The Pi 5 EEPROM must have `POWER_OFF_ON_HALT=1` so the halt actually
cuts power instead of hanging. The install script doesn't set this
because EEPROM edits need `rpi-eeprom-config --edit`; see "Manual
steps" below.

## What the patched server endpoints do

Two surgical changes to `pi-server/app/`:

1. **`transcription.py`** — Replaces the upstream `_emit` filter with
   substring-based dedup tolerant of whisper's revision behavior, adds a
   `finalize()` method that stops audio capture immediately on
   end-of-class (so silence can't bury trailing speech) and runs one
   final transcription pass with a relaxed short-suffix threshold.
2. **`main.py`** — Calls `transcriber.finalize()` BEFORE
   `store.end_class()` so the drain pass's captions are still attributed
   to the active class.

If you're running EchoLang on something other than a Pi 5 (no rolling-
window timestamp quirk, faster inference), these patches don't hurt but
also aren't strictly necessary.

## Install

```bash
# As root or with sudo:
cd ~/EchoLang/pi5-hardware
sudo ./install.sh
```

The script:

1. Installs system packages (`swig`, `liblgpio-dev`, `i2c-tools`, etc.)
2. Enables I²C and SPI via `raspi-config`
3. Appends `dtoverlay=spi0-0cs` to `/boot/firmware/config.txt` (needed
   so Adafruit's display library can manage CS in software)
4. Installs Python deps into `pi-server/.venv` from
   `requirements-hardware.txt`
5. Drops `asoundrc` into `~/.asoundrc` (routes USB mic through ALSA's
   plug device so PortAudio gets 48 kHz → 16 kHz resampling for free)
6. Installs and enables three systemd units

After running, do these manual steps:

```bash
# 1. Edit Pi 5 EEPROM so halt actually cuts power
sudo -E rpi-eeprom-config --edit
#    Add or set:
#      POWER_OFF_ON_HALT=1
#      PSU_MAX_CURRENT=5000

# 2. Add 6 GB swap (Pi 5 with Gemma loaded sits near 7.5 GB used; without
#    swap, study-pack generation can OOM and hard-reboot the Pi)
sudo fallocate -l 6G /swapfile
sudo chmod 600 /swapfile
sudo mkswap /swapfile
sudo swapon /swapfile
echo '/swapfile none swap sw 0 0' | sudo tee -a /etc/fstab

# 3. Reboot so dtoverlay=spi0-0cs takes effect
sudo reboot
```

## Sanity checks

After install + reboot, with the USB mic plugged in:

```bash
# UPS reachable on I2C 0x36?
sudo i2cdetect -y 1 | grep 36

# UPS service running and reading voltage?
sudo journalctl -u x1200.service -n 5 --no-pager

# EchoLang server up?
curl http://127.0.0.1:8080/api/health

# Controller service running?
sudo systemctl status echolang-controller.service --no-pager | head -5

# Audio capture works at 16 kHz mono?
arecord -D default -f S16_LE -r 16000 -c 1 -d 3 /tmp/mic_test.wav && \
  ls -lh /tmp/mic_test.wav    # ~94 KB = 3 s of 16 kHz mono = good
```

## Known issues / future work

- Whisper's `tiny.en` mishears proper nouns (e.g. "Fontainebleau" →
  "Fontaine Blue"). `base.en` is more accurate but Pi 5 inference is too
  slow for streaming. A medium-term fix would be quantized whisper on a
  Coral TPU or migration to a faster STT.
- USB mic card index can shift across reboots (sometimes 0, sometimes 2).
  `~/.asoundrc` hardcodes `hw:0,0`; if `arecord -l` shows a different
  index after a reboot, edit the file. A more robust fix would be
  addressing by name with `hw:CARD=<name>`.
- The save directory currently lives under `~/EchoLang/recordings/`
  which puts it inside the cloned git repo. Recordings are gitignored,
  but if you'd rather have them fully outside the repo, change `SAVE_DIR`
  in `echolang_controller.py`.
