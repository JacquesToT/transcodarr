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

---

# Implementation Plan: jellyfin-ffmpeg in Transcodarr Installer

Dit gedeelte documenteert de geplande wijzigingen om jellyfin-ffmpeg support toe te voegen aan de Transcodarr installer.

## Huidige Architectuur Analyse

### FFmpeg Installatie Flow

```
┌─────────────────┐    ┌──────────────────────┐    ┌─────────────────┐
│   install.sh    │───▶│   lib/mac-setup.sh   │───▶│ Homebrew FFmpeg │
│  (entry point)  │    │   install_ffmpeg()   │    │  /opt/homebrew  │
└─────────────────┘    └──────────────────────┘    └─────────────────┘
         │
         ▼
┌─────────────────┐    ┌──────────────────────┐    ┌─────────────────┐
│   add-node.sh   │───▶│  lib/remote-ssh.sh   │───▶│ Homebrew FFmpeg │
│  (remote Mac)   │    │remote_install_ffmpeg │    │   via SSH       │
└─────────────────┘    └──────────────────────┘    └─────────────────┘
         │
         ▼
┌─────────────────┐    ┌──────────────────────┐    ┌─────────────────┐
│  jellyfin-setup │───▶│   rffmpeg.yml        │───▶│ Path hardcoded: │
│     .sh         │    │  create_rffmpeg_...  │    │ /opt/homebrew/  │
└─────────────────┘    └──────────────────────┘    └─────────────────┘
```

### Bestanden en Functies Betrokken

#### 1. `lib/mac-setup.sh` (Lokale Mac Installatie)

| Regel | Functie | Huidige Werking | Wijziging Nodig |
|-------|---------|-----------------|-----------------|
| 61-64 | `check_ffmpeg()` | Checkt `/opt/homebrew/bin/ffmpeg` + VideoToolbox | Uitbreiden voor jellyfin-ffmpeg |
| 66-69 | `check_ffmpeg_fdk_aac()` | Checkt libfdk_aac encoder | Ongewijzigd |
| 71-131 | `install_ffmpeg()` | Installeert via `brew install homebrew-ffmpeg/...` | Optie toevoegen voor jellyfin-ffmpeg |

```bash
# Huidige check_ffmpeg():
check_ffmpeg() {
    [[ -f "/opt/homebrew/bin/ffmpeg" ]] && \
        /opt/homebrew/bin/ffmpeg -encoders 2>&1 | grep -q "videotoolbox"
}
```

**Probleem:** Checkt alleen Homebrew locatie, niet jellyfin-ffmpeg.

#### 2. `lib/remote-ssh.sh` (Remote Mac via SSH)

| Regel | Functie | Huidige Werking | Wijziging Nodig |
|-------|---------|-----------------|-----------------|
| 290-296 | `remote_check_ffmpeg()` | SSH check voor `/opt/homebrew/bin/ffmpeg` | Uitbreiden voor jellyfin-ffmpeg |
| 375-432 | `remote_install_ffmpeg()` | SSH installatie via Homebrew | Optie toevoegen voor jellyfin-ffmpeg |

```bash
# Huidige remote_check_ffmpeg():
remote_check_ffmpeg() {
    ssh_exec "$mac_user" "$mac_ip" "$key_path" \
        "[[ -f /opt/homebrew/bin/ffmpeg ]] && /opt/homebrew/bin/ffmpeg -encoders 2>&1 | grep -q videotoolbox"
}
```

**Probleem:** Identiek aan lokale check - alleen Homebrew pad.

#### 3. `lib/jellyfin-setup.sh` (rffmpeg Configuratie)

| Regel | Functie | Huidige Werking | Wijziging Nodig |
|-------|---------|-----------------|-----------------|
| 184-227 | `create_rffmpeg_config()` | Genereert rffmpeg.yml met hardcoded paden | Dynamisch pad op basis van installatie |

