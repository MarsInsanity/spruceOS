#!/bin/sh
# Retroid Pocket Mini V2 device functions, on LightMoss. The base behaves as
# dArkMoss does (systemctl, nmcli, the softvol "Master" over hw:0,0, the
# "ssh" unit), so dArkMossCommon.sh provides nearly everything; this replaces
# what is RK3326/RK3566 about it.

. "/mnt/SDCARD/spruce/scripts/platform/darkmoss/dArkMossCommon.sh"
. "/mnt/SDCARD/spruce/scripts/platform/lightmoss/rpminiv2_retroarch.sh"

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
    lightmoss_wait_for_audio
    /mnt/SDCARD/spruce/scripts/asound-setup.sh "$HOME" >/dev/null 2>&1
    # alsa-lib creates softvol's "Master" (at full level) when PyUI opens its
    # audio, and PyUI applies the saved volume right after, before any sound.
    # No priming: nothing needs to play before PyUI does.
    /mnt/SDCARD/spruce/scripts/bluetooth.sh boot &
    lightmoss_speaker_gain
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
#
# The card by its id rather than as card 0: snd-usb-audio is built into the
# kernel and the SoC card only registers once the audio DSP is up, so a USB
# DAC or headset attached at boot takes index 0, and Master and the output
# would go to it (and nowhere once it is unplugged).
device_write_default_asound_rc() {
    # spruce_menu: the menu's own output (PYUI_AUDIODEV, and bt_audio_device
    # below), its sounds LIGHTMOSS_MENU_SOUND_DB down before softvol. Everything
    # else - Songo, ports, aplay - plays to the default, spruce_speaker.
    _g="$(awk -v db="${LIGHTMOSS_MENU_SOUND_DB:-0}" 'BEGIN { printf "%.4f", 10 ^ (db / 20) }')"
    _card="$(lightmoss_card_id)"
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
    card        $_card
}

pcm.softvol {
    type        softvol
    slave.pcm   "hw:$_card,0"
    control {
        name    "Master"
        card    $_card
    }
}
ASOUND
}

# The SoC sound card's id (RetroidPocket), or 0 if it is not there.
lightmoss_card_id() {
    for _c in /proc/asound/card[0-9]*; do
        _id="$(cat "$_c/id" 2>/dev/null)"
        case "$_id" in
            RetroidPocket*) echo "$_id"; return 0 ;;
        esac
    done
    echo 0
}

# Every program spruce starts with its own HOME gets this config as
# $HOME/.asoundrc from asound-setup.sh; one started some other way (a port or
# app that sets HOME itself, a shell) would play to the bare card, past
# Master and the volume keys. LightMoss reads /run/lightmoss/asound.conf as
# its system-wide config (/etc/asound.conf links to it), so asound-setup.sh
# leaves its finished file there too: copied whole and renamed into place, so
# no program reads half of it. Loaded twice when HOME has the same file, which
# alsa-lib merges to the same thing.
lightmoss_publish_asound_rc() {
    [ -d /run/lightmoss ] && [ -f "$ASOUND_CONF" ] || return 0
    # Only a finished file: asound-setup.sh names the default last.
    tail -n 1 "$ASOUND_CONF" | grep -q '^pcm\.!default' || return 0
    cp "$ASOUND_CONF" "/run/lightmoss/asound.conf.$$" 2>/dev/null &&
        mv -f "/run/lightmoss/asound.conf.$$" /run/lightmoss/asound.conf
    rm -f "/run/lightmoss/asound.conf.$$" 2>/dev/null
}

