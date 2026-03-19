#!/bin/bash

usage() {
  echo "
Supported formats: .mkv .avi .mp4 .m4v .mov .wmv .flv .divx .mpg .mpeg
This script re-encodes video files using hardware-accelerated HEVC (H.265) compression,
optionally skipping already optimized files and ignoring small files.

Usage:
  ./script.sh [-R] [min=X] [test=Y] [--dry-run] [--check] [--keep-original] [--allow-h265] [--allow-av1] [-backup /path] <folder>
    -R              : Encode recursively inside subfolders
    -min=X.YZ        : Ignore files smaller than X.YZ GB
    --regex="PATTERN"        Only include files matching the given regex pattern (e.g., --regex="\.avi$").
    -test=N          : Use N seconds for the test encode (default: 5)
    -log            : Show ffmpeg log infos when encoding
    --dry-run       : Only show compatible files without encoding
    --check         : Scan all videos recursively and show compression opportunities sorted by potential savings
    -keep-original : Keep original files instead of replacing them
    -allow-h265    : Allow files already encoded in H.265
    -allow-av1     : Allow files already encoded in AV1
    -backup /path   : Save original files to backup path (used only if not using --keep-original)
    --clean         : Remove temporary encoding files (.tmp_encode_*, .tmp_encode_test_*) from the folder(s, if combined with -R) 
    --purge         : Remove encoded.list files from the folder(s, if combined with -R) 
    --retry         : Remove failed.list files from the folder(s, if combined with -R) 
    -h              : Show this help message
    -stop-after HH.5  : Stop after HH.5 hours of encoding (useful if in cron)"
  exit 0
}



# ===========================
# User Configuration Section
# ===========================

# Notification env file
if [[ -f /scripts/notification.env ]]; then
  source /scripts/notification.env
fi

# Define send_notif stub if not already defined
if ! type send_notif &>/dev/null; then
  send_notif() { :; }  # No-op function
fi

# Detect platform and set defaults
if [[ "$(uname)" == "Darwin" ]]; then
  # macOS detected
  if [[ "$(uname -m)" == "arm64" ]]; then
    # Apple Silicon (M1/M2/M3/etc.)
    DEFAULT_HWACCEL_TYPE="videotoolbox"
    DEFAULT_VIDEO_CODEC="hevc_videotoolbox"
  else
    # Intel Mac
    DEFAULT_HWACCEL_TYPE="videotoolbox"
    DEFAULT_VIDEO_CODEC="hevc_videotoolbox"
  fi
else
  # Linux or other - assume NVIDIA CUDA
  DEFAULT_HWACCEL_TYPE="cuda"
  DEFAULT_VIDEO_CODEC="hevc_nvenc"
fi

# Enable hardware acceleration (true/false)
# true  = use GPU for decoding/encoding (faster, lower CPU usage)
# false = use CPU only (slower, but more widely supported)
USE_HWACCEL=true

# Hardware acceleration type
# Common options:
# - "cuda"         = NVIDIA GPUs (NVENC)
# - "videotoolbox" = Apple Silicon / macOS (VideoToolbox)
# - "vaapi"        = Intel/AMD GPUs on Linux
# - "qsv"          = Intel QuickSync Video
HWACCEL_TYPE="${HWACCEL_TYPE:-$DEFAULT_HWACCEL_TYPE}"

# Video codec to use for encoding
# Options:
# - "hevc_nvenc"        = H.265 with NVIDIA NVENC (requires CUDA)
# - "hevc_videotoolbox" = H.265 with Apple VideoToolbox (macOS)
# - "libx265"           = H.265 via CPU
# - "hevc_vaapi"        = H.265 via VAAPI (hardware, Linux)
# - "hevc_qsv"          = H.265 via Intel QuickSync (hardware)
VIDEO_CODEC="${VIDEO_CODEC:-$DEFAULT_VIDEO_CODEC}"

# Audio codec to use
# Most compatible option: "aac"
AUDIO_CODEC="aac"
# For better compatibility with Chromecasts, use 1 to keep as is if 5.1
KEEP_MULTICHANNEL_ORIGINAL_ENCODING=1

# Target audio bitrate
# Recommended: 128k (good), 192k (better), 256k+ (high quality)
AUDIO_BITRATE="256k"

# Constant quality factor for video (0–51)
# Lower = better quality, bigger file
# Higher = lower quality, smaller file
# - NVENC recommended range: 19–28
# - libx265 recommended range: 18–28
# Adaptive CQ settings based on video resolution
CQ_HD="30"           # For HD videos (resolution >= CQ_WIDTH_THRESHOLD)
CQ_SD="26"           # For SD videos (resolution < CQ_WIDTH_THRESHOLD)
CQ_WIDTH_THRESHOLD=1900  # WIDTH threshold in pixels to determine HD vs SD
#
CQ="30"
# Width cheatsheet
# Height	Width	CQ range
# 480p	     720	26–28
# 720p   	1280	28–30
# 1080p	    1920	30–32
# 2K (DCI)	2048	30–32
# 4K (UHD)	3840	32–34

# Encoding preset — affects speed and compression efficiency
# ⚠️ Available values depend on the selected VIDEO_CODEC

# For hevc_nvenc (NVIDIA):
#   "p1" = slowest, best quality
#   "p2"
#   "p3" = balanced (default)
#   "p4"
#   "p5"
#   "p6"
#   "p7" = fastest, lower quality

# For hevc_videotoolbox (Apple Silicon / macOS):
#   No preset option - uses quality parameter instead

# For libx265 (CPU encoder):
#   "ultrafast", "superfast", "veryfast", "faster", "fast",
#   "medium" (default), "slow", "slower", "veryslow", "placebo"
#   Slower = better compression and quality, but takes longer

# For hevc_vaapi (Linux hardware encoding):
#   "veryfast", "fast", "medium", "slow" (not all drivers support all)

