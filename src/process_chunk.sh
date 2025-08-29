#!/bin/bash
set -e
set -o pipefail

# --- Configuration ---
readonly DURATION=5
readonly WIDTH=1280
readonly HEIGHT=720
readonly HALF_HEIGHT=360
readonly FPS=30
readonly WAVE_COLOR_UNPLAYED="#808695"
readonly WAVE_COLOR_PLAYED="#a8c7fa"
readonly BG_COLOR="#202124"
readonly NUM_BARS=100
readonly NUM_BINS=8
readonly BAR_WIDTH=4
readonly GAP_WIDTH=8
readonly MAX_HEIGHT_SCALE=0.25
readonly VISUAL_WIDTH=$(( (NUM_BARS * BAR_WIDTH) + ((NUM_BARS - 1) * GAP_WIDTH) ))
readonly X_OFFSET=$(( (WIDTH - VISUAL_WIDTH) / 2 ))

function log() { echo "[$(date +'%Y-%m-%d %H:%M:%S')] [$(basename "$0")] $1"; }

if [[ "$#" -ne 3 ]]; then exit 1; fi
readonly INPUT_CHUNK="$1"
readonly OUTPUT_VIDEO_SEGMENT="$2"
readonly LOG_DIR="$3"
readonly CHUNK_BASENAME=$(basename "$INPUT_CHUNK")
readonly ERROR_LOG="${LOG_DIR}/${CHUNK_BASENAME%.*}_error.log"

readonly CHUNK_DURATION=$(ffprobe -v error -show_entries format=duration -of default=noprint_wrappers=1:nokey=1 "$INPUT_CHUNK")
readonly SLICE_DURATION=$(awk -v d="$CHUNK_DURATION" -v b="$NUM_BARS" 'BEGIN{print d/b}')

played_cmds=""
unplayed_cmds=""
log "Analyzing chunk in ${NUM_BARS} slices: $CHUNK_BASENAME"
for i in $(seq 0 $((NUM_BARS - 1))); do
    start_time=$(awk -v i="$i" -v s="$SLICE_DURATION" 'BEGIN{print i*s}')

    vol_output=$(ffmpeg -y -hide_banner -ss "$start_time" -t "$SLICE_DURATION" -i "$INPUT_CHUNK" -af volumedetect -f null - 2>&1)
    peak_db=$(echo "$vol_output" | grep "max_volume" | awk -F': ' '{print $2}' | sed 's/ dB//' || echo "-inf")

    level=0
    if [[ "$peak_db" != "-inf" ]]; then
        if (( $(echo "$peak_db > -6" | bc -l) )); then level=8
        elif (( $(echo "$peak_db > -12" | bc -l) )); then level=7
        elif (( $(echo "$peak_db > -18" | bc -l) )); then level=6
        elif (( $(echo "$peak_db > -24" | bc -l) )); then level=5
        elif (( $(echo "$peak_db > -30" | bc -l) )); then level=4
        elif (( $(echo "$peak_db > -36" | bc -l) )); then level=3
        elif (( $(echo "$peak_db > -42" | bc -l) )); then level=2
        else level=1; fi
    else
        level=1
    fi

    bar_height=$(awk -v lvl="$level" -v max_h="$HALF_HEIGHT" -v bins="$NUM_BINS" -v scale="$MAX_HEIGHT_SCALE" 'BEGIN{print int((lvl * max_h / bins) * scale)}')
    if [[ "$bar_height" -lt 1 ]]; then bar_height=1; fi
    x_pos=$(( X_OFFSET + (i * (BAR_WIDTH + GAP_WIDTH)) ))
    y_pos=$(( HALF_HEIGHT - bar_height ))
    played_cmds+="drawbox=x=${x_pos}:y=${y_pos}:w=${BAR_WIDTH}:h=${bar_height}:c=${WAVE_COLOR_PLAYED}@1.0:t=fill,"
    unplayed_cmds+="drawbox=x=${x_pos}:y=${y_pos}:w=${BAR_WIDTH}:h=${bar_height}:c=${WAVE_COLOR_UNPLAYED}@1.0:t=fill,"
done

log "Rendering video for: $CHUNK_BASENAME"
played_cmds=${played_cmds%?}
unplayed_cmds=${unplayed_cmds%?}
ffmpeg -y -hide_banner \
    -f lavfi -i "color=c=black@0.0:s=${WIDTH}x${HALF_HEIGHT}:d=${CHUNK_DURATION}:r=${FPS}" \
    -f lavfi -i "color=c=black@0.0:s=${WIDTH}x${HALF_HEIGHT}:d=${CHUNK_DURATION}:r=${FPS}" \
    -filter_complex "
        [0:v] ${unplayed_cmds} [unplayed_wave];
        [1:v] ${played_cmds} [played_wave];
        color=c=black:s=${WIDTH}x${HALF_HEIGHT}:d=${DURATION}:r=${FPS} [mask_base];
        color=c=white:s=${WIDTH}x${HALF_HEIGHT}:d=${DURATION}:r=${FPS} [mask_color];
        [mask_base][mask_color] overlay=x='-w+(w/${CHUNK_DURATION})*t' [animated_mask];
        [played_wave][animated_mask] alphamerge [played_animated];
        [unplayed_wave][played_animated] overlay [animated_top_half];
        [animated_top_half] split [top][bottom];
        [bottom] vflip [bottom_flipped];
        [top][bottom_flipped] vstack [mirrored_waves];
        color=c=${BG_COLOR}:s=${WIDTH}x${HEIGHT}:d=${CHUNK_DURATION}:r=${FPS} [bg];
        [bg][mirrored_waves] overlay=(W-w)/2:(H-h)/2 [final_video]
    " \
    -map "[final_video]" -t "$CHUNK_DURATION" -c:v libx264 -preset medium -crf 23 -pix_fmt yuv420p -an "$OUTPUT_VIDEO_SEGMENT" &> "$ERROR_LOG"
log "Finished chunk: $CHUNK_BASENAME"