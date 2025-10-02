#!/usr/bin/env bash
set -euo pipefail

# Quality-first 360 joiner for YouTube.
# Requires: ffmpeg, exiftool, jq
# Optional: spatialmedia (pip install --user spatialmedia)

# ---- options --------------------------------------------------------------
want_h264=0              # kept for parity; if set, re-encode H.264 instead of HEVC
vt_bitrate="80M"         # default VT bitrate if we must re-encode with VT
use_vt=0                 # force VT re-encode with --vt <bitrate>
use_x265=0               # use libx265 CRF if needed: --hevc-crf <N>
x265_crf=12
use_prores=0             # use ProRes mezzanine if needed: --prores
out="joined_360.mp4"

# parse
while (( $# )); do
  case "$1" in
    --h264) want_h264=1 ;;
    --vt) shift; vt_bitrate="${1:-80M}"; use_vt=1 ;;
    --hevc-crf) shift; x265_crf="${1:-12}"; use_x265=1 ;;
    --prores) use_prores=1 ;;
    *) out="$1" ;;
  esac
  shift || true
done

# ---- inputs ---------------------------------------------------------------
shopt -s nullglob
files=( *.mp4 )
(( ${#files[@]} >= 2 )) || { echo "Need >=2 .mp4 files"; exit 1; }

# sort for consistent order
IFS=$'\n' files=($(printf '%s\n' "${files[@]}" | sort)); unset IFS

echo "Inputs (${#files[@]}):"
for f in "${files[@]}"; do echo "  - $f"; done
echo

# ---- helpers --------------------------------------------------------------
get_video_info() {
  ffprobe -v quiet -print_format json -show_streams -select_streams v:0 "$1" \
  | jq -r '.streams[0] | "\(.width)x\(.height) \(.r_frame_rate) \(.codec_name) \(.pix_fmt) \(.color_space // "na") \(.profile // "na")"'
}

compatible=true
first_info="$(get_video_info "${files[0]}")"
echo "Checking video compatibility vs first…"
for f in "${files[@]:1}"; do
  info="$(get_video_info "$f")"
  if [[ "$info" != "$first_info" ]]; then
    echo "  WARN: $f differs → may require re-encode"
    compatible=false
  fi
done
echo

# temp + cleanup
config=".exiftool_config.$$"
cat > "$config" << 'EOF'
$Image::ExifTool::LargeFileSupport = 1;
EOF

tmp_norm_dir="._tmp_norm.$$"
mkdir -p "$tmp_norm_dir"
trap 'rm -rf "$tmp_norm_dir" "$config" "._tmp_"* ".concat_list."*' EXIT

# ---- Step 0: PRE-NORMALIZE EACH INPUT (copy) to maximize concat success ----
# (fix PTS/DTS, brand, moov at front)
echo "0) Pre-normalize each input (copy, no quality loss)…"
norm_files=()
idx=0
for f in "${files[@]}"; do
  nf="$tmp_norm_dir/$(printf "%03d" $idx)_${f##*/}"
  ffmpeg -hide_banner -loglevel error -y \
    -fflags +genpts -avoid_negative_ts make_zero \
    -i "$f" -map 0 -c copy -movflags +faststart -brand mp42 "$nf"
  norm_files+=("$nf")
  ((idx++))
done
echo "   Normalized ${#norm_files[@]} files."
echo

# ---- Step 1: TRY LOSSLESS CONCAT (copy) -----------------------------------
list=".concat_list.$$_.txt"
: > "$list"
for f in "${norm_files[@]}"; do printf "file '%s/%s'\n" "$PWD" "$f" >> "$list"; done

joined="._tmp_join.mp4"
echo "1) Fast concat (copy)…"
if ffmpeg -hide_banner -loglevel error -y -safe 0 -f concat -i "$list" -c copy -movflags +faststart "$joined"; then
  echo "   OK (no re-encode)."
  need_reencode=0
else
  echo "   FAILED → will re-encode."
  need_reencode=1
fi
echo

# ---- Step 2: IF NEEDED, RE-ENCODE (pick the least-destructive path) -------
if (( need_reencode )); then
  inopts=(); for f in "${norm_files[@]}"; do inopts+=(-i "$f"); done
  n=${#norm_files[@]}
  va=""; for ((i=0;i<n;i++)); do va+="[$i:v:0][$i:a:0]"; done
  fgraph="${va}concat=n=${n}:v=1:a=1[v][a]"

  if (( use_prores )); then
    echo "2) Re-encode to ProRes 422 HQ (mezzanine, huge but near-lossless)…"
    ffmpeg -hide_banner -y "${inopts[@]}" -filter_complex "$fgraph" -map "[v]" -map "[a]" \
      -c:v prores_ks -profile:v 3 -pix_fmt yuv422p10le \
      -c:a pcm_s16le \
      -movflags +faststart "$joined"
  elif (( use_x265 )); then
    echo "2) Re-encode HEVC libx265 10-bit CRF ${x265_crf} (slow, very high quality)…"
    ffmpeg -hide_banner -y "${inopts[@]}" -filter_complex "$fgraph" -map "[v]" -map "[a]" \
      -c:v libx265 -pix_fmt yuv420p10le -preset slow -crf "$x265_crf" \
      -x265-params "hdr-opt=1:aq-mode=3:cbqpoffs=0:crqpoffs=0:strong-intra-smoothing=0" \
      -c:a aac -b:a 192k -movflags +faststart "$joined"
  elif (( want_h264 )); then
    echo "2) Re-encode H.264 (VideoToolbox) high bitrate for fast YT ingest…"
    ffmpeg -hide_banner -y "${inopts[@]}" -filter_complex "$fgraph" -map "[v]" -map "[a]" \
      -c:v h264_videotoolbox -b:v 50M -maxrate 50M -bufsize 50M -tag:v avc1 \
      -pix_fmt yuv420p \
      -c:a aac -b:a 192k -movflags +faststart "$joined"
  else
    echo "2) Re-encode HEVC (VideoToolbox) high bitrate ${vt_bitrate}…"
    ffmpeg -hide_banner -y "${inopts[@]}" -filter_complex "$fgraph" -map "[v]" -map "[a]" \
      -c:v hevc_videotoolbox -b:v "$vt_bitrate" -maxrate "$vt_bitrate" -bufsize "$vt_bitrate" -tag:v hvc1 \
      -c:a aac -b:a 192k -movflags +faststart "$joined"
  fi
  echo
fi

# ---- Step 3: 360 METADATA (XMP + V2 box) ----------------------------------
echo "3) Inject 360 metadata…"
exiftool -config "$config" -overwrite_original -api QuickTimeUTC \
  -tagsFromFile "${files[0]}" -XMP:all "$joined" >/dev/null || true

# Ensure basic spherical tags exist
if ! exiftool -config "$config" -s -XMP-GSpherical:Spherical "$joined" | grep -q '^1$'; then
  exiftool -config "$config" -overwrite_original -api QuickTimeUTC \
    -XMP-GSpherical:Spherical=true \
    -XMP-GSpherical:Stitched=true \
    -XMP-GSpherical:ProjectionType=equirectangular \
    -XMP-GSpherical:StereoMode=mono \
    -XMP-GSpherical:SourceCount=1 \
    "$joined" >/dev/null
fi

# Spatial Video V2 box if available
final="._tmp_tagged.mp4"
if python3 -c "import spatialmedia" 2>/dev/null; then
  echo "   Adding Spherical V2 box…"
  python3 -m spatialmedia -i --projection=equirectangular --stereo=mono \
    "$joined" "$final" >/dev/null 2>&1 || cp -f "$joined" "$final"
else
  echo "   spatialmedia not found — skipping V2 box"
  cp -f "$joined" "$final"
fi

mv -f "$final" "$out"
echo "Done → $out"
