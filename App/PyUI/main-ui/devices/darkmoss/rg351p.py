import os

from controller.controller_inputs import ControllerInput
from controller.key_state import KeyState
from controller.key_watcher_controller_dataclasses import InputResult, KeyEvent
from devices.darkmoss.v10 import V10, V10KeyMappingProvider
from utils.logger import PyUiLogger

PAD_NAME = "OpenSimHardware OSH PB Controller"


def find_pad_node():
    """The pad is a USB device with no fixed by-path link: find it by name."""
    try:
        entries = sorted(os.listdir("/sys/class/input"))
    except OSError:
        return None
    for entry in entries:
        if not entry.startswith("event"):
            continue
        try:
            with open(f"/sys/class/input/{entry}/device/name") as f:
                if f.read().strip() == PAD_NAME:
                    return f"/dev/input/{entry}"
        except OSError:
            continue
    return None


class RG351PKeyMappingProvider(V10KeyMappingProvider):
    """The V10's SELECT+START menu chord on the RG351P's USB pad.

    Codes are ArkOS's RG351P EmulationStation config. The d-pad is a hat
    (ABS_HAT0X/Y), looked up straight from the key map. The stick axes are
    ignored in the menus: this pad's axis range is not the V10's +-1800 the
    base provider is sized for, and a wrong deadzone would make the menus
    scroll on their own. The stick click is MENU; R3 is reported by the
    controller but the RG351P has no second stick.
    """

    SELECT_KEY = 311
    START_KEY = 310
    L3_KEY = 312
    R3_KEY = 313
    ABS_HAT0X = 16
    ABS_HAT0Y = 17

    # The V10 provider sets these on the first SELECT press only; START
    # pressed first would read them unset.
    select_down = False
    menu_down = False
    select_released_by_chord = False

    THUMB_FALLBACK = {
        L3_KEY: ControllerInput.L3,
        R3_KEY: ControllerInput.R3,
    }

    def _menu_thumb_code(self):
        return self.L3_KEY

    def get_mapped_events(self, key_event):
        if key_event.event_type == self.EV_ABS:
            if key_event.code in (self.ABS_HAT0X, self.ABS_HAT0Y):
                return self.key_mappings.get(key_event)
            return None
        return super().get_mapped_events(key_event)


class RG351P(V10):
    """Anbernic RG351P on dArkMoss: the V10's panel and board, a USB pad."""

    JOYPAD_NODE = "/dev/input/event2"
    SYSTEM_JSON_NAME = "rg351p-system.json"
    SELECT_KEY = 311
    START_KEY = 310

    def _resolve_joypad(self):
        node = find_pad_node()
        if node:
            PyUiLogger.get_logger().info(f"{self.device_name}: joypad '{PAD_NAME}' at {node}")
            return node
        PyUiLogger.get_logger().error(
            f"{self.device_name}: no '{PAD_NAME}' input device, trying {self.JOYPAD_NODE}"
        )
        return self.JOYPAD_NODE

    def _button_mappings(self):
        key_mappings = {}

        def bind(code, control):
            key_mappings[KeyEvent(1, code, 1)] = [InputResult(control, KeyState.PRESS)]
            key_mappings[KeyEvent(1, code, 0)] = [InputResult(control, KeyState.RELEASE)]

        bind(304, ControllerInput.A)
        bind(305, ControllerInput.B)
        bind(306, ControllerInput.X)
        bind(307, ControllerInput.Y)
        bind(308, ControllerInput.L1)
        bind(309, ControllerInput.R1)
        bind(314, ControllerInput.L2)
        bind(315, ControllerInput.R2)
        bind(self.START_KEY, ControllerInput.START)
        bind(self.SELECT_KEY, ControllerInput.SELECT)

        hat_y, hat_x = RG351PKeyMappingProvider.ABS_HAT0Y, RG351PKeyMappingProvider.ABS_HAT0X
        key_mappings[KeyEvent(3, hat_y, -1)] = [InputResult(ControllerInput.DPAD_UP, KeyState.PRESS)]
        key_mappings[KeyEvent(3, hat_y, 1)] = [InputResult(ControllerInput.DPAD_DOWN, KeyState.PRESS)]
        key_mappings[KeyEvent(3, hat_y, 0)] = [InputResult(ControllerInput.DPAD_UP, KeyState.RELEASE),
                                               InputResult(ControllerInput.DPAD_DOWN, KeyState.RELEASE)]
        key_mappings[KeyEvent(3, hat_x, -1)] = [InputResult(ControllerInput.DPAD_LEFT, KeyState.PRESS)]
        key_mappings[KeyEvent(3, hat_x, 1)] = [InputResult(ControllerInput.DPAD_RIGHT, KeyState.PRESS)]
        key_mappings[KeyEvent(3, hat_x, 0)] = [InputResult(ControllerInput.DPAD_LEFT, KeyState.RELEASE),
                                               InputResult(ControllerInput.DPAD_RIGHT, KeyState.RELEASE)]
        return key_mappings

    def _mapping_provider(self, key_mappings):
        return RG351PKeyMappingProvider(key_mappings)

    # Volume is a hardware wheel after the codec: no volume setting or
    # indicator, and the codec stays at full (RG351P.sh's set_volume does the
    # same on the shell side).
    def supports_volume(self):
        return False

    def _set_volume(self, volume):
        return super()._set_volume(100)

    def change_volume(self, amount):
        self._set_volume(100)
        if self.system_config.get_volume() != 100:
            self.system_config.set_volume(100)
            self.system_config.save_config()
