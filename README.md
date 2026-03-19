# H265 Video Re-encoding Script (with HEVC/AV1 Detection & Recompression)

## 📦 Description

This Bash script scans a folder (optionally recursively) for video files (`*.mkv`, `*.avi`, `*.mp4`, `*.m4v`, `*.mov`, `*.wmv`, `*.flv`, `*.divx`, `*.mpg`, `*.mpeg`) that are **not** already encoded in HEVC (H.265) or AV1 format. 

It performs a **15-second test encoding** to estimate final file size. 

If the estimated encoded file is at least **20% smaller** than the original, it performs a full re-encoding using **GPU acceleration (CUDA)** via `ffmpeg`, replacing the original file if the new one is smaller.

## 🎯 Features

- ✅ Keeps all audio tracks and subtitles
- ✅ Skips files already encoded in **HEVC** or **AV1**
- ✅ Skips files for which re-encoding will only decrease size by <20% by taking 3 small samples
- ✅ Skips files **smaller than a defined minimum size (in GB)** (accepts decimals with . or ,)
- ✅ Skips files with **invalid duration** or that **fail test encoding**
- ✅ Skips files with already low bitrate
- ✅ Automatically avoids reprocessing files listed in `encoded.list` or 'failed.list'
- ✅ Converts output to **MKV** if input is AVI or (if needed) MP4 for compatibility
- ✅ Keeps original file if re-encoded version is not smaller
- ✅ Keeps original file if duration mismatch (in case of a bug)
- ✅ Adds fast-start flag and hvc1 tags on mp4 and mov files
- ✅ Different CQ depending on video definition (SD/HD) (thx to @BrendanoElTaco for the request)
- ✅ Can be graciously stopped after encoding when X hours have passed (so it can be used in a nightly cron)
- ✅ Allows REGEX filters


## ⚙️ Requirements

### For NVIDIA GPUs (Linux/Windows)
- `ffmpeg` compiled with **NVENC** support (NVIDIA GPU encoding)
- `ffprobe` (usually bundled with ffmpeg)
- GNU `coreutils` (`stat`, `find`, etc.)

### For Apple Silicon (M1/M2/M3/etc.) Macs
- `ffmpeg` compiled with **VideoToolbox** support (included in Homebrew builds)
- `ffprobe` (usually bundled with ffmpeg)
- macOS 11.0 or later

**Note:** The script automatically detects your platform and selects the appropriate hardware acceleration:
- **macOS (Apple Silicon/Intel)**: Uses VideoToolbox (`hevc_videotoolbox`)
- **Linux/Other**: Uses NVIDIA CUDA (`hevc_nvenc`)

You can override the defaults by setting `HWACCEL_TYPE` and `VIDEO_CODEC` environment variables before running the script.

### Installing ffmpeg on macOS

For Apple Silicon Macs, install ffmpeg via Homebrew (includes VideoToolbox support):

```bash
brew install ffmpeg
```

To verify VideoToolbox support:

```bash
ffmpeg -hide_banner -encoders | grep hevc_videotoolbox
```

## 🧪 How it works

1. When collecting eligible files
   - Skips if already in HEVC or AV1
   - Skips if file size is below the `min=X` threshold
   - Skips if already listed in `encoded.list` or `failed.list`
2. For each eligible video files
   - Skips if global bitrate already under threshold
   - Performs a 15s GPU-accelerated test encode (3 samples of 5s at 1/4, 1/2, 3/4 of the duration)
   - Estimates full file size based on result
   - If estimated size is ≥80% of original, skips encoding
   - Otherwise, encodes full file using `ffmpeg`
   - If the encoded file is smaller, and duration of new file matches the original, replaces the original
3. If encoded are logged in a file named `encoded.list` in each directory, if failed, added in a `failed.list` file

## 📥 Usage

