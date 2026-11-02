"""Fan Control for the Anbernic RG552, run inside PyUI ("pyuiEntry").

The fan belongs to dArkMoss's rg552-fan daemon (scripts/rg552 in dArkMoss);
this only picks its mode, which the base keeps across reboots:

  Auto    a temperature curve: off when cool, up to full speed at 70 C
  High    full speed
  Medium  about two thirds
  Low     about two fifths
  Off     stopped

Whatever the mode, the daemon runs the fan at full speed from 85 C until the
SoC is back under 80 C.
"""

import subprocess

FAN_CMD = "/usr/local/bin/rg552-fan"

MODES = [
    ("auto", "Auto (follows temperature)"),
    ("high", "High"),
    ("medium", "Medium"),
    ("low", "Low"),
    ("off", "Off (full speed above 85°C)"),
]


def _fan(*args):
    try:
        out = subprocess.run([FAN_CMD, *args], capture_output=True, text=True, timeout=10)
    except (OSError, subprocess.SubprocessError):
        return None
    return out.stdout if out.returncode == 0 else None


def _status():
    """(mode, temperature in C or None, pwm 0-255 or None)."""
    values = {}
    for line in (_fan("status") or "").splitlines():
        if "=" in line:
            key, value = line.split("=", 1)
            values[key.strip()] = value.strip()
    mode = values.get("mode") or (_fan("get") or "auto").strip()
    temp = values.get("temp")
    pwm = values.get("pwm")
    return (mode,
            int(temp) if temp and temp.isdigit() else None,
            int(pwm) if pwm and pwm.isdigit() else None)


def _title(mode, temp, pwm):
    label = dict(MODES).get(mode, mode).split(" (")[0]
    parts = [f"Fan: {label}"]
    if temp is not None:
        parts.append(f"{temp}°C")
    if pwm is not None:
        parts.append(f"{round(pwm * 100 / 255)}%")
    return "  ·  ".join(parts)


def run():
    from display.display import Display
    from menus.settings.list_of_options_selection_menu import ListOfOptionsSelectionMenu

    if _fan("get") is None:
        Display.display_message("Fan control is not available on this firmware.", 3000)
        return

    menu = ListOfOptionsSelectionMenu()
    while True:
        mode, temp, pwm = _status()
        keys = [key for key, _ in MODES]
        current = keys.index(mode) if mode in keys else 0
        labels = [f"{text}  ✓" if key == mode else text for key, text in MODES]
        index = menu.get_selected_option_index(labels, _title(mode, temp, pwm), default_index=current)
        if index is None:
            return
        chosen = keys[index]
        if _fan("set", chosen) is None:
            Display.display_message("Could not change the fan mode.", 2500)
        else:
            Display.display_message(f"Fan set to {dict(MODES)[chosen].split(' (')[0]}", 1200)
