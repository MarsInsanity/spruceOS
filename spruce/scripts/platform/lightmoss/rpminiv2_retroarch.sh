#!/bin/sh
# RetroArch on the Retroid Pocket Mini V2: the hotkey reset with this pad's
# numbers, and bringing a live config written from an older platform cfg up to
# date. Sourced by RPMiniV2.sh after dArkMossCommon.sh, whose
# set_default_ra_hotkeys (the RGB30's numbers) this replaces.
#
# RetroArch's udev joypad driver numbers a pad's keys up from BTN_MISC, and the
# Retroid pad has BTN_BACK (0x116), so: BACK 0, SOUTH 1, EAST 2, NORTH 3,
# WEST 4, TL 5, TR 6, TL2 7, TR2 8, SELECT 9, START 10, MODE 11, THUMBL 12,
# THUMBR 13, d-pad up, down, left, right 14-17. The hotkey enable is SELECT.

RPMINIV2_RA_CFG_STAMP="/mnt/SDCARD/Saves/spruce/rpminiv2-ra-cfg-rev"
# Bump with a new block in rpminiv2_ra_cfg_changes whenever a value in
# retroarch-RPMiniV2.cfg.bak changes that existing live configs should follow.
RPMINIV2_RA_CFG_REV=1

# rpminiv2_ra_cfg_values FILE KEY...: the values of KEY... in a RetroArch cfg,
# quotes removed, one line separated by spaces, "-" for a key it does not have.
rpminiv2_ra_cfg_values() {
    _rcv_file="$1"
    shift
    awk -v keys="$*" '
        BEGIN { n = split(keys, want, " ") }
        {
            eq = index($0, "=")
            if (!eq) next
            key = substr($0, 1, eq - 1)
            gsub(/[ \t]/, "", key)
            val = substr($0, eq + 1)
            gsub(/^[ \t]+|[ \t\r]+$/, "", val)
            if (val ~ /^".*"$/) val = substr(val, 2, length(val) - 2)
            seen[key] = val
        }
        END {
            for (i = 1; i <= n; i++)
                printf "%s%s", (i > 1 ? " " : ""), ((want[i] in seen) ? seen[want[i]] : "-")
            print ""
        }
    ' "$_rcv_file"
}

# The hotkeys a reset writes: the values retroarch-RPMiniV2.cfg.bak ships,
# read from it so the two cannot drift apart, with these as the fallback.
rpminiv2_ra_hotkey_defaults() {
    _rhd_bak="$(platform_path "/mnt/SDCARD/RetroArch/platform/retroarch-%s.cfg.bak")"
    _rhd_table='input_enable_hotkey_btn 9
input_exit_emulator_btn 1
input_fps_toggle_btn 4
input_load_state_btn 5
input_save_state_btn 6
input_menu_toggle f1
input_menu_toggle_btn 3
input_quit_gamepad_combo 0
input_toggle_fast_forward_btn 8
input_screenshot_btn 2
input_shader_toggle_btn 14
input_state_slot_decrease_btn 16
input_state_slot_increase_btn 17
input_toggle_slowmotion_btn 7'
    # shellcheck disable=SC2046 # the keys, split on purpose
    _rhd_from_bak="$(rpminiv2_ra_cfg_values "$_rhd_bak" $(echo "$_rhd_table" | cut -d' ' -f1) 2>/dev/null)"
    echo "$_rhd_table" | while read -r _rhd_key _rhd_val; do
        _rhd_bak_val="${_rhd_from_bak%% *}"
        _rhd_from_bak="${_rhd_from_bak#* }"
        case "$_rhd_bak_val" in
            ""|-) ;;
            *) _rhd_val="$_rhd_bak_val" ;;
        esac
        echo "$_rhd_key = \"$_rhd_val\""
    done
}

