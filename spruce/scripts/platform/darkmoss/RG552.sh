#!/bin/sh
# Anbernic RG552 device functions. Everything the base OS decides is in
# dArkMossCommon.sh; this file holds what is particular to this unit.

. "/mnt/SDCARD/spruce/scripts/platform/darkmoss/dArkMossCommon.sh"

# dArkMossCommon's device_init clears two RK817 registers over i2c-0 (0x20).
# The RG552's PMIC is an RK808 at 0x1b and that address is not its, so never
# write there.
clear_stale_pmic_power_en() {
    :
}

# The BSP es8316 driver owns the jack (hp-det-gpio, gpio0 PB0) and switches the
# speaker amp itself, so there is no path for spruce to set.
apply_playback_path() {
    :
}

# The jack GPIO is claimed by the codec, so read its level from debugfs:
# GPIO_ACTIVE_HIGH, high with a plug in. UNVERIFIED on hardware.
are_headphones_plugged_in() {
    _dbg=/sys/kernel/debug/gpio
    [ -r "$_dbg" ] || mount -t debugfs debugfs /sys/kernel/debug 2>/dev/null
    grep -s "^ *gpio-8 " "$_dbg" | grep -q " in  *hi"
}

# idlemon's default node is event3. The js node, because emulators write
# rumble to the event node (as on the G350, same pad driver).
set_event_arg_for_idlemon() {
    EVENT_ARG="-e $(readlink -f /dev/input/by-path/platform-odroidgo3-joypad-joystick)"
}

# The gauge has no "battery" supply here (see BATTERY in RG552.cfg), and its own
# status is the only charging signal this board's kernel exposes.
device_get_charging_status() {
    _st="$(cat "$BATTERY/status" 2>/dev/null)"
    case "$_st" in
        Charging|Full|Discharging|"Not charging") ;;
        *) _st="Discharging" ;;
    esac
    if [ "$_st" = "Charging" ] && [ "$(cat "$BATTERY/capacity" 2>/dev/null)" = "100" ]; then
        _st="Full"
    fi
    echo "$_st"
}

device_low_battery_shutdown_ok() {
    case "$(cat "$BATTERY/status" 2>/dev/null)" in
        Charging|Full)
            log_message "$PLATFORM battery: charging, not forcing a shutdown"
            return 1 ;;
    esac
}

# The common defaults with this pad's udev numbering: select 12, L3 14.
set_default_ra_hotkeys() {
    RA_FILE="$(platform_path "/mnt/SDCARD/Saves/ra-configs/retroarch-%s.cfg")"

    log_message "Resetting RetroArch hotkeys to Spruce defaults."

    update_ra_config_file_with_new_setting "$RA_FILE" \
        "input_enable_hotkey_btn = \"12\"" \
        "input_exit_emulator_btn = \"0\"" \
        "input_fps_toggle_btn = \"2\"" \
        "input_load_state_btn = \"4\"" \
        "input_save_state_btn = \"5\"" \
        "input_menu_toggle = \"f1\"" \
        "input_menu_toggle_btn = \"3\"" \
        "input_quit_gamepad_combo = \"0\"" \
        "input_toggle_fast_forward_btn = \"14\"" \
        "input_screenshot_btn = \"nul\"" \
        "input_shader_toggle_btn = \"nul\"" \
        "input_state_slot_decrease_btn = \"nul\"" \
        "input_state_slot_increase_btn = \"nul\"" \
        "input_toggle_slowmotion_btn = \"nul\""
}

  ###############
#####   FAN   #####
  ###############

# The base's rg552-fan daemon owns the fan; spruce only picks the mode, which
# the base keeps across reboots. Modes: auto high medium low off.
rg552_fan_get_mode() {
    "$FAN_CONTROL_CMD" get 2>/dev/null || echo auto
}

rg552_fan_set_mode() {
    "$FAN_CONTROL_CMD" set "$1" >/dev/null 2>&1 || return 1
    log_message "$PLATFORM: fan mode $1"
}

rg552_fan_status() {
    "$FAN_CONTROL_CMD" status 2>/dev/null
}

  ###########################
#####   BOOT TO ANDROID   #####
  ###########################

# "android" or "linux": what the TF1 card will boot next.
rg552_next_boot() {
    "$BOOT_SWITCH_CMD" status 2>/dev/null | tail -n 1
}

rg552_boot_android_next() {
    "$BOOT_SWITCH_CMD" android
}
