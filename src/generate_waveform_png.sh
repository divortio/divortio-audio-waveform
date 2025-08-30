#!/bin/bash
set -e

# --- Configuration ---
readonly DURATION=5
readonly WIDTH=1280
readonly HEIGHT=720
readonly HALF_HEIGHT=360

readonly NUM_BARS=100
readonly NUM_BINS=8                 # MODIFIED: Increased for more detail
readonly BAR_WIDTH=4
readonly GAP_WIDTH=8
readonly MAX_HEIGHT_SCALE=0.25      # MODIFIED: Scaled down to 25%

readonly VISUAL_WIDTH=$(( (NUM_BARS * BAR_WIDTH) + ((NUM_BARS - 1) * GAP_WIDTH) ))
readonly X_OFFSET=$(( (WIDTH - VISUAL_WIDTH) / 2 ))
readonly WAVE_COLOR="white"
readonly BG_COLOR="black"

# --- Function Definitions ---
function show_usage() { echo "Usage: $0 -i <input_audio> -o <output_png>"; }

# --- Argument Parsing ---
INPUT_FILE=""
OUTPUT_PNG=""
while [[ "$#" -gt 0 ]]; do
    case $1 in -i|--input) INPUT_FILE="$2"; shift ;; -o|--output) OUTPUT_PNG="$2"; shift ;; *) show_usage; exit 1 ;; esac; shift
done
if [[ -z "$INPUT_FILE" || -z "$OUTPUT_PNG" ]]; then show_usage; exit 1; fi

# --- Script Body ---
TEMP_DIR=$(mktemp -d "waveform_png_XXXXXX")
trap 'rm -rf -- "$TEMP_DIR"' EXIT
TEMP_CHUNK="${TEMP_DIR}/chunk.wav"
LEVELS_FILE="${TEMP_DIR}/levels.txt"
SLICE_DURATION=$(awk -v d="$DURATION" -v b="$NUM_BARS" 'BEGIN{print d/b}')

ffmpeg -y -hide_banner -i "$INPUT_FILE" -t "$DURATION" -c:a pcm_s16le "$TEMP_CHUNK" &>/dev/null
ffprobe -v error -f lavfi \
    -i "amovie=${TEMP_CHUNK},astats=metadata=1:length=${SLICE_DURATION},ametadata=mode=print:key=lavfi.astats.Overall.Peak_level:file=-" \
    -show_entries frame_tags=lavfi.astats.Overall.Peak_level -of default=noprint_wrappers=1 \
    | grep "lavfi.astats.Overall.Peak_level" | awk -F'=' '{print $2}' > "$LEVELS_FILE"

max_peak_db=$(awk 'BEGIN{max=-999} {if ($1>max && $1!="-inf") max=$1} END{print max}' "$LEVELS_FILE")
if [[ -z "$max_peak_db" || "$max_peak_db" == "-999" ]]; then max_peak_db=0; fi

draw_cmds=""
bar_index=0
while read -r peak_db; do
    if [[ -z "$peak_db" || "$peak_db" == "-inf" ]]; then amplitude=0; else
        relative_db=$(awk -v peak="$peak_db" -v max="$max_peak_db" 'BEGIN{print peak-max}')
        amplitude=$(awk -v db="$relative_db" 'BEGIN{print 10^(db/20)}')
    fi

    level=$(awk -v amp="$amplitude" -v bins="$NUM_BINS" 'BEGIN{print int(amp * bins + 0.9999)}')

    # MODIFIED: Logic to draw a bar for silence
    if [[ "$level" -eq 0 ]]; then
        level=1 # Force silent sections to be Level 1
    fi

    bar_height=$(awk -v lvl="$level" -v max_h="$HALF_HEIGHT" -v bins="$NUM_BINS" -v scale="$MAX_HEIGHT_SCALE" 'BEGIN{print int((lvl * max_h / bins) * scale)}')

    if [[ "$bar_height" -lt 1 ]]; then bar_height=1; fi

    x_pos=$(( X_OFFSET + (bar_index * (BAR_WIDTH + GAP_WIDTH)) ))
    y_top=$(( HALF_HEIGHT - bar_height ))
    y_bottom=$(( HALF_HEIGHT ))
    draw_cmds+="drawbox=x=${x_pos}:y=${y_top}:w=${BAR_WIDTH}:h=${bar_height}:c=${WAVE_COLOR}:t=fill,"
    draw_cmds+="drawbox=x=${x_pos}:y=${y_bottom}:w=${BAR_WIDTH}:h=${bar_height}:c=${WAVE_COLOR}:t=fill,"

    bar_index=$(( bar_index + 1 ))
done < "$LEVELS_FILE"

if [[ -n "$draw_cmds" ]]; then
    draw_cmds=${draw_cmds%?}
    ffmpeg -y -hide_banner -f lavfi -i "color=c=${BG_COLOR}:s=${WIDTH}x${HEIGHT}:d=1:r=1" -filter_complex "$draw_cmds" -frames:v 1 -update 1 "$OUTPUT_PNG"
fi
echo "✅ Success! PNG created at $OUTPUT_PNG"