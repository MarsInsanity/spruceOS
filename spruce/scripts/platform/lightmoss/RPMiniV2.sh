#!/bin/sh
# Retroid Pocket Mini V2 device functions, on LightMoss. The base behaves as
# dArkMoss does (systemctl, nmcli, the softvol "Master" over hw:0,0, the
# "ssh" unit), so dArkMossCommon.sh provides nearly everything; this replaces
# what is RK3326/RK3566 about it.

. "/mnt/SDCARD/spruce/scripts/platform/darkmoss/dArkMossCommon.sh"

# dArkMossCommon's, without what belongs to Rockchip boards: no rk817 PMIC
# clean-up (it writes I2C bus 0, address 0x20, which is something else here)
# and no dArkMoss debug dump.
device_init() {
    resolve_pad_node
    log_message "$PLATFORM: spruce is ${SD_DEV:-<unresolved>} at $SD_MOUNTPOINT"
    resolve_key_event_node
    setup_mainui_alias
    if [ -n "$DARKMOSS_SEED_SYSTEM_JSON" ] && [ ! -f "$SYSTEM_JSON" ] && [ -f "$SYSTEM_JSON_DEFAULT" ]; then
        cp "$SYSTEM_JSON_DEFAULT" "$SYSTEM_JSON"
    fi
    set_backlight "$(get_backlight_level)"
    darkmoss_wifi_up
    # A few times over the first seconds: LightMoss's audio service may still be
    # running ROCKNIX's UCM boot sequence, which sets the gain this undoes.
    ( for _t in 0 3 5 10; do sleep "$_t"; lightmoss_speaker_gain; done ) &
}

# The speakers' digital gain (WSA_RX0/RX1 Digital Volume) at 0 dB. ROCKNIX's UCM
# boots it at +36 dB for PipeWire's software volume to bring down; spruce's
# softvol "Master" starts at full level, so the first sounds were painfully loud.
# LightMoss does this itself from 62af605; this covers the images before it.
lightmoss_speaker_gain() {
    for _c in /proc/asound/card[0-9]*; do
        case "$(cat "$_c/id" 2>/dev/null)" in
            RetroidPocket*)
                for _e in "WSA_RX0 Digital" "WSA_RX1 Digital"; do
                    amixer -q -c "${_c##*/card}" sset "$_e" 0dB 2>/dev/null
                done
                ;;
        esac
    done
}

# LightMoss updates itself; there is no dArkMoss firmware for this device.
check_if_fw_needs_update() {
    echo "false"
}

local_fw_update_file() {
    return 1
}

device_get_fw_version() {
    sed -n 's/^LIGHTMOSS_VERSION="\(.*\)"/\1/p' /etc/os-release 2>/dev/null
}

# LightMoss's lightmoss-audio routes hw:0,0 to the headphones or the speakers
# by the jack itself: no codec path for spruce to set.
apply_playback_path() {
    :
}

# The battery's own status; the charger's "online" is the USB/Mains supply's.
device_get_charging_status() {
    cat "$BATTERY/status" 2>/dev/null
}