# For hevc_qsv (Intel QuickSync):
#   "veryfast", "faster", "fast", "medium", "slow", "slower"

if [[ "$VIDEO_CODEC" == "hevc_videotoolbox" ]]; then
  ENCODE_PRESET=""  # VideoToolbox doesn't use preset
else
  ENCODE_PRESET="p3"
fi

# Duration in seconds for test encoding (used to estimate file size before full encoding)
# Helps skip files where re-encoding won’t reduce size significantly
# Sample will be taken at 1/4th, 1/2 and 3/4th of the duration
TEST_DURATION=5

#Expected ratio between old and new encoded file to allow transcoding
MIN_SIZE_RATIO=0.8

#Skip files below this bitrate (in kbps)
MIN_BITRATE=500
MIN_BYTE_PER_SEC=$((MIN_BITRATE * 1000 / 8))
MARK_AS_ENCODED=true
ENCODE_FAILED=true

###################
# System settings
##################
offset_auto=0
RECURSIVE=0
raw_min=0
MIN_SIZE_BYTES=0
FOLDER=""
DRY_RUN=0
CHECK_MODE=0
KEEP_ORIGINAL=0
ALLOW_H265=0
ALLOW_AV1=0
BACKUP_DIR=""
CLEAN_ONLY=0
PURGE_ONLY=0
STOP_AFTER_HOURS=0
REGEX_FILTER=""
RETRY=0
LOGLEVEL="error" # par défaut, on reste silencieux
TIMEOUT=3600 #1h in seconds
TIMEOUT_SAMPLE=8 #seconds


# =====================
# Function Definitions
# =====================


print_size() {
  local bytes=$1
  if (( bytes >= 1073741824 )); then
    LC_NUMERIC=C printf "%.2f GB" "$(echo "scale=2; $bytes / 1073741824" | bc -l)"
  else
    LC_NUMERIC=C printf "%.2f MB" "$(echo "scale=2; $bytes / 1048576" | bc -l)"
  fi
}