```yaml
# Huidige hardcoded paden in rffmpeg.yml:
commands:
    ffmpeg: "/opt/homebrew/bin/ffmpeg"
    ffprobe: "/opt/homebrew/bin/ffprobe"
```

**Probleem:** Pad is hardcoded, ondersteunt geen jellyfin-ffmpeg.

#### 4. `lib/detection.sh` (Systeem Detectie)

| Regel | Functie | Huidige Werking | Wijziging Nodig |
|-------|---------|-----------------|-----------------|
| 215-217 | `is_ffmpeg_installed()` | Checkt `command -v ffmpeg` of Homebrew pad | Uitbreiden voor jellyfin-ffmpeg |
| 220-228 | `has_videotoolbox()` | Checkt VideoToolbox encoder | Ongewijzigd |

#### 5. `rffmpeg/rffmpeg.yml` (Template)

```yaml
# Huidige template:
commands:
    ffmpeg: "/opt/homebrew/bin/ffmpeg"     # ← Moet configureerbaar zijn
    ffprobe: "/opt/homebrew/bin/ffprobe"   # ← Moet configureerbaar zijn
```

#### 6. `lib/state.sh` (State Management)

Geen directe wijzigingen nodig, maar nieuwe config keys toevoegen:
- `ffmpeg_variant`: `"homebrew"` of `"jellyfin"`
- `ffmpeg_path`: Absoluut pad naar ffmpeg binary

---

## Implementatie Ontwerp

### Nieuwe Constanten

```bash
# lib/constants.sh (nieuw bestand of toevoegen aan bestaand)
JELLYFIN_FFMPEG_DIR="/opt/jellyfin-ffmpeg"
JELLYFIN_FFMPEG_BIN="${JELLYFIN_FFMPEG_DIR}/ffmpeg"
JELLYFIN_FFPROBE_BIN="${JELLYFIN_FFMPEG_DIR}/ffprobe"

HOMEBREW_FFMPEG_BIN="/opt/homebrew/bin/ffmpeg"
HOMEBREW_FFPROBE_BIN="/opt/homebrew/bin/ffprobe"

JELLYFIN_RELEASES_URL="https://api.github.com/repos/jellyfin/jellyfin-server-macos/releases/latest"
```

### Nieuwe Functies in `lib/mac-setup.sh`

#### 1. `check_jellyfin_ffmpeg()`

**Doel:** Detecteren of jellyfin-ffmpeg is geïnstalleerd en werkend.

```bash
check_jellyfin_ffmpeg() {
    # Check 1: Binary bestaat
    [[ -f "$JELLYFIN_FFMPEG_BIN" ]] || return 1

    # Check 2: Kan uitvoeren (geen quarantine/permissions issues)
    "$JELLYFIN_FFMPEG_BIN" -version &>/dev/null || return 1

    # Check 3: Heeft tonemapx filter (de reden dat we jellyfin-ffmpeg willen)
    "$JELLYFIN_FFMPEG_BIN" -filters 2>&1 | grep -q "tonemapx" || return 1

    # Check 4: Heeft VideoToolbox (hardware acceleratie)
    "$JELLYFIN_FFMPEG_BIN" -encoders 2>&1 | grep -q "videotoolbox" || return 1

    return 0
}
```

**Waarom deze checks:**
- Check 1: Basis aanwezigheid
- Check 2: macOS quarantine kan execution blokkeren
- Check 3: tonemapx is de primaire reden voor jellyfin-ffmpeg
- Check 4: VideoToolbox is essentieel voor hardware transcoding

#### 2. `get_jellyfin_ffmpeg_latest_version()`

**Doel:** Ophalen van de laatste versie van jellyfin-ffmpeg.

```bash
get_jellyfin_ffmpeg_latest_version() {
    local api_response
    api_response=$(curl -sL "$JELLYFIN_RELEASES_URL")

    # Parse JSON response voor tag_name
    # Formaat: "tag_name": "v10.9.11"
    echo "$api_response" | grep -o '"tag_name": *"[^"]*"' | head -1 | sed 's/.*: *"\(.*\)"/\1/'
}
```

