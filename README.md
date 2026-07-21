# FluidWall - Dynamic Wallpaper Engine with Conky Integration

A complete solution for dynamic wallpaper management with intelligent contrast-based text coloring for Conky.

## Overview

FluidWall is a sophisticated wallpaper engine that provides:
- **Dynamic wallpaper cycling** with smooth transitions between images and live videos
- **Intelligent text contrast** - automatically adjusts Conky text color to remain readable against any wallpaper
- **Live video wallpaper support** - seamlessly integrates video clips into your wallpaper rotation
- **Zero-config Conky integration** - no need to edit `.conkyrc` or restart Conky
- **Resource-efficient** - uses caching and pre-generation to minimize CPU/GPU usage
- **GPU acceleration support** - optional VAAPI hardware encoding/decoding

## Components

The system consists of three main components:

### 1. `fluidwall.sh` - The Wallpaper Engine
Manages the wallpaper slideshow with support for static images and live videos.

### 2. `sconky.sh` - Contrast-Based Text Color Updater
Monitors wallpaper changes and automatically adjusts Conky text colors for optimal readability.

### 3. `conky_helpers.lua` - Conky Integration
Lua script that reads color states and displays dynamic greetings in Conky.

## Requirements

### System Dependencies
```bash
# Core utilities
ffmpeg ffprobe mpv socat yad xwinwrap inotify-tools feh

# GPU acceleration (optional)
vainfo mesa-va-drivers intel-media-va-driver

# Build dependencies (for xwinwrap)
git build-essential libx11-dev libxrender-dev x11-xserver-utils
```

### Installation
```bash
# Clone and build xwinwrap (required for video wallpapers)
git clone https://github.com/mmhobi7/xwinwrap.git
cd xwinwrap && make && sudo make install

# Install dependencies via apt
sudo apt install ffmpeg mpv socat yad feh inotify-tools
```

## Quick Start

### 1. Initial Setup

```bash
# Make scripts executable
chmod +x fluidwall.sh sconky.sh

# Install required dependencies
./fluidwall.sh install

# Generate cached clips for faster startup (optional)
./fluidwall.sh generate
```

### 2. Start the Wallpaper Engine

```bash
# Start with default settings (30-minute interval)
./fluidwall.sh start

# Start with custom interval (5 minutes)
./fluidwall.sh start --change 5m

# Start with GPU acceleration
./fluidwall.sh start --gpu
```

### 3. Start the Conky Color Updater

```bash
# Run as daemon
./sconky.sh

# Run in foreground for debugging
./sconky.sh --foreground
```

### 4. Configure Conky

Add to your `.conkyrc`:
```lua
# Load the Lua helpers
lua_load ~/scripts/lib/conky_helpers.lua

# Use in your conky text:
${lua conky_greeting}
${lua_parse conky_color_open}This text adapts to wallpaper contrast${lua_parse conky_color_close}
```

## Detailed Usage

### FluidWall Commands

```bash
# Start/Stop the daemon
./fluidwall.sh start [--change DURATION] [--gpu|--no-gpu]
./fluidwall.sh stop
./fluidwall.sh restart [--change DURATION] [--gpu|--no-gpu]

# View status and logs
./fluidwall.sh status
./fluidwall.sh log
./fluidwall.sh live-log

# Change settings on the fly
./fluidwall.sh change 10m                    # Change interval to 10 minutes
./fluidwall.sh set-live-every 5              # Show live video every 5 images
./fluidwall.sh set-pic-dir ~/Pictures        # Change image directory
./fluidwall.sh set-live-dir ~/.set           # Change video directory

# Pre-generation and cleanup
./fluidwall.sh generate [--gpu|--no-gpu] [--parallel N]
./fluidwall.sh generate --clean              # Remove orphaned cached files
```

### Duration Format

Durations can be specified in human-readable format:
- `30s` - 30 seconds
- `5m` - 5 minutes
- `2h` - 2 hours
- `1h-30m` - 1 hour and 30 minutes
- `2h-4m-30s` - 2 hours, 4 minutes, 30 seconds

**Minimum interval**: 60 seconds

### SConky Configuration

```bash
# Set contrast skew (0=linear inversion, 100=hard black/white)
./sconky.sh --set-skew 70

# Enable smooth color transitions
./sconky.sh --set-smooth 50    # 0=off, 1=fast, 100=slow

# Enable random flicker effects
./sconky.sh --set-random 30    # 0=off, 1=few, 100=rapid

# View current settings
./sconky.sh --show-skew --show-smooth --show-random
```

## Architecture

### How It Works

1. **Wallpaper Cycling** (`fluidwall.sh`):
   - Scans directories for images and videos
   - Generates short "base clips" (0.5 seconds) of each media
   - Maintains a buffer of pre-generated clips for seamless transitions
   - Uses `mpv` + `xwinwrap` for video playback
   - Applies crossfade transitions between clips