print_boxed_message() {
    local message="$1"
    local padding=2
    local stripped_message=$(echo "$message" | sed -E 's/\x1B\[[0-9;]*[mK]//g')
    local length=${#stripped_message}
    local width=$((length + padding * 2))
    local top="┌$(printf '─%.0s' $(seq 1 "$width"))┐"
    local bottom="└$(printf '─%.0s' $(seq 1 "$width"))┘"
    local middle="│$(printf ' %.0s' $(seq 1 "$padding"))$message$(printf ' %.0s' $(seq 1 "$padding"))│"
    echo "$top"
    echo "$middle"
    echo "$bottom"
}

build_ffmpeg_command() {
  local input_file="$1"
  local output_file="$2"
  local duration="$3"
  local mode="$4"
  local offset="${5:-0}"  # offset en secondes, par défaut 0
  local cq_value="${6:-$CQ}" # Dynamic CQ, fallback on global $CQ if undefined
  local ffmpeg_opts=()
  local timeout_limit=0
  local stats_opts=()
  if [[ "$mode" != "test" ]]; then
    stats_opts+=("-stats")
  fi

  [[ "$USE_HWACCEL" == "true" ]] && ffmpeg_opts+=("-hwaccel" "$HWACCEL_TYPE")

  if [[ "$mode" == "test" ]]; then
    ffmpeg_opts+=("-ss" "$offset" "-t" "$TEST_DURATION")
    timeout_limit=$TIMEOUT_SAMPLE 
  else
    timeout_limit=$TIMEOUT 
  fi
  
  # in case of subtitle error
  if [[ "$mode" == "no_sub" ]]; then
    ffmpeg_opts+=("-sn")
  fi

  # Only needed for mp4 and mov to enhance compatibility with Apple products
  container_ext="${input_file##*.}"
  container_args=()
  if [[ "$container_ext" =~ ^(mp4|mov|MP4|MOV)$ ]]; then
    container_args=(-tag:v hvc1 -movflags +faststart)
  fi

  if [[ "$KEEP_MULTICHANNEL_ORIGINAL_ENCODING" == "1" ]]; then
    channels=$(ffprobe -v error -select_streams a:0 -show_entries stream=channels -of csv=p=0 "$f")
    if [[ -z "$channels" || "$channels" -gt 2 ]]; then
      AUDIO_CODEC="copy"
    fi
  fi
  
  # ---- Nouveau : filtrer uniquement le flux vidéo principal ----
  # On récupère le premier flux vidéo qui n'est pas mjpeg
  main_video_index=$(ffprobe -v error -select_streams v -show_entries stream=index,codec_name \
                     -of csv=p=0 "$input_file" | grep -v '^.*,mjpeg$' | head -n1 | cut -d',' -f1)

  # On mappe uniquement le flux vidéo principal + audio + sous-titres
  map_args=("-map" "0:${main_video_index}" "-map" "0:a?" "-map" "0:s?")

  # Build codec-specific arguments
  local codec_args=()
  if [[ "$VIDEO_CODEC" == "hevc_videotoolbox" ]]; then
    # VideoToolbox uses q:v instead of cq, and doesn't use preset or rc
    # q:v range: 0-100 (lower is better quality)
    # Convert CQ (0-51) to q:v (0-100) approximately
    local vt_quality=$(awk "BEGIN {printf \"%.0f\", ($cq_value / 51) * 100}")
    codec_args=("-c:v" "$VIDEO_CODEC" "-q:v" "$vt_quality" "-pix_fmt" "yuv420p")
  elif [[ "$VIDEO_CODEC" == "hevc_nvenc" ]]; then
    # NVENC uses preset, rc, and cq
    codec_args=("-c:v" "$VIDEO_CODEC" "-pix_fmt" "yuv420p" "-preset" "$ENCODE_PRESET" "-rc" "vbr" "-cq" "$cq_value")
  else
    # Generic fallback (libx265, hevc_vaapi, hevc_qsv, etc.)
    if [[ -n "$ENCODE_PRESET" ]]; then
      codec_args=("-c:v" "$VIDEO_CODEC" "-pix_fmt" "yuv420p" "-preset" "$ENCODE_PRESET" "-cq" "$cq_value")
    else
      codec_args=("-c:v" "$VIDEO_CODEC" "-pix_fmt" "yuv420p" "-cq" "$cq_value")
    fi
  fi

  # Use timeout if available, otherwise run without timeout
  if command -v timeout &>/dev/null; then
    timeout --foreground "$timeout_limit" \
    ffmpeg -y "${ffmpeg_opts[@]}" \
    -fflags +genpts -avoid_negative_ts make_zero \
    -i "$input_file" \
    "${map_args[@]}" -hide_banner -loglevel "$LOGLEVEL" "${stats_opts[@]}" \
    "${codec_args[@]}" \
    -c:a "$AUDIO_CODEC" -b:a "$AUDIO_BITRATE" \
    -c:s copy \
    "${container_args[@]}" \
    "$output_file"
  elif command -v gtimeout &>/dev/null; then
    gtimeout --foreground "$timeout_limit" \
    ffmpeg -y "${ffmpeg_opts[@]}" \
    -fflags +genpts -avoid_negative_ts make_zero \
    -i "$input_file" \
    "${map_args[@]}" -hide_banner -loglevel "$LOGLEVEL" "${stats_opts[@]}" \
    "${codec_args[@]}" \
    -c:a "$AUDIO_CODEC" -b:a "$AUDIO_BITRATE" \
    -c:s copy \
    "${container_args[@]}" \
    "$output_file"
  else
    # No timeout available, run ffmpeg directly
    ffmpeg -y "${ffmpeg_opts[@]}" \
    -fflags +genpts -avoid_negative_ts make_zero \
    -i "$input_file" \
    "${map_args[@]}" -hide_banner -loglevel "$LOGLEVEL" "${stats_opts[@]}" \
    "${codec_args[@]}" \
    -c:a "$AUDIO_CODEC" -b:a "$AUDIO_BITRATE" \
    -c:s copy \
    "${container_args[@]}" \
    "$output_file"
  fi

}


print_boxed_message_multiline() {
    local padding=2
    local lines=()
    local max_length=0

    # Read multiline input via stdin (so we can preserve ANSI codes correctly)
    while IFS= read -r line || [[ -n "$line" ]]; do
        # Store original and stripped versions
        lines+=("$line")
        local stripped=$(echo -e "$line" | sed -E 's/\x1B\[[0-9;]*[mK]//g')
        (( ${#stripped} > max_length )) && max_length=${#stripped}
    done

    local width=$((max_length + padding * 2))
    local top="┌$(printf '─%.0s' $(seq 1 "$width"))┐"
    local bottom="└$(printf '─%.0s' $(seq 1 "$width"))┘"

    echo "$top"
    for line in "${lines[@]}"; do
        local stripped=$(echo -e "$line" | sed -E 's/\x1B\[[0-9;]*[mK]//g')
        local pad_right=$((width - ${#stripped} - padding))
        printf "│%*s%s%*s│\n" $padding "" "$(echo -e "$line")" $pad_right ""
    done
    echo "$bottom"
}



clear

echo "██   ██ ██████   ██████  ███████     ███████ ███    ██  ██████  ██████  ██████  ███████ ██████  
██   ██      ██ ██       ██          ██      ████   ██ ██      ██    ██ ██   ██ ██      ██   ██ 
███████  █████  ███████  ███████     █████   ██ ██  ██ ██      ██    ██ ██   ██ █████   ██████  
██   ██ ██      ██    ██      ██     ██      ██  ██ ██ ██      ██    ██ ██   ██ ██      ██   ██ 
██   ██ ███████  ██████  ███████     ███████ ██   ████  ██████  ██████  ██████  ███████ ██   ██
"




# Validate hardware acceleration support
if [[ "$USE_HWACCEL" == "true" ]]; then
  if ! ffmpeg -hide_banner -hwaccels 2>/dev/null | grep -q "$HWACCEL_TYPE"; then
    echo "⚠️  Hardware acceleration type '$HWACCEL_TYPE' not supported. Disabling."
    USE_HWACCEL=false
    VIDEO_CODEC="libx265"
    ENCODE_PRESET="medium"
  fi
  
  # Additional check for VideoToolbox encoder availability
  if [[ "$VIDEO_CODEC" == "hevc_videotoolbox" ]]; then
    if ! ffmpeg -hide_banner -encoders 2>/dev/null | grep -q "hevc_videotoolbox"; then
      echo "⚠️  hevc_videotoolbox encoder not available. Falling back to libx265."
      VIDEO_CODEC="libx265"
      ENCODE_PRESET="medium"
      HWACCEL_TYPE=""
      USE_HWACCEL=false
    fi
  fi
fi

# =====================
# Argument Parsing
# =====================


while [[ $# -gt 0 ]]; do
  case "$1" in
    -R) RECURSIVE=1 ; shift ;;
    min=*) raw_min="${1#min=}"; MIN_SIZE_BYTES=$(echo "$raw_min" | sed 's/,/./' | awk '{printf "%.0f", $1 * 1024 * 1024 * 1024}') ; shift ;;
    test=*) TEST_DURATION="${1#test=}"; TEST_DURATION=${TEST_DURATION%.*} ; shift ;;
    --dry-run) DRY_RUN=1 ; shift ;;
    --check) CHECK_MODE=1 ; RECURSIVE=1 ; shift ;;
    -keep-original) KEEP_ORIGINAL=1 ; shift ;;
    -allow-h265) ALLOW_H265=1 ; shift ;;
    -allow-av1) ALLOW_AV1=1 ; shift ;;
    -backup) BACKUP_DIR="$2" ; shift 2 ;;
    --clean) CLEAN_ONLY=1 ; shift ;;
    --purge) PURGE_ONLY=1 ; shift ;;
    --retry) RETRY=1 ; shift ;;
    -log) LOGLEVEL="info"; shift ;;
	  -stop-after) STOP_AFTER_HOURS=$(echo "$2" | sed 's/,/./' | awk '{printf "%.0f", $1}'); shift 2 ;;
    -regex=*) REGEX_FILTER="${1#--regex=}" ; shift ;;
    -h) usage ;;
    *) [[ -z "$FOLDER" ]] && FOLDER="$1" || usage; shift ;;
  esac