#### 3. `download_jellyfin_ffmpeg()`

**Doel:** Download de juiste jellyfin-ffmpeg voor het platform.

```bash
download_jellyfin_ffmpeg() {
    local version="${1:-$(get_jellyfin_ffmpeg_latest_version)}"
    local arch=$(uname -m)
    local download_url=""
    local dmg_file="/tmp/jellyfin-${version}.dmg"

    # Bepaal architecture
    case "$arch" in
        arm64)
            download_url="https://github.com/jellyfin/jellyfin-server-macos/releases/download/${version}/jellyfin_${version#v}-arm64.dmg"
            ;;
        x86_64)
            download_url="https://github.com/jellyfin/jellyfin-server-macos/releases/download/${version}/jellyfin_${version#v}-x64.dmg"
            ;;
        *)
            show_error "Unsupported architecture: $arch"
            return 1
            ;;
    esac

    show_info "Downloading jellyfin-ffmpeg ${version}..."

    if curl -L -o "$dmg_file" "$download_url" 2>&1; then
        echo "$dmg_file"
        return 0
    else
        show_error "Download failed"
        return 1
    fi
}
```

**Waarom DMG i.p.v. tar.gz:**
- Jellyfin Server macOS releases zijn betrouwbaarder beschikbaar
- Bevatten gegarandeerd werkende binaries voor macOS
- Standalone jellyfin-ffmpeg builds zijn niet altijd beschikbaar voor macOS

#### 4. `install_jellyfin_ffmpeg()`

**Doel:** Volledige installatie van jellyfin-ffmpeg.

```bash
install_jellyfin_ffmpeg() {
    # Check of al geïnstalleerd
    if check_jellyfin_ffmpeg; then
        show_skip "jellyfin-ffmpeg is already installed"
        return 0
    fi

    show_what_this_does "Installing jellyfin-ffmpeg for full HDR/Dolby Vision support."

    local version
    version=$(get_jellyfin_ffmpeg_latest_version)

    if [[ -z "$version" ]]; then
        show_error "Could not determine latest jellyfin-ffmpeg version"
        show_info "Check your internet connection"
        return 1
    fi

    show_info "Latest version: $version"

    # Stap 1: Download DMG
    local dmg_file
    dmg_file=$(download_jellyfin_ffmpeg "$version")

    if [[ ! -f "$dmg_file" ]]; then
        show_error "Download failed"
        return 1
    fi

    # Stap 2: Mount DMG
    local mount_point="/tmp/jellyfin_mount_$$"
    mkdir -p "$mount_point"

    if ! hdiutil attach "$dmg_file" -nobrowse -mountpoint "$mount_point" 2>/dev/null; then
        show_error "Failed to mount DMG"
        rm -f "$dmg_file"
        return 1
    fi

    # Stap 3: Kopieer binaries
    local app_frameworks="${mount_point}/Jellyfin.app/Contents/Frameworks"

    if [[ ! -d "$app_frameworks" ]]; then
        show_error "FFmpeg binaries not found in DMG"
        hdiutil detach "$mount_point" 2>/dev/null
        rm -f "$dmg_file"
        return 1
    fi

    sudo mkdir -p "$JELLYFIN_FFMPEG_DIR"

    # Kopieer ffmpeg en ffprobe
    # In jellyfin-server-macos zijn deze direct in Frameworks/
    if [[ -f "${app_frameworks}/ffmpeg" ]]; then
        sudo cp "${app_frameworks}/ffmpeg" "$JELLYFIN_FFMPEG_BIN"
        sudo cp "${app_frameworks}/ffprobe" "$JELLYFIN_FFPROBE_BIN"
    else
        # Alternatieve locatie in sommige versies
        sudo cp -R "${app_frameworks}/"* "$JELLYFIN_FFMPEG_DIR/"
    fi

    # Stap 4: Unmount en cleanup
    hdiutil detach "$mount_point" 2>/dev/null
    rm -f "$dmg_file"
    rmdir "$mount_point" 2>/dev/null || true

    # Stap 5: Verwijder quarantine
    sudo xattr -rd com.apple.quarantine "$JELLYFIN_FFMPEG_DIR" 2>/dev/null || true

    # Stap 6: Zet permissions
    sudo chmod +x "$JELLYFIN_FFMPEG_BIN" "$JELLYFIN_FFPROBE_BIN"

    # Stap 7: Verificatie
    if check_jellyfin_ffmpeg; then
        show_result true "jellyfin-ffmpeg installed"

        # Sla versie en pad op in state
        set_config "ffmpeg_variant" "jellyfin"
        set_config "ffmpeg_path" "$JELLYFIN_FFMPEG_BIN"
        set_config "jellyfin_ffmpeg_version" "$version"

        mark_step_complete "jellyfin_ffmpeg"
        return 0
    else
        show_result false "jellyfin-ffmpeg installation verification failed"
        return 1
    fi
}
```

