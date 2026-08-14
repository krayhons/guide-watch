#!/bin/sh
# Executed by Onion's runtime as the next "app" after guidewatch swaps
# cmd_to_run.sh (the quick-switch handoff). Shows the guide in the Ebook
# Reader, then hands the original game command back to the runtime with the
# auto-load-state flag so the game resumes exactly where it was.
#
# Every step logs to guidewatch.log so a failed handoff is diagnosable.
sysdir=/mnt/SDCARD/.tmp_update
log=/mnt/SDCARD/App/GuideWatch/guidewatch.log
guide=$(cat /tmp/guidewatch_guide 2>/dev/null)
resume=/tmp/guidewatch_resume.sh

echo "wrapper: start (guide=[$guide])" >> "$log"

if [ -z "$guide" ] || [ ! -f "$resume" ]; then
  # stale handoff (e.g. device rebooted while the guide was open): clear the
  # command file so the runtime falls back to MainUI instead of looping us
  echo "wrapper: stale handoff, bailing to MainUI" >> "$log"
  rm -f "$sysdir/cmd_to_run.sh" /tmp/guidewatch_guide "$resume"
  exit 0
fi

cd /mnt/SDCARD/App/PixelReader
echo "wrapper: launching reader" >> "$log"
LD_LIBRARY_PATH="/mnt/SDCARD/App/PixelReader/lib:$LD_LIBRARY_PATH" ./reader "$guide" >> "$log" 2>&1
rc=$?
echo "wrapper: reader exited rc=$rc" >> "$log"

# reader closed (MENU): give the game back, resuming from its auto-save.
# quick_switch keeps check_switcher() from deleting the restored command
# when this wrapper exits (it would fall back to MainUI without it).
cp "$resume" "$sysdir/cmd_to_run.sh"
touch /tmp/force_auto_load_state
touch /tmp/quick_switch
rm -f /tmp/guidewatch_guide "$resume"
echo "wrapper: game command restored" >> "$log"
exit 0