# LightMoss sets the card up and routes hw:0,0 before it starts spruce, once
# lightmoss-audio is a oneshot. Its earlier images start spruce while the card
# is still being set up: wait for the route (its state file), up to 5 s, so
# PyUI does not open hw:0,0 unrouted and the card is there to be named in the
# ALSA config. Immediate on the newer images.
lightmoss_wait_for_audio() {
    [ -x /usr/libexec/lightmoss/audio ] || return 0
    _n=0
    while [ ! -e /run/lightmoss/headphones ] && [ "$_n" -lt 25 ]; do
        sleep 0.2
        _n=$((_n + 1))
    done
    [ -e /run/lightmoss/headphones ] ||
        log_message "$PLATFORM: LightMoss's sound card is not set up after 5 s"
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

# The event node whose device has exactly the name $1, or nothing.
lightmoss_input_node() {
    for _d in /sys/class/input/event*; do
        [ "$(cat "$_d/device/name" 2>/dev/null)" = "$1" ] && { echo "/dev/input/${_d##*/}"; return 0; }
    done
    return 1
}

# The same, waiting up to $2 tenths of a second for it to appear.
lightmoss_wait_input_node() {
    _w=0
    until lightmoss_input_node "$1"; do
        [ "$_w" -ge "$2" ] && return 1
        sleep 0.1
        _w=$((_w + 1))
    done
}

# The nodes by name, not by number: event numbers change between boots (on one
# the gpio-keys and touchscreen nodes swapped), and the pad (the retroid module)
# and the volume keys (LightMoss's uinput daemon) register around the time spruce
# starts, so each gets a few seconds to appear. Without a pad dArkMoss's resolver
# left event0 (the haptics) and every control was dead.
resolve_pad_node() {
    _pad=""
    _old_ifs="$IFS"; IFS='|'
    # shellcheck disable=SC2086 # split on | on purpose
    set -- $PAD_NAME_CANDIDATES
    IFS="$_old_ifs"
    _w=0
    while [ "$#" -gt 0 ]; do
        for _name in "$@"; do
            _pad="$(lightmoss_input_node "$_name")" && break
        done
        [ -n "$_pad" ] && break
        [ "$_w" -ge 50 ] && break
        sleep 0.1
        _w=$((_w + 1))
    done
    if [ -n "$_pad" ]; then
        export EVENT_PATH_READ_INPUTS_SPRUCE="$_pad"
        export EVENT_PATH_SEND_TO_RA_AND_PPSSPP="$_pad"
        export EVENT_PATH_SEND_TO_DRASTIC="$_pad"
        log_message "$PLATFORM: joypad at $_pad"
    else
        log_message "$PLATFORM: no joypad node found after 5 s - controls will be dead"
    fi
}

# The volume keys are LightMoss's "LightMoss Volume Keys" (its daemon merges
# gpio-keys' Volume Up and the PMIC's Volume Down). dArkMoss's resolver took the
# first node declaring both keys, and the sound card's "RetroidPocket Headset
# Jack" declares both too (its buttons 2 and 3): it registered only about 0.2 s
# after LightMoss's node on every logged boot, and the first to register won.
# Power is pm8941_pwrkey. The name decides; the capability scan, without the
# jack, the pad and anything else named "...Jack", is only the fallback.
resolve_key_event_node() {
    _seen=""
    for _d in /sys/class/input/event*; do
        [ -e "$_d" ] && _seen="$_seen ${_d##*/}:$(cat "$_d/device/name" 2>/dev/null)"
    done
    log_message "$PLATFORM: input nodes:$_seen"

    _power="$(lightmoss_input_node pm8941_pwrkey)"
    _volume=""
    if [ -x /usr/sbin/lightmoss-volkeys ]; then
        _volume="$(lightmoss_wait_input_node "LightMoss Volume Keys" 30)" ||
            log_message "$PLATFORM: no LightMoss Volume Keys node after 3 s"
    fi
    for _d in /sys/class/input/event*; do
        [ -e "$_d" ] || continue
        _ev="${_d##*/}"
        _name="$(cat "$_d/device/name" 2>/dev/null)"
        [ -z "$_power" ] && case "$_name" in *pwrkey*) _power="/dev/input/$_ev" ;; esac
        [ -n "$_volume" ] && continue
        [ "/dev/input/$_ev" = "$EVENT_PATH_READ_INPUTS_SPRUCE" ] && continue
        case "$_name" in *Jack) continue ;; esac
        node_reports_volume_keys "$_ev" && _volume="/dev/input/$_ev"
    done

    if [ -n "$_power" ] && [ -c "$_power" ]; then
        export EVENT_PATH_POWER="$_power"
        log_message "$PLATFORM: power key on $_power"
    fi
    if [ -n "$_volume" ] && [ -c "$_volume" ]; then
        export EVENT_PATH_VOLUME="$_volume"
        log_message "$PLATFORM: volume keys on $_volume"
    else
        log_message "$PLATFORM: no node reports the volume keys - leaving $EVENT_PATH_VOLUME"
    fi
    export VOLUME_KEYS_ON_PAD=0

    {
        echo "EVENT_PATH_READ_INPUTS_SPRUCE='${EVENT_PATH_READ_INPUTS_SPRUCE}'"
        echo "EVENT_PATH_SEND_TO_RA_AND_PPSSPP='${EVENT_PATH_READ_INPUTS_SPRUCE}'"
        echo "EVENT_PATH_SEND_TO_DRASTIC='${EVENT_PATH_READ_INPUTS_SPRUCE}'"
        echo "EVENT_PATH_VOLUME='${EVENT_PATH_VOLUME}'"
        echo "EVENT_PATH_POWER='${EVENT_PATH_POWER}'"
        echo "VOLUME_KEYS_ON_PAD='${VOLUME_KEYS_ON_PAD}'"
    } > "$SPRUCE_INPUT_NODES_FILE" 2>/dev/null
}

