#!/bin/sh
# Retroid Pocket Mini V2 stick lights, from Settings > RGB LED Settings.
# Sourced by RPMiniV2.sh; defines functions only.
#
# A ring of four RGB LEDs round each stick, behind two HTR3212 controllers that
# the kernel groups (leds-group-multicolor) into /sys/class/leds/rgb:l1..l4 and
# rgb:r1..r4. Colour is multi_intensity, one 0-255 value per channel in the
# order multi_index gives (blue green red on this board); the level is
# brightness, 0-255. Zones: l is the left stick's ring, r the right's.
#
# Breathing, rise and blinking are the kernel's pattern trigger, so nothing
# runs in userspace and nothing wakes the CPU but the kernel's own timer.
# Without the pattern trigger (LightMoss before it was built in), blinking
# falls back to the timer trigger and the rest to a steady light. Effects only
# the TrimUI/Anbernic/Miniloong hardware does (sniff, rainbow) are steady too.
#
# LightMoss turns the lights off around suspend and at power-off
# (/usr/libexec/lightmoss/leds and its sleep/shutdown hooks); spruce does not.
#
# All variables here are _rl_-prefixed: set_rgb_in_menu calls rgb_led from a
# loop that reuses its own effect/hex/duration between calls.

RPMINIV2_LED_SYSFS="${RPMINIV2_LED_SYSFS:-/sys/class/leds}"
RPMINIV2_LED_STATE="${RPMINIV2_LED_STATE:-/tmp/rpminiv2_rgb_state}"

# The zone's multicolor LED directories, one per line. The single-colour
# channels under them (l:r1, r:g2, ...) have no multi_intensity.
rpminiv2_leds() {
    for _rl_d in "$RPMINIV2_LED_SYSFS"/*:"$1"[1-4]; do
        [ -w "$_rl_d/multi_intensity" ] && echo "$_rl_d"
    done
}

has_rgb_leds() {
    for _rl_d in "$RPMINIV2_LED_SYSFS"/*:[lr][1-4]; do
        [ -w "$_rl_d/multi_intensity" ] && return 0
    done
    return 1
}

# Shares the TrimUI's 5-80 setting, spread over the LEDs' 0-255.
rpminiv2_led_level() {
    _rl_scale="$(get_config_value '.menuOptions."RGB LED Settings".LEDmaxScale.selected' "15")"
    case "$_rl_scale" in ''|*[!0-9]*) _rl_scale=15 ;; esac
    [ "$_rl_scale" -gt 80 ] && _rl_scale=80
    [ "$_rl_scale" -lt 1 ] && _rl_scale=1
    echo $(( _rl_scale * 255 / 80 ))
}

# spruce's effect names and numbers to one word each.
rpminiv2_led_effect() {
    case "$1" in
        0|off|disable) echo off ;;
        1|linear|rise) echo rise ;;
        2|breath*)     echo breathe ;;
        5|blink*1)     echo blink1 ;;
        6|blink*2)     echo blink2 ;;
        7|blink*3)     echo blink3 ;;
        *)             echo static ;;
    esac
}

# The pattern trigger's "brightness duration" pairs for an effect at a level
# over a cycle of ms. A pair with the next one's brightness holds; a pair
# with a different one ramps to it (kernel steps of 50 ms); a 0 ms pair is a
# jump. Breathe and rise go through a quarter of the level first, which reads
# as an even swell rather than a light that is mostly on.
rpminiv2_led_pattern() {
    _rl_l="$2" _rl_t="$3"
    _rl_q=$((_rl_t / 4)) _rl_low=$((_rl_l / 4))
    case "$1" in
        breathe) echo "0 $_rl_q $_rl_low $_rl_q $_rl_l $_rl_q $_rl_low $_rl_q" ;;
        rise)    echo "0 $((_rl_t / 2)) $_rl_low $((_rl_t / 2)) $_rl_l 0" ;;
        blink1)  echo "$_rl_l $((_rl_t / 2)) $_rl_l 0 0 $((_rl_t / 2)) 0 0" ;;
        blink2)  _rl_e=$((_rl_t / 8))
                 echo "$_rl_l $_rl_e $_rl_l 0 0 $_rl_e 0 0 $_rl_l $_rl_e $_rl_l 0 0 $((_rl_t - 3 * _rl_e)) 0 0" ;;
        blink3)  echo "$_rl_l $((_rl_t / 10)) $_rl_l 0 0 $((_rl_t - _rl_t / 10)) 0 0" ;;
    esac
}

# Timer trigger fallback for the blinks: "on_ms off_ms".
rpminiv2_led_blink_delays() {
    case "$1" in
        blink1) echo "$(($2 / 2)) $(($2 / 2))" ;;
        blink2) echo "$(($2 / 4)) $(($2 - $2 / 4))" ;;
        blink3) echo "$(($2 / 10)) $(($2 - $2 / 10))" ;;
    esac
}

# The channel values for one LED in its multi_index order. $2-$4 = R G B.
rpminiv2_led_intensity() {
    _rl_idx="blue green red"
    [ -r "$1/multi_index" ] && read -r _rl_idx < "$1/multi_index"
    _rl_out=""
    for _rl_c in $_rl_idx; do
        case "$_rl_c" in
            red)   _rl_v="$2" ;;
            green) _rl_v="$3" ;;
            blue)  _rl_v="$4" ;;
            *)     _rl_v=0 ;;
        esac
        _rl_out="${_rl_out:+$_rl_out }$_rl_v"
    done
    echo "$_rl_out"
}

rpminiv2_led_has_trigger() {
    grep -qw "$2" "$1/trigger" 2>/dev/null
}

rpminiv2_led_first() {
    for _rl_d in $(rpminiv2_leds "$1"); do
        echo "$_rl_d"
        return 0
    done
}

# What an LED shows now: "<active trigger> <brightness>".
rpminiv2_led_live() {
    _rl_bri=0
    [ -r "$1/brightness" ] && read -r _rl_bri < "$1/brightness"
    echo "$(sed -n 's/.*\[\([^]]*\)\].*/\1/p' "$1/trigger" 2>/dev/null) $_rl_bri"
}

