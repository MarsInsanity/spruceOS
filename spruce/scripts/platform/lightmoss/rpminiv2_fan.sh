#!/bin/sh
# System Settings > Fan Speed on the Retroid Pocket Mini V2: Auto, Quiet,
# Performance, Max or Off. LightMoss's lightmoss-fan does the work: it moves
# the fan's thermal trips for the mode (the kernel drives the fan) and keeps
# the mode for its next boot. Off still runs the fan if the chip passes 75 C.
#
# The setting's changeCmd: PyUI runs it with the value it just saved.
# device_init runs it at every start with no value, for the saved setting:
# LightMoss's own copy can differ (after a LightMoss update, or with this card
# in another Mini V2).

. /mnt/SDCARD/spruce/scripts/helperFunctions.sh

FAN=/usr/bin/lightmoss-fan
if [ ! -x "$FAN" ]; then
    log_message "rpminiv2_fan.sh: no $FAN, this LightMoss has no fan modes"
    exit 0
fi

mode="$1"
if [ -z "$mode" ]; then
    mode="$(get_config_value '.menuOptions."System Settings".fanModeRPMiniV2.selected' "")"
    # A settings file from before the option: LightMoss's saved mode stays.
    [ -n "$mode" ] || exit 0
fi

out="$("$FAN" set "$mode" 2>&1)"
log_message "rpminiv2_fan.sh: $mode: ${out:-done}"
exit 0
