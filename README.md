# FluidWall — Dynamic Wallpaper Engine with Conky Integration

A complete solution for dynamic wallpaper management: smooth image/video cycling, intelligent contrast-based text coloring for Conky, and a tray icon to control it all without touching a terminal.

### preview video
https://github.com/user-attachments/assets/073ef5a4-09df-4477-a04a-95c95f4fd122

### preview image
<img width="1920" height="1080" alt="preview" src="https://github.com/user-attachments/assets/1d56ba96-2849-4f77-a153-03ebabfaf7b2" />

## Quick setup

```bash
curl https://raw.githubusercontent.com/ndu-ik/ndu-ndi/wallpaper/setup.sh | bash
```

This clones the required files into `~/ndu-ndi`, installs OS-level dependencies, sets up conky's config, `conky_helpers.lua`, and the Anurati font, puts `fluidwall` and `fluidwall-tray` on your `PATH` (`~/.local/bin`), and installs `picom.conf` to `~/.config/`. Picom is started automatically at the end of setup; conky is started automatically the first time you run `fluidwall start`.

If GitHub's raw-content CDN serves you a stale copy of `setup.sh`, bust the cache with a dummy query param:

```bash
curl "https://raw.githubusercontent.com/ndu-ik/ndu-ndi/wallpaper/setup.sh?nocache=$(date +%s)" | bash
```

