#!/usr/bin/env python3
"""EchoLang recording controller for Pi 5 + BrainCraft HAT.

Top button (GPIO 24): start, then stop, then save.
Bottom button (GPIO 23): discard after stop.
Display: ST7789 1.54" 240x240. Shows REC + timer.
"""
import socket
import threading
import time
from pathlib import Path

import board
import digitalio
import requests
from PIL import Image, ImageDraw, ImageFont
from adafruit_rgb_display import st7789
from gpiozero import Button, Device
from gpiozero.pins.lgpio import LGPIOFactory

Device.pin_factory = LGPIOFactory()


def get_lan_ip() -> str:
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    try:
        s.connect(("8.8.8.8", 80))
        return s.getsockname()[0]
    except OSError:
        return "127.0.0.1"
    finally:
        s.close()


LAN_IP = get_lan_ip()
API_BASE = f"http://{LAN_IP}:8080"
print(f"using API_BASE={API_BASE}", flush=True)

TOP_BUTTON = 24
BOTTOM_BUTTON = 23

# Small client-side delay before POSTing /end so the user sees "Finishing…"
# briefly. The actual drain happens server-side inside transcriber.finalize().
FINISH_GRACE_S = 0.5
SAVE_TIMEOUT_S = 3600.0
SAVED_FLASH_S = 1.8
ERROR_BANNER_S = 3.0
SAVE_DIR = Path.home() / "EchoLang" / "recordings"
SAVE_DIR.mkdir(parents=True, exist_ok=True)

# --- Display ----------------------------------------------------------------

cs = digitalio.DigitalInOut(board.CE0)
dc = digitalio.DigitalInOut(board.D25)
bl = digitalio.DigitalInOut(board.D26)
bl.direction = digitalio.Direction.OUTPUT
bl.value = True

disp = st7789.ST7789(
    board.SPI(),
    cs=cs,
    dc=dc,
    rst=None,
    baudrate=64_000_000,
    width=240,
    height=240,
    x_offset=0,
    y_offset=80,
)

FONT_BOLD = "/usr/share/fonts/truetype/dejavu/DejaVuSans-Bold.ttf"
FONT_REG = "/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf"
font_huge = ImageFont.truetype(FONT_BOLD, 64)
font_big = ImageFont.truetype(FONT_BOLD, 44)
font_med = ImageFont.truetype(FONT_BOLD, 26)
font_small = ImageFont.truetype(FONT_REG, 18)


def centered(draw, y, text, font, fill):
    w = draw.textlength(text, font=font)
    draw.text(((240 - w) / 2, y), text, font=font, fill=fill)


# --- State ------------------------------------------------------------------

IDLE, RECORDING, STOPPING, REVIEW, SAVING, FLASH = (
    "idle", "recording", "stopping", "review", "saving", "flash",
)

state_lock = threading.Lock()
state = IDLE
class_id = None
record_start = 0.0
stop_pressed_at = 0.0
save_start = 0.0
caption_count = 0
flash_message = ""
flash_until = 0.0
error_msg = ""
error_until = 0.0


def set_state(new_state, **kw):
    with state_lock:
        globals()["state"] = new_state
        for k, v in kw.items():
            globals()[k] = v


def show_flash(msg, hold=SAVED_FLASH_S):
    set_state(FLASH, flash_message=msg, flash_until=time.monotonic() + hold)


def show_error(msg, hold=ERROR_BANNER_S):
    global error_msg, error_until
    with state_lock:
        error_msg = msg
        error_until = time.monotonic() + hold


# --- HTTP helpers -----------------------------------------------------------

def http_start_class():
    global class_id, record_start
    try:
        r = requests.post(f"{API_BASE}/api/class", json={"title": "Live"}, timeout=5)
        r.raise_for_status()
        cid = r.json()["id"]
        with state_lock:
            class_id = cid
            record_start = time.monotonic()
        print(f"started class {cid}", flush=True)
        set_state(RECORDING)
    except requests.exceptions.ConnectionError:
        show_error("server offline")
    except Exception as e:
        show_error(f"start: {type(e).__name__}")
        print(f"start failed: {e}", flush=True)


def http_end_class():
    """Server's /end handler now blocks while it runs the final transcription
    pass, so we just need a token client-side delay (for UI smoothness) then
    POST and wait for the response.
    """
    global caption_count
    time.sleep(FINISH_GRACE_S)
    cid = class_id
    if cid is None:
        return
    try:
        # Long timeout: server drain on tiny.en is ~3-5s, on base.en up to ~25s.
        r = requests.post(f"{API_BASE}/api/class/{cid}/end", timeout=60)
        r.raise_for_status()
        try:
            meta = requests.get(f"{API_BASE}/api/class/{cid}", timeout=5).json()
            with state_lock:
                caption_count = meta.get("caption_count", 0)
        except Exception:
            with state_lock:
                caption_count = 0
        print(f"ended class {cid} ({caption_count} captions)", flush=True)
        set_state(REVIEW)
    except Exception as e:
        print(f"end failed: {e}", flush=True)
        show_error(f"end: {type(e).__name__}")
        set_state(REVIEW)


