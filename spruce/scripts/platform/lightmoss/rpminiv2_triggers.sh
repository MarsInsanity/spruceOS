#!/bin/sh
# Retroid Pocket Mini V2: L2/R2 trigger mode (Button Settings > Trigger mode).
# Sourced by RPMiniV2.sh, so by every script that sources helperFunctions.sh.
#
# LightMoss's retroid driver (kernel patch 4-lightmoss/0021) reports the
# analog triggers on ABS_Z (L2) and ABS_RZ (R2), 0 at rest, and also as the
# buttons BTN_TL2/BTN_TR2, pressed past half travel and released below 40%.
# Its parameter trigger_mode chooses what they report, at any time:
#   0 analog: the axes and the buttons (the driver's default);
#   1 digital: the buttons only, the axes held at 0.
# LightMoss images from before that patch have no parameter (their analog
# triggers are on hats nothing here reads); the setting then does nothing and
# the triggers stay buttons.
#
# Who reads what:
# - RetroArch: its autoconfig binds L2/R2 to the button and to the axis,
#   which works in both modes (see the autoconfig).
# - SDL programs (ports, standalone emulators, apps) through
#   SDL_GAMECONTROLLER_MAP: the axes (a2/a5) while the driver reports them,
#   the buttons (b6/b7) otherwise. RPMiniV2.cfg carries the button form, which
#   is right in every mode and on every image; rpminiv2_sdl_trigger_map turns
#   it into the axis form and back.
# - Everything that reads the pad's events directly (PyUI, the button
#   watchdogs, DraStic) uses BTN_TL2/BTN_TR2 (B_L2/B_R2), there in both modes.

RPMINIV2_TRIGGER_MODE_PARAM="/sys/module/retroid/parameters/trigger_mode"

# Replace the mapping entry $1 by $2 in SDL_GAMECONTROLLER_MAP, if it is there.
_rpminiv2_sdl_map_entry() {
    case "$SDL_GAMECONTROLLER_MAP" in
        *",$1,"*)
            SDL_GAMECONTROLLER_MAP="${SDL_GAMECONTROLLER_MAP%%,"$1",*},$2,${SDL_GAMECONTROLLER_MAP#*,"$1",}"
            ;;
    esac
}

# Point the SDL mapping's triggers at what the driver reports now: the axes in
# analog mode, the buttons in digital mode or when there is no mode to read.
rpminiv2_sdl_trigger_map() {
    [ -n "${SDL_GAMECONTROLLER_MAP:-}" ] || return 0
    _rpminiv2_tm=""
    if [ -r "$RPMINIV2_TRIGGER_MODE_PARAM" ]; then
        { read -r _rpminiv2_tm < "$RPMINIV2_TRIGGER_MODE_PARAM"; } 2>/dev/null || _rpminiv2_tm=""
    fi
    if [ "$_rpminiv2_tm" = "0" ]; then
        _rpminiv2_sdl_map_entry "lefttrigger:b6" "lefttrigger:a2"
        _rpminiv2_sdl_map_entry "righttrigger:b7" "righttrigger:a5"
    else
        _rpminiv2_sdl_map_entry "lefttrigger:a2" "lefttrigger:b6"
        _rpminiv2_sdl_map_entry "righttrigger:a5" "righttrigger:b7"
    fi
    export SDL_GAMECONTROLLER_MAP
    unset _rpminiv2_tm
}

# Set the driver's trigger mode. $1: the setting's value (Analog or Digital);
# without it, the saved setting. At boot from device_init, and from
# applySetting/triggerMode.sh when the setting changes.
rpminiv2_apply_trigger_mode() {
    _rpminiv2_mode="${1:-}"
    if [ -z "$_rpminiv2_mode" ]; then
        _rpminiv2_mode="$(get_config_value '.menuOptions."Button Settings".triggerMode.selected' "Analog" 2>/dev/null)"
    fi
    case "$_rpminiv2_mode" in
        Digital) _rpminiv2_val=1 ;;
        *) _rpminiv2_mode="Analog"; _rpminiv2_val=0 ;;
    esac
    if [ ! -e "$RPMINIV2_TRIGGER_MODE_PARAM" ]; then
        log_message "$PLATFORM: this LightMoss kernel has no trigger mode; L2/R2 stay buttons"
    elif { echo "$_rpminiv2_val" > "$RPMINIV2_TRIGGER_MODE_PARAM"; } 2>/dev/null; then
        log_message "$PLATFORM: triggers $_rpminiv2_mode (retroid trigger_mode=$_rpminiv2_val)"
    else
        log_message "$PLATFORM: could not set the retroid trigger_mode to $_rpminiv2_val"
    fi
    rpminiv2_sdl_trigger_map
    unset _rpminiv2_mode _rpminiv2_val
}

rpminiv2_sdl_trigger_map
