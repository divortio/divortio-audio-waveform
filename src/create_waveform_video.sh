#!/bin/bash
set -e
set -o pipefail
SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd)
CHILD_SCRIPT="${SCRIPT_DIR}/process_chunk.sh"
INPUT_FILE=""
OUTPUT_FILE=""
TEMP_DIR_BASE=""

# ==============================================================================
# Style Configuration
# ==============================================================================
readonly FONT_FILE="/System/Library/Fonts/Helvetica.ttc" # <-- IMPORTANT: CHANGE THIS PATH
readonly FONT_COLOR="white"
readonly FONT_SIZE_SMALL=20
readonly FONT_SIZE_LARGE=28
readonly MARGIN=24
readonly LINE_HEIGHT_SMALL=$((FONT_SIZE_SMALL * 12 / 10))

# --- Argument Toggles & Values ---
SHOW_FILENAME=false
SHOW_TIMECODE_MS=false
SHOW_TIMECODE_S=false
DATE_RECORDED=""
DATETIME_RECORDED=""
DATE_REMASTERED=""
DATETIME_REMASTERED=""
DATE_RENDERED=""
DATETIME_RENDERED=""
SHOW_WATERMARK=false

function log() { echo "[$(date +'%Y-%m-%d %H:%M:%S')] [$(basename "$0")] $1"; }
function show_usage() {
  echo "Usage: $0 -i <input_audio> [-o <output_video>] [options]"
  echo "  -i, --input <file>         : Path to the input audio file (required)."
  echo "  -o, --output <file>        : Path for the final output video (optional)."
  echo "  -t, --temp <dir>           : Path for a temporary working directory (optional)."
  echo
  echo "Metadata Options:"
  echo "  --show-filename            : Render the input filename in the top left."
  echo "  --show-timecode-ms         : Render timecode (HH:MM:SS.ms) in the bottom right."
  echo "  --show-timecode-s          : Render timecode (HH:MM:SS) at the bottom center."
  echo "  --date-recorded <val>      : Set 'Date Recorded: YYYY-MM-DD' text."
  echo "  --datetime-recorded <val>  : Set 'Date Recorded: YYYY-MM-DDTHH:MM:SS' text."
  echo "  --date-remastered <val>    : Set 'Date Remastered: YYYY-MM-DD' text."
  echo "  --datetime-remastered <val>: Set 'Date Remastered: YYYY-MM-DDTHH:MM:SS' text."
  echo "  --date-rendered [val]      : Set 'Date Rendered: YYYY-MM-DD' text. Defaults to now."
  echo "  --datetime-rendered [val]  : Set 'Date Rendered: YYYY-MM-DDTHH:MM:SS' text. Defaults to now."
  echo "  --watermark                : Show the 'butterWaveform' watermark."
}
function cleanup() {
  if [[ -n "$TEMP_DIR" && -d "$TEMP_DIR" ]]; then
    log "Cleaning up temporary directory: $TEMP_DIR"
    rm -rf "$TEMP_DIR"
  fi
}
function on_fail() {
  log "❌ SCRIPT FAILED. Temp directory and logs preserved at: $TEMP_DIR"
  exit 1
}

# --- Argument Parsing ---
SCRIPT_START_DATE=$(date +'%Y-%m-%d')
SCRIPT_START_DATETIME=$(date +'%Y-%m-%dT%H:%M:%S')

# Robust argument parsing
while [[ "$#" -gt 0 ]]; do
  case $1 in
  -i | --input)
    INPUT_FILE="$2"
    shift
    shift
    ;;
  -o | --output)
    OUTPUT_FILE="$2"
    shift
    shift
    ;;
  -t | --temp)
    TEMP_DIR_BASE="$2"
    shift
    shift
    ;;
  --show-filename)
    SHOW_FILENAME=true
    shift
    ;;
  --show-timecode-ms)
    SHOW_TIMECODE_MS=true
    shift
    ;;
  --show-timecode-s)
    SHOW_TIMECODE_S=true
    shift
    ;;
  --date-recorded)
    DATE_RECORDED="$2"
    shift
    shift
    ;;
  --datetime-recorded)
    DATETIME_RECORDED="$2"
    shift
    shift
    ;;
  --date-remastered)
    DATE_REMASTERED="$2"
    shift
    shift
    ;;
  --datetime-remastered)
    DATETIME_REMASTERED="$2"
    shift
    shift
    ;;
  --watermark)
    SHOW_WATERMARK=true
    shift
    ;;
  --date-rendered)
    if [[ -n "$2" && "$2" != -* ]]; then
      DATE_RENDERED="$2"
      shift
      shift
    else
      DATE_RENDERED="$SCRIPT_START_DATE"
      shift
    fi
    ;;
  --datetime-rendered)
    if [[ -n "$2" && "$2" != -* ]]; then
      DATETIME_RENDERED="$2"
      shift
      shift
    else
      DATETIME_RENDERED="$SCRIPT_START_DATETIME"
      shift
    fi
    ;;
  -h | --help)
    show_usage
    exit 0
    ;;
  *)
    echo "Unknown parameter passed: $1"
    show_usage
    exit 1
    ;;
  esac