# rpminiv2_write_ra_hotkeys FILE: the hotkey defaults into a RetroArch cfg.
rpminiv2_write_ra_hotkeys() {
    _rwh_file="$1"
    set --
    while IFS= read -r _rwh_line; do
        [ -n "$_rwh_line" ] && set -- "$@" "$_rwh_line"
    done <<EOF
$(rpminiv2_ra_hotkey_defaults)
EOF
    [ "$#" -gt 0 ] || return 1
    update_ra_config_file_with_new_setting "$_rwh_file" "$@"
}

# Emulator Reset Tasks / Reset RetroArch hotkeys (tasks/resetRAHotkeys.sh).
set_default_ra_hotkeys() {
    RA_FILE="$(platform_path "/mnt/SDCARD/Saves/ra-configs/retroarch-%s.cfg")"
    log_message "Resetting RetroArch hotkeys to Spruce defaults ($PLATFORM numbering: hotkey enable SELECT = 9)."
    rpminiv2_write_ra_hotkeys "$RA_FILE"
}

# rpminiv2_has_vulkan: whether this LightMoss has Vulkan: the Khronos loader and
# an ICD manifest (Turnip's; its lib32 build ships the 32-bit pair alongside).
rpminiv2_has_vulkan() {
    [ -e /usr/lib/libvulkan.so.1 ] || return 1
    for _rhv in /usr/share/vulkan/icd.d/*.json /etc/vulkan/icd.d/*.json; do
        [ -e "$_rhv" ] && return 0
    done
    return 1
}

# rpminiv2_ra_vulkan_guard FILE: RetroArch's video driver back on "gl" when the
# live config asks for "vulkan" (Settings > Drivers > Video) and this LightMoss
# has no Vulkan: an image from before Turnip, such as the older system copy an
# update falls back to. RetroArch quits when its video driver does not start,
# so every game would end at once. Each start, before RetroArch reads it.
rpminiv2_ra_vulkan_guard() {
    [ "$(rpminiv2_ra_cfg_values "$1" video_driver)" = "vulkan" ] || return 0
    rpminiv2_has_vulkan && return 0
    if sed -e 's|^video_driver[[:space:]]*=.*$|video_driver = "gl"|' "$1" > "$1.rpminiv2.tmp" &&
        [ -s "$1.rpminiv2.tmp" ] && mv -f "$1.rpminiv2.tmp" "$1"; then
        log_message "$PLATFORM: RetroArch's video driver was vulkan, which this LightMoss does not have: gl"
    else
        rm -f "$1.rpminiv2.tmp"
    fi
}

# REV KEY OLD NEW: a value a live config written from an older platform cfg
# still holds, and what replaces it. Add a block with the next rev for a later
# change; never edit a block that has shipped.
rpminiv2_ra_cfg_changes() {
    cat <<'EOF'
1 input_enable_hotkey_btn 8 9
1 input_exit_emulator_btn 0 1
1 input_fps_toggle_btn 3 4
1 input_load_state_btn 4 5
1 input_save_state_btn 5 6
1 input_menu_toggle_btn 2 3
1 input_screenshot_btn 1 2
1 input_shader_toggle_btn 13 14
1 input_state_slot_decrease_btn 15 16
1 input_state_slot_increase_btn 16 17
1 input_toggle_fast_forward_btn 7 8
1 input_toggle_slowmotion_btn 6 7
1 audio_volume 0.000000 6.000000
1 input_analog_deadzone 0.000000 0.100000
EOF
}

# rpminiv2_migrate_ra_config FILE: the live config up to date with the platform
# cfg, once per rev (prepare_ra_config runs it before every RetroArch start).
# RetroArch copies the .bak only when there is no live config and rewrites the
# live one on every exit, so fixes to the .bak never reached a card that had
# already run it. Rev 1: the hotkeys were one button low (written in SDL's
# numbering, where BACK comes last), which made R2 the hotkey enable;
# audio_volume +6 dB; a 0.1 stick deadzone. A value changes only while it is
# still the old default, so a choice made in RetroArch's menu stays. A config
# whose hotkeys are exactly what dArkMoss's reset wrote (the RGB30's numbers,
# before this file gave the reset its own) gets this pad's reset instead.
rpminiv2_migrate_ra_config() {
    _rmc_cfg="$1"
    # nothing to bring up to date yet: RetroArch writes it in full on exit
    [ -s "$_rmc_cfg" ] || return 0
    rpminiv2_ra_vulkan_guard "$_rmc_cfg"
    _rmc_rev="$(cat "$RPMINIV2_RA_CFG_STAMP" 2>/dev/null)"
    case "$_rmc_rev" in ""|*[!0-9]*) _rmc_rev=0 ;; esac
    [ "$_rmc_rev" -ge "$RPMINIV2_RA_CFG_REV" ] && return 0

    _rmc_darkmoss_reset=false
    if [ "$_rmc_rev" -lt 1 ] && [ "$(rpminiv2_ra_cfg_values "$_rmc_cfg" input_enable_hotkey_btn \
        input_exit_emulator_btn input_fps_toggle_btn input_load_state_btn input_save_state_btn \
        input_menu_toggle_btn input_toggle_fast_forward_btn)" = "8 0 2 4 5 3 10" ]; then
        _rmc_darkmoss_reset=true
    fi

    _rmc_changes="$(rpminiv2_ra_cfg_changes | awk -v from="$_rmc_rev" '$1 > from { printf "%s %s %s;", $2, $3, $4 }')"
    _rmc_tmp="$_rmc_cfg.rpminiv2.tmp"
    _rmc_log="$_rmc_cfg.rpminiv2.log"
    if ! awk -v changes="$_rmc_changes" -v logf="$_rmc_log" '
        BEGIN {
            n = split(changes, c, ";")
            m = 0
            for (i = 1; i <= n; i++) {
                if (split(c[i], f, " ") != 3) continue
                m++; k[m] = f[1]; o[m] = f[2]; v[m] = f[3]
            }
        }
        {
            line = $0
            eq = index(line, "=")
            if (eq) {
                key = substr(line, 1, eq - 1)
                gsub(/[ \t]/, "", key)
                val = substr(line, eq + 1)
                gsub(/^[ \t]+|[ \t\r]+$/, "", val)
                if (val ~ /^".*"$/) val = substr(val, 2, length(val) - 2)
                hit = 0
                # in rev order, so a value can move on through later revs
                for (i = 1; i <= m; i++) {
                    if (k[i] == key && o[i] == val) {
                        printf("%s %s->%s\n", key, val, v[i]) > logf
                        val = v[i]
                        hit = 1
                    }
                }
                if (hit) line = key " = \"" val "\""
            }
            print line
        }
    ' "$_rmc_cfg" > "$_rmc_tmp" || [ ! -s "$_rmc_tmp" ]; then
        rm -f "$_rmc_tmp" "$_rmc_log"
        log_message "$PLATFORM: could not update $_rmc_cfg to RetroArch config rev $RPMINIV2_RA_CFG_REV, trying again next time"
        return 1
    fi
    if [ -s "$_rmc_log" ]; then
        if ! mv -f "$_rmc_tmp" "$_rmc_cfg"; then
            rm -f "$_rmc_tmp" "$_rmc_log"
            log_message "$PLATFORM: could not replace $_rmc_cfg, trying again next time"
            return 1
        fi
        log_message "$PLATFORM: RetroArch config rev $_rmc_rev -> $RPMINIV2_RA_CFG_REV: $(tr '\n' ' ' < "$_rmc_log")"
    else
        rm -f "$_rmc_tmp"
    fi
    rm -f "$_rmc_log"
    if [ "$_rmc_darkmoss_reset" = true ]; then
        log_message "$PLATFORM: hotkeys were the RGB30's reset, resetting them with this pad's numbers"
        rpminiv2_write_ra_hotkeys "$_rmc_cfg"
    fi
    mkdir -p "${RPMINIV2_RA_CFG_STAMP%/*}" 2>/dev/null
    echo "$RPMINIV2_RA_CFG_REV" > "$RPMINIV2_RA_CFG_STAMP"
}
