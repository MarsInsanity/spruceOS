#!/bin/sh
# Retroid Pocket Mini V2 touchscreen, sourced by RPMiniV2.cfg: sets
# EVENT_PATH_TOUCH (spruce-device-env.sh hands it to PyUI as TOUCH_EVENT_PATH),
# DEVICE_HAS_TOUCHSCREEN, and TOUCH_ROTATION when the kernel already turns
# touch. Only reads sysfs, no programs: the cfg is sourced by nearly every
# script.
#
# The touchscreen is the FocalTech ft5452 on i2c13 (0x38), "generic ft5x06
# (8d)" after its firmware id. Its event number changes between boots (event3
# or event4 in the logs), so it is found each time, by its device tree node
# (any input device whose DT node has touchscreen-size-x), else by name. No
# numbered fallback: a wrong node would feed PyUI some other device.
#
# Which way it reports. The panel scans out 1080x1240 portrait and is mounted
# right side up (DT rotation = <90>); the picture is 1240x1080 landscape,
# turned 90 degrees clockwise onto the panel (LightMoss's SDL2 plane rotation,
# PyUI's SCREEN_ROTATION=90). From LightMoss's kernel patch 4-lightmoss/0030
# the touchscreen node has touchscreen-swapped-x-y and touchscreen-inverted-x,
# and the driver reports that landscape frame itself (X = panel y, Y = 1079 -
# panel x), for SDL, RetroArch and PyUI alike. PyUI's TouchWatcher would undo
# SCREEN_ROTATION on top of that, so TOUCH_ROTATION=0 tells it the points are
# already upright. An older LightMoss reports the panel's frame, and PyUI
# turns it by SCREEN_ROTATION as before (TOUCH_ROTATION unset).

DEVICE_HAS_TOUCHSCREEN="false"
EVENT_PATH_TOUCH=""
unset TOUCH_ROTATION
for _rpm_ev in /sys/class/input/event*; do
    _rpm_dt="$_rpm_ev/device/device/of_node"
    if [ ! -e "$_rpm_dt/touchscreen-size-x" ]; then
        _rpm_name=""
        { read -r _rpm_name < "$_rpm_ev/device/name"; } 2>/dev/null
        case "$_rpm_name" in
            *ft5x06*) ;;
            *) continue ;;
        esac
    fi
    DEVICE_HAS_TOUCHSCREEN="true"
    EVENT_PATH_TOUCH="/dev/input/${_rpm_ev##*/}"
    if [ -e "$_rpm_dt/touchscreen-swapped-x-y" ]; then
        TOUCH_ROTATION="0"
        export TOUCH_ROTATION
    fi
    break
done
export DEVICE_HAS_TOUCHSCREEN EVENT_PATH_TOUCH
unset _rpm_ev _rpm_dt _rpm_name