done

[[ -z "$FOLDER" || ! -d "$FOLDER" ]] && { echo "❌ Folder not found or not specified: $FOLDER"; exit 1; }


# =====================
# Cleaning task
# =====================
if (( CLEAN_ONLY > 0 )); then
  echo "🧹 Cleaning temporary files..."
  find_opts=( "$FOLDER" )
  (( RECURSIVE == 0 )) && find_opts+=( -maxdepth 1 )

  patterns=( -name '.tmp_encode_*' -o -name '.tmp_encode_test_*' -o -name 'encoded_tmp*' )

  find "${find_opts[@]}" -type f \( "${patterns[@]}" \) -print0 |
  while IFS= read -r -d '' file; do
    echo "🗑️  Removing: $file"
    rm -f "$file"
  done

  echo "✅ Cleanup complete."
  exit 0
fi

# =====================
# Purge encoded.list
# =====================
if (( PURGE_ONLY > 0 )); then
  echo "🧹 Purging failed.list files..."
  find_opts=( "$FOLDER" )
  (( RECURSIVE == 0 )) && find_opts+=( -maxdepth 1 )

  patterns=( -name 'encoded.list' )

  find "${find_opts[@]}" -type f \( "${patterns[@]}" \) -print0 |
  while IFS= read -r -d '' file; do
    echo "🗑️  Removing: $file"
    rm -f "$file"
  done

  echo "✅ Purge complete."
  exit 0
fi

# =====================
# Purge failed.list
# =====================
if (( RETRY > 0 )); then
  echo "🧹 Purging failed.list files..."
  find_opts=( "$FOLDER" )
  (( RECURSIVE == 0 )) && find_opts+=( -maxdepth 1 )

  patterns=( -name 'failed.list' )

  find "${find_opts[@]}" -type f \( "${patterns[@]}" \) -print0 |
  while IFS= read -r -d '' file; do
    echo "🗑️  Removing: $file"
    rm -f "$file"
  done

  echo "✅ Purge complete."
  exit 0
fi

############################
# Startup
############################

