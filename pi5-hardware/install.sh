#!/usr/bin/env bash
# pi5-hardware/install.sh — wire up the BrainCraft HAT, X1200 UPS, and
# autostart units on a freshly-set-up Pi 5 running EchoLang.
#
# Prerequisites:
#   - You've already run pi-server/scripts/setup-pi.sh and the FastAPI
#     server boots without crashing.
#   - Ollama is installed and `gemma4:e2b` (or whichever model `config.py`
#     names) is pulled.
#   - The user account is `kfareed`. If yours is different, edit the
#     systemd unit files in pi5-hardware/systemd/ before running this
#     script (or sed them in below).
#
# What this does:
#   1. apt-installs system build deps for the display + UPS libraries.
#   2. Enables I2C and SPI via raspi-config.
#   3. Appends dtoverlay=spi0-0cs to /boot/firmware/config.txt if missing.
#   4. pip-installs the hardware deps into pi-server's venv.
#   5. Drops .asoundrc into the user's home so USB mic resampling works.
#   6. Installs and enables the three systemd services.
#
# Things it does NOT do (manual steps still required):
#   - Edit Pi 5 EEPROM (POWER_OFF_ON_HALT=1, PSU_MAX_CURRENT=5000).
#     Run `sudo -E rpi-eeprom-config --edit` separately.
#   - Create swap. Pi 5 + Gemma + whisper is tight on 8 GB; we add 6 GB
#     of swap as belt-and-suspenders.
#   - Insert 18650 cells into the X1200. That's a screwdriver job.
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HW_DIR="$REPO_DIR/pi5-hardware"
USER_NAME="${SUDO_USER:-$USER}"
USER_HOME="$(getent passwd "$USER_NAME" | cut -d: -f6)"

if [[ $EUID -ne 0 ]]; then
  echo "Re-running with sudo..."
  exec sudo -E "$0" "$@"
fi

echo "==> 1/6 Installing system packages..."
apt-get update
apt-get install -y \
  python3-dev swig liblgpio-dev \
  i2c-tools \
  python3-libgpiod python3-smbus2

echo "==> 2/6 Enabling I2C and SPI..."
raspi-config nonint do_i2c 0
raspi-config nonint do_spi 0

echo "==> 3/6 Disabling kernel SPI chip-select claim..."
CONFIG_TXT="/boot/firmware/config.txt"
if ! grep -q "^dtoverlay=spi0-0cs" "$CONFIG_TXT"; then
  echo "dtoverlay=spi0-0cs" >> "$CONFIG_TXT"
  echo "  added dtoverlay=spi0-0cs (reboot required for this to take effect)"
else
  echo "  already present"
fi

echo "==> 4/6 Installing Python hardware deps into pi-server venv..."
VENV="$USER_HOME/EchoLang/pi-server/.venv"
if [[ ! -d "$VENV" ]]; then
  echo "  ERROR: $VENV does not exist. Run pi-server/scripts/setup-pi.sh first."
  exit 1
fi
sudo -u "$USER_NAME" "$VENV/bin/pip" install --upgrade pip wheel
sudo -u "$USER_NAME" "$VENV/bin/pip" install -r "$HW_DIR/requirements-hardware.txt"

echo "==> 5/6 Installing .asoundrc for USB mic resampling..."
install -o "$USER_NAME" -g "$USER_NAME" -m 0644 "$HW_DIR/asoundrc" "$USER_HOME/.asoundrc"
echo "  NOTE: edit ~/.asoundrc if 'arecord -l' shows your USB mic at a card index other than 0."

echo "==> 6/6 Installing systemd units..."
install -m 0644 "$HW_DIR/systemd/echolang.service"            /etc/systemd/system/
install -m 0644 "$HW_DIR/systemd/echolang-controller.service" /etc/systemd/system/
install -m 0644 "$HW_DIR/systemd/x1200.service"               /etc/systemd/system/
systemctl daemon-reload
systemctl enable echolang.service echolang-controller.service x1200.service
systemctl restart x1200.service
echo "  echolang.service + echolang-controller.service will autostart on next boot."
echo "  Not starting them now in case you still need to reboot for SPI changes."

echo
echo "==> Done. Remaining manual steps:"
echo "   1. sudo -E rpi-eeprom-config --edit  → add POWER_OFF_ON_HALT=1 and PSU_MAX_CURRENT=5000"
echo "   2. Add 6 GB swap:"
echo "        sudo fallocate -l 6G /swapfile"
echo "        sudo chmod 600 /swapfile && sudo mkswap /swapfile && sudo swapon /swapfile"
echo "        echo '/swapfile none swap sw 0 0' | sudo tee -a /etc/fstab"
echo "   3. Reboot so dtoverlay=spi0-0cs takes effect:"
echo "        sudo reboot"
