#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Proves which Android media process used the GPU's video engine.
#
#   sample-video-engine.sh OUT [INTERVAL]   sample until killed (default 0.2 s)
#   sample-video-engine.sh --summary OUT    per process: CPU seconds and video-engine ms
#
# For this user's host processes that are Android media processes (the FFmpeg
# Codec2 service, Android's software codecs, mediaserver, the media probe), it
# logs CPU ticks and the DRM fdinfo video-engine time: drm-engine-video (i915)
# and drm-engine-dec (amdgpu). A process's counter restarts when it closes and
# reopens the render node (a new decoder session), which --summary accounts
# for. Hardware decoding shows video-engine time for
# android.hardware.media.c2-ffmpeg-service; software decoding shows none.
# Run it during a test, e.g.:
#   bash tests/runtime/sample-video-engine.sh /tmp/v.log & s=$!
#   bash tests/runtime/run-apk.sh ... --video-hwaccel --execute; kill $s
#   bash tests/runtime/sample-video-engine.sh --summary /tmp/v.log
set -u

if [[ "${1:-}" == --summary ]]; then
    [[ -r "${2:-}" ]] || { echo "usage: $0 --summary OUT" >&2; exit 2; }
    awk '{
        for (i = 1; i <= NF; i++) { split($i, a, "="); v[a[1]] = a[2] }
        c = $0; sub(/.*cmd=/, "", c); p = v["pid"]; name[p] = c
        if (!(p in c0)) c0[p] = v["cpu_ticks"]
        c1[p] = v["cpu_ticks"]
        x = v["video_ns"] + 0
        if (x < last[p]) total[p] += last[p]
        last[p] = x
    } END {
        for (p in name)
            printf "%-60s cpu_s=%.2f video_ms=%.1f\n", substr(name[p], 1, 60),
                   (c1[p] - c0[p]) / 100, (total[p] + last[p]) / 1e6
    }' "$2" | sort
    exit 0
fi

out="${1:?usage: $0 OUT [INTERVAL] | --summary OUT}"
interval="${2:-0.2}"
: > "$out"
while :; do
    t=$(date +%T.%N | cut -c1-12)
    for p in $(pgrep -u "$(id -u)" -f 'mediaswcodec|media.c2|c2-ffmpeg|media.codec|mediaserver|org.lepton.smoke|android.hardware.media'); do
        cmd=$(tr '\0' ' ' < "/proc/$p/cmdline" 2>/dev/null | cut -c1-60)
        [[ -n "$cmd" ]] || continue
        cpu=$(awk '{print $14+$15}' "/proc/$p/stat" 2>/dev/null)
        vid=0
        for fd in /proc/"$p"/fdinfo/*; do
            x=$(awk '/^drm-engine-(video|dec):/{s+=$2} END{print s+0}' "$fd" 2>/dev/null)
            vid=$((vid + ${x:-0}))
        done
        echo "$t pid=$p cpu_ticks=${cpu:-0} video_ns=$vid cmd=$cmd" >> "$out"
    done
    sleep "$interval"
done