**Waarom deze stappen:**
1. **Download**: Haalt nieuwste versie op van GitHub
2. **Mount**: macOS DMG moet gemount worden om content te lezen
3. **Copy**: Extraheert alleen ffmpeg/ffprobe (niet hele Jellyfin app)
4. **Quarantine**: macOS blokkeert downloads standaard
5. **Permissions**: Zorgt dat binary uitvoerbaar is
6. **Verificatie**: Bevestigt dat installatie succesvol was

#### 5. `choose_ffmpeg_variant()` (Gebruikerskeuze)

**Doel:** Laat gebruiker kiezen tussen Homebrew en jellyfin-ffmpeg.

```bash
choose_ffmpeg_variant() {
    echo ""
    show_explanation "FFmpeg Variant Selection" \
        "Homebrew FFmpeg: Standaard, makkelijk te updaten, GEEN HDR support" \
        "jellyfin-ffmpeg: Volledige HDR/Dolby Vision support, handmatige updates"

    if command -v gum &>/dev/null; then
        local choice
        choice=$(gum choose \
            "jellyfin-ffmpeg (Recommended for HDR content)" \
            "Homebrew FFmpeg (Standard, SDR only)")

        case "$choice" in
            "jellyfin-ffmpeg"*)
                echo "jellyfin"
                ;;
            "Homebrew"*)
                echo "homebrew"
                ;;
            *)
                echo "homebrew"  # Default
                ;;
        esac
    else
        echo ""
        echo "Choose FFmpeg variant:"
        echo "  1) jellyfin-ffmpeg (Recommended for HDR content)"
        echo "  2) Homebrew FFmpeg (Standard, SDR only)"
        read -p "Choice [1]: " choice

        case "$choice" in
            2)
                echo "homebrew"
                ;;
            *)
                echo "jellyfin"
                ;;
        esac
    fi
}
```

---

### Wijzigingen aan Bestaande Functies

#### 1. Wijziging: `install_ffmpeg()` in `lib/mac-setup.sh`

**Van:**
```bash
install_ffmpeg() {
    if check_ffmpeg; then
        show_skip "FFmpeg with VideoToolbox is already installed"
        return 0
    fi
    # ... Homebrew installatie ...
}
```

**Naar:**
```bash
install_ffmpeg() {
    local variant="${1:-}"

    # Auto-detect bestaande installatie
    if check_jellyfin_ffmpeg; then
        show_skip "jellyfin-ffmpeg is already installed"
        set_config "ffmpeg_variant" "jellyfin"
        set_config "ffmpeg_path" "$JELLYFIN_FFMPEG_BIN"
        return 0
    fi

    if check_ffmpeg; then
        show_skip "FFmpeg with VideoToolbox is already installed"
        set_config "ffmpeg_variant" "homebrew"
        set_config "ffmpeg_path" "$HOMEBREW_FFMPEG_BIN"
        return 0
    fi

    # Vraag gebruiker om variant als niet meegegeven
    if [[ -z "$variant" ]]; then
        variant=$(choose_ffmpeg_variant)
    fi

    case "$variant" in
        jellyfin)
            install_jellyfin_ffmpeg
            ;;
        homebrew|*)
            install_homebrew_ffmpeg  # Hernoemde originele functie
            ;;
    esac
}
```

