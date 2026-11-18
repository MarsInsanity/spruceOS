#!/bin/sh
# Bluetooth on the Retroid Pocket Mini V2 under LightMoss, sourced by
# RPMiniV2.sh after dArkMossCommon.sh, whose functions these replace.
#
# The controller is the QCA6390's, on a UART (hci_uart + btqca): hci0 appears
# a few seconds into boot, firmware and all, without anything from spruce.
# LightMoss ships BlueZ (bluetoothctl) and bluez-alsa 4.3.1, both units
# disabled for spruce to start and stop as on dArkMoss. bluez-alsa 4 names
# its daemon bluealsa and its client bluealsa-cli where dArkMoss's
# bluez-alsa 5 has bluealsad and bluealsactl; its ALSA plugin is 64-bit only,
# so 32-bit programs cannot play to a headset.

# bluetooth.sh boot rewrites $HOME/.asoundrc in the background while PyUI
# starts: asound-setup.sh writes it aside and renames it into place.
# shellcheck disable=SC2034 # read by asound-setup.sh
ASOUND_WRITE_ATOMIC=1

lightmoss_bt_controller() {
    for _hci in /sys/class/bluetooth/hci*; do
        [ -e "$_hci" ] && return 0
    done
    return 1
}

# The menu where the image has BlueZ (LightMoss images before it have none,
# and keep the menu hidden) and the kernel has a controller.
device_bluetooth_supported() {
    command -v bluetoothctl >/dev/null 2>&1 || return 1
    [ -e /usr/lib/systemd/system/bluetooth.service ] || return 1
    lightmoss_bt_controller && return 0
    # hci_uart registers hci0 about when spruce starts: wait up to 3 s, once
    # per boot, so a boot that gets here first does not leave Bluetooth off
    # (and a board whose controller never comes does not wait on every call).
    [ -e /tmp/rpminiv2_bt_waited ] && return 1
    touch /tmp/rpminiv2_bt_waited 2>/dev/null
    _bt_w=0
    while ! lightmoss_bt_controller; do
        [ "$_bt_w" -ge 30 ] && return 1
        sleep 0.1; _bt_w=$((_bt_w + 1))
    done
    return 0
}

# dArkMossCommon's (systemctl, bluealsa with --keep-alive in a runtime
# drop-in), with what this board adds before it: the controller there, and
# its rfkill switch open, since nothing on LightMoss restores rfkill state
# and a blocked adapter refuses "power on" (org.bluez.Error.Blocked).
# bluealsa is audio only: pads work without it, so it failing to start
# leaves the radio on.
device_bluetooth_up() {
    _n=0
    until lightmoss_bt_controller; do
        [ "$_n" -ge 10 ] && return 1
        sleep 1
        _n=$((_n + 1))
    done
    for _rf in /sys/class/rfkill/rfkill*; do
        [ "$(cat "$_rf/type" 2>/dev/null)" = bluetooth ] || continue
        [ "$(cat "$_rf/soft" 2>/dev/null)" = 0 ] || echo 0 > "$_rf/soft" 2>/dev/null
    done
    _dropin=/run/systemd/system/bluealsa.service.d/spruce-keep-alive.conf
    if [ ! -f "$_dropin" ]; then
        _cmd=$(systemctl show -p ExecStart --value bluealsa 2>/dev/null | sed -n 's/.*argv\[\]=\([^;]*\);.*/\1/p' | head -n 1)
        case "$_cmd" in
            ""|*--keep-alive*) ;;
            *)
                mkdir -p "${_dropin%/*}"
                printf '[Service]\nExecStart=\nExecStart=%s --keep-alive=%s\n' "${_cmd% }" "${BLUEALSA_KEEP_ALIVE:-10}" > "$_dropin"
                systemctl daemon-reload
                systemctl is-active --quiet bluealsa && systemctl restart bluealsa
                ;;
        esac
    fi
    systemctl start bluetooth || return 1
    systemctl start bluealsa || log_message "$PLATFORM: bluealsa did not start: no Bluetooth audio" >/dev/null
    return 0
}

# The client of whichever bluez-alsa runs: 5's bluealsactl or 4's
# bluealsa-cli. Their list-pcms, soft-volume and volume are the same.
lightmoss_bluealsa_cli() {
    if pidof bluealsad >/dev/null 2>&1 && command -v bluealsactl >/dev/null 2>&1; then
        echo bluealsactl
    elif pidof bluealsa >/dev/null 2>&1 && command -v bluealsa-cli >/dev/null 2>&1; then
        echo bluealsa-cli
    else
        return 1
    fi
}

# dArkMossCommon's, for bluez-alsa 4 as well: it looks for bluealsad only,
# so on LightMoss the headset's level never followed spruce's. Soft volume
# (bluealsa scales the stream), so the level holds on headsets that ignore
# the remote one; switched on only when off, as turning it on resets the
# level to full. The 0-20 level on bluealsa's 0-127.
bt_headset_volume() {
    _cli="$(lightmoss_bluealsa_cli)" || return 0
    _v=$(( $1 * 127 / 20 ))
    for _pcm in $(${BTCTL_TIMEOUT:-timeout 2} "$_cli" --quiet list-pcms 2>/dev/null | grep '/a2dpsrc/sink$'); do
        ${BTCTL_TIMEOUT:-timeout 2} "$_cli" soft-volume "$_pcm" 2>/dev/null | grep -q true ||
            ${BTCTL_TIMEOUT:-timeout 2} "$_cli" soft-volume "$_pcm" y >/dev/null 2>&1
        ${BTCTL_TIMEOUT:-timeout 2} "$_cli" volume "$_pcm" "$_v" "$_v" >/dev/null 2>&1
    done
}