rpminiv2_led_remember() {
    _rl_keep="$(grep -v "^$1 " "$RPMINIV2_LED_STATE" 2>/dev/null)"
    {
        [ -n "$_rl_keep" ] && echo "$_rl_keep"
        echo "$1 $2"
    } > "$RPMINIV2_LED_STATE" 2>/dev/null
}

# Light one zone. $1 zone (l|r), $2 effect word, $3 RRGGBB, $4 cycle ms,
# $5 cycles (-1 = for ever), $6 level 0-255.
rpminiv2_led_zone() {
    _rl_z="$1" _rl_eff="$2" _rl_hex="$3" _rl_dur="$4" _rl_cyc="$5" _rl_lvl="$6"
    _rl_first="$(rpminiv2_led_first "$_rl_z")"
    [ -n "$_rl_first" ] || return 0
    [ "$_rl_hex" = 000000 ] && _rl_eff=off

    _rl_pat="" _rl_delays=""
    if [ "$_rl_eff" = off ]; then
        _rl_mode=off _rl_state=off
    else
        _rl_state="$_rl_eff $_rl_hex $_rl_dur $_rl_cyc $_rl_lvl"
        _rl_pat="$(rpminiv2_led_pattern "$_rl_eff" "$_rl_lvl" "$_rl_dur")"
        _rl_delays="$(rpminiv2_led_blink_delays "$_rl_eff" "$_rl_dur")"
        if [ -n "$_rl_pat" ] && rpminiv2_led_has_trigger "$_rl_first" pattern; then
            _rl_mode=pattern
        elif [ -n "$_rl_delays" ] && rpminiv2_led_has_trigger "$_rl_first" timer; then
            _rl_mode=timer
        else
            _rl_mode=static
        fi
    fi

    # Already showing this? Rewriting a pattern restarts it, and
    # set_rgb_in_menu runs on every return to the menu. The state file is
    # only believed when the LED agrees with it.
    if grep -qxF "$_rl_z $_rl_state" "$RPMINIV2_LED_STATE" 2>/dev/null; then
        _rl_live="$(rpminiv2_led_live "$_rl_first")"
        case "$_rl_mode" in
            off)    [ "$_rl_live" = "none 0" ] && return 0 ;;
            static) [ "$_rl_live" = "none $_rl_lvl" ] && return 0 ;;
            *)      [ "${_rl_live%% *}" = "$_rl_mode" ] && return 0 ;;
        esac
    fi

    _rl_rest="${_rl_hex#??}"
    _rl_r=$((0x${_rl_hex%????})) _rl_g=$((0x${_rl_rest%??})) _rl_b=$((0x${_rl_rest#??}))
    for _rl_d in $(rpminiv2_leds "$_rl_z"); do
        # Stops whatever pattern or blink was running; the level stays.
        echo none > "$_rl_d/trigger" 2>/dev/null
        if [ "$_rl_mode" = off ]; then
            echo 0 > "$_rl_d/brightness" 2>/dev/null
            continue
        fi
        rpminiv2_led_intensity "$_rl_d" "$_rl_r" "$_rl_g" "$_rl_b" > "$_rl_d/multi_intensity" 2>/dev/null
        case "$_rl_mode" in
            pattern)
                echo pattern > "$_rl_d/trigger" 2>/dev/null
                echo "$_rl_pat" > "$_rl_d/pattern" 2>/dev/null
                [ "$_rl_cyc" -gt 0 ] && echo "$_rl_cyc" > "$_rl_d/repeat" 2>/dev/null
                ;;
            timer)
                # The blink lights at the level set before it starts.
                echo "$_rl_lvl" > "$_rl_d/brightness" 2>/dev/null
                echo timer > "$_rl_d/trigger" 2>/dev/null
                echo "${_rl_delays% *}" > "$_rl_d/delay_on" 2>/dev/null
                echo "${_rl_delays#* }" > "$_rl_d/delay_off" 2>/dev/null
                ;;
            *)
                echo "$_rl_lvl" > "$_rl_d/brightness" 2>/dev/null
                ;;
        esac
    done
    rpminiv2_led_remember "$_rl_z" "$_rl_state"
}

