#!/bin/sh
# Retroid Pocket Mini V2 device functions, on LightMoss. The base behaves as
# dArkMoss does (systemctl, nmcli, the softvol "Master" over hw:0,0, the
# "ssh" unit), so dArkMossCommon.sh provides nearly everything; this replaces
# what is RK3326/RK3566 about it.

. "/mnt/SDCARD/spruce/scripts/platform/darkmoss/dArkMossCommon.sh"
. "/mnt/SDCARD/spruce/scripts/platform/lightmoss/rpminiv2_leds.sh"

# dArkMossCommon's, without what belongs to Rockchip boards: no rk817 PMIC
# clean-up (it writes I2C bus 0, address 0x20, which is something else here)
# and no dArkMoss debug dump.
device_init() {
    lightmoss_pad_is_a_joystick
    resolve_pad_node
    log_message "$PLATFORM: spruce is ${SD_DEV:-<unresolved>} at $SD_MOUNTPOINT"
    resolve_key_event_node
    setup_mainui_alias
    if [ -n "$DARKMOSS_SEED_SYSTEM_JSON" ] && [ ! -f "$SYSTEM_JSON" ] && [ -f "$SYSTEM_JSON_DEFAULT" ]; then
        cp "$SYSTEM_JSON_DEFAULT" "$SYSTEM_JSON"
    fi
    set_backlight "$(get_backlight_level)"
    darkmoss_wifi_up
    # The ALSA config: runtime.sh removes $HOME/.asoundrc before device_init, and
    # on dArkMoss bluetooth.sh boot writes it again (asound-setup.sh, also with
    # Bluetooth unsupported). Without it PyUI played to hw:0,0 directly, past the
    # softvol "Master" spruce's volume works on: always full volume. Written here
    # first so it is there before PyUI opens its audio, then bluetooth.sh boot as
    # dArkMossCommon's device_init runs it.
    /mnt/SDCARD/spruce/scripts/asound-setup.sh "$HOME" >/dev/null 2>&1
    # alsa-lib creates softvol's "Master" (at full level) when PyUI opens its
    # audio, and PyUI applies the saved volume right after, before any sound.
    # No priming: nothing needs to play before PyUI does.
    /mnt/SDCARD/spruce/scripts/bluetooth.sh boot &
    # A few times over the first seconds: LightMoss's audio service may still be
    # running ROCKNIX's UCM boot sequence, which sets the gain this undoes.
    ( for _t in 0 3 5 10; do sleep "$_t"; lightmoss_speaker_gain; done ) &
}

# softvol "Master" straight on hw:0,0 (the DSP's MultiMedia1 stream), without
# dArkMoss's dmix. On the device every session with dmix in the path had PyUI
# hang on its way out to a game: it closed its window (tty1 showed through)
# and never exited, so spruce never started the game. The one session with no
# ALSA config from spruce at all handed over normally. A dmix stream on the
# q6asm PCM that stops advancing would leave SDL's audio thread blocked, and
# closing the audio device waits for that thread. Without dmix one program
# plays at a time: a second gets EBUSY instead of mixing in, and PyUI closes
# its audio before a game starts.
device_write_default_asound_rc() {
    # spruce_menu: the menu's own output (PYUI_AUDIODEV, and bt_audio_device
    # below), its sounds LIGHTMOSS_MENU_SOUND_DB down before softvol. Everything
    # else - Songo, ports, aplay - plays to the default, spruce_speaker.
    _g="$(awk -v db="${LIGHTMOSS_MENU_SOUND_DB:-0}" 'BEGIN { printf "%.4f", 10 ^ (db / 20) }')"
    cat > "$ASOUND_CONF" <<ASOUND
pcm.spruce_speaker {
    type        plug
    slave.pcm   "softvol"
}

pcm.spruce_menu {
    type        plug
    slave.pcm   "spruce_menu_level"
}

pcm.spruce_menu_level {
    type        route
    slave.pcm   "softvol"
    slave.channels 2
    ttable.0.0  $_g
    ttable.1.1  $_g
}

ctl.!default {
    type        hw
    card        0
}

pcm.softvol {
    type        softvol
    slave.pcm   "hw:0,0"
    control {
        name    "Master"
        card    0
    }
}
ASOUND
}

# PyUI asks this (get-bt-audio-device.sh) which ALSA device to play to and
# sets AUDIODEV to it: a USB card or Bluetooth headset as on every board, and
# for the speakers spruce_menu rather than spruce_speaker, so the menu's own
# sounds stay turned down when it changes route.
bt_audio_device() {
    if usb_audio_read_route; then
        # shellcheck disable=SC2086 # card, device and usbbus, split on purpose
        set -- $usb_routed
        echo "plughw:$1,$2"
        return 0
    fi
    grep -q "^pcm.spruce_bt" "$HOME/.asoundrc" 2>/dev/null || return 0
    if bt_audio_ready && bt_connected_audio_mac >/dev/null; then
        echo spruce_bt
    else
        echo spruce_menu
    fi
}