2. **Contrast Detection** (`sconky.sh`):
   - Monitors `~/.local/run/fluidwall.current_img`
   - Samples average brightness of current wallpaper
   - Applies sigmoid mapping with configurable skew
   - Writes contrast color to `~/.local/run/conky_color.txt`

3. **Conky Integration** (`conky_helpers.lua`):
   - Reads color state file on each Conky update
   - Applies color without restarting Conky
   - Rotates greetings from a text file

### Directory Structure

```
~/.local/run/
├── fluidwall.current_img      # Current wallpaper path
├── conky_color.txt            # Current contrast color (hex)
├── fluidwall.pid              # Daemon PID
└── fluidwall_mpv.sock         # MPV IPC socket

~/.config/wallpaper_contrast/
├── skew.conf                  # Contrast skew (0-100)
├── smooth.conf                # Smooth transition speed
└── random.conf                # Random flicker intensity

~/Pictures/wallpaper_engine/   # Generated clip cache
├── bases/                     # 0.5s base clips of images
└── clips/                     # Live video head/tail clips

/tmp/fluidwall_ram_*/          # RAM cache for active clips
/tmp/wallpaper_engine/         # Transition clips cache
```

## Performance Optimization

### GPU Acceleration
Enable hardware encoding/decoding for better performance:
```bash
./fluidwall.sh start --gpu
```

### Pre-Generation
Generate all clips in advance to avoid startup delays:
```bash
./fluidwall.sh generate --parallel 4
```

### Memory Usage
- Base clips are cached in RAM (`/tmp/fluidwall_ram_*/`)
- Only `PREGEN_COUNT` clips are kept in memory
- Default buffer size: 3 clips (~10-15MB)

## Troubleshooting

### Common Issues

**Wallpaper not changing:**
```bash
# Check if daemon is running
./fluidwall.sh status

# Check logs for errors
./fluidwall.sh log

# Restart the daemon
./fluidwall.sh restart
```

**Conky color not updating:**
```bash
# Check if sconky is running
ps aux | grep sconky

# View sconky log
tail -f ~/.log/srwbg.log

# Force color update
echo "ffffff" > ~/.local/run/conky_color.txt
```

**Video wallpapers not working:**
```bash
# Verify xwinwrap is installed
which xwinwrap

# Check GPU/VAAPI setup
vainfo

# Fall back to CPU
./fluidwall.sh restart --no-gpu
```

**Memory/CPU issues:**
```bash
# Reduce buffer size (edit fluidwall.sh)
PREGEN_COUNT=1  # Instead of 3

# Reduce cache generation
./fluidwall.sh generate --parallel 1
```

## Advanced Configuration

### Custom Contrast Mapping
The contrast mapping uses a sigmoid function with configurable skew:
- **Skew=0**: Linear inversion (text = 255 - bg)
- **Skew=70** (default): Smooth contrast with some saturation
- **Skew=100**: Hard black/white step function

### Custom Conky Greetings
Create `~/greetings3.txt` with one greeting per line:
```
Good Morning!
Hello World!
Welcome back!
```

### Custom Live Video Scheduling
```bash
# Show live video every N static images
./fluidwall.sh set-live-every 3

# Disable live videos
./fluidwall.sh set-live-every 0
```

## License

These scripts are provided as-is. Feel free to modify and distribute.

## Contributing

Suggestions and improvements welcome! Key areas for contribution:
- Additional transition effects
- More color mapping algorithms
- Support for more video formats
- Integration with other desktop environments

---

**Note**: This system was designed for X11 environments. Wayland support may require additional configuration.

---

## AntiX Minimal Conky Clock

For a clean, minimalist clock widget for antiX Linux (and other light X11 environments), check out the **Minimal Clock** project:

**[Minimal Clock Repository](https://github.com/shuokenzi23/minimal-clock.git)**

### Features
- Perfect alignment with `${alignc}` and `${voffset}` formatting
- True desktop integration with `own_window_type override`
- Geometric **Anurati** display font for a high-end look
- Clean digital clock centered underneath the day display

### Quick Setup
```bash
# Clone the repository
git clone https://github.com/shuokenzi23/minimal-clock.git
cd minimal-clock

# Install the Anurati font
mkdir -p ~/.local/share/fonts
# Download Anurati-Regular.otf from:
# https://www.dafontfree.co/anurati-font/
cp Anurati-Regular.otf ~/.local/share/fonts/
fc-cache -fv

# Deploy the Conky config
cp .conkyrc ~/.conkyrc

# Restart Conky
killall conky && conky &
```

### Preview
<img width="1366" height="768" alt="minimal-clock" src="https://github.com/user-attachments/assets/b1de28e2-7a81-4745-90e3-96aff175d071" />

The Minimal Clock pairs perfectly with FluidWall, providing a sleek typographic display that automatically adapts to your dynamic wallpaper colors.
