#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Compare host VA-API copy-back and VPP with the same input and CPU output format.
set -euo pipefail

if (( $# != 3 )); then
    echo "Usage: bash $0 CLIP RENDER_NODE NEW_OUTPUT_DIRECTORY" >&2
    exit 2
fi

clip=$1
node=$2
out=$3
ffmpeg_bin=${FFMPEG_BIN:-ffmpeg}

[[ -f "$clip" && -r "$clip" ]] || { echo "Cannot read clip: $clip" >&2; exit 2; }
[[ -c "$node" && -r "$node" && -w "$node" ]] || { echo "Cannot access render node: $node" >&2; exit 2; }
command -v "$ffmpeg_bin" >/dev/null
mkdir -- "$out"
"$ffmpeg_bin" -version > "$out/ffmpeg-version.txt"
if command -v vainfo >/dev/null; then
    vainfo --display drm --device "$node" > "$out/vainfo.txt" 2>&1 || true
fi

hw=(-hwaccel vaapi -hwaccel_device "$node" -hwaccel_output_format vaapi)
failed=0

run_case() {
    local label=$1 filter=$2
    shift 2
    if "$ffmpeg_bin" -hide_banner -nostdin -loglevel info -xerror -benchmark \
        -nostats -stats_period 0.25 -progress pipe:1 -filter_threads 2 \
        "$@" -i "$clip" -map 0:v:0 -an -sn -dn -vf "$filter" \
        -fps_mode passthrough -f null - \
        > "$out/$label.progress" 2> "$out/$label.log"; then
        awk -F= '/^frame=/{frame=$2} /^fps=/{fps=$2}
            END{printf "%s frames=%s fps=%s\n", label, frame, fps}' \
            label="$label" "$out/$label.progress" | tee -a "$out/summary.txt"
    else
        printf '%s failed (see %s)\n' "$label" "$out/$label.log" | tee -a "$out/summary.txt"
        failed=1
    fi
}

run_case software-full 'scale=flags=bicubic,format=yuv420p'
run_case copy-full 'hwdownload,format=p010le,scale=flags=bicubic,format=yuv420p' "${hw[@]}"
run_case map-full 'hwmap=mode=read+direct,format=p010le,scale=flags=bicubic,format=yuv420p' "${hw[@]}"
run_case vpp-full 'scale_vaapi=format=nv12,hwdownload,format=nv12,format=yuv420p' "${hw[@]}"
run_case vpp-720 'scale_vaapi=w=1280:h=720:format=nv12,hwdownload,format=nv12,format=yuv420p' "${hw[@]}"
exit "$failed"
