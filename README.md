# join360-youtube

Quality-first **360° video joiner** for YouTube.

- **Lossless when possible** — tries concat copy first  
- **Smart fallback** — re-encodes at high quality only if needed  
- **360 metadata fixed** — copies XMP from first clip and adds Spherical Video V2 box  
- **YouTube-friendly container** — faststart, sane brands, timestamps normalized  
- macOS/Linux (bash). Requires `ffmpeg`, `exiftool`, `jq`. Optional: `spatialmedia` (Python).

---

## Why this exists

Joining Insta360 (or other equirectangular 360) clips can stall in YouTube processing if:
- containers/timestamps differ,
- brands/moov atom are off,
- 360 XMP/Spherical tags are missing or inconsistent.

This script fixes all that while prioritizing **no quality loss** when possible.

---

## Quick start

```bash
# Clone & make executable
git clone https://github.com/you/join360-youtube.git
cd join360-youtube
chmod +x join360.sh

# Put your 360 MP4s in this folder, then:
./join360.sh
# -> outputs joined_360.mp4 ready for YouTube
````

**Install deps (macOS with Homebrew):**

```bash
brew install ffmpeg exiftool jq
python3 -m pip install --user spatialmedia   # optional but recommended
```

**Linux (Debian/Ubuntu):**

```bash
sudo apt-get install -y ffmpeg exiftool jq
python3 -m pip install --user spatialmedia   # optional
```

---

## Usage

```bash
./join360.sh [options] [output.mp4]
```

**Options**

* `--vt <bitrate>` – force HEVC (VideoToolbox) re-encode at bitrate (e.g. `--vt 80M`)
* `--hevc-crf <N>` – use libx265 10-bit CRF encode (e.g. `--hevc-crf 12`)
* `--h264` – encode H.264 (VT) for **faster YouTube ingest**
* `--prores` – ProRes 422 HQ mezzanine (huge but near-lossless)
* No options → tries **lossless concat**, else HEVC VT @ `80M`

**Defaults**

* Output: `joined_360.mp4`
* Inputs: all `*.mp4` in the current folder, sorted A→Z

---

## Examples

**Lossless (if compatible), else HEVC VT @ 100M**

```bash
./join360.sh --vt 100M my_trip_360.mp4
```

**Force x265 for maximum quality (slow)**

```bash
./join360.sh --hevc-crf 12 my_trip_360.mp4
```

**Prefer faster YT processing (H.264)**

```bash
./join360.sh --h264 my_trip_360.mp4
```

**Mezzanine export (edit again later)**

```bash
./join360.sh --prores master_360.mov
```

---

## What it does (pipeline)

0. **Pre-normalize every input (copy only)**
   Fix PTS/DTS, move moov to front, set `mp42` brand → better concat reliability.

1. **Try fast concat (copy)**
   If all streams match (codec/resolution/fps/pix_fmt…), we concatenate losslessly.

2. **If needed, re-encode (pick best path)**

   * HEVC VT (default, high bitrate)
   * or H.264 VT (`--h264`) for faster YT ingestion
   * or libx265 10-bit CRF (`--hevc-crf N`) for max quality
   * or ProRes 422 HQ (`--prores`) mezzanine

3. **Inject 360 metadata**

   * Copy XMP from first clip with `exiftool`
   * Ensure GSpherical basics (Spherical/ProjectionType=Equirectangular/Mono)
   * Add **Spherical Video V2 box** with `spatialmedia` if available

---

## Tips for YouTube

* If YouTube **hangs in processing** on HEVC: export with `--h264`.
* Leave the file alone after upload; YT may take longer for 5.7K/8K 360.
* Ensure your input clips are already **stitched/equirectangular** (not raw dual-fisheye).

---

## Troubleshooting

* **“Need >=2 .mp4 files”**
  Put at least two MP4s in the folder (stitched 360) or pass your own output name.

* **Still not recognized as 360**
  Make sure `spatialmedia` was installed. Re-run; script adds the V2 box.
  You can also inject manually:

  ```bash
  python3 -m spatialmedia -i --projection=equirectangular --stereo=mono in.mp4 out.mp4
  ```

* **Concat fails even though files look similar**
  Use `--vt 100M` or `--hevc-crf 12` to re-encode consistently.

* **Color looks washed**
  If your source is HDR/10-bit, prefer `--hevc-crf 12` (x265 10-bit).

---

## FAQ

**Q: Why not always lossless?**
A: We try! When streams differ, lossless concat breaks. Then we re-encode once, cleanly.

**Q: Why copy XMP only from the first clip?**
A: YouTube reads container/XMP for the *final file*, not per-segment. We copy from the first (typical Insta360 has correct XMP) and then **enforce** core spherical tags + V2 box so the whole result is recognized.

**Q: Will order be correct?**
A: Files are sorted alphabetically. Rename if you need a specific order.

---

## Requirements

* `ffmpeg` 4.2+
* `exiftool`
* `jq`
* Optional: `spatialmedia` (`python3 -m pip install --user spatialmedia`)

---

## License

MIT

```

If you want, I’ll also add a minimal `.gitignore`:

```

.*tmp**
.concat_list.*.txt
._tmp_norm.*
joined_360.mp4
.DS_Store

```