# The pad reports BTN_BACK (0x116) besides its gamepad buttons, and that code
# is in the mouse button range (BTN_MOUSE..BTN_JOYSTICK): udev's input_id then
# takes a device with ABS_X/ABS_Y and a mouse button for an absolute mouse
# (the VMware USB mouse case) and never tags it ID_INPUT_JOYSTICK. RetroArch's
# udev joypad driver, and SDL in ports and standalone emulators, only look at
# joysticks: on the device RetroArch listed the pad as "Mouse/Touch" and no
# control worked in a game. A runtime rule after 60-input-id.rules says what it
# is, and a change event applies it now. LightMoss ships the same rule from its
# next image; this covers the ones before.
lightmoss_pad_is_a_joystick() {
    _rules=/run/udev/rules.d/61-lightmoss-retroid-pad.rules
    command -v udevadm >/dev/null 2>&1 || return 0
    [ -e /usr/lib/udev/rules.d/61-lightmoss-retroid-pad.rules ] && return 0
    if [ ! -f "$_rules" ]; then
        mkdir -p /run/udev/rules.d
        cat > "$_rules" <<'RULES'
# Written by spruce (RPMiniV2.sh). The Retroid pad's BTN_BACK sits in the mouse
# button range, so input_id calls it an absolute mouse: it is a gamepad.
ACTION!="remove", SUBSYSTEM=="input", ATTRS{name}=="Retroid Pocket Gamepad", ENV{ID_INPUT_MOUSE}="", ENV{ID_INPUT_JOYSTICK}="1"
RULES
        udevadm control --reload >/dev/null 2>&1
    fi
    udevadm trigger --action=change --subsystem-match=input >/dev/null 2>&1
    udevadm settle --timeout=3 >/dev/null 2>&1
    for _d in /sys/class/input/event*; do
        [ "$(cat "$_d/device/name" 2>/dev/null)" = "Retroid Pocket Gamepad" ] || continue
        if udevadm info -q property -p "$_d" 2>/dev/null | grep -q '^ID_INPUT_JOYSTICK=1$'; then
            log_message "$PLATFORM: pad ${_d##*/} tagged as a joystick for udev"
        else
            log_message "$PLATFORM: pad ${_d##*/} is still not a joystick for udev"
        fi
    done
}

# The speakers' digital gain (WSA_RX0/RX1 Digital Volume) at
# LIGHTMOSS_SPEAKER_GAIN_DB: control value 84 + dB on its 0..124 scale
# (-84..+40 dB). ROCKNIX's UCM boots it at 120, +36 dB, for PipeWire's software
# volume to bring down; under spruce only softvol "Master" is in front of it,
# and full-scale menu sounds clipped, painfully loud. The codec's soft
# clippers stay off: with them on and +6 dB, music pumped on the device.
# LightMoss sets 0 dB itself from 62af605; this covers the images before it.
# It runs at boot and on every volume change (apply_playback_path), and logs
# whenever it finds the gain anywhere else, so a log shows what moved it.
lightmoss_speaker_gain() {
    _want=$((84 + ${LIGHTMOSS_SPEAKER_GAIN_DB:-0}))
    for _c in /proc/asound/card[0-9]*; do
        case "$(cat "$_c/id" 2>/dev/null)" in
            RetroidPocket*) ;;
            *) continue ;;
        esac
        _n="${_c##*/card}"
        for _e in "WSA_RX0 Digital Volume" "WSA_RX1 Digital Volume"; do
            _v="$(amixer -c "$_n" cget name="$_e" 2>/dev/null | sed -n 's/.*: values=\([0-9]*\).*/\1/p')"
            case "$_v" in
                "$_want") continue ;;
                "") log_message "$PLATFORM: could not read $_e"; continue ;;
            esac
            if amixer -q -c "$_n" cset name="$_e" "$_want" 2>/dev/null; then
                log_message "$PLATFORM: $_e was $((_v - 84)) dB, set to $((_want - 84)) dB"
            else
                log_message "$PLATFORM: $_e is $((_v - 84)) dB and could not be set to $((_want - 84)) dB"
            fi
        done
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
# by the jack itself: no codec path for spruce to set. set_volume calls this
# on every change, which makes it the place to keep the speakers' gain right.
apply_playback_path() {
    lightmoss_speaker_gain
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
    # On the device two Game Switcher screenshots outlived timeout's SIGTERM by
    # minutes, the game left running behind them. Under LightMoss spruce's
    # stdin is tty1, and an ffmpeg that sets up the terminal from outside its
    # foreground group is stopped (SIGTTOU), where SIGTERM does nothing: so
    # -nostdin and </dev/null, and SIGKILL for one that hangs anyway.
    if timeout -s KILL 15 "$_ff" -nostdin -hide_banner -loglevel error -f kmsgrab -i - \
        -vf "hwdownload,format=bgr0,format=rgba,transpose=2" \
        -frames:v 1 -update 1 -y "$screenshot_path" </dev/null >/dev/null 2>&1; then
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