def http_save_bundle():
    cid = class_id
    if cid is None:
        return
    try:
        r = requests.get(
            f"{API_BASE}/api/lecture/{cid}/bundle",
            params={"lang": "en"},
            timeout=SAVE_TIMEOUT_S,
        )
        r.raise_for_status()
        cd = r.headers.get("content-disposition", "")
        fname = cd.split("filename=")[-1].strip('"') or f"{cid}_en.zip"
        out = SAVE_DIR / fname
        out.write_bytes(r.content)
        print(f"saved {out} ({len(r.content)} bytes)", flush=True)
        show_flash(f"Saved ({len(r.content)//1024} KB)")
        return
    except Exception as e:
        print(f"save failed: {e}", flush=True)
        show_error("save failed")
        set_state(REVIEW)


# --- Button handlers --------------------------------------------------------

def on_top():
    if state == IDLE:
        threading.Thread(target=http_start_class, daemon=True).start()
    elif state == RECORDING:
        set_state(STOPPING, stop_pressed_at=time.monotonic())
        threading.Thread(target=http_end_class, daemon=True).start()
    elif state == REVIEW:
        set_state(SAVING, save_start=time.monotonic())
        threading.Thread(target=http_save_bundle, daemon=True).start()


def on_bottom():
    if state == REVIEW:
        show_flash("Discarded")


top_btn = Button(TOP_BUTTON, pull_up=True, bounce_time=0.1)
bot_btn = Button(BOTTOM_BUTTON, pull_up=True, bounce_time=0.1)
top_btn.when_pressed = on_top
bot_btn.when_pressed = on_bottom


# --- Render -----------------------------------------------------------------

def render():
    with state_lock:
        s = state
        cid = class_id
        rstart = record_start
        spress = stop_pressed_at
        sstart = save_start
        ccount = caption_count
        fmsg = flash_message
        funtil = flash_until
        emsg = error_msg
        euntil = error_until

    img = Image.new("RGB", (240, 240), (0, 0, 0))
    draw = ImageDraw.Draw(img)

    if s == IDLE:
        centered(draw, 50, "EchoLang", font_med, (255, 255, 255))
        centered(draw, 110, "press top button", font_small, (180, 180, 180))
        centered(draw, 135, "to start class", font_small, (180, 180, 180))

    elif s == RECORDING:
        # Big REC indicator near the top
        if int(time.monotonic() * 2) % 2 == 0:
            draw.ellipse((30, 30, 80, 80), fill=(255, 40, 40))
        draw.text((95, 28), "REC", font=font_big, fill=(255, 255, 255))
        # Huge timer in the middle
        elapsed = int(time.monotonic() - rstart)
        mm, ss = divmod(elapsed, 60)
        centered(draw, 110, f"{mm:02d}:{ss:02d}", font_huge, (255, 255, 255))
        # Class id at bottom
        if cid:
            centered(draw, 210, f"class {cid[:8]}", font_small, (160, 160, 160))

    elif s == STOPPING:
        elapsed = int(time.monotonic() - spress)
        centered(draw, 80, "Finishing…", font_med, (255, 200, 80))
        centered(draw, 125, "processing last audio", font_small, (180, 180, 180))
        centered(draw, 155, f"{elapsed}s", font_small, (160, 160, 160))

    elif s == REVIEW:
        centered(draw, 25, "Recording done", font_med, (255, 255, 255))
        centered(draw, 70, f"{ccount} captions", font_small, (180, 180, 180))
        draw.rectangle((10, 105, 230, 150), outline=(80, 200, 80), width=2)
        centered(draw, 113, "TOP = Save", font_med, (80, 220, 80))
        draw.rectangle((10, 165, 230, 210), outline=(200, 80, 80), width=2)
        centered(draw, 173, "BOT = Discard", font_med, (220, 80, 80))

    elif s == SAVING:
        elapsed = int(time.monotonic() - sstart) if sstart else 0
        mm, ss = divmod(elapsed, 60)
        centered(draw, 60, "Saving…", font_med, (255, 200, 80))
        centered(draw, 110, f"{mm:02d}:{ss:02d} elapsed", font_med, (255, 255, 255))
        centered(draw, 160, "generating study pack", font_small, (180, 180, 180))
        centered(draw, 185, "scales with lecture length", font_small, (180, 180, 180))

    elif s == FLASH:
        if time.monotonic() >= funtil:
            set_state(IDLE, class_id=None, record_start=0.0, caption_count=0,
                      flash_message="", flash_until=0.0)
        else:
            centered(draw, 100, fmsg, font_med, (255, 255, 255))

    if emsg and time.monotonic() < euntil:
        draw.rectangle((0, 215, 240, 240), fill=(120, 0, 0))
        centered(draw, 219, emsg, font_small, (255, 255, 255))

    disp.image(img)


print("controller running. Top=start/stop/save, Bottom=discard.", flush=True)
try:
    while True:
        render()
        time.sleep(0.25)
except KeyboardInterrupt:
    print("\nexiting.")
    if state in (RECORDING, STOPPING) and class_id:
        try:
            requests.post(f"{API_BASE}/api/class/{class_id}/end", timeout=3)
        except Exception:
            pass
    disp.image(Image.new("RGB", (240, 240), (0, 0, 0)))