#### 2. Wijziging: `check_ffmpeg()` in `lib/mac-setup.sh`

**Van:**
```bash
check_ffmpeg() {
    [[ -f "/opt/homebrew/bin/ffmpeg" ]] && \
        /opt/homebrew/bin/ffmpeg -encoders 2>&1 | grep -q "videotoolbox"
}
```

**Naar:**
```bash
check_ffmpeg() {
    # Check jellyfin-ffmpeg eerst (heeft prioriteit)
    if check_jellyfin_ffmpeg; then
        return 0
    fi

    # Check Homebrew FFmpeg
    [[ -f "$HOMEBREW_FFMPEG_BIN" ]] && \
        "$HOMEBREW_FFMPEG_BIN" -encoders 2>&1 | grep -q "videotoolbox"
}

# Geeft het pad naar de actieve ffmpeg binary
get_ffmpeg_path() {
    if check_jellyfin_ffmpeg; then
        echo "$JELLYFIN_FFMPEG_BIN"
    elif [[ -f "$HOMEBREW_FFMPEG_BIN" ]]; then
        echo "$HOMEBREW_FFMPEG_BIN"
    else
        echo ""
    fi
}

get_ffprobe_path() {
    if check_jellyfin_ffmpeg; then
        echo "$JELLYFIN_FFPROBE_BIN"
    elif [[ -f "$HOMEBREW_FFPROBE_BIN" ]]; then
        echo "$HOMEBREW_FFPROBE_BIN"
    else
        echo ""
    fi
}
```

#### 3. Wijziging: `create_rffmpeg_config()` in `lib/jellyfin-setup.sh`

**Van:**
```bash
create_rffmpeg_config() {
    # ...
    cat > "$config_file" << EOF
    commands:
        ffmpeg: "/opt/homebrew/bin/ffmpeg"
        ffprobe: "/opt/homebrew/bin/ffprobe"
EOF
}
```

**Naar:**
```bash
create_rffmpeg_config() {
    local mac_ip="$1"
    local mac_user="$2"
    local config_file="${OUTPUT_DIR}/rffmpeg/rffmpeg.yml"

    # Bepaal FFmpeg paden op basis van variant
    local ffmpeg_path ffprobe_path
    local variant=$(get_config "ffmpeg_variant")

    case "$variant" in
        jellyfin)
            ffmpeg_path="$JELLYFIN_FFMPEG_BIN"
            ffprobe_path="$JELLYFIN_FFPROBE_BIN"
            ;;
        homebrew|*)
            ffmpeg_path="$HOMEBREW_FFMPEG_BIN"
            ffprobe_path="$HOMEBREW_FFPROBE_BIN"
            ;;
    esac

    mkdir -p "$(dirname "$config_file")"

    cat > "$config_file" << EOF
# Transcodarr - rffmpeg Configuration
# FFmpeg variant: ${variant}
# Generated by Transcodarr Installer

rffmpeg:
    logging:
        log_to_file: true
        logfile: "/config/log/rffmpeg.log"
        debug: false

    directories:
        state: "/config/rffmpeg"
        persist: "/config/rffmpeg/persist"
        owner: abc
        group: abc

    remote:
        user: "${mac_user}"
        persist: 300
        args:
            - "-o"
            - "StrictHostKeyChecking=no"
            - "-o"
            - "UserKnownHostsFile=/dev/null"
            - "-i"
            - "/config/rffmpeg/.ssh/id_rsa"

    commands:
        ssh: "/usr/bin/ssh"
        ffmpeg: "${ffmpeg_path}"
        ffprobe: "${ffprobe_path}"
        fallback_ffmpeg: "/usr/lib/jellyfin-ffmpeg/ffmpeg"
        fallback_ffprobe: "/usr/lib/jellyfin-ffmpeg/ffprobe"
EOF

    show_result true "rffmpeg.yml created (using ${variant} FFmpeg)"
}
```