done

# --- Validation & Setup ---
if [[ -z "$INPUT_FILE" ]]; then
  log "ERROR: Input file is required." >&2
  show_usage
  exit 1
fi
if [[ ! -f "$INPUT_FILE" ]]; then
  log "ERROR: Input file not found at '$INPUT_FILE'" >&2
  exit 1
fi
if [[ ! -x "$CHILD_SCRIPT" ]]; then
  log "ERROR: Child script 'process_chunk.sh' not found or not executable in '$SCRIPT_DIR'." >&2
  exit 1
fi
ANY_TEXT_ENABLED=false
if [[ "$SHOW_FILENAME" == true || "$SHOW_TIMECODE_MS" == true || "$SHOW_TIMECODE_S" == true || -n "$DATE_RECORDED" || -n "$DATETIME_RECORDED" || -n "$DATE_REMASTERED" || -n "$DATETIME_REMASTERED" || -n "$DATE_RENDERED" || -n "$DATETIME_RENDERED" || "$SHOW_WATERMARK" == true ]]; then
  ANY_TEXT_ENABLED=true
  if [[ ! -f "$FONT_FILE" ]]; then
    log "ERROR: Font file not found at '$FONT_FILE'. Please update FONT_FILE." >&2
    exit 1
  fi
fi
# Other setup...
if [[ -z "$OUTPUT_FILE" ]]; then
  INPUT_DIR=$(dirname -- "$INPUT_FILE")
  INPUT_BASENAME=$(basename -- "$INPUT_FILE")
  OUTPUT_FILE="${INPUT_DIR}/${INPUT_BASENAME%.*}_wave.mp4"
fi
if [[ -n "$TEMP_DIR_BASE" ]]; then TEMP_DIR=$(mktemp -d -p "$TEMP_DIR_BASE" "waveform_XXXXXX"); else TEMP_DIR=$(mktemp -d "waveform_XXXXXX"); fi
trap on_fail ERR
LOG_DIR="${TEMP_DIR}/logs"
mkdir -p "$LOG_DIR"
log "Input:          $INPUT_FILE"
log "Output:         $OUTPUT_FILE"
log "Temp Directory: $TEMP_DIR"

# --- Main Script Body (Steps 1-3 are unchanged) ---
log "--- Step 1: Splitting audio into 5-second chunks ---"
ffmpeg -hide_banner -i "$INPUT_FILE" -f segment -segment_time 5 -c:a pcm_s16le "${TEMP_DIR}/chunk_%04d.wav"
log "--- Step 2: Processing audio chunks into video segments ---"
CORES=$(nproc 2>/dev/null || sysctl -n hw.ncpu 2>/dev/null || echo 4)
log "Using up to $CORES parallel jobs."
export CHILD_SCRIPT TEMP_DIR LOG_DIR
find "$TEMP_DIR" -name "chunk_*.wav" | sort | xargs -I {} -P "$CORES" \
  bash -c '
        chunk_file="$1"
        base_name=$(basename "$chunk_file" .wav)
        video_segment="'"$TEMP_DIR"'/video_${base_name#chunk_}.mp4"
        "$CHILD_SCRIPT" "$chunk_file" "$video_segment" "'"$LOG_DIR"'"
    ' _ {}
NUM_CHUNKS=$(find "$TEMP_DIR" -name "chunk_*.wav" | wc -l)
NUM_SEGMENTS=$(find "$TEMP_DIR" -name "video_*.mp4" | wc -l)
if [[ "$NUM_CHUNKS" -ne "$NUM_SEGMENTS" ]]; then
  log "ERROR: Mismatch in processed files." >&2
  exit 1
fi
log "All chunks processed successfully."
log "--- Step 3: Concatenating video segments ---"
CONCAT_LIST_FILE="${TEMP_DIR}/concat_list.txt"
SILENT_VIDEO_FILE="${TEMP_DIR}/final_silent_video.mp4"
find "$TEMP_DIR" -name "video_*.mp4" | sort | while read -r f; do echo "file '$(realpath "$f")'" >>"$CONCAT_LIST_FILE"; done
ffmpeg -y -hide_banner -f concat -safe 0 -i "$CONCAT_LIST_FILE" -c copy "$SILENT_VIDEO_FILE"

# --- Step 4: Final Assembly with Optional Metadata ---
log "--- Step 4: Final Assembly ---"

escape_text() {
  echo "$1" | sed "s/'/\\\\'/g; s/:/\\\\:/g; s/%/\\\\%/g"
}