```bash
Usage:
  ./script.sh [arguments] <folder>
    List of arguments :
    -R              : Encode recursively inside subfolders
    min=X.YZ        : Ignore files smaller than X.YZ GB
    --regex="PATTERN"        Only include files matching the given regex pattern (e.g., --regex="\.avi$").
    test=N          : Use N seconds for the test encode (default: 5)
    --dry-run       : Only show compatible files without encoding
    --keep-original : Keep original files instead of replacing them
    --allow-h265    : Allow files already encoded in H.265
    --allow-av1     : Allow files already encoded in AV1
    -backup /path   : Save original files to backup path (used only if not using --keep-original)
    --clean         : Remove temporary encoding files (.tmp_encode_*, .tmp_encode_test_*) from the folder(s, if combined with -R) 
    --purge         : Remove encoded.list files (.tmp_encode_*, .tmp_encode_test_*) from the folder(s, if combined with -R) 
    -h              : Show this help message
    --stop-after HH.5  : Stop after HH.5 hours of encoding (useful if in cron)

```
### How it will look

```bash
██   ██ ██████   ██████  ███████     ███████ ███    ██  ██████  ██████  ██████  ███████ ██████  
██   ██      ██ ██       ██          ██      ████   ██ ██      ██    ██ ██   ██ ██      ██   ██ 
███████  █████  ███████  ███████     █████   ██ ██  ██ ██      ██    ██ ██   ██ █████   ██████  
██   ██ ██      ██    ██      ██     ██      ██  ██ ██ ██      ██    ██ ██   ██ ██      ██   ██ 
██   ██ ███████  ██████  ███████     ███████ ██   ████  ██████  ██████  ██████  ███████ ██   ██
┌────────────────────────────────────────────────────────────┐
│  CURRENT ENCODING SETTINGS                                 │
│                                                            │
│  Hardware Acceleration:     true (cuda)                    │
│  Video Codec:               hevc_nvenc                     │
│  Audio Codec:               aac @ 256k                     │
│  Constant Quality HD:       30                             │
│  Constant Quality SD:       26                             │
│  Constant Quality Default:  30                             │
│  Encoding Preset:           p3                             │
│  Minimum bitrate:           2000kbps                       │
│  Test Clip Duration:        (3x) 5s                        │
│  Minimum Size Ratio:        0.8                            │
│                                                            │
│  ONE-TIME SETTINGS                                         │
│  Folder                     /FAMILY/TRAVELS/  │
│  Recursive                  1                              │
│  Minimum Size               0 GB                           │
│  Keep original              0                              │
│  Stop after                 0h                             │
│  Allow H265                 0                              │
│  Allow AV1                  0                              │
│  Backup directory                                          │
│  Dry run                    0                              │
└────────────────────────────────────────────────────────────┘
Scanning...
├── 112 video files found / 48 will be encoded / 0 indicated as encoded / 0 indicated as failed

┌──────────────────────────────────────────────────────────────────────────────────────────┐
│  Task 1 / 48 : 2010-10-18-22-LES-ISSAMBRES.mp4 (637.45 MB | 00:22:51 | 720x574 | CQ=26)  │
└──────────────────────────────────────────────────────────────────────────────────────────┘
 Encoding samples (3x 5s)
|------|----|----| @ 342s
|----|------|----| @ 685s
|----|----|------| @ 1028s
├── Estimated size (median of 3 samples): 384.68 MB
▶️  Full encoding (00:22:51)
frame=34280 fps=308 q=21.0 Lsize=  341027kB time=00:22:51.50 bitrate=2037.0kbits/s speed=12.3x    
├── ✅ Encoding succeeded
⏳  Duration validation
├── ✅ Duration validated (diff: 0s)
  Video file replacement
├── Replaced original
├── Size reduced: 637.45 MB → 333.03 MB | −47%

┌──────────────────────────────────────────────────────────────────────────────────────────────────────────────────────┐
│  Task 2 / 48 : 2000-CASSAGNE-2002-ESPARSAC-2003-LE-PUY-2003-PELUSSIN-CH1.mp4 (1.55 GB | 00:41:58 | 720x574 | CQ=26)  │
└──────────────────────────────────────────────────────────────────────────────────────────────────────────────────────┘
 Encoding samples (3x 5s)
|------|----|----| @ 629s
|----|------|----| @ 1259s
|----|----|------| @ 1888s
├── Estimated size (median of 3 samples): 738.27 MB
▶️  Full encoding (00:41:58)
frame= 4872 fps=140 q=32.0 size=   52736kB time=00:03:15.17 bitrate=2213.4kbits/s speed=5.59x 
```
