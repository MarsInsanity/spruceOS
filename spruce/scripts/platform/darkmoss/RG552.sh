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
# speaker amp itself, so there is no path for spruce to set. Volume lives on the
# codec's DAC (RG552.cfg), so keep spruce's softvol, where a program uses it,
# from attenuating a second time.
apply_playback_path() {
    amixer -q sset Master 100% 2>/dev/null
}

  ###################
#####   INPUT   #####
  ###################

# By name, not by capability: the power key is rk_keys' "rk29-keypad" (the
# RK808 has no pwrkey cell, so nothing is called *power*), and HDMI-CEC's
# "RC for dw_hdmi" declares every key code and enumerates before the real
# rocker, gpio-keys "volume-keys". Event numbers are not stable across boots.
resolve_key_event_node() {
    _seen=""
    for _dir in /sys/class/input/event*; do
        [ -e "$_dir" ] || continue
        _ev="${_dir##*/}"
        _name="$(cat "$_dir/device/name" 2>/dev/null)"
        _seen="$_seen ${_ev}:${_name}"
        case "$_name" in
            rk29-keypad) EVENT_PATH_POWER="/dev/input/$_ev" ;;
            volume-keys) EVENT_PATH_VOLUME="/dev/input/$_ev" ;;
        esac
    done
    VOLUME_KEYS_ON_PAD=0
    export EVENT_PATH_POWER EVENT_PATH_VOLUME VOLUME_KEYS_ON_PAD
    log_message "$PLATFORM: input nodes:$_seen; power $EVENT_PATH_POWER, volume $EVENT_PATH_VOLUME"
    {
        echo "EVENT_PATH_READ_INPUTS_SPRUCE='${EVENT_PATH_READ_INPUTS_SPRUCE}'"
        echo "EVENT_PATH_SEND_TO_RA_AND_PPSSPP='${EVENT_PATH_READ_INPUTS_SPRUCE}'"
        echo "EVENT_PATH_SEND_TO_DRASTIC='${EVENT_PATH_READ_INPUTS_SPRUCE}'"
        echo "EVENT_PATH_VOLUME='${EVENT_PATH_VOLUME}'"
        echo "EVENT_PATH_POWER='${EVENT_PATH_POWER}'"
        echo "VOLUME_KEYS_ON_PAD='0'"
    } > "$SPRUCE_INPUT_NODES_FILE" 2>/dev/null
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

# A gauge that failed to probe reads as 0%: never power off on that.
device_low_battery_shutdown_ok() {
    if [ ! -r "$BATTERY/capacity" ]; then
        log_message "$PLATFORM battery: no fuel gauge at '$BATTERY', not forcing a shutdown"
        return 1
    fi
    case "$(cat "$BATTERY/status" 2>/dev/null)" in
        Charging|Full)
            log_message "$PLATFORM battery: charging, not forcing a shutdown"
            return 1 ;;
    esac
    return 0
}

  #######################
#####   SCREENSHOTS   #####
  #######################

# kmsgrab captures the scanout, the 1152x1920 portrait buffer: PyUI and the
# system SDL both draw the landscape picture onto it turned 270 degrees
# clockwise, so turn the capture 90 degrees clockwise back (transpose=1), as
# E5Plus.sh does the other way for its ROT_90 panel. Game Switcher thumbnails
# (button_actions.sh capture_screen) and the screenshot hotkey both land here.
# Always on: HDMI is not supported here (RG552.cfg).
take_screenshot() {
    screenshot_path="$1"
    [ -n "$screenshot_path" ] || return 1
    _ff=""
    for _c in /mnt/SDCARD/spruce/bin/ffmpeg /usr/bin/ffmpeg; do
        [ -x "$_c" ] && { _ff="$_c"; break; }
    done
    [ -n "$_ff" ] || {
        log_message "take_screenshot: no ffmpeg with kmsgrab available"
        return 1
    }
    mkdir -p "$(dirname "$screenshot_path")" 2>/dev/null

    if timeout 15 "$_ff" -hide_banner -loglevel error \
        -f kmsgrab -i - \
        -vf "hwdownload,format=bgr0,format=rgba,transpose=1" \
        -frames:v 1 -update 1 -y "$screenshot_path" >/dev/null 2>&1; then
        return 0
    fi

    rm -f "$screenshot_path" 2>/dev/null
    log_message "take_screenshot: kmsgrab capture failed"
    return 1
}

  ###################
