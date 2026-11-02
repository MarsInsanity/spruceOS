import os
import threading

from controller.controller_inputs import ControllerInput
from controller.key_state import KeyState
from controller.key_watcher_controller_dataclasses import InputResult, KeyEvent
from devices.charge.charge_status import ChargeStatus
from devices.darkmoss.darkmoss_device import DarkmossDevice
from utils import throttle
from utils.logger import PyUiLogger


class Rg552(DarkmossDevice):
    """Anbernic RG552 on dArkMoss: RK3399, a 1152x1920 portrait panel used in
    landscape (1920x1152), a GT927 touchscreen, two sticks, the RG351MP-family
    odroidgo3 pad (same codes as the G350).

    PyUI lays out a 1280x768 canvas and scales it 1.5x to the panel, the way the
    Miniloong does 960x720 -> 1440x1080, and turns it 270 degrees to match the
    base's fbcon=rotate:3 and its RGA ROT_270 SDL build.
    """

    JOYPAD_NODE = "/dev/input/by-path/platform-odroidgo3-joypad-event-joystick"
    SYSTEM_JSON_NAME = "rg552-system.json"
    # The 4.4 kernel lists the panel colour properties but rejects every set.
    PANEL_CALIBRATION = False
    SELECT_KEY = 704  # BTN_TRIGGER_HAPPY1 (F1)
    START_KEY = 705   # F2
    MENU_KEY = 708    # F5, the F key
    # A 0-100 backlight and no softvol on the codec itself: the py-ui-config
    # scripts apply spruce's own tables (RG552.cfg).
    VOLUME_BACKLIGHT_CMDS = True

    SCALE = 1.5
    HDMI_STATUS = "/sys/class/drm/card0-HDMI-A-1/status"

    def __init__(self, device_name, main_ui_mode=True):
        super().__init__(device_name)
        self.touch_watcher = None
        if main_ui_mode:
            self._start_touch_watcher()

    # ----- input -----
    def _button_mappings(self):
        key_mappings = super()._button_mappings()
        for code, control in ((706, ControllerInput.L3), (707, ControllerInput.R3)):
            key_mappings[KeyEvent(1, code, 1)] = [InputResult(control, KeyState.PRESS)]
            key_mappings[KeyEvent(1, code, 0)] = [InputResult(control, KeyState.RELEASE)]
        return key_mappings

    @staticmethod
    def _find_touch_node():
        """The GT927's event node, by evdev name ("Goodix Capacitive TouchScreen")."""
        override = os.environ.get("TOUCH_EVENT_PATH") or os.environ.get("EVENT_PATH_TOUCH")
        if override and os.path.exists(override):
            return override
        try:
            entries = sorted(os.listdir("/sys/class/input"))
        except OSError:
            return None
        for entry in entries:
            if not entry.startswith("event"):
                continue
            try:
                with open(f"/sys/class/input/{entry}/device/name") as f:
                    name = f.read().strip().lower()
            except OSError:
                continue
            if "goodix" in name or "touch" in name:
                return f"/dev/input/{entry}"
        return None

    def supports_touch(self):
        return self.touch_watcher is not None

    def _start_touch_watcher(self):
        path = self._find_touch_node()
        if not path:
            PyUiLogger.get_logger().warning("RG552: no touchscreen node found; touch off")
            return
        try:
            from controller.touch_watcher import TouchWatcher
            self.touch_watcher = TouchWatcher(path, self)
        except Exception as e:
            PyUiLogger.get_logger().error(f"RG552: touch watcher failed on {path}: {e}")
            self.touch_watcher = None
            return
        threading.Thread(target=self.touch_watcher.poll, daemon=True).start()

    # ----- display -----
    def screen_width(self):
        return 1280

    def screen_height(self):
        return 768

    def screen_rotation(self):
        return 270

    def output_screen_width(self):
        if self.should_scale_screen():
            return 1920
        return int(self.screen_width() * self.SCALE)

    def output_screen_height(self):
        if self.should_scale_screen():
            return 1080
        return int(self.screen_height() * self.SCALE)

    def get_scale_factor(self):
        # 768 * 1.40625 = 1080 on a 1080p TV; 1.5 fills the 1152-line panel.
        return 1080 / 768 if self.is_hdmi_connected() else self.SCALE

    @throttle.limit_refresh(5)
    def is_hdmi_connected(self):
        try:
            with open(self.HDMI_STATUS) as f:
                return f.read().strip().lower() == "connected"
        except OSError:
            return False

    # ----- power -----
    @staticmethod
    def _battery_dir():
        """The fuel gauge registers as "bat" on this kernel, not "battery"."""
        base = "/sys/class/power_supply"
        try:
            for entry in sorted(os.listdir(base)):
                try:
                    with open(f"{base}/{entry}/type") as f:
                        if f.read().strip() == "Battery":
                            return f"{base}/{entry}"
                except OSError:
                    continue
        except OSError:
            pass
        return f"{base}/battery"

    @throttle.limit_refresh(15)
    def get_battery_percent(self):
        if self.BATTERYPLUS_PERCENT_FILE:
            try:
                with open(self.BATTERYPLUS_PERCENT_FILE) as f:
                    percent = int(f.read().strip())
                if 0 <= percent <= 100:
                    return percent
            except (OSError, ValueError):
                pass
        try:
            with open(f"{self._battery_dir()}/capacity") as f:
                return int(f.read().strip())
        except (OSError, ValueError):
            return 0

    @throttle.limit_refresh(5)
    def get_charge_status(self):
        try:
            with open(f"{self._battery_dir()}/status") as f:
                status = f.read().strip()
        except OSError:
            return ChargeStatus.DISCONNECTED
        return ChargeStatus.CHARGING if status in ("Charging", "Full") else ChargeStatus.DISCONNECTED
