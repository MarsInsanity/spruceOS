#!/bin/sh
# Anbernic RG351P device functions. Everything the base OS decides is in
# dArkMossCommon.sh; this file holds what is particular to this unit. Board,
# codec and memory behave as on the V10 (V10.sh), the pad and the motor do not.

. "/mnt/SDCARD/spruce/scripts/platform/darkmoss/dArkMossCommon.sh"

# The rk817's "Playback Path" has to be SPK_HP, as ArkOS sets it on its RK3326
# units (dArkMoss's spktoggle.sh): both outputs powered, and the kernel's jack
# detection (hp-det-gpio in rk3326-rg351p-linux.dts) mutes the speaker while
# headphones are in. On SPK the headphone output stays off: plugging in still
# muted the speaker, and the headphones got nothing (seen on hardware). Only
# written when it differs, so the many calls (boot, wake, every volume change)
# do not re-power the outputs and pop.
RG351P_PLAYBACK_PATH="SPK_HP"
apply_playback_path() {
    _path="$(amixer sget 'Playback Path' 2>/dev/null | sed -n "s/^ *Item0: '\(.*\)'$/\1/p")"
    [ "$_path" = "$RG351P_PLAYBACK_PATH" ] && return 0
    amixer -q sset 'Playback Path' "$RG351P_PLAYBACK_PATH" 2>/dev/null
    log_message "$PLATFORM: Playback Path ${_path:-unknown} -> $RG351P_PLAYBACK_PATH"
}

set_event_arg_for_idlemon() {
    EVENT_ARG="-e $EVENT_PATH_READ_INPUTS_SPRUCE"
}

# Volume is the hardware wheel, after the codec. spruce keeps everything in
# front of it at full and stores full, whatever level it is asked for: the
# setting is hidden in PyUI (rg351p.py's supports_volume) and nothing here
# steps it. "Everything" is two controls: the codec's own "Playback" and the
# softvol "Master" that all of spruce's audio goes through (dArkMossCommon's
# .asoundrc), which alsa-restore brings back at whatever level it was saved
# at: pinning only "Playback" left audio quiet with the wheel at max (seen on
# hardware). Master exists once a stream has opened it; before that the set
# fails quietly and the next call pins it.
# The one exception is a temporary mute that is not saved (sleep_helper.sh
# mutes with "set_volume 0 false" so waking to shut down is silent, then
# restores).
RG351P_VOLUME_CONTROLS="Playback Master"
set_volume() {
    if [ "$1" = "0" ] && [ "${2:-true}" = "false" ]; then
        amixer -q sset -M "${VOLUME_CONTROL:-Playback}" 0% 2>/dev/null
        log_message "$PLATFORM: codec muted (temporary)"
        return 0
    fi
    for _ctl in $RG351P_VOLUME_CONTROLS; do
        amixer -q sset -M "$_ctl" 100% 2>/dev/null
    done
    bt_headset_volume 20
    apply_playback_path
    if [ "${2:-true}" = "true" ]; then
        save_volume_to_config_file 20 2>/dev/null
    fi
}

volume_up() {
    :
}

volume_down() {
    :
}

# A real stick and a hat d-pad: nothing to swap.
swap_dpad_analog_toggle() {
    :
}

treat_dpad_as_analog() {
    :
}

treat_dpad_as_dpad() {
    :
}

device_get_charging_status() {
    if grep -qs "^1$" /sys/class/power_supply/ac/online /sys/class/power_supply/usb/online; then
        if [ "$(cat "$BATTERY/capacity" 2>/dev/null)" = "100" ]; then
            echo "Full"
        else
            echo "Charging"
        fi
    else
        echo "Discharging"
    fi
}

# As the V10: memory clock changes make the sound crackle, so pin it.
set_dram_governor() {
    [ -n "$DRAM_DEVFREQ_DIR" ] && [ -d "$DRAM_DEVFREQ_DIR" ] || return 0
    _top=$(tr ' ' '\n' < "$DRAM_DEVFREQ_DIR/available_frequencies" 2>/dev/null | grep -v '^$' | sort -n | tail -1)
    [ -n "$_top" ] || return 0
    echo userspace > "$DRAM_DEVFREQ_DIR/governor" 2>/dev/null
    echo "$_top" > "$DRAM_DEVFREQ_DIR/userspace/set_freq" 2>/dev/null
    echo "$_top" > "$DRAM_DEVFREQ_DIR/min_freq" 2>/dev/null
}