#####   SLEEP   #####
  ###################

# Pseudo sleep (oakMOSS's model): the panel goes dark and the session stops
# until sleep_helper sees the power key, or its own timer powers off. Kernel
# suspend is not the default here, because on this board it is untested and risky:
#  - neither SD slot can be power-cycled (no vmmc) and this 4.4 kernel lacks
#    mainline's "card still at 1.8 V after resume" fixup, so a UHS card can
#    fail to come back, and TF1 is the root filesystem;
#  - the RK808's interrupt is wired to GPIO3, which the RK3399 PMU cannot wake
#    from, so spruce's RTC "power off after N minutes asleep" never fires.
# `touch /mnt/SDCARD/spruce/flags/rg552_real_sleep.lock` opts into suspend-to-RAM.
# Everything a darkmoss session runs in the foreground (PortMaster ports are
# paused as their own session, from /tmp/last_port_sid).
RG552_SLEEP_STOP="MainUI ra64.universal ra32.universal retroarch drastic drastic64 $PSP_BIN mupen64plus flycast flycast2024 yabasanshiro scummvm scummvm.64 ffplay dsperate gvu bigpemu pico8_64 pico8_dyn xroar GameTankEmulator OpenBOR_TrimUI OpenBOR_64_mod"
RG552_SLEEP_BRIGHTNESS="/tmp/rg552_sleep_brightness"
# The green LED by Start (dts battery_green, on from boot). A real suspend
# turns it off (gpio-leds without retain-state-suspended); pseudo sleep does
# the same by hand and puts back what it was.
RG552_POWER_LED="/sys/class/leds/battery_green/brightness"
RG552_SLEEP_LED="/tmp/rg552_sleep_led"
RG552_SLEEP_GRABS="/tmp/rg552_sleep_grabs"

device_uses_pseudo_sleep() {
    if flag_check "rg552_real_sleep"; then echo "false"; else echo "true"; fi
}

# No lid: sleep_helper's pseudo loop takes the power key while this reads "1".
device_lid_open() {
    echo "1"
}

device_enter_sleep() {
    IDLE_TIMEOUT="$1"
    if flag_check "rg552_real_sleep"; then
        log_message "Entering sleep w/ IDLE_TIMEOUT of $IDLE_TIMEOUT"
        save_sleep_info "$IDLE_TIMEOUT" || return 1
        set_wake_alarm "$IDLE_TIMEOUT" "$WAKE_ALARM_PATH" || return 1
        trigger_device_sleep
        return
    fi
    log_message "Entering pseudo sleep w/ IDLE_TIMEOUT of $IDLE_TIMEOUT"
    # The power watchdog holds the key with an exclusive grab and runs
    # sleep_helper in the foreground, so sleep_helper's reader would never see
    # the wake press. Drop the grab; the watchdog restarts its reader after.
    kill $(pgrep -f "getevent.*-exclusive") 2>/dev/null
    # Hold the pad, the rocker and the touchscreen while asleep: nothing queues
    # up for the stopped session (stale taps on wake) and no hotkey acts on the
    # dark panel. The grabs end with sleep_helper (-pid) or on wake.
    : > "$RG552_SLEEP_GRABS"
    for _n in "$EVENT_PATH_READ_INPUTS_SPRUCE" "$EVENT_PATH_VOLUME" "$EVENT_PATH_TOUCH"; do
        [ -c "$_n" ] || continue
        getevent -exclusive -pid $$ "$_n" >/dev/null 2>&1 &
        echo $! >> "$RG552_SLEEP_GRABS"
    done
    killall -q -STOP $RG552_SLEEP_STOP 2>/dev/null
    _sid="$(cat /tmp/last_port_sid 2>/dev/null)"
    [ -n "$_sid" ] && kill -STOP -"$_sid" 2>/dev/null
    cat "$DEVICE_BACKLIGHT_PATH" > "$RG552_SLEEP_BRIGHTNESS" 2>/dev/null
    echo 0 > "$DEVICE_BACKLIGHT_PATH" 2>/dev/null
    if [ -e "$RG552_POWER_LED" ]; then
        cat "$RG552_POWER_LED" > "$RG552_SLEEP_LED" 2>/dev/null
        echo 0 > "$RG552_POWER_LED" 2>/dev/null
    fi
}

