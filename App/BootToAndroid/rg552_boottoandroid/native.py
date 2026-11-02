"""Boot to Android for the Anbernic RG552, run inside PyUI ("pyuiEntry").

The RG552 boots the TF1 card when it carries a boot loader and Android from the
eMMC when it does not. dArkMoss's rg552-bootswitch saves the start of each
loader stage into an unused area of the card and blanks it, then this reboots
through spruce's normal reboot path, so the device comes up in Android.

Getting back: the "RG552 Boot Switch" app on Android (needs root), or a PC with
the card in a reader (rg552-bootswitch/README.txt on the card's BOOT partition).
"""

import subprocess

SWITCH_CMD = "/usr/local/sbin/rg552-bootswitch"


def _switch(action):
    try:
        out = subprocess.run([SWITCH_CMD, action], capture_output=True, text=True, timeout=60)
    except (OSError, subprocess.SubprocessError) as e:
        return False, str(e)
    text = (out.stdout + out.stderr).strip()
    return out.returncode == 0, text


def run():
    from devices.device import Device
    from display.display import Display
    from menus.settings.list_of_options_selection_menu import ListOfOptionsSelectionMenu

    ok, _ = _switch("status")
    if not ok and not _is_installed():
        Display.display_message("Boot switching is not available on this firmware.", 3000)
        return

    choice = ListOfOptionsSelectionMenu().get_selected_option_index(
        ["Reboot into Android", "Cancel"],
        "Boot to Android? To come back, use the RG552 Boot Switch app on Android.",
        default_index=1)
    if choice != 0:
        return

    ok, text = _switch("android")
    if not ok:
        Display.display_message(f"Could not switch to Android: {text.splitlines()[-1] if text else 'unknown error'}", 5000)
        return

    Display.display_message("Rebooting into Android...", 1500)
    Device.get_device().reboot()


def _is_installed():
    import os
    return os.access(SWITCH_CMD, os.X_OK)
