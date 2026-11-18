#!/bin/sh
# Apply Settings -> Button Settings -> Trigger mode. Retroid Pocket Mini V2
# only (RPMiniV2, LightMoss): its L2/R2 are analog, and LightMoss's retroid
# driver reports them as axes and buttons (Analog) or as buttons only, the axes
# held at 0 (Digital). This writes the driver's trigger_mode parameter, which
# takes effect at once; programs started from now on get the matching SDL
# mapping. device_init applies the saved value at boot.
# See spruce/scripts/platform/lightmoss/rpminiv2_triggers.sh.
#
# Run as the setting's changeCmd. PyUI appends the newly-selected value as $1.

. /mnt/SDCARD/spruce/scripts/helperFunctions.sh

if command -v rpminiv2_apply_trigger_mode >/dev/null 2>&1; then
    rpminiv2_apply_trigger_mode "${1:-}"
else
    log_message "triggerMode.sh: no trigger mode on $PLATFORM"
fi
exit 0