# The speakers' digital gain (WSA_RX0/RX1 Digital Volume) at
# LIGHTMOSS_SPEAKER_GAIN_DB: control value 84 + dB on its 0..124 scale
# (-84..+40 dB). ROCKNIX's UCM boots it at 120, +36 dB, for PipeWire's software
# volume to bring down; under spruce only softvol "Master" is in front of it,
# and full-scale menu sounds clipped, painfully loud. The codec's soft
# clippers stay off: with them on and +6 dB, music pumped on the device.
# LightMoss sets 0 dB itself from 62af605; this covers the images before it.
# It runs at boot, once the card is set up (lightmoss_wait_for_audio), and on
# every volume change (apply_playback_path), and logs whenever it finds the
# gain anywhere else, so a log shows what moved it.
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
# by the jack itself (and writes HEADPHONE_STATE_PATH): no codec path for
# spruce to set. set_volume calls this on every change, which makes it the
# place to keep the speakers' gain right.
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

# Idle on the charger (idlemon_chargingAction.sh): the AMOLED dark rather than
# a menu left lit for hours. DCS brightness 0 is the darkest the panel goes
# without a DPMS off, which only the DRM master can ask for.
turn_off_screen() {
    [ -n "$DEVICE_BACKLIGHT_PATH" ] && echo 0 > "$DEVICE_BACKLIGHT_PATH" 2>/dev/null
}

turn_on_screen() {
    apply_backlight "$(get_backlight_level)"
}

# spruce's idle timers count the pad as activity: its js node, which has the
# buttons and sticks but not the rumble emulators write to its event node
# (EV_FF goes to every reader of the event node), so a game that keeps
# rumbling does not hold off the idle actions.
set_event_arg_for_idlemon() {
    set_idlemon_to_pad
}

# SSH is spruce's own dropbear (dropbearmulti, as on spruce's other 64-bit
# devices), not LightMoss's "ssh" unit: the toggle starts and stops the
# daemon by unit name but tells whether it runs with pgrep of the same name,
# and LightMoss's unit runs a process called dropbear, so "SSH off" never
# stopped it. dropbearmulti matches itself, keeps its host keys on the card
# (they survive a LightMoss update or reinstall) and serves SFTP.
get_ssh_service_name() {
    echo "dropbearmulti"
}

# The darkmoss_force_ssh flag (bring-up, no settings screen needed) still
# starts LightMoss's own unit, unless the setting has spruce's on port 22.
darkmoss_ssh_up() {
    [ -e /mnt/SDCARD/spruce/flags/darkmoss_force_ssh ] || return 0
    command -v systemctl >/dev/null 2>&1 || return 0
    [ "$(get_config_value '.menuOptions."Network Settings".enableSSH.selected' "False")" = "True" ] && return 0
    systemctl is-active --quiet ssh 2>/dev/null && return 0
    if systemctl start ssh >/dev/null 2>&1; then
        log_message "$PLATFORM: started LightMoss's ssh unit (darkmoss_force_ssh)"
    else
        log_message "$PLATFORM: could not start LightMoss's ssh unit"
    fi
}

