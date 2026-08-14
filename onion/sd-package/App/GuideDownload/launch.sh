#!/bin/sh
# Guide Downloader for OnionOS (Miyoo Mini Plus)
#
# On-device version of guides.retromodlab.com: scans mapped folders in
# /mnt/SDCARD/Roms, and for each ROM without a "<name>.txt" guide it looks the
# game up in the same guides-index JSONs the web tool uses, then downloads the
# walkthrough from archive.org's in-7z extraction endpoint.
#
# Flow: "Scanning" panel immediately -> wifi check -> fast pre-scan (one awk
# per console folder, no per-file forks: the Mini Plus CPU takes minutes to
# fork thousands of subshells, which showed as a black screen) -> console
# picker (Onion's prompt tool: All, or a single console) -> download with a
# time estimate shown up front.
#
# Matching = same normalize() + FIXES table as the web app, exact and
# subtitle matching only. The fuzzy tier stays on the web tool; unmatched
# games are listed in guide-download.log.
#
# Needs wifi. Uses OnionOS's own curl + jq + infoPanel + prompt.

cd "$(dirname "$0")"
BIN=/mnt/SDCARD/.tmp_update/bin
ROMS=/mnt/SDCARD/Roms
SITE=https://guides.retromodlab.com/app/guides-index
ITEM=Gamespot_Gamefaqs_TXTs
LOG="$(pwd)/guide-download.log"
IDXCACHE=/tmp/guides-index
SCANLIST=/tmp/guide-scan.txt
CURL="$BIN/curl -k -s -f -L --connect-timeout 15 --max-time 120"
JQ=$BIN/jq
PANEL=$BIN/infoPanel
PROMPT=$BIN/prompt

panel_pid=""

# show a persistent status panel, replacing the previous one
show_panel() {
  close_panel
  if [ -x "$PANEL" ]; then
    $PANEL --title "Guide Downloader" --message "$1" --persistent &
    panel_pid=$!
  fi
}

close_panel() {
  [ -n "$panel_pid" ] && kill "$panel_pid" 2>/dev/null
  panel_pid=""
  touch /tmp/dismiss_info_panel
}

# same console-folder -> index-platform mapping as the web app (FOLDER_MAP)
folder_platforms() {
  case "$1" in
    FC|NES|FAMICOM) echo "nes";;
    FDS) echo "famicomds nes";;
    SFC|SNES) echo "snes";;
    MD|GENESIS|MEGADRIVE|SMD) echo "genesis";;
    MDCD|SEGACD|MEGACD) echo "segacd";;
    SEGA32X|32X) echo "sega32x";;
    SMS|MASTERSYSTEM) echo "sms";;
    GG|GAMEGEAR) echo "gamegear sms";;
    GB) echo "gameboy";;
    GBC) echo "gbc gameboy";;
    GBA) echo "gba";;
    N64) echo "n64";;
    NDS|DS) echo "ds";;
    PS|PSX|PS1|PSONE) echo "ps";;
    PSP) echo "psp";;
    SATURN|SS) echo "saturn";;
    DC|DREAMCAST) echo "dreamcast";;
    PCE|PCENGINE|TG16) echo "tg16";;
    PCECD|TGCD) echo "turbocd tg16";;
    NGP|NGPC) echo "ngpc ngpocket ngp";;
    LYNX) echo "lynx";;
    WS|WONDERSWAN) echo "wonderswan wsc";;
    WSC) echo "wsc wonderswan";;
    VB|VIRTUALBOY) echo "virtualboy";;
    MSX|MSX2) echo "msx";;
    C64) echo "c64";;
    VIC20) echo "vic20";;
    A2600|ATARI2600) echo "atari2600";;
    A5200) echo "atari5200";;
    A7800) echo "atari7800";;
    A800) echo "atari8bit";;
    NEOGEO) echo "neo";;
    NEOCD) echo "neogeocd";;
    ODYSSEY) echo "odyssey2";;
    INTELLIVISION) echo "intellivision";;
    COLECO|COLECOVISION) echo "colecovision";;
    VECTREX) echo "vectrex";;
    SG1000) echo "sg1000";;
    3DO) echo "3do";;
    JAGUAR) echo "jaguar";;
    AMIGA) echo "amiga";;
    *) echo "";;
  esac
}