device_exit_sleep() {
    if ! flag_check "rg552_real_sleep"; then
        _raw="$(cat "$RG552_SLEEP_BRIGHTNESS" 2>/dev/null)"
        rm -f "$RG552_SLEEP_BRIGHTNESS"
        case "$_raw" in
            ''|0|*[!0-9]*) apply_backlight "$(get_backlight_level)" ;;
            *) echo "$_raw" > "$DEVICE_BACKLIGHT_PATH" 2>/dev/null ;;
        esac
        if [ -f "$RG552_SLEEP_LED" ]; then
            _led="$(cat "$RG552_SLEEP_LED" 2>/dev/null)"
            rm -f "$RG552_SLEEP_LED"
            case "$_led" in ''|*[!0-9]*) _led=1 ;; esac
            echo "$_led" > "$RG552_POWER_LED" 2>/dev/null
        fi
        kill $(cat "$RG552_SLEEP_GRABS" 2>/dev/null) 2>/dev/null
        rm -f "$RG552_SLEEP_GRABS"
        _sid="$(cat /tmp/last_port_sid 2>/dev/null)"
        [ -n "$_sid" ] && kill -CONT -"$_sid" 2>/dev/null
        killall -q -CONT $RG552_SLEEP_STOP 2>/dev/null
        log_message "Left pseudo sleep"
    fi
    darkmoss_exit_sleep
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

  ##########################
#####   FIRMWARE UPDATES   #####
  ##########################

# RG552 builds live on the fork's fixed RG552 tag (DARKMOSS_RELEASE_API in
# RG552.cfg), whose version is in the payload's name, not in the tag.
check_if_fw_needs_update() {
    _have="$(darkmoss_installed_version)"
    if [ -z "$_have" ]; then
        echo "true"
        return
    fi
    if ! wifi_available_on_device || [ "$(jq -r '.wifi' "$SYSTEM_JSON" 2>/dev/null)" != "1" ]; then
        echo "false"
        return
    fi
    # Three tries 20 s apart, as github_latest_version: at boot the USB Wi-Fi
    # may not have an address yet (this runs in the background).
    for _try in 1 2 3; do
        _want="$(curl -sfL -m 20 "$DARKMOSS_RELEASE_API" 2>/dev/null | jq -r '.assets[]?.name' 2>/dev/null |
            sed -n 's/^dArkMoss_RG552_[vV]\{0,1\}\([0-9]\{1,\}\.[0-9]\{1,\}\.[0-9]\{1,\}\)\.dmupd$/\1/p' | head -n 1)"
        [ -n "$_want" ] && break
        [ "$_try" -lt 3 ] && sleep 20
    done
    [ -n "$_want" ] && version_older_than "$_have" "$_want" && echo "true" || echo "false"
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

  ##########################
#####   MENU CPU MODE   #####
  ##########################

# In the menu SMART runs PyUI on the four A53s (or all six cores with Battery
# Settings > CPU cores at "Full", RG552.cfg). SMART would put the A53s on
# CPU_SMART_GOVENOR, ondemand, and the A72s on conservative; the menu gets the
# BSP's interactive governor on both instead: Rockchip's Android tuning, which
# goes straight to its high speed under load and boosts the A53s to 1.2 GHz for
# half a second on every button press or touch. Same frequency limits as SMART;
# games keep spruce's SMART as it is.
RG552_MENU_GOVERNOR="interactive"

rg552_menu_governor() {
    unlock_governor 2>/dev/null
    for _dir in "$CPU_0_DIR" "$CPU_4_DIR"; do
        grep -qw "$RG552_MENU_GOVERNOR" "$_dir/scaling_available_governors" 2>/dev/null || continue
        echo "$RG552_MENU_GOVERNOR" > "$_dir/scaling_governor" 2>/dev/null
    done
    log_message "RG552: menu CPU governor $RG552_MENU_GOVERNOR on both clusters" -v
}

# dArkMossCommon's, with the menu governor after SMART.
prepare_for_pyui_launch() {
    set_performance
    (
        sleep 5
        if flag_check "in_menu"; then
            set_smart
            rg552_menu_governor
        fi
        unlock_governor 2>/dev/null
    ) &
}
