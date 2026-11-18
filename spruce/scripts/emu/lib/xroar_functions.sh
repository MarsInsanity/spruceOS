#!/bin/sh

# Requires globals:
#   PLATFORM
#   EMU_DIR
#   ROM_FILE
#   LD_LIBRARY_PATH
#   LOG_DIR
#
# Requires functions:
#   log_message
#
# Provides:
#   run_xroar

run_xroar() {

XROAR_BIN="xroar"

LD_LIBRARY_PATH="$EMU_DIR/libs.aarch64:$LD_LIBRARY_PATH"
export LD_LIBRARY_PATH

XR_GPTK="$EMU_DIR/gptk"

GAME_BN=$(basename "${ROM_FILE%.*}")
GPTK_SP="${XR_GPTK}/${GAME_BN}.gptk"

[ ! -f "$GPTK_SP" ] && GPTK_SP="${XR_GPTK}/$XROAR_BIN.gptk"

# gptokeyb reads the pad through SDL's game controller API and the .gptk files
# speak SDL's positional names; the Retroid pad has no stock mapping, and
# SDL's own one swaps L2/R2.
[ "$PLATFORM" = "RPMiniV2" ] && export_sdl_gamecontroller_map positional

gptokeyb -k "$XROAR_BIN" -c "$GPTK_SP" &

"$EMU_DIR/$XROAR_BIN" -c "$EMU_DIR/$XROAR_BIN.conf" -default-machine coco2bus "$ROM_FILE" > "$(emu_log_file)" 2>&1

}