# count ROMs missing a guide in one folder - single awk pass, zero per-file
# forks. Keep the aux-extension list in sync with is_candidate() below.
count_missing() {
  ls -1 "$1" 2>/dev/null | awk '
    BEGIN {
      # direct assignments: split()+for-in init can silently fail on the
      # ancient busybox awk some devices ship. Keep in sync with is_candidate.
      # NOTE: cue is NOT aux here - for bin/cue games the cue IS the ROM.
      aux["bin"]=1; aux["sub"]=1; aux["img"]=1; aux["ccd"]=1; aux["txt"]=1;
      aux["sav"]=1; aux["srm"]=1; aux["state"]=1; aux["png"]=1; aux["jpg"]=1;
      aux["jpeg"]=1; aux["xml"]=1; aux["dat"]=1; aux["db"]=1; aux["cfg"]=1;
      aux["log"]=1;
    }
    { names[$0] = 1 }
    END {
      cnt = 0;
      for (f in names) {
        if (f ~ /^\./) continue;
        n = split(f, parts, ".");
        if (n < 2) continue;
        ext = tolower(parts[n]);
        if (ext in aux) continue;
        base = substr(f, 1, length(f) - length(parts[n]) - 1);
        if ((base ".txt") in names) continue;
        cnt++;
      }
      print cnt;
    }'
}

# true if this basename is a ROM we should find a guide for.
# cue is deliberately a candidate (for bin/cue games the cue IS the ROM);
# bin/img/sub/ccd stay skipped as disc data. Keep in sync with count_missing.
is_candidate() {
  case "$1" in .*) return 1;; esac
  ext=$(echo "${1##*.}" | tr 'A-Z' 'a-z')
  [ "$ext" = "$1" ] && return 1  # no extension
  case "$ext" in
    bin|sub|img|ccd|txt|sav|srm|state|png|jpg|jpeg|xml|dat|db|cfg|log) return 1;;
  esac
  return 0
}

# keep in sync with normalize() in guides-app build-index.py / app js:
# lowercase, -/_ -> space, strip (..) [..] tags, non-alnum -> space,
# drop the/a/an/and, roman numerals i..xvi -> digits
#
# Deliberately awk-free and regex-free. The device's busybox awk returned an
# empty string for every name here (2026-08-14: 68 candidates in, 0 out) while
# the plain awk in count_missing worked - the difference being the bracket
# regexes. Shell built-ins are the one thing that cannot vary between busybox
# builds, and this version forks once (tr) instead of once per name.
normalize() {
  s=$(echo "$1" | tr 'A-Z' 'a-z')

  # drop "(...)" and "[...]" tag groups, innermost-first, left to right
  while :; do
    case "$s" in
      *"("*")"*) s="${s%%"("*} ${s#*")"}";;
      *) break;;
    esac
  done
  while :; do
    case "$s" in
      *"["*"]"*) s="${s%%"["*} ${s#*"]"}";;
      *) break;;
    esac
  done

  # every character that is not a-z0-9 becomes a space
  rest="$s"; s=""
  while [ -n "$rest" ]; do
    c="${rest%"${rest#?}"}"
    rest="${rest#?}"
    case "$c" in
      [a-z0-9]) s="$s$c";;
      *) s="$s ";;
    esac
  done

  # drop stopwords, roman numerals -> digits (unquoted $s splits on spaces;
  # only a-z0-9 survive above, so there is nothing for the shell to glob)
  out=""
  for w in $s; do
    case "$w" in
      the|a|an|and) continue;;
      i) w=1;; ii) w=2;; iii) w=3;; iv) w=4;; v) w=5;; vi) w=6;;
      vii) w=7;; viii) w=8;; ix) w=9;; x) w=10;; xi) w=11;; xii) w=12;;
      xiii) w=13;; xiv) w=14;; xv) w=15;; xvi) w=16;;
    esac
    out="${out:+$out }$w"
  done
  printf '%s\n' "$out"
}

