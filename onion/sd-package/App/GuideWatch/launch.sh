#!/bin/sh
# Toggles the guidewatch daemon on/off from the Apps menu.
# The daemon normally starts at boot via .tmp_update/startup/guidewatch.sh;
# this app entry is just a manual kill switch / restart.
cd "$(dirname "$0")"
infopanel=/mnt/SDCARD/.tmp_update/bin/infoPanel

if pgrep guidewatch > /dev/null 2>&1; then
  killall guidewatch
  msg="Guide daemon stopped.\nIt will start again on next boot."
else
  ./guidewatch >> guidewatch.log 2>&1 &
  msg="Guide daemon started."
fi

[ -x "$infopanel" ] && "$infopanel" --title "Guide Watch" --message "$msg" --auto
