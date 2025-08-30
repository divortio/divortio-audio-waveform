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
readonly VISUAL_WIDTH=$(((NUM_BARS * BAR_WIDTH) + ((NUM_BARS - 1) * GAP_WIDTH)))
readonly X_OFFSET=$(((WIDTH - VISUAL_WIDTH) / 2))

function log() { echo "[$(date +'%Y-%m-%d %H:%M:%S')] [$(basename "$0")] $1"; }

if [[ "$#" -ne 3 ]]; then exit 1; fi
readonly INPUT_CHUNK="$1"
readonly OUTPUT_VIDEO_SEGMENT="$2"
readonly LOG_DIR="$3"
readonly CHUNK_BASENAME=$(basename "$INPUT_CHUNK")
readonly ERROR_LOG="${LOG_DIR}/${CHUNK_BASENAME%.*}_error.log"
readonly TEMP_DIR=$(dirname "$LOG_DIR")
readonly LEVELS_FILE="${TEMP_DIR}/${CHUNK_BASENAME%.*}_levels.txt"
readonly SLICE_DURATION=.05

SAMPLE_RATE=$(ffprobe -v error -select_streams a:0 -show_entries stream=sample_rate -of default=noprint_wrappers=1:nokey=1 "$INPUT_CHUNK")
SLICE_SAMPLES=$((SAMPLE_RATE / 20)) # 1/20th of a second = 0.05s

log "Analyzing chunk: $CHUNK_BASENAME (${SAMPLE_RATE}) (${SLICE_SAMPLES} samples)"
# This is the corrected analysis command with 'reset=1' to ensure
# each 0.05s slice is measured independently.
#ffmpeg -y -hide_banner -i "$INPUT_CHUNK" \
#  -af "aformat=channel_layouts=mono,asetnsamples=n=${SLICE_SAMPLES}:p=0,astats=metadata=1:reset=1,ametadata=mode=print:key=lavfi.astats.Overall.Peak_level:file=-" \
#  -f null - 2>&1 | grep "lavfi.astats.Overall.Peak_level" | awk -F'=' '{print $2}' >"$LEVELS_FILE"
#
# This works
#ffprobe -v error -f lavfi \
#  -i "amovie=${INPUT_CHUNK},astats=metadata=1:length=${SLICE_DURATION}:reset=1,ametadata=mode=print:key=lavfi.astats.Overall.RMS_level:file=-" \
#  -show_entries frame_tags=lavfi.astats.Overall.RMS_level -of default=noprint_wrappers=1 |
#  grep "lavfi.astats.Overall.RMS_level" | awk -F'=' '{print $2}' >"$LEVELS_FILE"

SAMPLES_PER_INTERVAL=$(printf "%.0f" $(echo "$SAMPLE_RATE * 0.05" | bc))
log "Audio sample rate: ${SAMPLE_RATE}"
log "Samples per 0.05s interval: ${SAMPLES_PER_INTERVAL}"

ffprobe -v error -f lavfi \
  -i "amovie=${INPUT_CHUNK},aformat=channel_layouts=mono,asetnsamples=n=${SAMPLES_PER_INTERVAL}:p=1,astats=metadata=1:reset=1,ametadata=mode=print:key=lavfi.astats.Overall.Peak_level:file=-" \
  -show_entries frame_tags=lavfi.astats.Overall.Peak_level -of default=noprint_wrappers=1 |
  grep "lavfi.astats.Overall.Peak_level" | awk -F'=' '{print $2}' >"$LEVELS_FILE"

played_cmds=""
unplayed_cmds=""
bar_index=0
while read -r peak_db; do
  # Absolute dB Threshold Logic
  level=$(awk -v db="$peak_db" '
        BEGIN {
            if (db > -6)      { print 8 }
            else if (db > -12) { print 7 }
            else if (db > -18) { print 6 }
            else if (db > -24) { print 5 }
            else if (db > -30) { print 4 }
            else if (db > -36) { print 3 }
            else if (db > -42) { print 2 }
            else              { print 1 }
        }
    ')

  bar_height=$(awk -v lvl="$level" -v max_h="$HALF_HEIGHT" -v bins="$NUM_BINS" -v scale="$MAX_HEIGHT_SCALE" 'BEGIN{print int((lvl * max_h / bins) * scale)}')
  if [[ "$bar_height" -lt 1 ]]; then bar_height=1; fi

  x_pos=$((X_OFFSET + (bar_index * (BAR_WIDTH + GAP_WIDTH))))
  y_pos=$((HALF_HEIGHT - bar_height))
  played_cmds+="drawbox=x=${x_pos}:y=${y_pos}:w=${BAR_WIDTH}:h=${bar_height}:c=${WAVE_COLOR_PLAYED}@1.0:t=fill,"
  unplayed_cmds+="drawbox=x=${x_pos}:y=${y_pos}:w=${BAR_WIDTH}:h=${bar_height}:c=${WAVE_COLOR_UNPLAYED}@1.0:t=fill,"
  bar_index=$((bar_index + 1))
done <"$LEVELS_FILE"

log "Rendering video for: $CHUNK_BASENAME"
if [[ -z "$played_cmds" ]]; then
  ffmpeg -y -hide_banner -f lavfi -i "color=c=${BG_COLOR}:s=${WIDTH}x${HEIGHT}:d=${DURATION}:r=${FPS}" -c:v libx264 -pix_fmt yuv420p -an "$OUTPUT_VIDEO_SEGMENT" &>"$ERROR_LOG"
else
  played_cmds=${played_cmds%?}
  unplayed_cmds=${unplayed_cmds%?}
  ffmpeg -y -hide_banner \
    -f lavfi -i "color=c=black@0.0:s=${WIDTH}x${HALF_HEIGHT}:d=${DURATION}:r=${FPS}" \
    -f lavfi -i "color=c=black@0.0:s=${WIDTH}x${HALF_HEIGHT}:d=${DURATION}:r=${FPS}" \
    -filter_complex "
            [0:v] ${unplayed_cmds} [unplayed_wave];
            [1:v] ${played_cmds} [played_wave];
            color=c=black:s=${WIDTH}x${HALF_HEIGHT}:d=${DURATION}:r=${FPS} [mask_base];
            color=c=white:s=${WIDTH}x${HALF_HEIGHT}:d=${DURATION}:r=${FPS} [mask_color];
            [mask_base][mask_color] overlay=x='-w+(w/${DURATION})*t' [animated_mask];
            [played_wave][animated_mask] alphamerge [played_animated];
            [unplayed_wave][played_animated] overlay [animated_top_half];
            [animated_top_half] split [top][bottom];
            [bottom] vflip [bottom_flipped];
            [top][bottom_flipped] vstack [mirrored_waves];
            color=c=${BG_COLOR}:s=${WIDTH}x${HEIGHT}:d=${DURATION}:r=${FPS} [bg];
            [bg][mirrored_waves] overlay=(W-w)/2:(H-h)/2 [final_video]
        " \
    -map "[final_video]" -c:v libx264 -preset medium -crf 23 -pix_fmt yuv420p -an "$OUTPUT_VIDEO_SEGMENT" &>"$ERROR_LOG"
fi
log "Finished chunk: $CHUNK_BASENAME"