# hand-reviewed FIXES from the web app, keyed "firstPlatform|normalizedName".
# __SKIP__ = no correct guide exists in the dump (a lookalike would match).
fixes_lookup() {
  case "$1" in
    'gba|fire emblem binding blade') echo 'fire emblem fuuin no tsurugi';;
    'gba|medabots metabee version') echo 'medabots metabee';;
    'gba|medabots rokusho version') echo 'medabots rokusho';;
    'gba|spider man battle for new york'|'genesis|spot goes to hollywood'|'ps|destruction derby raw'|'gbc|asterix search for dogmatix') echo '__SKIP__';;
  esac
}

# fetch index json for a platform once per run; echo cached path or nothing
index_for() {
  idx="$IDXCACHE/$1.json"
  if [ ! -s "$idx" ]; then
    $CURL -o "$idx" "$SITE/$1.json" || rm -f "$idx"
  fi
  [ -s "$idx" ] && echo "$idx"
}

# look up a normalized key across the folder's platforms; echo "archive<TAB>path"
lookup() {
  key="$1"; platforms="$2"
  [ -z "$key" ] && return 1
  for p in $platforms; do
    idx=$(index_for "$p") || continue
    [ -z "$idx" ] && continue
    hit=$($JQ -r --arg k "$key" '.[$k] // empty | .[1] + "\t" + .[2]' "$idx")
    if [ -n "$hit" ]; then echo "$hit"; return 0; fi
  done
  return 1
}