drawtext_filters=""
if [[ "$SHOW_FILENAME" == true ]]; then
  FILENAME_TEXT=$(escape_text "$(basename "$INPUT_FILE")")
  drawtext_filters+="drawtext=fontfile='${FONT_FILE}':fontsize=${FONT_SIZE_SMALL}:fontcolor=${FONT_COLOR}:x=${MARGIN}:y=${MARGIN}:text='${FILENAME_TEXT}',"
fi
if [[ "$SHOW_TIMECODE_MS" == true ]]; then
  TIMECODE_MS_TEXT="%{pts\\:gmtime\\:0\\:%H\\\\\\:%M\\\\\\:%S}.%{eif\\:mod(t*1000\\,1000)\\:d\\:3}"
  drawtext_filters+="drawtext=fontfile='${FONT_FILE}':fontsize=${FONT_SIZE_SMALL}:fontcolor=${FONT_COLOR}:x=w-tw-${MARGIN}:y=h-th-${MARGIN}:text='${TIMECODE_MS_TEXT}',"
fi

bottom_left_lines=()
if [[ -n "$DATE_RENDERED" ]]; then bottom_left_lines+=("Date Rendered: $DATE_RENDERED"); fi
if [[ -n "$DATETIME_RENDERED" ]]; then bottom_left_lines+=("Date Rendered: $DATETIME_RENDERED"); fi
if [[ -n "$DATE_REMASTERED" ]]; then bottom_left_lines+=("Date Remastered: $DATE_REMASTERED"); fi
if [[ -n "$DATETIME_REMASTERED" ]]; then bottom_left_lines+=("Date Remastered: $DATETIME_REMASTERED"); fi
if [[ -n "$DATE_RECORDED" ]]; then bottom_left_lines+=("Date Recorded: $DATE_RECORDED"); fi
if [[ -n "$DATETIME_RECORDED" ]]; then bottom_left_lines+=("Date Recorded: $DATETIME_RECORDED"); fi

for i in "${!bottom_left_lines[@]}"; do
  line_text=$(escape_text "${bottom_left_lines[$i]}")
  y_pos="h-th-${MARGIN}-(${i}*${LINE_HEIGHT_SMALL})"
  drawtext_filters+="drawtext=fontfile='${FONT_FILE}':fontsize=${FONT_SIZE_SMALL}:fontcolor=${FONT_COLOR}:x=${MARGIN}:y=${y_pos}:text='${line_text}',"
done

if [[ "$SHOW_WATERMARK" == true ]]; then
  WATERMARK_L1=$(escape_text "Open Source")
  WATERMARK_L2=$(escape_text "butterWaveform, by Divort.io")
  drawtext_filters+="drawtext=fontfile='${FONT_FILE}':fontsize=${FONT_SIZE_SMALL}:fontcolor=${FONT_COLOR}:x=(w-tw)/2:y=h-th-${MARGIN}-${LINE_HEIGHT_SMALL}:text='${WATERMARK_L1}',"
  drawtext_filters+="drawtext=fontfile='${FONT_FILE}':fontsize=${FONT_SIZE_SMALL}:fontcolor=${FONT_COLOR}:x=(w-tw)/2:y=h-th-${MARGIN}:text='${WATERMARK_L2}',"
fi
if [[ "$SHOW_TIMECODE_S" == true ]]; then
  TIMECODE_S_TEXT="%{pts\\:gmtime\\:0\\:%H\\\\\\:%M\\\\\\:%S}"
  Y_POS_S=$((720 / 2 + 90 + MARGIN))
  drawtext_filters+="drawtext=fontfile='${FONT_FILE}':fontsize=${FONT_SIZE_LARGE}:fontcolor=${FONT_COLOR}:x=(w-tw)/2:y=${Y_POS_S}:text='${TIMECODE_S_TEXT}',"
fi

DUAL_MONO_FILTER="aformat=channel_layouts=mono,pan=stereo|c0=c0|c1=c0"
if [[ "$ANY_TEXT_ENABLED" == false ]]; then
  ffmpeg -y -hide_banner -i "$SILENT_VIDEO_FILE" -i "$INPUT_FILE" -map 0:v:0 -map 1:a:0 -af "$DUAL_MONO_FILTER" -c:v copy -c:a aac -b:a 192k -shortest "$OUTPUT_FILE"
else
  drawtext_filters=${drawtext_filters%?}
  filter_complex="[0:v]${drawtext_filters}[video_out]"
  ffmpeg -y -hide_banner -i "$SILENT_VIDEO_FILE" -i "$INPUT_FILE" -map 1:a:0 -filter_complex "${filter_complex}" -map "[video_out]" -af "$DUAL_MONO_FILTER" -c:v libx264 -preset medium -crf 23 -pix_fmt yuv420p -c:a aac -b:a 192k -shortest "$OUTPUT_FILE"
fi

log "✅ Success! Final video created at: $OUTPUT_FILE"
cleanup