---

### Remote Installatie (SSH) Wijzigingen

#### `lib/remote-ssh.sh`

Nieuwe functie `remote_install_jellyfin_ffmpeg()`:

```bash
remote_install_jellyfin_ffmpeg() {
    local mac_user="$1"
    local mac_ip="$2"
    local key_path="$3"

    # Check of al geïnstalleerd
    if ssh_exec "$mac_user" "$mac_ip" "$key_path" \
        "[[ -f /opt/jellyfin-ffmpeg/ffmpeg ]] && /opt/jellyfin-ffmpeg/ffmpeg -filters 2>&1 | grep -q tonemapx"; then
        show_skip "jellyfin-ffmpeg is already installed on Mac"
        return 0
    fi

    show_info "Installing jellyfin-ffmpeg on Mac..."
    show_info "This will download ~300MB..."

    # Remote installatie script
    ssh_exec "$mac_user" "$mac_ip" "$key_path" '
        set -e

        # Bepaal versie
        VERSION=$(curl -sL "https://api.github.com/repos/jellyfin/jellyfin-server-macos/releases/latest" | grep -o "\"tag_name\": *\"[^\"]*\"" | head -1 | sed "s/.*: *\"\(.*\)\"/\1/")

        if [[ -z "$VERSION" ]]; then
            echo "ERROR: Could not determine version"
            exit 1
        fi

        echo "Downloading jellyfin-ffmpeg $VERSION..."

        # Bepaal architecture
        ARCH=$(uname -m)
        if [[ "$ARCH" == "arm64" ]]; then
            URL="https://github.com/jellyfin/jellyfin-server-macos/releases/download/${VERSION}/jellyfin_${VERSION#v}-arm64.dmg"
        else
            URL="https://github.com/jellyfin/jellyfin-server-macos/releases/download/${VERSION}/jellyfin_${VERSION#v}-x64.dmg"
        fi

        DMG_FILE="/tmp/jellyfin-$$.dmg"
        curl -L -o "$DMG_FILE" "$URL"

        # Mount en extract
        MOUNT_POINT="/tmp/jellyfin_mount_$$"
        mkdir -p "$MOUNT_POINT"
        hdiutil attach "$DMG_FILE" -nobrowse -mountpoint "$MOUNT_POINT"

        # Kopieer binaries
        sudo mkdir -p /opt/jellyfin-ffmpeg
        sudo cp "$MOUNT_POINT/Jellyfin.app/Contents/Frameworks/ffmpeg" /opt/jellyfin-ffmpeg/
        sudo cp "$MOUNT_POINT/Jellyfin.app/Contents/Frameworks/ffprobe" /opt/jellyfin-ffmpeg/

        # Cleanup
        hdiutil detach "$MOUNT_POINT"
        rm -f "$DMG_FILE"
        rmdir "$MOUNT_POINT" 2>/dev/null || true

        # Verwijder quarantine en zet permissions
        sudo xattr -rd com.apple.quarantine /opt/jellyfin-ffmpeg
        sudo chmod +x /opt/jellyfin-ffmpeg/ffmpeg /opt/jellyfin-ffmpeg/ffprobe

        # Verificatie
        if /opt/jellyfin-ffmpeg/ffmpeg -filters 2>&1 | grep -q tonemapx; then
            echo "SUCCESS: jellyfin-ffmpeg installed"
        else
            echo "WARNING: tonemapx filter not found"
        fi
    '

    # Controleer resultaat
    if ssh_exec "$mac_user" "$mac_ip" "$key_path" \
        "/opt/jellyfin-ffmpeg/ffmpeg -filters 2>&1 | grep -q tonemapx"; then
        show_result true "jellyfin-ffmpeg installed on Mac"
        return 0
    else
        show_warning "jellyfin-ffmpeg installed but tonemapx not detected"
        return 0  # Niet fataal
    fi
}
```

