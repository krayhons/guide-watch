#!/bin/sh
# OnionOS runs every .tmp_update/startup/*.sh at boot (see runtime.sh).
# Starts the in-game guide daemon in the background; the script itself
# must return quickly because runtime.sh runs startup scripts blocking.
appdir=/mnt/SDCARD/App/GuideWatch

if [ -x "$appdir/guidewatch" ]; then
  "$appdir/guidewatch" > "$appdir/guidewatch.log" 2>&1 &
fi