# match + download every guide-less ROM in one console folder
process_folder() {
  dir="$1"
  folder=${dir%/}; folder=${folder##*/}
  platforms=$(folder_platforms "$(echo "$folder" | tr 'a-z' 'A-Z')")
  [ -z "$platforms" ] && return
  first_platform=${platforms%% *}

  # diagnostic: what does this folder actually contain?
  n=0
  for e in "$dir"*; do
    n=$((n + 1))
    if [ "$n" -le 8 ]; then
      if [ -d "$e" ]; then t=dir; elif [ -f "$e" ]; then t=file; else t=other; fi
      echo "  entry($t): ${e##*/}" >> "$LOG"
    fi
  done
  nfiles=0; ncand=0

  for f in "$dir"*; do
    [ -f "$f" ] || continue
    nfiles=$((nfiles + 1))
    fname=${f##*/}
    is_candidate "$fname" || continue
    ncand=$((ncand + 1))
    base=${fname%.*}

    if [ -f "$dir$base.txt" ]; then
      had=$((had + 1))
      continue
    fi

    norm=$(normalize "$base")
    [ "$ncand" -le 3 ] && echo "  norm: [$base] -> [$norm]" >> "$LOG"
    if [ -z "$norm" ]; then
      echo "EMPTY NORMALIZE: $folder/$base" >> "$LOG"
      miss=$((miss + 1)); continue
    fi

    # FIXES table first, then exact, then subtitle halves ("Anthology - FF V")
    key="$norm"
    fix=$(fixes_lookup "$first_platform|$norm")
    if [ "$fix" = "__SKIP__" ]; then
      echo "SKIP (no correct guide in dump): $folder/$base" >> "$LOG"
      miss=$((miss + 1)); continue
    elif [ -n "$fix" ]; then
      key="$fix"
    fi

    hit=$(lookup "$key" "$platforms")
    if [ -z "$hit" ]; then
      case "$base" in
        *" - "*)
          hit=$(lookup "$(normalize "${base##* - }")" "$platforms")
          [ -z "$hit" ] && hit=$(lookup "$(normalize "${base%% - *}")" "$platforms")
          ;;
      esac
    fi
    if [ -z "$hit" ]; then
      echo "NOT MATCHED: $folder/$base (try guides.retromodlab.com)" >> "$LOG"
      miss=$((miss + 1)); continue
    fi

    archive=$(printf '%s\n' "$hit" | cut -f1)
    gpath=$(printf '%s\n' "$hit" | cut -f2)
    # local index says genN.7z; the archive.org file uses the long name
    remote="gamefaqs.gamespot.com.txt.faqs.$(printf '%s\n' "$archive" | sed 's/^gen\([0-9]\)\.7z$/\1/').gen.7z"
    encpath=$(printf '%s\n' "$gpath" | sed 's|/|%2F|g')
    url="https://archive.org/download/$ITEM/$ITEM%2F$remote/$encpath"

    tmp="/tmp/guide-dl.txt"
    if $CURL -o "$tmp" "$url" && [ -s "$tmp" ] && [ "$(head -c1 "$tmp")" != "<" ]; then
      mv "$tmp" "$dir$base.txt"
      echo "OK: $folder/$base.txt" >> "$LOG"
      new=$((new + 1))
    else
      rm -f "$tmp"
      echo "DOWNLOAD FAILED: $folder/$base" >> "$LOG"
      fail=$((fail + 1))
    fi
  done

  echo "folder $folder: $n entries, $nfiles files, $ncand candidates" >> "$LOG"
}

# "12 guides" -> rough honest wall-clock text (about 1-2s per guide)
estimate() {
  secs=$(($1 * 2))
  if [ "$secs" -le 60 ]; then
    echo "under a minute"
  else
    echo "about $(((secs + 59) / 60)) min"
  fi
}

mkdir -p "$IDXCACHE"
: > "$LOG"
echo "$(date) start" >> "$LOG"

# feedback on screen from second one, so a slow card scan never looks dead
show_panel "Scanning your card..."

# wifi / site reachability check
if ! $CURL --head -o /dev/null "$SITE/nes.json"; then
  close_panel
  [ -x "$PANEL" ] && $PANEL --title "Guide Downloader" \
    --message "Cannot reach guides.retromodlab.com.\nConnect to wifi first (Tweaks or quick menu)." --auto
  echo "ERROR: no connection to $SITE" >> "$LOG"
  exit 1
fi

# pre-scan: how many ROMs are missing a guide, per mapped console folder
: > "$SCANLIST"
total=0
for dir in "$ROMS"/*/; do
  folder=${dir%/}; folder=${folder##*/}
  [ -n "$(folder_platforms "$(echo "$folder" | tr 'a-z' 'A-Z')")" ] || continue
  cnt=$(count_missing "$dir")
  if [ "$cnt" -gt 0 ]; then
    echo "$folder $cnt" >> "$SCANLIST"
    total=$((total + cnt))
  fi
done
echo "$(date) scan done: $total missing" >> "$LOG"

if [ "$total" -eq 0 ]; then
  close_panel
  [ -x "$PANEL" ] && $PANEL --title "Guide Downloader" \
    --message "Nothing to download.\nEvery ROM in a mapped folder already has a guide." --auto
  echo "DONE: nothing to download" >> "$LOG"
  exit 0
fi

# console picker: All, or one console (selection comes back as the exit code;
# B/cancel returns 255). Falls back to All if prompt is unavailable.
close_panel
want=""
if [ -x "$PROMPT" ]; then
  set -- "All consoles ($total missing)"
  while read -r fol cnt; do
    set -- "$@" "$fol ($cnt missing)"
  done < "$SCANLIST"
  LD_PRELOAD=/mnt/SDCARD/miyoo/lib/libpadsp.so $PROMPT \
    -t "Guide Downloader" -m "Download guides for which console?" "$@"
  rc=$?
  lines=$(wc -l < "$SCANLIST")
  if [ "$rc" -eq 0 ]; then
    want=""
  elif [ "$rc" -le "$lines" ]; then
    want=$(sed -n "${rc}p" "$SCANLIST" | cut -d' ' -f1)
    total=$(sed -n "${rc}p" "$SCANLIST" | cut -d' ' -f2)
  else
    echo "cancelled at picker" >> "$LOG"
    exit 0
  fi
fi

show_panel "Fetching up to $total guides ($(estimate $total)).\nGuides download one per second or two -\nplease leave the device on.\nLog: App/GuideDownload/guide-download.log"

new=0; had=0; miss=0; fail=0

if [ -n "$want" ]; then
  process_folder "$ROMS/$want/"
else
  for dir in "$ROMS"/*/; do
    process_folder "$dir"
  done
fi

close_panel
sleep 1
echo "$(date) DONE: $new new, $had already had one, $miss not matched, $fail failed" >> "$LOG"

[ -x "$PANEL" ] && $PANEL --title "Guide Downloader" \
  --message "New guides: $new\nAlready had one: $had\nNot matched: $miss  Failed: $fail\nDetails: guide-download.log" --auto
exit 0
