# Encoder Compatibility - HDR/HEVC Transcoding Guide

## Overview

Transcodarr uses Homebrew FFmpeg on Mac by default. This document explains the limitations with HDR content and provides **working solutions** for successful HEVC/HDR transcoding.

---

## The Problem: tonemapx Filter Missing

Jellyfin uses a custom FFmpeg filter called `tonemapx` for HDR-to-SDR conversion. This filter is **exclusive to jellyfin-ffmpeg** and is NOT available in standard Homebrew FFmpeg.

**Symptoms:**
```
Finished rffmpeg with return code 8
No such filter: 'tonemapx'
```

**Affected content:**
- HDR10 (10-bit HEVC with static metadata)
- HDR10+ (10-bit HEVC with dynamic metadata)
- Dolby Vision (Profile 5 & 8)
- HLG (Hybrid Log-Gamma)

---

## Solutions

### Solution 1: Use jellyfin-ffmpeg (Recommended)

Replace Homebrew FFmpeg with Jellyfin's custom FFmpeg build that includes all required filters.

**Requirements:**
- macOS 12 (Monterey) or later
- Apple Silicon Mac (M1/M2/M3/M4)

**Step 1: Download jellyfin-ffmpeg**

Download from: https://github.com/jellyfin/jellyfin-server-macos/releases

- For Apple Silicon: `jellyfin_x.x.x-arm64.dmg`
- The DMG contains bundled FFmpeg binaries

Or download standalone builds from: https://github.com/jellyfin/jellyfin-ffmpeg/releases

**Step 2: Extract FFmpeg binaries**

```bash
# Mount the DMG and copy FFmpeg
hdiutil attach jellyfin_*.dmg
sudo mkdir -p /opt/jellyfin-ffmpeg
sudo cp -R "/Volumes/Jellyfin/Jellyfin.app/Contents/Frameworks/ffmpeg" /opt/jellyfin-ffmpeg/
sudo cp -R "/Volumes/Jellyfin/Jellyfin.app/Contents/Frameworks/ffprobe" /opt/jellyfin-ffmpeg/
hdiutil detach "/Volumes/Jellyfin"

# Or extract from tar.gz (standalone builds)
sudo mkdir -p /opt/jellyfin-ffmpeg
sudo tar -xzf jellyfin-ffmpeg-*.tar.gz -C /opt/jellyfin-ffmpeg
```

**Step 3: Remove macOS quarantine flag**

```bash
sudo xattr -rd com.apple.quarantine /opt/jellyfin-ffmpeg
```

**Step 4: Create symlinks (Option A - Replace Homebrew)**

```bash
# Backup original Homebrew FFmpeg
sudo mv /opt/homebrew/bin/ffmpeg /opt/homebrew/bin/ffmpeg.homebrew
sudo mv /opt/homebrew/bin/ffprobe /opt/homebrew/bin/ffprobe.homebrew

# Create symlinks to jellyfin-ffmpeg
sudo ln -sf /opt/jellyfin-ffmpeg/ffmpeg /opt/homebrew/bin/ffmpeg
sudo ln -sf /opt/jellyfin-ffmpeg/ffprobe /opt/homebrew/bin/ffprobe
```

**Step 4: Update rffmpeg.yml (Option B - Direct path)**

Edit your rffmpeg configuration to point directly to jellyfin-ffmpeg:

```yaml
ffmpeg: /opt/jellyfin-ffmpeg/ffmpeg
```

**Step 5: Verify installation**

```bash
# Check for tonemapx filter
/opt/jellyfin-ffmpeg/ffmpeg -filters 2>&1 | grep tonemapx
# Should output: tonemapx

# Check VideoToolbox support
/opt/jellyfin-ffmpeg/ffmpeg -encoders 2>&1 | grep videotoolbox
# Should show h264_videotoolbox and hevc_videotoolbox
```

**Updating jellyfin-ffmpeg:**
- Check releases periodically: https://github.com/jellyfin/jellyfin-server-macos/releases
- Re-download and replace binaries when new versions are available

---

### Solution 2: VideoToolbox Native Tone Mapping

Jellyfin 10.9+ supports native VideoToolbox tone mapping that works **without** the tonemapx filter.

