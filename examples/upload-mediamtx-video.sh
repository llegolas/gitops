#!/bin/bash
# Transcodes a local video into something both HLS and WebRTC can carry
# (MediaMTX does not transcode) and copies it into the mediamtx-videos PVC,
# where camera-sim-files publishes it on a loop as rtsp://camera-sim:8554/<name>
# (a simulated camera). <name> may contain slashes, e.g. cabinet1/camera3.
#
#   H264 Constrained Baseline (no B-frames, which WebRTC can't handle), 720p30,
#   fixed 2s GOP (aligned HLS segments), Opus 48kHz stereo (WebRTC has no AAC).
#
# ffmpeg runs in the same image the cluster uses (Fedora's ffmpeg-free has no
# libx264). Usage: upload-mediamtx-video.sh <input-file> [stream-name]
set -euo pipefail

IN=$(realpath "$1")
NAME=${2:-$(basename "${IN%.*}" | tr -c 'A-Za-z0-9_-' '_')}
if ! [[ "$NAME" =~ ^[A-Za-z0-9_-]+(/[A-Za-z0-9_-]+)*$ ]]; then
  echo "invalid stream name: $NAME" >&2; exit 1
fi
FILE=$(basename "$NAME")
NS=mediamtx
PVC=mediamtx-videos
LOADER=mediamtx-videos-loader
ENGINE=${CONTAINER_ENGINE:-podman}
FFMPEG_IMAGE=docker.io/jrottenberg/ffmpeg:8.1.2-ubuntu2404-amd64

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"; kubectl -n "$NS" delete pod "$LOADER" --ignore-not-found --wait=false >/dev/null' EXIT

echo "==> transcoding $IN -> $NAME.mkv"
"$ENGINE" run --rm \
  -v "$(dirname "$IN")":/in:ro,Z -v "$TMP":/out:Z \
  "$FFMPEG_IMAGE" -hide_banner -loglevel warning -stats -y \
  -i "/in/$(basename "$IN")" \
  -map 0:v:0 -map "0:a:0?" \
  -vf "scale=1280:-2,fps=30" \
  -c:v libx264 -preset veryfast -crf 23 -maxrate 3M -bufsize 6M \
  -pix_fmt yuv420p -profile:v baseline -bf 0 -g 60 -keyint_min 60 -sc_threshold 0 \
  -c:a libopus -b:a 128k -ar 48000 -ac 2 \
  -f matroska "/out/$FILE.mkv"

echo "==> copying into pvc/$PVC"
kubectl -n "$NS" apply -f - <<YAML
apiVersion: v1
kind: Pod
metadata:
  name: $LOADER
spec:
  restartPolicy: Never
  containers:
    - name: loader
      image: busybox:1.37
      command: ["sleep", "3600"]
      volumeMounts:
        - name: videos
          mountPath: /videos
  volumes:
    - name: videos
      persistentVolumeClaim:
        claimName: $PVC
YAML
kubectl -n "$NS" wait --for=condition=Ready "pod/$LOADER" --timeout=120s
kubectl -n "$NS" exec "$LOADER" -- mkdir -p "/videos/$(dirname "$NAME")"
kubectl -n "$NS" cp "$TMP/$FILE.mkv" "$LOADER:/videos/$NAME.mkv.part"
kubectl -n "$NS" exec "$LOADER" -- mv "/videos/$NAME.mkv.part" "/videos/$NAME.mkv"
kubectl -n "$NS" exec "$LOADER" -- find /videos -name '*.mkv' 

echo "==> restarting publisher"
kubectl -n "$NS" rollout restart deploy/camera-sim-files
echo "done: rtsp://camera-sim:8554/$NAME -- add a replica path with this source to serve it"