# Screenshots. RetroArch makes its own. The Game Switcher shows the thumbnail
# RetroArch writes with its auto save state on the way out
# (savestate_thumbnail_enable; PyUI looks there before .gameswitcher), and the
# Screenshot action asks it through its command port (it saves to
# Saves/screenshots). On the device kmsgrab never returned while RetroArch's
# frame was on the plane: SIGKILL after 15 s, the game left running all that
# time and a second press started a second Game Switcher (cause UNVERIFIED).
#
# Anything else is kmsgrab's. It reads the plane's framebuffer, which is the
# program's own buffer, not the SDE rotator's turned copy: SDL programs
# (LightMoss's SDL turns the panel with the plane) draw 1240x1080 upright;
# PyUI, with its own SDL, draws 1080x1240, its picture turned 90 degrees
# clockwise (SCREEN_ROTATION). Only a portrait frame is turned back.
take_screenshot() {
    screenshot_path="$1"
    [ -n "$screenshot_path" ] || return 1
    if pidof ra64.universal ra32.universal retroarch >/dev/null 2>&1; then
        case "$screenshot_path" in
            */.gameswitcher/*)
                log_message "take_screenshot: RetroArch's own save state thumbnail serves the Game Switcher"
                return 1
                ;;
        esac
        if echo "SCREENSHOT" | /usr/bin/nc -u -w1 127.0.0.1 55355 >/dev/null 2>&1; then
            log_message "take_screenshot: asked RetroArch for a screenshot"
            return 0
        fi
    fi
    _ff=""
    for _c in /mnt/SDCARD/spruce/bin/ffmpeg /usr/bin/ffmpeg; do
        [ -x "$_c" ] && { _ff="$_c"; break; }
    done
    [ -n "$_ff" ] || { log_message "take_screenshot: no ffmpeg with kmsgrab available"; return 1; }
    mkdir -p "$(dirname "$screenshot_path")" 2>/dev/null
    _err="/tmp/rpminiv2_screenshot.err"
    # On the device two Game Switcher screenshots outlived timeout's SIGTERM by
    # minutes, the game left running behind them. Under LightMoss spruce's
    # stdin is tty1, and an ffmpeg that sets up the terminal from outside its
    # foreground group is stopped (SIGTTOU), where SIGTERM does nothing: so
    # -nostdin and </dev/null, and SIGKILL for one that hangs anyway. Its
    # complaints go to the log, so the next failure says why.
    timeout -s KILL "${LIGHTMOSS_SCREENSHOT_TIMEOUT:-5}" "$_ff" -nostdin -hide_banner -loglevel warning \
        -f kmsgrab -i - \
        -vf "hwdownload,format=bgr0,format=rgba,transpose=dir=cclock:passthrough=landscape" \
        -frames:v 1 -update 1 -y "$screenshot_path" </dev/null >/dev/null 2>"$_err"
    _rc=$?
    if [ "$_rc" -eq 0 ] && [ -s "$screenshot_path" ]; then
        rm -f "$_err"
        return 0
    fi
    rm -f "$screenshot_path" 2>/dev/null
    case "$_rc" in
        124|137) _why="no frame within ${LIGHTMOSS_SCREENSHOT_TIMEOUT:-5} s" ;;
        *) _why="exit $_rc" ;;
    esac
    log_message "take_screenshot: kmsgrab capture failed ($_why): $(tail -n 3 "$_err" 2>/dev/null | tr '\n' ' ')"
    rm -f "$_err"
    # A quick failure, not a hang: spruce/bin's ffmpeg is a 32-bit build, so
    # try spruce's 64-bit kmsgrab (GETFB and mmap, no DMA-BUF sync; it needs
    # LightMoss's libpng and libdrm), then turn a portrait PNG as above.
    case "$_rc" in 124|137) return 1 ;; esac
    _raw="/tmp/rpminiv2_screenshot_raw.png"
    if [ -x /mnt/SDCARD/spruce/bin64/kmsgrab ] &&
        timeout -s KILL 3 /mnt/SDCARD/spruce/bin64/kmsgrab "$_raw" </dev/null >/dev/null 2>&1 && [ -s "$_raw" ] &&
        timeout -s KILL 5 "$_ff" -nostdin -hide_banner -loglevel error -i "$_raw" \
            -vf "transpose=dir=cclock:passthrough=landscape" \
            -frames:v 1 -update 1 -y "$screenshot_path" </dev/null >/dev/null 2>&1 &&
        [ -s "$screenshot_path" ]; then
        rm -f "$_raw"
        log_message "take_screenshot: captured with bin64/kmsgrab instead"
        return 0
    fi
    rm -f "$_raw" "$screenshot_path" 2>/dev/null
    return 1
}

  ########################
#####   CPU AND GPU   #####
  ########################

# The common CPU functions write cpu0 and cpu4 with one set of frequencies;
# the SM8250 has three clusters with their own (policy0, policy4, policy7).
# Each mode sets every policy from its own cpuinfo limits.
#
#   powersave   cpu0-3 only, schedutil up to LIGHTMOSS_POWERSAVE_PERCENT;
#               GPU simple_ondemand up to LIGHTMOSS_GPU_POWERSAVE_MAX_HZ
#   smart       all cores, schedutil over the whole range;
#               GPU simple_ondemand up to LIGHTMOSS_GPU_STOCK_MAX_HZ
#   performance all cores, schedutil with a floor at
#               LIGHTMOSS_PERFORMANCE_MIN_PERCENT of each cluster's top;
#               GPU pinned at LIGHTMOSS_GPU_STOCK_MAX_HZ
#   overclock   all cores pinned at their top speed;
#               GPU simple_ondemand up to LIGHTMOSS_GPU_OVERCLOCK_MAX_HZ
#
# Performance used to pin all eight cores at their top speed, which is what
# NDS, N64, PSP, Dreamcast, Saturn and ports run in by default: the SD865 is
# far beyond what they need, and it only ran hotter. The GPU's steps above
# 587 MHz are the KonaBess ladder LightMoss's kernel carries from ROCKNIX
# (up to 925 MHz at a raised voltage), which ROCKNIX leaves off unless the
# user picks an overclock: here only overclock reaches them.
lightmoss_policies() {
    for _p in /sys/devices/system/cpu/cpufreq/policy*; do
        [ -d "$_p" ] && echo "$_p"
    done
}

# lightmoss_set_policies GOVERNOR MAX_PERCENT [MIN_PERCENT|max]
lightmoss_set_policies() {
    for _p in $(lightmoss_policies); do
        # A policy whose CPUs are all offline (powersave's policy4 and policy7)
        # answers EBUSY: nothing to set there until they come back.
        _lo="$(cat "$_p/cpuinfo_min_freq" 2>/dev/null)"
        _hi="$(cat "$_p/cpuinfo_max_freq" 2>/dev/null)"
        case "$_lo" in ''|*[!0-9]*) continue ;; esac
        case "$_hi" in ''|*[!0-9]*) continue ;; esac
        _max=$(( _hi * $2 / 100 ))
        [ "$_max" -lt "$_lo" ] && _max="$_lo"
        case "$3" in
            max) _min="$_max" ;;
            ''|*[!0-9]*) _min="$_lo" ;;
            *)
                _min=$(( _hi * $3 / 100 ))
                [ "$_min" -lt "$_lo" ] && _min="$_lo"
                [ "$_min" -gt "$_max" ] && _min="$_max"
                ;;
        esac
        chmod a+w "$_p/scaling_governor" "$_p/scaling_min_freq" "$_p/scaling_max_freq" 2>/dev/null
        echo "$1" > "$_p/scaling_governor" 2>/dev/null
        # The floor down first, so the new top is never below the old floor.
        echo "$_lo" > "$_p/scaling_min_freq" 2>/dev/null
        echo "$_max" > "$_p/scaling_max_freq" 2>/dev/null
        echo "$_min" > "$_p/scaling_min_freq" 2>/dev/null
        chmod a-w "$_p/scaling_governor" "$_p/scaling_min_freq" "$_p/scaling_max_freq" 2>/dev/null
    done
}

# lightmoss_set_gpu GOVERNOR [CAP_HZ]: the GPU's top at the highest step at or
# below CAP_HZ (the lowest step when every step is above it; no cap: the
# highest step the chip's speed bin offers). Prints the top it set.
lightmoss_set_gpu() {
    [ -d "$GPU_GOVENOR_DIR" ] || return 0
    _steps="$(tr ' ' '\n' < "$GPU_GOVENOR_DIR/available_frequencies" 2>/dev/null | grep -E '^[0-9]+$' | sort -n)"
    [ -n "$_steps" ] || return 0
    case "$2" in
        ''|*[!0-9]*) _top="$(echo "$_steps" | tail -n 1)" ;;
        *) _top="$(echo "$_steps" | awk -v cap="$2" '$1 <= cap { t = $1 } END { print t }')" ;;
    esac
    [ -n "$_top" ] || _top="$(echo "$_steps" | head -n 1)"
    # No floor (0 lifts it), then the top: devfreq clamps whatever runs now.
    echo 0 > "$GPU_GOVENOR_DIR/min_freq" 2>/dev/null
    echo "$_top" > "$GPU_GOVENOR_DIR/max_freq" 2>/dev/null
    echo "$1" > "$GPU_GOVENOR_DIR/governor" 2>/dev/null
    echo "$_top"
}

set_powersave() {
    flag_check "setting_cpu" && return 0
    flag_add "setting_cpu" --tmp
    cores_online "$DEVICE_MIN_CORES_ONLINE"
    lightmoss_set_policies "${CPU_SMART_GOVENOR:-schedutil}" "${LIGHTMOSS_POWERSAVE_PERCENT:-60}"
    _gpu="$(lightmoss_set_gpu "$GPU_SMART_GOVERNOR" "${LIGHTMOSS_GPU_POWERSAVE_MAX_HZ:-441600000}")"
    log_message "CPU locked to POWERSAVE: cores $DEVICE_MIN_CORES_ONLINE, ${LIGHTMOSS_POWERSAVE_PERCENT:-60}% of each cluster's top speed, GPU up to ${_gpu:-?} Hz"
    flag_remove "setting_cpu"
}

set_smart() {
    flag_check "setting_cpu" && return 0
    flag_add "setting_cpu" --tmp
    cores_online "$CPU_SMART_CORES_ONLINE"
    lightmoss_set_policies "${CPU_SMART_GOVENOR:-schedutil}" 100
    _gpu="$(lightmoss_set_gpu "$GPU_SMART_GOVERNOR" "${LIGHTMOSS_GPU_STOCK_MAX_HZ:-587000000}")"
    log_message "CPU Mode now locked to SMART: cores $CPU_SMART_CORES_ONLINE, ${CPU_SMART_GOVENOR:-schedutil} over each cluster's range, GPU up to ${_gpu:-?} Hz"
    flag_remove "setting_cpu"
}

set_performance() {
    flag_check "setting_cpu" && return 0
    flag_add "setting_cpu" --tmp
    cores_online "$DEVICE_MAX_CORES_ONLINE" "$1"
    lightmoss_set_policies "${LIGHTMOSS_PERFORMANCE_GOVERNOR:-schedutil}" 100 "${LIGHTMOSS_PERFORMANCE_MIN_PERCENT:-50}"
    _gpu="$(lightmoss_set_gpu "$GPU_PERFORMANCE_GOVERNOR" "${LIGHTMOSS_GPU_STOCK_MAX_HZ:-587000000}")"
    log_message "CPU Mode now locked to PERFORMANCE: cores $DEVICE_MAX_CORES_ONLINE, ${LIGHTMOSS_PERFORMANCE_GOVERNOR:-schedutil} from ${LIGHTMOSS_PERFORMANCE_MIN_PERCENT:-50}% of each cluster's top speed, GPU at ${_gpu:-?} Hz"
    flag_remove "setting_cpu"
}

# Everything at its top: every cluster pinned at its top speed, and the GPU
# allowed onto its overclock steps.
set_overclock() {
    flag_check "setting_cpu" && return 0
    flag_add "setting_cpu" --tmp
    cores_online "$DEVICE_MAX_CORES_ONLINE" "$1"
    lightmoss_set_policies performance 100 max
    _gpu="$(lightmoss_set_gpu "$GPU_OVERCLOCK_GOVERNOR" "$LIGHTMOSS_GPU_OVERCLOCK_MAX_HZ")"
    log_message "CPU Mode now locked to OVERCLOCK: cores $DEVICE_MAX_CORES_ONLINE at each cluster's top speed, GPU up to ${_gpu:-?} Hz"
    flag_remove "setting_cpu"
}