**Requirements:**
- Jellyfin Server 10.9.0 or later
- jellyfin-ffmpeg 6.0.1-5 or later
- macOS 12 (Monterey) or later
- Mac from 2017 or later (except MacBook Air 13" 2017)

**Configuration in Jellyfin:**

1. Go to **Dashboard** → **Playback** → **Transcoding**
2. Set **Hardware acceleration** to **VideoToolbox**
3. Enable **VideoToolbox Tone mapping** (native method)
4. Enable **Tone mapping** (Metal fallback)
5. Deselect any unsupported codecs for your Mac

**Two Tone Mapping Methods:**

| Method | Pros | Cons |
|--------|------|------|
| **VideoToolbox Native** | Lower power, less GPU dependent, good quality | No Dolby Vision P5, limited tuning |
| **Metal-based** | Dolby Vision P5 support, fine-tuning options | Slower on entry-level GPUs |

When both are enabled, VideoToolbox Native handles most content, and Metal is used as fallback for Dolby Vision Profile 5.

**Performance:**
- Apple M1: Can handle 3x simultaneous 4K 24fps Dolby Vision transcodes
- M1 Max/M2 Max: Extra video engine, supports 4K 120fps transcoding

---

### Solution 3: libplacebo (Advanced)

libplacebo provides GPU-accelerated tone mapping with extensive format support.

**Installation:**

```bash
# Install libplacebo
brew install libplacebo

# Install FFmpeg with libplacebo support
brew tap homebrew-ffmpeg/ffmpeg
brew install homebrew-ffmpeg/ffmpeg/ffmpeg --with-libplacebo
```

**Supported tone mapping algorithms:**
- `bt2390` - ITU-R BT.2390 (recommended)
- `bt2446a` - ITU-R BT.2446 method A
- `st2094-40` - SMPTE ST 2094-40 (for HDR10+)
- `reinhard`, `mobius`, `hable`

**Note:** This requires Jellyfin to use libplacebo filters instead of tonemapx, which may require custom configuration.

---

### Solution 4: Disable Tone Mapping (Workaround)

If none of the above solutions work, you can disable tone mapping entirely.

**In Jellyfin:**
1. Go to **Dashboard** → **Playback** → **Transcoding**
2. Set **Tone mapping algorithm** to **None**

**Consequences:**
- HDR content will still transcode
- Colors may appear washed out on SDR displays
- Works for clients that support HDR passthrough

---

## Content Compatibility Matrix

### With jellyfin-ffmpeg:

| Content Type | Status | Notes |
|-------------|--------|-------|
| SDR H.264 | Works | Full hardware acceleration |
| SDR HEVC/H.265 | Works | Full hardware acceleration |
| SDR AV1 | Works | Software decode, HW encode |
| HDR10 HEVC | Works | VideoToolbox tone mapping |
| HDR10+ HEVC | Works | VideoToolbox tone mapping |
| Dolby Vision P8 | Works | VideoToolbox native |
| Dolby Vision P5 | Works | Metal tone mapping required |
| HLG | Works | VideoToolbox tone mapping |
| Audio (any) | Works | AAC encoder available |

### With Homebrew FFmpeg (no tone mapping):

| Content Type | Status | Notes |
|-------------|--------|-------|
| SDR H.264 | Works | Full support |
| SDR HEVC/H.265 | Works | Full support |
| SDR AV1 | Works | libaom available |
| HDR10 HEVC | Fails* | Missing tonemapx filter |
| HDR10+ HEVC | Fails* | Missing tonemapx filter |
| Dolby Vision | Fails* | Missing DV processing |
| Audio (any) | Works | Falls back to standard aac |

*Falls back to Synology transcoding automatically via rffmpeg

---

## Checking Your FFmpeg

```bash
# Check FFmpeg version and build
ffmpeg -version

# Check for tonemapx filter (jellyfin-ffmpeg only)
ffmpeg -filters 2>&1 | grep tonemapx

# Check for standard tonemap filter
ffmpeg -filters 2>&1 | grep tonemap

# Check VideoToolbox encoders
ffmpeg -encoders 2>&1 | grep -E "videotoolbox"

# Check available decoders for HEVC
ffmpeg -decoders 2>&1 | grep hevc

# Check libplacebo (if installed)
ffmpeg -filters 2>&1 | grep libplacebo
```

---

## Recommended Setup

### For Full HDR Support (Recommended):

1. Install **jellyfin-ffmpeg** on all Mac nodes (Solution 1)
2. Configure **VideoToolbox tone mapping** in Jellyfin (Solution 2)
3. Enable both tone mapping methods for maximum compatibility

### For SDR-Only Transcoding:

Use default Homebrew FFmpeg setup:
```
Dashboard → Playback → Transcoding:

Hardware acceleration: None (or VideoToolbox for HW encoding)
Allow encoding in HEVC format: (optional)
Allow encoding in AV1 format: (disable - slow on CPU)
Tone mapping algorithm: None
```

HDR content will automatically fall back to Synology via rffmpeg.

---

## Troubleshooting

### "No such filter: 'tonemapx'"

**Cause:** Using Homebrew FFmpeg instead of jellyfin-ffmpeg.

**Solution:** Install jellyfin-ffmpeg (Solution 1) or disable tone mapping (Solution 4).

### Return code 8 on HDR content

**Cause:** FFmpeg command failed due to missing filter or configuration.

**Solutions:**
1. Check FFmpeg version: `ffmpeg -version`
2. Verify tonemapx filter: `ffmpeg -filters 2>&1 | grep tonemapx`
3. If missing, install jellyfin-ffmpeg or enable VideoToolbox native tone mapping

### Colors look washed out

**Cause:** Tone mapping disabled or incorrect settings.

**Solutions:**
1. Enable tone mapping in Jellyfin Dashboard
2. Verify HDR metadata is being read correctly
3. Try different tone mapping algorithms (hable, reinhard)

### Transcoding very slow on HDR content

**Cause:** Software tone mapping instead of hardware.

**Solutions:**
1. Enable VideoToolbox in Jellyfin
2. Ensure Metal or VideoToolbox tone mapping is active
3. Check Activity Monitor - FFmpeg CPU should be low (<200%) for HW transcoding

### VideoToolbox not available

**Cause:** macOS version too old or unsupported Mac.

**Requirements:**
- macOS 12 (Monterey) or later
- Mac from 2017 or later
- Apple Silicon preferred for best performance

---

## Technical Details

### VideoToolbox Capabilities

| Chip | Decode | Encode | Tone Map | Performance |
|------|--------|--------|----------|-------------|
| Intel (pre-2017) | HEVC 8-bit | H.264 only | No | Limited |
| Intel (2017+) | HEVC 10-bit | HEVC 8/10-bit | Metal | Good |
| M1 | HEVC 10-bit | HEVC 10-bit | VT Native + Metal | Excellent |
| M1 Pro/Max | HEVC 10-bit | HEVC 10-bit | VT Native + Metal | Excellent (extra engine) |
| M2/M3/M4 | HEVC 10-bit | HEVC 10-bit | VT Native + Metal | Excellent |

### Tone Mapping Filter Comparison

| Filter | Source | GPU Accel | HDR10 | HDR10+ | DV P5 | DV P8 |
|--------|--------|-----------|-------|--------|-------|-------|
| tonemapx | jellyfin-ffmpeg | Yes | Yes | Yes | Yes | Yes |
| tonemap | Standard FFmpeg | No (CPU) | Yes | No | No | No |
| tonemap_opencl | Standard FFmpeg | OpenCL | Yes | No | No | No |
| libplacebo | Homebrew option | Vulkan/Metal | Yes | Yes | Yes | Yes |
| VT Native | macOS built-in | VideoToolbox | Yes | Yes | No | Yes |
| Metal | macOS built-in | Metal | Yes | Yes | Yes | Yes |

---

## References

- [Jellyfin Apple Mac Documentation](https://jellyfin.org/docs/general/post-install/transcoding/hardware-acceleration/apple/)
- [jellyfin-ffmpeg GitHub](https://github.com/jellyfin/jellyfin-ffmpeg)
- [jellyfin-server-macos Releases](https://github.com/jellyfin/jellyfin-server-macos/releases)
- [rffmpeg GitHub](https://github.com/joshuaboniface/rffmpeg)
- [Homebrew FFmpeg Tap](https://github.com/homebrew-ffmpeg/homebrew-ffmpeg)
- [libplacebo Documentation](https://libplacebo.org/options/)