device_low_battery_shutdown_ok() {
    for _ps in /sys/class/power_supply/*; do
        [ "$(cat "$_ps/type" 2>/dev/null)" = "Battery" ] && continue
        if [ "$(cat "$_ps/online" 2>/dev/null)" = "1" ]; then
            log_message "$PLATFORM battery: charger online, not forcing a shutdown"
            return 1
        fi
    done
}

# AMOLED: no bl_power to switch on, the DCS brightness is all there is.
apply_backlight() {
    level="$1"
    [ "$level" -lt 0 ] && level=0
    [ "$level" -gt 10 ] && level=10
    eval "raw=\$SYSTEM_BACKLIGHT_LEVEL_$level"
    [ -n "$DEVICE_BACKLIGHT_PATH" ] && echo "$raw" > "$DEVICE_BACKLIGHT_PATH"
}

device_exit_sleep() {
    darkmoss_exit_sleep
    apply_backlight "$(get_backlight_level)"
}

# spruce's idle timers count the pad's events as activity only when told its node.
set_event_arg_for_idlemon() {
    EVENT_ARG="-e $EVENT_PATH_READ_INPUTS_SPRUCE"
}

# The kmsgrab capture is the panel's raw scanout: portrait, the picture
# turned by the plane. Turn it back for the Game Switcher. UNVERIFIED which way.
take_screenshot() {
    screenshot_path="$1"
    [ -n "$screenshot_path" ] || return 1
    _ff=""
    for _c in /mnt/SDCARD/spruce/bin/ffmpeg /usr/bin/ffmpeg; do
        [ -x "$_c" ] && { _ff="$_c"; break; }
    done
    [ -n "$_ff" ] || { log_message "take_screenshot: no ffmpeg with kmsgrab available"; return 1; }
    mkdir -p "$(dirname "$screenshot_path")" 2>/dev/null
    if timeout 15 "$_ff" -hide_banner -loglevel error -f kmsgrab -i - \
        -vf "hwdownload,format=bgr0,format=rgba,transpose=2" \
        -frames:v 1 -update 1 -y "$screenshot_path" >/dev/null 2>&1; then
        return 0
    fi
    rm -f "$screenshot_path" 2>/dev/null
    log_message "take_screenshot: kmsgrab capture failed"
    return 1
}

  ########################
#####   CPU AND GPU   #####
  ########################

# The common CPU functions write cpu0 and cpu4 with one set of frequencies;
# the SM8250 has three clusters with their own (policy0, policy4, policy7).
# Each mode sets every policy from its own cpuinfo limits.
lightmoss_policies() {
    for _p in /sys/devices/system/cpu/cpufreq/policy*; do
        [ -d "$_p" ] && echo "$_p"
    done
}

# lightmoss_set_policies GOVERNOR MAX_PERCENT [MIN=max]
lightmoss_set_policies() {
    for _p in $(lightmoss_policies); do
        _lo="$(cat "$_p/cpuinfo_min_freq")"; _hi="$(cat "$_p/cpuinfo_max_freq")"
        _max=$(( _hi * $2 / 100 ))
        [ "$_max" -lt "$_lo" ] && _max="$_lo"
        if [ "$3" = "max" ]; then _min="$_max"; else _min="$_lo"; fi
        chmod a+w "$_p/scaling_governor" "$_p/scaling_min_freq" "$_p/scaling_max_freq" 2>/dev/null
        echo "$1" > "$_p/scaling_governor" 2>/dev/null
        # The floor down first, so the new top is never below the old floor.
        echo "$_lo" > "$_p/scaling_min_freq" 2>/dev/null
        echo "$_max" > "$_p/scaling_max_freq" 2>/dev/null
        echo "$_min" > "$_p/scaling_min_freq" 2>/dev/null
        chmod a-w "$_p/scaling_governor" "$_p/scaling_min_freq" "$_p/scaling_max_freq" 2>/dev/null
    done
}

lightmoss_set_gpu() {
    [ -d "$GPU_GOVENOR_DIR" ] || return 0
    _top="$(tr ' ' '\n' < "$GPU_GOVENOR_DIR/available_frequencies" 2>/dev/null | sort -n | tail -n 1)"
    [ -n "$_top" ] && echo "$_top" > "$GPU_GOVENOR_DIR/max_freq" 2>/dev/null
    echo "$1" > "$GPU_GOVENOR_DIR/governor" 2>/dev/null
}

set_powersave() {
    flag_check "setting_cpu" && return 0
    flag_add "setting_cpu" --tmp
    cores_online "$DEVICE_MIN_CORES_ONLINE"
    lightmoss_set_policies "${CPU_SMART_GOVENOR:-schedutil}" "${LIGHTMOSS_POWERSAVE_PERCENT:-60}"
    lightmoss_set_gpu "$GPU_SMART_GOVERNOR"
    log_message "CPU locked to POWERSAVE: cores $DEVICE_MIN_CORES_ONLINE, ${LIGHTMOSS_POWERSAVE_PERCENT:-60}% of each cluster's top speed"
    flag_remove "setting_cpu"
}

set_smart() {
    flag_check "setting_cpu" && return 0
    flag_add "setting_cpu" --tmp
    cores_online "$CPU_SMART_CORES_ONLINE"
    lightmoss_set_policies "${CPU_SMART_GOVENOR:-schedutil}" 100
    lightmoss_set_gpu "$GPU_SMART_GOVERNOR"
    log_message "CPU Mode now locked to SMART: cores $CPU_SMART_CORES_ONLINE, ${CPU_SMART_GOVENOR:-schedutil} over each cluster's range"
    flag_remove "setting_cpu"
}

set_performance() {
    flag_check "setting_cpu" && return 0
    flag_add "setting_cpu" --tmp
    cores_online "$DEVICE_MAX_CORES_ONLINE" "$1"
    lightmoss_set_policies performance 100 max
    lightmoss_set_gpu "$GPU_PERFORMANCE_GOVERNOR"
    log_message "CPU Mode now locked to PERFORMANCE: cores $DEVICE_MAX_CORES_ONLINE at each cluster's top speed"
    flag_remove "setting_cpu"
}

# No overclock on this SoC: the top speeds are the top speeds.
set_overclock() {
    set_performance "$@"
}