# The motor hangs off pwm0 (GPIO0_B7) and runs while the pin is high (the
# V10's dtb, holding that pin high, left it running nonstop). It is not a
# force-feedback device on the pad, so darkmoss_vibrate's rumble tool has
# nothing to talk to: drive the PWM through sysfs.
#
# Polarity has to be set to "normal" first. The 4.4 Rockchip driver reports
# the reset register's polarity, "inversed", for a PWM nothing has claimed, and
# inversed, duty 0 is high all the time and even a disabled PWM idles high:
# that left the motor running nonstop after the first buzz (seen on hardware,
# from the Game Switcher's hold vibration). Polarity can only be changed while
# the PWM is disabled. Normal, both "duty 0" and "disabled" are low.
RG351P_PWM_PERIOD=1000000
_rg351p_pwm() {
    _chip="${RG351P_PWM_CHIP:-/sys/class/pwm/pwmchip0}"
    [ -d "$_chip" ] || return 1
    [ -d "$_chip/pwm0" ] || echo 0 2>/dev/null > "$_chip/export"
    [ -d "$_chip/pwm0" ] || return 1
    echo "$_chip/pwm0"
}

_rg351p_motor_off() {
    echo 0 2>/dev/null > "$1/duty_cycle"
    echo 0 2>/dev/null > "$1/enable"
}

vibrate() {
    duration=""
    intensity="$(get_config_value '.menuOptions."System Settings".rumbleIntensity.selected' "Medium")"
    while [ $# -gt 0 ]; do
        case "$1" in
        --intensity) shift; intensity="$1" ;;
        [0-9]*) duration="$1" ;;
        esac
        shift
    done

    case "$intensity" in
        "Off")    return 0 ;;
        "Weak")   duty=$((RG351P_PWM_PERIOD * 6 / 10)); tier_duration=200 ;;
        "Strong") duty=$RG351P_PWM_PERIOD;              tier_duration=450 ;;
        *)        duty=$((RG351P_PWM_PERIOD * 8 / 10)); tier_duration=300 ;;
    esac
    [ -n "$duration" ] || duration="$tier_duration"

    _pwm="$(_rg351p_pwm)" || return 0
    echo 0 2>/dev/null > "$_pwm/enable"
    echo normal 2>/dev/null > "$_pwm/polarity"
    if [ "$(cat "$_pwm/polarity" 2>/dev/null)" != "normal" ]; then
        # Never drive a motor whose off level is unknown.
        log_message "$PLATFORM: pwm0 polarity is not normal, no vibration"
        _rg351p_motor_off "$_pwm"
        return 0
    fi
    # period before duty_cycle: the kernel refuses a duty longer than the period.
    echo "$RG351P_PWM_PERIOD" 2>/dev/null > "$_pwm/period"
    echo "$duty" 2>/dev/null > "$_pwm/duty_cycle"
    echo 1 2>/dev/null > "$_pwm/enable"
    sleep "$(awk -v ms="$duration" 'BEGIN { printf "%.3f", ms / 1000 }')"
    _rg351p_motor_off "$_pwm"
}

# RetroArch's udev numbering of this pad (RG351P.cfg): Select 22, B 16, X 17,
# Y 18, L1 19, R1 20, R2 26.
set_default_ra_hotkeys() {
    RA_FILE="/mnt/SDCARD/Saves/ra-configs/retroarch-$PLATFORM.cfg"

    log_message "Resetting RetroArch hotkeys to Spruce defaults."

    update_ra_config_file_with_new_setting "$RA_FILE" \
        "input_enable_hotkey_btn = \"22\"" \
        "input_exit_emulator_btn = \"16\"" \
        "input_fps_toggle_btn = \"17\"" \
        "input_load_state_btn = \"19\"" \
        "input_save_state_btn = \"20\"" \
        "input_menu_toggle = \"f1\"" \
        "input_menu_toggle_btn = \"18\"" \
        "input_quit_gamepad_combo = \"0\"" \
        "input_toggle_fast_forward_btn = \"26\"" \
        "input_screenshot_btn = \"nul\"" \
        "input_shader_toggle_btn = \"nul\"" \
        "input_state_slot_decrease_btn = \"nul\"" \
        "input_state_slot_increase_btn = \"nul\"" \
        "input_toggle_slowmotion_btn = \"nul\""
}