print_config() {
  print_boxed_message_multiline <<EOF
\e[1;1mENCODING SETTINGS\e[0m
\e[1;33mHardware Acceleration\e[0m      ${USE_HWACCEL} (${HWACCEL_TYPE})
\e[1;33mVideo Codec\e[0m                ${VIDEO_CODEC}
\e[1;33mAudio Codec\e[0m                ${AUDIO_CODEC} @ ${AUDIO_BITRATE}
\e[1;33mConstant Quality :\e[0m        
\e[1;33m->${CQ_WIDTH_THRESHOLD}\e[0m                     ${CQ_HD}
\e[1;33m-<${CQ_WIDTH_THRESHOLD}\e[0m                     ${CQ_SD}
\e[1;33m-Default\e[0m                   ${CQ}
\e[1;33mEncoding Preset\e[0m            ${ENCODE_PRESET}

\e[1;1mMEDIA FILTERS\e[0m
\e[1;33mMinimum bitrate\e[0m            ${MIN_BITRATE}kbps
\e[1;33mTest Clip Duration\e[0m         (3x) ${TEST_DURATION}s
\e[1;33mMinimum Size Ratio\e[0m         ${MIN_SIZE_RATIO}

\e[1;1mONE-TIME SETTINGS\e[0m  
\e[1;33mFolder\e[0m                     ${FOLDER}
\e[1;33mRecursive\e[0m                  ${RECURSIVE}
\e[1;33mREGEX Filter\e[0m               ${REGEX_FILTER}
\e[1;33mMinimum Size\e[0m               ${raw_min} GB
\e[1;33mKeep original\e[0m              ${KEEP_ORIGINAL}
\e[1;33mStop after\e[0m                 ${STOP_AFTER_HOURS}h
\e[1;33mAllow H265\e[0m                 ${ALLOW_H265}
\e[1;33mAllow AV1\e[0m                  ${ALLOW_AV1}
\e[1;33mBackup directory\e[0m           ${BACKUP_DIR}
\e[1;33mDry run\e[0m                    ${DRY_RUN}
EOF
 echo""
}

print_config

send_notif "New H265 encoding process started at $(date +"%H:%M:%S")
$FOLDER"

find_cmd=(find "$FOLDER")
[[ $RECURSIVE -eq 0 ]] && find_cmd+=( -maxdepth 1 )
find_cmd+=( -type f \( -iname '*.mkv' -o -iname '*.avi' -o -iname '*.mp4' -o -iname '*.m4v' -o -iname '*.mov' -o -iname '*.wmv' -o -iname '*.flv' -o -iname '*.divx' -o -iname '*.mpg' -o -iname '*.mpeg' \) )

echo "Scanning..."
candidates=()
all_videos=0
already_encoded=0
already_failed=0


# =====================
# Scanning and filtering
# =====================

skipped_low_bitrate=0
skipped_regex=0
skipped_too_small=0

while IFS= read -r f; do
  base=$(basename "$f")
  dir=$(dirname "$f")
  list_file="$dir/encoded.list"
  failed_file="$dir/failed.list"


   all_videos=$((all_videos + 1))
  echo -ne "\r├── $all_videos video files found / ${#candidates[@]} will be encoded / $already_encoded indicated as encoded / $already_failed indicated as failed"

  # Apply regex filter if specified
  if [[ -n "$REGEX_FILTER" && ! "$f" =~ $REGEX_FILTER ]]; then
    skipped_regex=$((skipped_regex + 1))
    continue
  fi

  #detect files too small
  size_bytes=$(stat -f%z "$f" 2>/dev/null || stat -c%s "$f" 2>/dev/null) || continue
  if (( MIN_SIZE_BYTES > 0 && size_bytes < MIN_SIZE_BYTES )); then
    skipped_too_small=$((skipped_too_small + 1))
    continue
  fi
  
  #detect already encoded
  if [[ -f "$list_file" ]] && grep -Fxq "$base" "$list_file"; then
  already_encoded=$((already_encoded + 1))
  continue
  fi
  
  #detect already failed
  if [[ -f "$failed_file" ]] && grep -Fxq "$base" "$failed_file"; then
    already_failed=$((already_failed + 1))
    continue
  fi

  #detect codec
  codec_name=$(ffprobe -v quiet -select_streams v:0 -show_entries stream=codec_name -of default=nokey=1:noprint_wrappers=1 "$f" 2>/dev/null) || continue
  if [[ "$codec_name" == "hevc" && $ALLOW_H265 -eq 0 ]]; then
    already_encoded=$((already_encoded + 1))
    continue
  fi
  if [[ "$codec_name" == "av1" && $ALLOW_AV1 -eq 0 ]]; then
    already_encoded=$((already_encoded + 1))
    continue
  fi

  # Robust duration detection
  duration=$(ffprobe -v error -select_streams v:0 -show_entries format=duration \
    -of default=nokey=1:noprint_wrappers=1 "$f" 2>/dev/null)

  # Normalize duration string (decimal comma to dot)
duration="${duration//,/.}"

# Validate the duration (must be a positive number)
if [[ -z "$duration" || ! "$duration" =~ ^[0-9]+([.][0-9]+)?$ ]]; then
  duration_int=1
else
  duration_int=${duration%.*}
  [[ "$duration_int" -gt 0 ]] || duration_int=1
fi

# Calculate actual bitrate in kbps
actual_bitrate=$(( (size_bytes * 8) / (duration_int * 1000) ))

if (( size_bytes / duration_int < MIN_BYTE_PER_SEC )); then
  skipped_low_bitrate=$((skipped_low_bitrate + 1))
  if [ "$MARK_AS_ENCODED" = "true" ]; then
    echo "$base" >> "$list_file"
  fi
  continue
fi


  
  candidates+=("$f")



  
done < <( "${find_cmd[@]}" )

  echo -ne "\r├── $all_videos video files found / ${#candidates[@]} will be encoded / $already_encoded indicated as encoded / $already_failed indicated as failed"
  echo ""
  echo ""
  echo "📊 Scan Summary:"
  echo "├── Total videos found: $all_videos"
  echo "├── Will be encoded: ${#candidates[@]}"
  echo "├── Already encoded (HEVC/AV1): $already_encoded"
  echo "├── Previously failed: $already_failed"
  echo "├── Skipped (low bitrate < ${MIN_BITRATE}kbps): $skipped_low_bitrate"
  [[ $skipped_too_small -gt 0 ]] && echo "├── Skipped (too small): $skipped_too_small"
  [[ $skipped_regex -gt 0 ]] && echo "├── Skipped (regex filter): $skipped_regex"
  echo ""
  
  if [[ $skipped_low_bitrate -gt 0 ]]; then
    echo "💡 TIP: $skipped_low_bitrate file(s) were skipped due to low bitrate."
    echo "   These files already have bitrate < ${MIN_BITRATE}kbps and are considered well-compressed."
    echo "   To encode them anyway, you can:"
    echo "   1. Lower MIN_BITRATE in the script (currently ${MIN_BITRATE}kbps)"
    echo "   2. Or edit the script and set MARK_AS_ENCODED=false"
    echo ""
  fi

if (( DRY_RUN == 1 )); then
  echo -e "\n📝 Compatible files for encoding:"
  for file in "${candidates[@]}"; do
    size_bytes=$(stat -f%z "$file" 2>/dev/null || stat -c%s "$file" 2>/dev/null)
    size_fmt=$(print_size "$size_bytes")
    codec=$(ffprobe -v error -select_streams v:0 -show_entries stream=codec_name -of default=nokey=1:noprint_wrappers=1 "$file")
    duration=$(ffprobe -v error -show_entries format=duration -of default=nokey=1:noprint_wrappers=1 "$file")
    duration_fmt=$(printf "%.0f sec" "$duration")
    echo "  📆 $(basename "$file") | $size_fmt | $codec | $duration_fmt"
  done
  echo -e "\n✅ ${#candidates[@]} file(s) listed."
  exit 0
fi

# =====================
# CHECK MODE - Analyze compression opportunities
# =====================
if (( CHECK_MODE == 1 )); then
  echo ""
  echo "🔍 Analyzing compression opportunities..."
  echo "   This will test-encode a sample of each video to estimate savings."
  echo ""
  
  # Array to store results: "savings_mb|savings_pct|original_size|estimated_size|filepath"
  declare -a check_results=()
  
  total_files=${#candidates[@]}
  current_file=0
  
  for f in "${candidates[@]}"; do
    current_file=$((current_file + 1))
    base=$(basename "$f")
    dir=$(dirname "$f")
    
    # Get file info
    size_bytes=$(stat -f%z "$f" 2>/dev/null || stat -c%s "$f" 2>/dev/null)
    codec_name=$(ffprobe -v quiet -select_streams v:0 -show_entries stream=codec_name -of default=nokey=1:noprint_wrappers=1 "$f" 2>/dev/null)
    width=$(ffprobe -v error -select_streams v:0 -show_entries stream=width -of default=nokey=1:noprint_wrappers=1 "$f" 2>/dev/null)
    duration=$(ffprobe -v error -select_streams v:0 -show_entries format=duration -of default=nokey=1:noprint_wrappers=1 "$f" 2>/dev/null)
    duration="${duration//,/.}"
    
    if [[ -z "$duration" || ! "$duration" =~ ^[0-9]+([.][0-9]+)?$ ]]; then
      duration_int=1
    else
      duration_int=${duration%.*}
      [[ "$duration_int" -gt 0 ]] || duration_int=1
    fi
    
    # Determine CQ value
    if [[ -n "$width" && "$width" =~ ^[0-9]+$ ]]; then
      if (( width >= CQ_WIDTH_THRESHOLD )); then
        file_CQ="$CQ_HD"
      else
        file_CQ="$CQ_SD"
      fi
    else
      file_CQ="$CQ"
    fi
    
    echo -ne "\r[$current_file/$total_files] Testing: $(basename "$f")...                    "
    
    # Perform test encoding (use middle of video)
    offset=$(( duration_int / 2 ))
    tmp_test="$dir/.tmp_check_test_${base}"
    
    # Build ffmpeg command for test
    ffmpeg_opts=()
    [[ "$USE_HWACCEL" == "true" && -n "$HWACCEL_TYPE" ]] && ffmpeg_opts+=("-hwaccel" "$HWACCEL_TYPE")
    
    codec_args=()
    if [[ "$VIDEO_CODEC" == "hevc_videotoolbox" ]]; then
      vt_quality=$(awk "BEGIN {printf \"%.0f\", ($file_CQ / 51) * 100}")
      codec_args=("-c:v" "$VIDEO_CODEC" "-q:v" "$vt_quality" "-pix_fmt" "yuv420p")
    elif [[ "$VIDEO_CODEC" == "hevc_nvenc" ]]; then
      codec_args=("-c:v" "$VIDEO_CODEC" "-pix_fmt" "yuv420p" "-preset" "$ENCODE_PRESET" "-rc" "vbr" "-cq" "$file_CQ")
    else
      if [[ -n "$ENCODE_PRESET" ]]; then
        codec_args=("-c:v" "$VIDEO_CODEC" "-pix_fmt" "yuv420p" "-preset" "$ENCODE_PRESET" "-cq" "$file_CQ")
      else
        codec_args=("-c:v" "$VIDEO_CODEC" "-pix_fmt" "yuv420p" "-cq" "$file_CQ")
      fi
    fi
    
    # Run test encoding
    ffmpeg -y "${ffmpeg_opts[@]}" \
      -ss "$offset" -t "$TEST_DURATION" \
      -i "$f" \
      -map 0:v:0 -map 0:a? \
      -hide_banner -loglevel error \
      "${codec_args[@]}" \
      -c:a "$AUDIO_CODEC" -b:a "$AUDIO_BITRATE" \
      -f mp4 \
      "$tmp_test" 2>/dev/null
    
    if [[ -f "$tmp_test" ]]; then
      test_size=$(stat -f%z "$tmp_test" 2>/dev/null || stat -c%s "$tmp_test" 2>/dev/null)
      rm -f "$tmp_test"
      
      # Estimate full file size
      if (( test_size > 0 )); then
        estimated_size=$(( (test_size * duration_int) / TEST_DURATION ))
        
        # Calculate savings
        if (( estimated_size < size_bytes )); then
          savings_bytes=$(( size_bytes - estimated_size ))
          savings_mb=$(awk "BEGIN {printf \"%.2f\", $savings_bytes / 1024 / 1024}")
          savings_pct=$(awk "BEGIN {printf \"%.1f\", ($savings_bytes * 100.0) / $size_bytes}")
          
          # Store result
          check_results+=("$savings_mb|$savings_pct|$size_bytes|$estimated_size|$f")
        fi
      fi
    fi
  done
  
  echo -ne "\r                                                                                \r"
  
  # Sort results by savings (descending)
  IFS=$'\n' sorted_results=($(sort -t'|' -k1 -rn <<<"${check_results[*]}"))
  unset IFS
  
  # Display results
  echo ""
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo "🎯 COMPRESSION OPPORTUNITIES (sorted by potential savings)"
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo ""
  
  if [[ ${#sorted_results[@]} -eq 0 ]]; then
    echo "❌ No compression opportunities found."
    echo "   All videos are already well-compressed or would not benefit from re-encoding."
    echo ""
    exit 0
  fi
  
  total_savings_bytes=0
  rank=1
  
  printf "%-4s %-8s %-8s %-12s %-12s %s\n" "Rank" "Savings" "%" "Original" "Estimated" "File"
  printf "%-4s %-8s %-8s %-12s %-12s %s\n" "----" "--------" "--------" "------------" "------------" "----"
  
  for result in "${sorted_results[@]}"; do
    IFS='|' read -r savings_mb savings_pct orig_size est_size filepath <<< "$result"
    
    orig_fmt=$(print_size "$orig_size")
    est_fmt=$(print_size "$est_size")
    filename=$(basename "$filepath")
    
    # Truncate filename if too long
    if [[ ${#filename} -gt 60 ]]; then
      filename="${filename:0:57}..."
    fi
    
    printf "%-4d %-8s %-8s %-12s %-12s %s\n" \
      "$rank" \
      "${savings_mb}MB" \
      "${savings_pct}%" \
      "$orig_fmt" \
      "$est_fmt" \
      "$filename"
    
    total_savings_bytes=$(awk "BEGIN {printf \"%.0f\", $total_savings_bytes + ($orig_size - $est_size)}")
    rank=$((rank + 1))
  done
  
  echo ""
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  total_savings_fmt=$(print_size "$total_savings_bytes")
  echo "💾 TOTAL POTENTIAL SAVINGS: $total_savings_fmt across ${#sorted_results[@]} file(s)"
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo ""
  echo "💡 To encode these files, run:"
  echo "   ./$(basename "$0") -R \"$FOLDER\""
  echo ""
  
  exit 0
fi


send_notif "$FOLDER
$all_videos video files found / ${#candidates[@]} will be encoded / $already_encoded indicated as encoded / $already_failed indicated as failed"


# =====================
# Encoding tasks
# =====================

encoding_number=0
start_time=$(date +%s)
stop_after_seconds=$(awk "BEGIN {printf \"%.0f\", $STOP_AFTER_HOURS * 3600}")

for f in "${candidates[@]}"; do
  encoding_number=$((encoding_number + 1))
  base=$(basename "$f")
  dir=$(dirname "$f")
  list_file="$dir/encoded.list"
  failed_file="$dir/failed.list"
  size_bytes=$(stat -f%z "$f" 2>/dev/null || stat -c%s "$f" 2>/dev/null)
  height=$(ffprobe -v error -select_streams v:0 -show_entries stream=height -of csv=p=0 "$f" 2>/dev/null)
  channels=$(ffprobe -v error -select_streams a:0 -show_entries stream=channels -of csv=p=0 "$f")
  

    # Get duration using ffprobe (robust version)
  # Force C locale for ffprobe numeric output and normalize commas to dots
  duration=$(LC_ALL=C ffprobe -v error -select_streams v:0 -show_entries format=duration \
    -of default=nokey=1:noprint_wrappers=1 "$f" 2>/dev/null || true)
  # Normalise la virgule en point (au cas où la locale aurait renvoyé "6,123")
  duration="${duration//,/.}"
  # Validate the duration (must be a positive number)
  if [[ -z "$duration" || ! "$duration" =~ ^[0-9]+([.][0-9]+)?$ ]]; then
    duration_int=1
  else
    duration_int=${duration%.*}
    if ! [[ "$duration_int" =~ ^[0-9]+$ ]] || (( duration_int <= 0 )); then
      duration_int=1
    fi
  fi
  duration_view=$(printf '%02d:%02d:%02d' $((duration_int/3600)) $(( (duration_int%3600)/60 )) $((duration_int%60)))



  # Try to get the video width using ffprobe
  width=$(ffprobe -v error -select_streams v:0 -show_entries stream=width -of csv=p=0 "$f" 2>/dev/null)

  # Fallback if ffprobe fails or returns an invalid width
  if [[ $? -ne 0 || -z "$width" || "$width" -le 0 ]]; then
    echo "Warning: Unable to determine width for '$f', using fallback CQ=$CQ"
    file_CQ="$CQ"
  else
    # Assign CQ based on width threshold
    if (( width >= $CQ_WIDTH_THRESHOLD )); then
      file_CQ="$CQ_HD"
    else
      file_CQ="$CQ_SD"
    fi
  fi
  

  if (( STOP_AFTER_HOURS > 0 )); then
  current_time=$(date +%s)
  elapsed=$((current_time - start_time))
    if (( elapsed >= stop_after_seconds )); then
      echo ""
      echo "⏱️  Stop limit of $STOP_AFTER_HOURS hour(s) reached. Exiting."
      send_notif "⏱️  Stop limit of $STOP_AFTER_HOURS hour(s) reached at $(date +"%H:%M:%S"). Exiting...
      $FOLDER"
      break
    fi
  fi


  echo ""
  print_boxed_message "Task $encoding_number / ${#candidates[@]} : $(basename "$f") ($(print_size "$size_bytes") | $duration_view | "$width"x"$height" | CQ=$file_CQ)"

  ext="${base##*.}"
  ext_lower=$(echo "$ext" | tr 'A-Z' 'a-z')
  # Convert all to MP4 for maximum compatibility
  output_ext="mp4"
  tmp_file="$dir/.tmp_encode_${base%.*}.$output_ext"
  tmp_test="$dir/.tmp_encode_test_${base}"


##############################
# SAMPLING
###############################


  # Perform 3 test encodings at 1/4, 1/2, and 3/4 of the duration
    offsets=(
      $(( duration_int / 4 ))
      $(( duration_int / 2 ))
      $(( duration_int * 3 / 4 ))
    )

total_test_size=0
success=true
test_number=0

print_timeline() {
  local step=$1
  case $step in
    1) echo -ne "\r|---🔎---|----|----| @ $(( duration_int / 4 ))s" ;;
    2) echo -ne "\r|----|---🔎---|----| @ $(( duration_int / 2 ))s";;
    3) echo -ne "\r|----|----|---🔎---| @ $(( duration_int * 3 / 4 ))s" ;;
    *) echo "|----|----|----|----|" ;;  #fallback
  esac
}

echo "🔎 Encoding samples (3x ${TEST_DURATION}s)"
test_sizes=()
for offset_auto in "${offsets[@]}"; do
  test_number=$((test_number + 1))

  # Affichage graphique ASCII de la timeline avec curseur
  print_timeline "$test_number"

  if [[ "$LOGLEVEL" == "info" || "$LOGLEVEL" == "verbose" ]]; then
    echo ""
    echo "│ ▶️  Running sample test at offset ${offset_auto}s (log level: $LOGLEVEL)"
    build_ffmpeg_command "$f" "$tmp_test" "$duration" test "$offset_auto" "$file_CQ" < /dev/null
    ret=$?
  else
    # mode silencieux par défaut
    if ! build_ffmpeg_command "$f" "$tmp_test" "$duration" test "$offset_auto" "$file_CQ" < /dev/null >/dev/null 2>&1 ; then
      echo -ne "\r├── ❌ Test encoding failed at offset ${offset_auto}s"
      rm -f "$tmp_test"
      success=false
      break
    fi
    ret=0
  fi

  # Vérifie le résultat du test
  if (( ret != 0 )); then
    echo -ne "\r├── ❌ Test encoding failed at offset ${offset_auto}s"
    rm -f "$tmp_test"
    success=false
    break
  fi

  test_size=$(stat -f%z "$tmp_test" 2>/dev/null || stat -c%s "$tmp_test" 2>/dev/null)
  test_sizes+=("$test_size")
  rm -f "$tmp_test"
done


# 🔸 Calcul de la médiane
IFS=$'\n' sorted_sizes=($(sort -n <<<"${test_sizes[*]}"))
unset IFS
median_test_size=${sorted_sizes[1]}  # 2e élément de la liste triée (index 1)

# 🔸 Estimation avec la médiane
estimated_size=$(( median_test_size * duration_int / TEST_DURATION ))
echo -ne "\r├── Estimated size (median of 3 samples): $(print_size "$estimated_size")"

threshold_bytes=$(awk "BEGIN {printf \"%d\", $MIN_SIZE_RATIO * $size_bytes}")

if (( estimated_size == 0 )); then
  echo ""
  echo "├── ❌ Estimated size is 0 bytes, possible error"

  if [[ "$ENCODE_FAILED" != true ]]; then
    echo "│   → Skipping (ENCODE_FAILED is false)"
    echo "$base" >> "$list_file"
    rm -f "$tmp_test"
    success=false
    continue
  else
    echo "│   → Not skipping because ENCODE_FAILED=true"
  fi

elif (( estimated_size >= threshold_bytes )); then
  perc=$(awk "BEGIN {printf \"%.0f\", $MIN_SIZE_RATIO * 100}")
  echo ""
  echo "├── ❌ Estimated size > ${perc}% of original, skipping"
  echo "$base" >> "$list_file"
  continue
fi


##############################
# FULL ENCODING
###############################

echo""
echo "▶️  Full encoding ($duration_view)"
  
output=$(build_ffmpeg_command "$f" "$tmp_file" "$duration" "full" 0 "$file_CQ" < /dev/null 2>&1 | tee >(cat >&2))
ffmpeg_status=$?

if [[ $ffmpeg_status -ne 0 ]]; then
  echo "├── ⚠️ Retry: forcing audio to AAC and removing subtitles"
  build_ffmpeg_command "$f" "$tmp_file" "$duration" "full" 0 "$file_CQ" < /dev/null >/dev/null 2>&1 \
    -c:a aac -b:a "$AUDIO_BITRATE" -sn
  ffmpeg_status=$?
fi


# Case 1: Subtitle codec issue — retry without subtitles
if echo "$output" | grep -qE 'Subtitle codec|Could not write header'; then
  echo "├── ⚠️ Subtitle codec error detected, retrying without subtitles..."
  output=$(build_ffmpeg_command "$f" "$tmp_file" "$duration" "no_sub" 0 "$file_CQ" < /dev/null 2>&1 | tee >(cat >&2))
  
  if [ $? -eq 0 ]; then
    echo "├── ✅ Encoding succeeded without subtitles"
  else
    echo "├── ❌ Encoding failed even without subtitles"
    echo "$output"
    rm -f "$tmp_file"
    echo "$base" >> "$failed_file"
    continue
  fi

# Case 2: General failure or critical errors
elif [[ $ffmpeg_status -ne 0 ]] || echo "$output" | grep -qE 'Could not write header|Error initializing output stream|invalid encoder|Invalid argument|Conversion failed|non-monotonically increasing'; then
  echo "├── ❌ Full encoding failed"
  echo "$output"
  rm -f "$tmp_file"
  echo "$base" >> "$failed_file"
  continue

# Case 3: Success (no error detected and ffmpeg exited cleanly)
else
  echo "├── ✅ Encoding succeeded"
fi


# Compare durations
echo "⏳  Duration validation"

new_duration=""
ffprobe_output=$(ffprobe -v error -show_entries format=duration -of default=nokey=1:noprint_wrappers=1 "$tmp_file" 2>&1)
ffprobe_status=$?

if (( ffprobe_status == 0 )) && [[ "$ffprobe_output" =~ ^[0-9]+(\.[0-9]+)?$ ]]; then
  new_duration="${ffprobe_output}"
else
  echo "├── ⚠️ ffprobe failed or invalid duration: $ffprobe_output"
  echo "├── ⚠️ Duration could not be validated, failing this file"
  rm -f "$tmp_file" || true
  echo "$base" >> "$failed_file"
  continue
fi

new_duration_int=${new_duration%.*}
duration_diff=$(( duration_int - new_duration_int ))
if (( duration_diff < 0 )); then
  duration_diff=$(( -duration_diff ))
fi

max_diff=2
if (( duration_diff > max_diff )); then
  echo "├── ❌ Duration mismatch (diff: ${duration_diff}s), encoded file rejected"
  rm -f "$tmp_file" || true
  echo "$base" >> "$failed_file"
  continue
else
  echo "├── ✅ Duration validated (diff: ${duration_diff}s)"
fi

echo "🎥  Video file replacement"

  new_size=$(stat -f%z "$tmp_file" 2>/dev/null || stat -c%s "$tmp_file" 2>/dev/null)
  if (( new_size < size_bytes )); then
    if (( KEEP_ORIGINAL == 1 )); then
      mv -f "$tmp_file" "${f%.*}_encoded.$output_ext"
      echo "├── ✅ Saved as ${f%.*}_encoded.$output_ext"
    else
      if [[ -n "$BACKUP_DIR" ]]; then
        mkdir -p "$BACKUP_DIR"
        cp -f "$f" "$BACKUP_DIR/"
        echo "├── ☁️  Backed up original to $BACKUP_DIR"
      fi
      mv -f "$tmp_file" "$f"
      echo "├── Replaced original"
    fi
    orig_size_fmt=$(print_size "$size_bytes")
    new_size_fmt=$(print_size "$new_size")
    reduc_percent=$(( (size_bytes - new_size)*100 / size_bytes ))
    echo "├── Size reduced: $orig_size_fmt → $new_size_fmt | −${reduc_percent}%"
  else
    echo "├── ⚠️  Encoded file is larger, skipping replacement"
    rm -f "$tmp_file"
  fi
  echo "$base" >> "$list_file"
done

echo "FINISHED !"

send_notif "$FOLDER
Process ended at $(date +"%H:%M:%S") 
$encoding_number / ${#candidates[@]}"