Wijziging aan `remote_install_ffmpeg()`:

```bash
remote_install_ffmpeg() {
    local mac_user="$1"
    local mac_ip="$2"
    local key_path="$3"
    local variant="${4:-$(get_config ffmpeg_variant)}"

    case "$variant" in
        jellyfin)
            remote_install_jellyfin_ffmpeg "$mac_user" "$mac_ip" "$key_path"
            ;;
        homebrew|*)
            # Bestaande Homebrew installatie code
            # ...
            ;;
    esac
}
```

---

## State Management

### Nieuwe Config Keys

```json
{
  "config": {
    "ffmpeg_variant": "jellyfin",
    "ffmpeg_path": "/opt/jellyfin-ffmpeg/ffmpeg",
    "ffprobe_path": "/opt/jellyfin-ffmpeg/ffprobe",
    "jellyfin_ffmpeg_version": "v10.9.11"
  }
}
```

### Backward Compatibility

- Bestaande installaties met Homebrew blijven werken
- Nieuwe installaties krijgen keuze
- Upgrade path: `./install.sh --upgrade-ffmpeg` (toekomstige feature)

---

## Samenvatting Wijzigingen

| Bestand | Type | Beschrijving |
|---------|------|--------------|
| `lib/mac-setup.sh` | Wijzigen | Toevoegen jellyfin-ffmpeg functies, aanpassen check_ffmpeg() |
| `lib/remote-ssh.sh` | Wijzigen | Toevoegen remote_install_jellyfin_ffmpeg() |
| `lib/jellyfin-setup.sh` | Wijzigen | Dynamische FFmpeg paden in rffmpeg.yml |
| `lib/detection.sh` | Wijzigen | Uitbreiden is_ffmpeg_installed() |
| `lib/state.sh` | Ongewijzigd | Gebruik bestaande set_config/get_config |
| `rffmpeg/rffmpeg.yml` | Wijzigen | Template met placeholder voor pad |

### Nieuwe Functies Overzicht

| Functie | Locatie | Doel |
|---------|---------|------|
| `check_jellyfin_ffmpeg()` | mac-setup.sh | Detecteer jellyfin-ffmpeg installatie |
| `get_jellyfin_ffmpeg_latest_version()` | mac-setup.sh | Ophalen nieuwste versie |
| `download_jellyfin_ffmpeg()` | mac-setup.sh | Download DMG van GitHub |
| `install_jellyfin_ffmpeg()` | mac-setup.sh | Volledige installatie |
| `choose_ffmpeg_variant()` | mac-setup.sh | Gebruikerskeuze UI |
| `get_ffmpeg_path()` | mac-setup.sh | Geef actief FFmpeg pad |
| `get_ffprobe_path()` | mac-setup.sh | Geef actief FFprobe pad |
| `remote_install_jellyfin_ffmpeg()` | remote-ssh.sh | SSH installatie op remote Mac |

---

## Risico's en Mitigaties

| Risico | Impact | Mitigatie |
|--------|--------|-----------|
| GitHub API rate limiting | Download faalt | Cache versie nummer, fallback naar bekende versie |
| DMG structuur wijzigt | Extract faalt | Flexibele path detectie, error handling |
| macOS Quarantine blokkade | Executie faalt | Automatische xattr -rd aanroep |
| Geen internetverbinding | Download faalt | Skip met warning, handleiding tonen |
| Bestaande Homebrew breekt | Homebrew onbruikbaar | Geen symlinks overschrijven, parallelle installatie |

---

## Test Scenario's

1. **Schone Mac installatie** - Geen FFmpeg aanwezig
2. **Bestaande Homebrew** - Upgrade naar jellyfin-ffmpeg
3. **Bestaande jellyfin-ffmpeg** - Skip installatie
4. **Remote Mac via SSH** - Identiek gedrag
5. **Intel Mac** - x64 DMG downloaden
6. **Apple Silicon** - arm64 DMG downloaden
7. **Offline** - Graceful failure met instructies