> **Note:** this script was built for live wallpapers with short durations (under ~5 min). For every set duration, the daemon loops the live wallpaper at least **once**, regardless of how long the video is — see [How Duration Works with Live Wallpapers](#how-duration-works-with-live-wallpapers) below.

## Overview

FluidWall provides:

- **Dynamic wallpaper cycling** with smooth crossfade transitions between images and live videos
- **Intelligent text contrast** — automatically adjusts Conky text color to stay readable against any wallpaper
- **Live video wallpaper support** — seamlessly integrates video clips into your wallpaper rotation
- **Zero-config Conky integration** — no need to hand-edit `.conkyrc` colors or restart Conky on wallpaper change
- **Managed Conky lifecycle** — fluidwall starts conky when the daemon starts and checks on it every 30s, restarting it if it dies (can be disabled)
- **Resource-efficient** — caching and pre-generation minimize CPU/GPU usage
- **GPU acceleration support** — optional VAAPI hardware encoding/decoding (AMD/Intel)
- **Tray icon control** — start/stop, change duration, and toggle conky from `fluidwall-tray`, no terminal needed

## Components

| File | Purpose |
|---|---|
| `fluidwall.sh` | The wallpaper engine — daemon, CLI, and installer. Installed as `fluidwall`. |
| `fluidwall-tray.sh` | System tray control panel built on `yad`. Installed as `fluidwall-tray`. |
| `conky_helpers.lua` | Lua helpers Conky loads to read the contrast color state and display rotating greetings. |
| `.conkyrc` | Reference Conky config wired up to use the helpers above. |
| `picom.conf` | Compositor config for transitions/transparency. |

## Requirements

```bash
# Core utilities
ffmpeg ffprobe mpv socat yad xwinwrap conky picom

# GPU acceleration (optional — built for AMD/Intel VAAPI; Nvidia not currently supported)
vainfo mesa-va-drivers intel-media-va-driver

# Build dependencies (for compiling xwinwrap)
git build-essential libx11-dev libxrender-dev x11-xserver-utils
```

`fluidwall install` (or `set-install`, which runs it for you) installs all of the above automatically where possible.

## Quick Start

### Initial setup (manual, if not using the curl one-liner)

```bash
cd ~/ndu-ndi
./fluidwall.sh set-install
```

`set-install` handles:

- Installing all system dependencies
- Backing up your existing `~/.conkyrc` to `~/.conkyrc.bak` and installing the repo's `.conkyrc`
- Installing `conky_helpers.lua` to `~/.local/run/`
- Downloading and installing the Anurati font
- Adding `~/.local/bin` to `PATH` via `~/.bashrc`
- Installing `fluidwall` and `fluidwall-tray` to `~/.local/bin`

Conky is *not* force-restarted by `set-install` — it's started (and kept alive) by the daemon once you run `fluidwall start`.

### Start the wallpaper engine

```bash
# Start with default settings (30-minute interval, conky managed automatically)
fluidwall start

# Start with a custom interval
fluidwall start --change 5m

# Start with GPU acceleration
fluidwall start --gpu

# Force CPU-only (overrides a previously saved --gpu)
fluidwall start --no-gpu

# Start without fluidwall touching conky at all
fluidwall start --no-conky
```

### Tray icon

```bash
fluidwall-tray &
```

Gives you a tray icon with start/restart/stop, live status, change duration, set live-every, and enable/disable conky — all as clickable menu items, backed by the same `fluidwall` CLI underneath.

### Configure Conky manually (only if not using `set-install`)

Add to your `.conkyrc`:

```lua
-- Load the Lua helpers
lua_load ~/.local/run/conky_helpers.lua
```

```
# Use in your conky text:
${lua conky_greeting}
${lua_parse conky_color_open}This text adapts to wallpaper contrast${lua_parse conky_color_close}
```

## Detailed Usage

### FluidWall commands

```bash
# Start/stop the daemon
fluidwall start [--change DURATION|-c DURATION] [--gpu|--no-gpu] [--conky|--no-conky]
fluidwall stop
fluidwall restart [--change DURATION|-c DURATION] [--gpu|--no-gpu] [--conky|--no-conky]

# View status and logs
fluidwall status
fluidwall log
fluidwall live-log                    # live video scheduling log

# Change settings on the fly
fluidwall change DURATION             # change interval to DURATION
fluidwall set-live-every N            # show a live video every N images (N<0 = live-only mode; 0 = never)
fluidwall set-conky on|off            # enable/disable conky management, applied live
fluidwall set-pic-dir [DIR]           # change image directory (opens picker if omitted)
fluidwall set-live-dir [DIR]          # change video directory (opens picker if omitted)

# Pre-generation and cleanup
fluidwall generate [--gpu|--no-gpu] [--parallel N]
fluidwall generate --clean            # remove cached bases/clips/transitions with no matching source

# Contrast (text color) settings
fluidwall set-contrast N              # 0 = linear inversion, 100 = hard black/white (default: 70)
fluidwall show-contrast               # display current contrast value

# Installation
fluidwall install                     # install system dependencies only
fluidwall set-install                 # full setup: deps, .conkyrc, helpers, font, PATH, fluidwall + fluidwall-tray on PATH

# Help
fluidwall help
fluidwall -h / --help
```

### Duration format

- `30s` — 30 seconds
- `5m` — 5 minutes
- `2h` — 2 hours
- `1h-30m` — 1 hour 30 minutes
- `2h-4m-30s` — 2 hours, 4 minutes, 30 seconds

**Minimum interval: 5 seconds.**

### How Duration Works with Live Wallpapers

Fluidwall handles live wallpapers differently from static images.

**The short version:** every live wallpaper video will play at least once, regardless of how short your `--change` duration is.

**Why:** when you set a duration (e.g. `--change 30s`), fluidwall tries to fill that time with your live wallpaper by looping it. But if the video is longer than the duration, it still plays the entire video at least once — the duration is a floor, not a hard cutoff. Concretely, the number of loops is `ceil(duration / video_length)`, with a minimum of 1.

| Live video length | `--change` duration | What actually happens |
|---|---|---|
| 30 seconds | 2 minutes | 30s × **4 loops** = 2 minutes |
| 2 minutes | 30 seconds | **2 minutes × 1 loop** (duration exceeded) |
| 5 minutes | 1 minute | **5 minutes × 1 loop** (duration exceeded) |
| 10 seconds | 1 minute | 10s × **6 loops** = 1 minute |

> **For live wallpapers, `--change` duration is a MINIMUM, not an exact time.** Shorter-than-duration videos loop to fill the gap; longer-than-duration videos play once in full.

**Recommended usage** — for predictable timing, keep live wallpaper videos short:

```bash
# Good: 30-second live video
fluidwall start --change 2m        # plays 30s × 4 loops = 2 minutes

# Good: 10-second live video
fluidwall start --change 5m        # plays 10s × 30 loops = 5 minutes

# Less predictable: 3-minute live video
fluidwall start --change 1m        # actually plays ~3 minutes (video is longer than duration)
```

For best results, use live wallpapers that are short (under ~1 minute), loop-friendly (seamless start/end), and roughly consistent with your change interval.

### GPU acceleration flags

- `--gpu` — enable VAAPI hardware encoding/decoding (AMD/Intel)
- `--no-gpu` — force CPU encoding/decoding (overrides a previously saved setting)

Persists to `~/.local/run/fluidwall.conf`. Without either flag, the last saved setting is reused (default: off).

### Conky management

- `--conky` / `--no-conky` on `start`/`restart` — enable or disable fluidwall's conky handling; persists.
- `fluidwall set-conky on|off` — flips it immediately without restarting the daemon.
- When enabled (default), fluidwall starts conky the moment the daemon starts (if it isn't already running) and re-checks every 30 seconds, restarting conky if it has died.
- When disabled, fluidwall never touches conky — start, stop, or run it yourself.
- `fluidwall status` reports `Conky: enabled (running)` / `(not running)` / `disabled`.

### Contrast control

FluidWall automatically adjusts Conky text color for readability against the current wallpaper:

- **Contrast value (0–100)** controls the mapping from background brightness to text color
  - `0` — linear inversion (text = 255 − background)
  - `70` (default) — smooth contrast with balanced saturation
  - `100` — hard black/white step function

Color transitions are smooth, fixed at fade speed 20 (1 = fast, 100 = slow).

## Architecture

### How it works

1. **Wallpaper cycling**
   - Scans `PIC_DIR`/`LIVE_DIR` for images and videos
   - Generates short base clips (0.5s) of each image/video
   - Maintains a rolling buffer of `PREGEN_COUNT` (default: 5) distinct pre-generated steps queued ahead
   - Uses `mpv` + `xwinwrap` for playback, with crossfade transitions between clips

2. **Contrast detection**
   - Watches for wallpaper changes
   - Samples average brightness of the current image/video
   - Applies a sigmoid mapping at the configured contrast value
   - Writes the resulting color to `~/.local/run/conky_color.txt`

3. **Conky integration**
   - `conky_helpers.lua` reads the color state file on every Conky update cycle — no `.conkyrc` edit or Conky restart needed on wallpaper change
   - fluidwall separately manages whether the conky *process itself* is running (see [Conky management](#conky-management) above)
   - Rotates greetings from a text file

### Directory structure

```
~/.local/run/
├── fluidwall.current_img      # current wallpaper path
├── conky_color.txt            # current contrast color (hex)
├── fluidwall.pid              # daemon PID
├── fluidwall_mpv.sock         # mpv IPC socket
├── fluidwall.conf             # config (interval, live_every, GPU, conky)
└── conky_helpers.lua          # Lua helper script

~/.config/wallpaper_contrast/
└── skew.conf                  # contrast value (0-100)

<pic_dir>/wallpaper_engine/    # generated clip cache (default pic dir: ~/Pictures)
├── bases/                     # 0.5s base clips of images
├── clips/                     # live video head/tail clips
└── brightness/                # cached brightness values

/mnt/fluidwall_ram/<uid>/      # RAM cache for active clips
/mnt/fluidwall_ram/wallpaper_engine/transitions/   # transition clips cache
```

## Performance Optimization

### GPU acceleration

```bash
fluidwall start --gpu
```

### Pre-generation

Build all clips ahead of time to avoid first-run stalls:

```bash
fluidwall generate --parallel 4
```

### Memory usage

- Active clips are cached in RAM under `/mnt/fluidwall_ram/<uid>/`
- The daemon keeps `PREGEN_COUNT` (default: 5) distinct steps queued ahead at any time
- Buffer refills happen automatically in the background as playback consumes the queue

## Troubleshooting

**Wallpaper not changing:**
```bash
fluidwall status
fluidwall log
fluidwall restart
```

**Conky not running / conky color not updating:**
```bash
fluidwall status              # shows conky's running state
fluidwall set-conky on        # re-enable/restart conky management
fluidwall show-contrast
fluidwall set-contrast 50     # force a color update
```

**Video wallpapers not working:**
```bash
which xwinwrap
vainfo                        # check GPU/VAAPI setup
fluidwall restart --no-gpu    # fall back to CPU
```

**Memory/CPU issues:**
```bash
fluidwall generate --parallel 1
```

## Advanced Configuration

### Custom image and video directories

```bash
fluidwall set-pic-dir ~/Pictures/Wallpapers
fluidwall set-live-dir ~/Videos/LiveWallpapers
```

### Live video scheduling

```bash
fluidwall set-live-every 3     # show a live video every 3 static images
fluidwall set-live-every 0     # never show live videos (static images only)
fluidwall set-live-every -1    # live-only mode, no static images at all
```

## License

These scripts are provided as-is. Feel free to modify and distribute.

## Appreciations

Many thanks to [shuokenzi23](https://github.com/shuokenzi23/minimal-clock.git), whose work inspired this project.

## Contributing

Suggestions and improvements welcome. Areas of interest:

- Additional transition effects
- More color mapping algorithms
- Support for more video formats
- Integration with other desktop environments / compositors

---

**Note:** built and tested for X11 with AMD/Intel GPUs. Nvidia support is not currently available. Wayland may require additional configuration.