# rgb_led <zones> <effect> [color] [duration_ms] [cycles] [trigger], as in
# device.sh. Zones l and r are the two sticks; m, 1, 2 and b have no hardware
# here, and neither has the A30/Flip trigger argument.
rgb_led() {
    has_rgb_leds || return 0
    rgb_leds_enabled || return 0
    flag_check "leds_forced_off" && return 0

    _rl_zones="${1:-lr}"
    _rl_effect="$(rpminiv2_led_effect "${2:-static}")"
    _rl_colour="${3:-FFFFFF}"
    case "$_rl_colour" in
        [0-9A-Fa-f][0-9A-Fa-f][0-9A-Fa-f][0-9A-Fa-f][0-9A-Fa-f][0-9A-Fa-f]) ;;
        *) _rl_colour=FFFFFF ;;
    esac
    [ "$_rl_effect" = off ] && _rl_colour=000000
    _rl_ms="${4:-1000}"
    case "$_rl_ms" in ''|*[!0-9]*) _rl_ms=1000 ;; esac
    [ "$_rl_ms" -lt 200 ] && _rl_ms=200
    [ "$_rl_ms" -gt 60000 ] && _rl_ms=60000
    _rl_cycles="${5:--1}"
    case "$_rl_cycles" in ''|*[!0-9]*|0) _rl_cycles=-1 ;; esac

    _rl_level=0
    [ "$_rl_effect" = off ] || _rl_level="$(rpminiv2_led_level)"

    case "$_rl_zones" in *l*) rpminiv2_led_zone l "$_rl_effect" "$_rl_colour" "$_rl_ms" "$_rl_cycles" "$_rl_level" ;; esac
    case "$_rl_zones" in *r*) rpminiv2_led_zone r "$_rl_effect" "$_rl_colour" "$_rl_ms" "$_rl_cycles" "$_rl_level" ;; esac
    return 0
}

# Off when the setting is off. Turning them on is set_rgb_in_menu's job
# (rgbLed.sh and principal.sh call it right after this).
enable_or_disable_rgb() {
    has_rgb_leds || return 0
    rgb_leds_enabled && return 0
    rpminiv2_led_zone l off 000000 1000 -1 0
    rpminiv2_led_zone r off 000000 1000 -1 0
}

toggle_led() {
    has_rgb_leds || return 0
    if flag_check "leds_forced_off"; then
        flag_remove "leds_forced_off"
        set_rgb_in_menu
    else
        rgb_led lr off
        flag_add "leds_forced_off" --tmp
    fi
}

# Per-stick colours (Settings > RGB LED Settings > Left/Right stick LED color).
led_zone_settings() {
    echo "leftStickLEDcolor l"
    echo "rightStickLEDcolor r"
}
