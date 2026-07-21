#!/bin/bash
#distro=debian
#
# fluidwall.sh — on-the-fly fluid wallpaper engine (mpv playlist streaming).
# Maintains a rolling buffer of PREGEN_COUNT distinct steps queued ahead
# of playback. Base images/live clips/transitions are generated once and
# cached; to "hold" a picture for the configured interval, its short base
# clip is simply enqueued repeatedly (mpv loops it back-to-back) instead of
# ffmpeg-concatenating a long padded file. Nothing beyond bases/heads/
# tails/transitions is ever written to disk.
#
# Usage:
#   fluidwall.sh start [--change DURATION|-c DURATION] [--gpu|--no-gpu]
#   fluidwall.sh stop
#   fluidwall.sh restart [--change DURATION|-c DURATION] [--gpu|--no-gpu]
#   fluidwall.sh status
#   fluidwall.sh log
#   fluidwall.sh change DURATION
#   fluidwall.sh set-live-every N
#   fluidwall.sh set-pic-dir [DIR]
#   fluidwall.sh set-live-dir [DIR]
#   fluidwall.sh generate [--gpu|--no-gpu] [--parallel N]
#   fluidwall.sh generate --clean
#   fluidwall.sh install
#   fluidwall.sh --worker             (internal: the generator loop itself)
#   fluidwall.sh --generate-worker N  (internal: the pregeneration loop itself)
#   fluidwall.sh --clean-worker       (internal: the cleanup loop itself)

set -u

# ---------------------------------------------------------------------------
# 1. Paths / constants
# ---------------------------------------------------------------------------
if [ -d "$HOME/Pictures" ]; then
    DEFAULT_PIC_DIR="$HOME/Pictures"
elif [ -d "$HOME/pictures" ]; then
    DEFAULT_PIC_DIR="$HOME/pictures"
else
    DEFAULT_PIC_DIR="$HOME/Pictures"
fi
DEFAULT_LIVE_DIR="$HOME/.set"
DEFAULT_INTERVAL=1800
DEFAULT_LIVE_EVERY=3
DEFAULT_GPU=0
DEFAULT_PARALLEL=4

RUN_DIR="${HOME}/.local/run"
LOG_DIR="${HOME}/.local/log"
LOG_FILE="$LOG_DIR/fluidwall.log"
LIVE_LOG_FILE="$LOG_DIR/fluidwall_live.log"
PID_FILE="$RUN_DIR/fluidwall.pid"
GEN_PID_FILE="$RUN_DIR/fluidwall_generate.pid"
SOCK="$RUN_DIR/fluidwall_mpv.sock"
CONFIG_FILE="$RUN_DIR/fluidwall.conf"
STATE_FILE="$RUN_DIR/fluidwall.current_img"

BASE_DUR=0.5           # duration of a static base video / transition clip source
TRANS_DUR=0.4          # xfade duration
TRANS_OFFSET=0.05      # xfade offset into the clip

VAAPI_DEVICE="/dev/dri/renderD128"

# --- Buffer-based pregeneration ---------------------------------------------
PREGEN_COUNT=3          # how many distinct steps to keep queued ahead
BUFFER_POLL_INTERVAL=5   # seconds between buffer-level checks in steady state
MIN_INTERVAL=60          # hard floor for per-clip display duration

SCRIPT_PATH="$(readlink -f "${BASH_SOURCE[0]}")"

mkdir -p "$LOG_DIR" "$RUN_DIR"
touch "$LOG_FILE" "$LIVE_LOG_FILE"

# ---------------------------------------------------------------------------
# 2. Logging
# ---------------------------------------------------------------------------
log_event() {
    local level="$1"; shift
    local ts; ts=$(date '+%Y-%m-%d %H:%M:%S')
    printf '[%s] [%s] %s\n' "$ts" "$level" "$*" >> "$LOG_FILE"
    if [ "$level" = "ERROR" ]; then
        printf '[%s] [%s] %s\n' "$ts" "$level" "$*" >&2
    fi
}
log_info()  { log_event INFO  "$*"; }
log_warn()  { log_event WARN  "$*"; }
log_err()   { log_event ERROR "$*"; }
die()       { log_err "$*"; exit 1; }

# Separate, focused log of live-video loop scheduling: what mpv is actually
# being told to play (loop count, per-loop start/end, source duration).
log_live() {
    local ts; ts=$(date '+%Y-%m-%d %H:%M:%S')
    printf '[%s] %s\n' "$ts" "$*" >> "$LIVE_LOG_FILE"
}

# ---------------------------------------------------------------------------
# 2b. Screen resolution detection
# ---------------------------------------------------------------------------
detect_resolution() {
    local res=""
    if command -v xrandr >/dev/null 2>&1; then
        res=$(xrandr --current 2>/dev/null | awk '/\*/{print $1; exit}')
        if [ -z "$res" ]; then
            res=$(xrandr --current 2>/dev/null | awk '/ connected/{getline; print $1; exit}')
        fi
    fi
    if [[ "$res" =~ ^([0-9]+)x([0-9]+)$ ]]; then
        printf '%s %s\n' "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}"
    else
        log_warn "Could not detect screen resolution via xrandr, falling back to 1920x1080."
        printf '%s %s\n' 1920 1080
    fi
}

read -r TARGET_W TARGET_H < <(detect_resolution)
log_info "Detected target resolution: ${TARGET_W}x${TARGET_H}"

# Pick the closest "standard" aspect ratio to the detected screen resolution,
# for use as a redundant --video-aspect-override on the mpv live-wallpaper
# player only (not used for the generated short videos, which already
# handle aspect ratio correctly on their own).
detect_aspect_ratio() {
    local w="$1" h="$2"
    awk -v w="$w" -v h="$h" '
        BEGIN {
            split("16:9 16:10 21:9 32:9 3:2 4:3 5:4", labels, " ")
            n = split("1.77778 1.6 2.33333 3.55556 1.5 1.33333 1.25", vals, " ")
            target = w / h
            best_i = 1
            best_diff = 999
            for (i = 1; i <= n; i++) {
                diff = target - vals[i]
                if (diff < 0) diff = -diff
                if (diff < best_diff) {
                    best_diff = diff
                    best_i = i
                }
            }
            print labels[best_i]
        }
    '
}

TARGET_ASPECT="$(detect_aspect_ratio "$TARGET_W" "$TARGET_H")"
log_info "Selected closest standard aspect ratio: ${TARGET_ASPECT} (from ${TARGET_W}x${TARGET_H})."

# ---------------------------------------------------------------------------
# 3. Duration parsing (30s, 10m, 2h, 1h-30m ...)
# ---------------------------------------------------------------------------
normalize_duration() {
    local raw="${1:-}"
    raw="${raw,,}"
    raw="${raw// /}"
    raw="${raw//_/}"
    [ -n "$raw" ] || return 1

    local total=0
    local rest="$raw"

    while [ -n "$rest" ]; do
        if [[ "$rest" =~ ^([0-9]+)(s|m|h)([-,:]*)(.*)$ ]]; then
            local value="${BASH_REMATCH[1]}"
            local unit="${BASH_REMATCH[2]}"
            rest="${BASH_REMATCH[4]}"
            case "$unit" in
                s) total=$((total + value)) ;;
                m) total=$((total + value * 60)) ;;
                h) total=$((total + value * 3600)) ;;
                *) return 1 ;;
            esac
        else
            return 1
        fi
    done

    [ "$total" -gt 0 ] || return 1
    printf '%s\n' "$total"
}

parse_interval() {
    local input="${1:-}"
    local resolved
    if [ -z "$input" ]; then
        resolved="$DEFAULT_INTERVAL"
    else
        resolved=$(normalize_duration "$input") || return 1
    fi
    if [ "$resolved" -lt "$MIN_INTERVAL" ]; then
        log_err "Requested interval (${resolved}s) is below the minimum of ${MIN_INTERVAL}s. Refusing."
        return 1
    fi
    printf '%s\n' "$resolved"
}

# Parses --change/-c DURATION, --gpu, --no-gpu, and --parallel N from a
# command's argument list, regardless of order.
interval_arg=""
gpu_flag=0
nogpu_flag=0
parallel_arg=""
clean_flag=0
extract_flags() {
    interval_arg=""
    gpu_flag=0
    nogpu_flag=0
    parallel_arg=""
    clean_flag=0
    while [ $# -gt 0 ]; do
        case "$1" in
            -c|--change)
                interval_arg="${2:-}"
                shift 2 ;;
            --change=*)
                interval_arg="${1#--change=}"
                shift ;;
            --gpu)
                gpu_flag=1
                shift ;;
            --no-gpu)
                nogpu_flag=1
                shift ;;
            --parallel)
                parallel_arg="${2:-}"
                shift 2 ;;
            --parallel=*)
                parallel_arg="${1#--parallel=}"
                shift ;;
            --clean)
                clean_flag=1
                shift ;;
            *)
                shift ;;
        esac
    done
}

usage() {
    cat <<EOF
Usage:
  fluidwall.sh start [--change DURATION|-c DURATION] [--gpu|--no-gpu]
  fluidwall.sh stop
  fluidwall.sh restart [--change DURATION|-c DURATION] [--gpu|--no-gpu]
  fluidwall.sh status
  fluidwall.sh log
  fluidwall.sh live-log
  fluidwall.sh change DURATION
  fluidwall.sh set-live-every N
  fluidwall.sh set-pic-dir [DIR]     (opens picker if DIR omitted)
  fluidwall.sh set-live-dir [DIR]    (opens picker if DIR omitted)
  fluidwall.sh generate [--gpu|--no-gpu] [--parallel N]
                                     (pregenerate all bases/clips in the
                                      background, N jobs at once, default ${DEFAULT_PARALLEL})
  fluidwall.sh generate --clean
                                     (background cleanup: remove cached
                                      bases/clips/transitions left over from
                                      images/videos no longer present in
                                      PIC_DIR/LIVE_DIR)
  fluidwall.sh install

DURATION = how long each image/live-clip is displayed before advancing.
Minimum allowed: ${MIN_INTERVAL}s.
Duration examples: 5m, 10m, 2h, 1h-30m, 2h-4m-30s

--gpu enables VAAPI (AMD/Intel) for BOTH encoding and playback. --no-gpu
forces CPU for both, overriding a previously-saved --gpu. Both flags
persist to ${CONFIG_FILE} so you don't need to edit it by hand.
Without either flag, whatever was last set is reused (default: off).

--parallel N (generate only) runs up to N ffmpeg jobs concurrently.
Default: ${DEFAULT_PARALLEL}.

--clean (generate only) skips generation entirely and instead sweeps
${CACHE_DIR}/{bases,clips} and the transitions cache for files whose
source image/video no longer exists (deleted, renamed, or moved out of
PIC_DIR/LIVE_DIR). Runs in the background just like a normal generate.

Detected screen resolution: ${TARGET_W}x${TARGET_H} (auto-detected via xrandr;
re-detected on every run, so it always matches the current display).

Generated bases/clips/transitions are cached as .mp4 under
<pic_dir>/wallpaper_engine/{bases,clips,transitions}. Your own live
wallpaper source files (in the live dir) are untouched and can be any
format ffmpeg reads.

The worker keeps ${PREGEN_COUNT} playlist entries queued ahead at all times.
A picture is "held" for the configured interval by repeating its short
base clip on the playlist rather than generating one long padded file.
Config changes (duration, live-every, folders) are applied live via a
reload signal — no restart needed.

'generate' pregenerates every image base and every live head/tail clip
in the background ahead of time, so the daemon has no first-run stalls.
EOF
}

# ---------------------------------------------------------------------------
# 4. Config file
# ---------------------------------------------------------------------------
PIC_DIR="$DEFAULT_PIC_DIR"
LIVE_DIR="$DEFAULT_LIVE_DIR"
INTERVAL="$DEFAULT_INTERVAL"
LIVE_EVERY="$DEFAULT_LIVE_EVERY"
GPU="$DEFAULT_GPU"

ensure_config() {
    if [ ! -f "$CONFIG_FILE" ]; then
        cat > "$CONFIG_FILE" <<EOF
PIC_DIR=$DEFAULT_PIC_DIR
LIVE_DIR=$DEFAULT_LIVE_DIR
INTERVAL=$DEFAULT_INTERVAL
LIVE_EVERY=$DEFAULT_LIVE_EVERY
GPU=$DEFAULT_GPU
EOF
    fi
}

load_config() {
    ensure_config
    local k v
    while IFS='=' read -r k v; do
        [ -z "$k" ] && continue
        case "$k" in
            PIC_DIR)    PIC_DIR="$v" ;;
            LIVE_DIR)   LIVE_DIR="$v" ;;
            INTERVAL)   [[ "$v" =~ ^[0-9]+$ ]] && INTERVAL="$v" ;;
            LIVE_EVERY) [[ "$v" =~ ^[0-9]+$ ]] && LIVE_EVERY="$v" ;;
            GPU)        [[ "$v" =~ ^[01]$ ]] && GPU="$v" ;;
        esac
    done < "$CONFIG_FILE"
}

set_config_key() {
    local key="$1" val="$2"
    ensure_config
    if grep -q "^${key}=" "$CONFIG_FILE" 2>/dev/null; then
        sed -i "s|^${key}=.*|${key}=${val}|" "$CONFIG_FILE"
    else
        printf '%s=%s\n' "$key" "$val" >> "$CONFIG_FILE"
    fi
}

# Applies --gpu / --no-gpu to the saved config. --no-gpu wins if both given
# (shouldn't happen, but be predictable). No-op if neither flag was passed.
apply_gpu_flags() {
    local gpu="$1" nogpu="$2"
    if [ "$nogpu" = "1" ]; then
        set_config_key GPU 0
    elif [ "$gpu" = "1" ]; then
        set_config_key GPU 1
    fi
}

# CACHE_DIR and friends depend on PIC_DIR, so they're (re)computed after config load.
recompute_cache_paths() {
    CACHE_DIR="$PIC_DIR/wallpaper_engine"
    BASE_DIR="$CACHE_DIR/bases"
    CLIP_DIR="$CACHE_DIR/clips"
    TRANS_DIR="/tmp/wallpaper_engine/transitions"
    mkdir -p "$CACHE_DIR" "$BASE_DIR" "$CLIP_DIR" "$TRANS_DIR"
}

# ---------------------------------------------------------------------------
# 4b. RAM cache — base clips are ~2-5MB each; keeping the handful currently
#     "in play" on a tmpfs turns their reads from disk I/O into memory
#     reads. Only the tiny 0.5s base clips live here — everything else
#     (originals, disk cache of bases, transitions, live head/tail clips)
#     is untouched and still lives under $CACHE_DIR / $TRANS_DIR as before.
#
#     Uses /tmp rather than /run/user/$UID: on sysvinit systems (antiX and
#     friends) there's no logind/systemd session to create and own a
#     per-user /run/user/$UID directory, and this script deliberately never
#     shells out to sudo/root to create one. /tmp is always present, always
#     writable by the invoking user, and — on any system where /tmp is
#     itself tmpfs (the antiX/most-distros default) — gives the same "it's
#     actually RAM" benefit. On systems where /tmp is disk-backed, the base
#     clips still get mirrored here so repeated reads at least hit the page
#     cache instead of re-reading a fresh path off the original disk cache
#     dir each time; the per-user suffix keeps it private and collision-free
#     on shared machines.
#
#     RAM_CACHE_DIR does NOT depend on PIC_DIR, so it's computed once, here,
#     independent of recompute_cache_paths().
# ---------------------------------------------------------------------------
RAM_CACHE_DIR="/tmp/fluidwall_ram_${UID}"

# Wipes and (re)creates the RAM cache. Called on every daemon/generate
# startup and restart so stale clips from a previous run (or a previous
# PIC_DIR) never linger.
init_ram_cache() {
    rm -rf "$RAM_CACHE_DIR" 2>/dev/null
    local mkdir_err
    if ! mkdir_err=$(mkdir -p -m 700 "$RAM_CACHE_DIR" 2>&1); then
        log_err "RAM cache disabled: could not create $RAM_CACHE_DIR (${mkdir_err}). Falling back to disk-only base clips for this run."
        RAM_CACHE_DIR=""
        return
    fi
    # /tmp is shared/world-writable; the rm -rf above can silently no-op if
    # $RAM_CACHE_DIR already exists and is owned by someone else (sticky bit
    # on /tmp blocks us from deleting it), in which case mkdir -p just
    # returns success without it actually being ours. Catch that here with
    # one clear error instead of a confusing stream of per-clip cp failures
    # later in cache_to_ram.
    if [ "$(stat -c %U "$RAM_CACHE_DIR" 2>/dev/null)" != "$(id -un)" ]; then
        log_err "RAM cache disabled: $RAM_CACHE_DIR exists but is not owned by the current user. Falling back to disk-only base clips for this run."
        RAM_CACHE_DIR=""
        return
    fi
    log_info "RAM cache initialized at $RAM_CACHE_DIR."
}

# Removes the RAM cache dir entirely. Called on daemon exit/stop so nothing
# is left behind in tmpfs between runs.
cleanup_ram_cache() {
    [ -n "$RAM_CACHE_DIR" ] && rm -rf "$RAM_CACHE_DIR" 2>/dev/null
}

load_config
recompute_cache_paths

# ---------------------------------------------------------------------------
# 5. Dependency install
# ---------------------------------------------------------------------------
install_dependencies() {
    echo "Installing dependencies (apt + xwinwrap from source)..."
    sudo apt update
    sudo apt install -y ffmpeg mpv socat yad libnotify-bin git build-essential \
        libx11-dev libxrender-dev x11-xserver-utils \
        vainfo mesa-va-drivers intel-media-va-driver

    if command -v xwinwrap >/dev/null 2>&1; then
        echo "xwinwrap already installed, skipping build."
    else
        local build_dir="$HOME/xwinwrap"
        if [ -d "$build_dir" ]; then
            echo "Found existing $build_dir, pulling latest instead of re-cloning."
            git -C "$build_dir" pull || true
        else
            git clone https://github.com/mmhobi7/xwinwrap.git "$build_dir" || {
                echo "git clone failed."; return 1;
            }
        fi
        ( cd "$build_dir" && make && sudo make install ) || {
            echo "xwinwrap build/install failed."; return 1;
        }
    fi

    echo "Dependency install complete."
}

# ---------------------------------------------------------------------------
# 6. Hashing helpers
# ---------------------------------------------------------------------------
hash_content() { md5sum "$1" 2>/dev/null | cut -d' ' -f1; }

hash_identity() {
    local f="$1"
    local size mtime
    size=$(stat -c%s "$f" 2>/dev/null) || size=0
    mtime=$(stat -c%Y "$f" 2>/dev/null) || mtime=0
    printf '%s' "${f}${size}${mtime}" | md5sum | cut -d' ' -f1
}

# ---------------------------------------------------------------------------
# 6b. Encoding config — depends on the GPU config value.
#
#     GPU on: VAAPI via `-init_hw_device vaapi=va:<dev> -filter_hw_device va`,
#     decode stays on CPU, the existing software scale+crop chain sizes the
#     frame, then format=nv12,hwupload puts it on the GPU right before
#     h264_vaapi encodes it.
#     GPU off: plain libx264 CPU path.
# ---------------------------------------------------------------------------
USE_VAAPI=0
ENC_VIDEO_ARGS=()
FFMPEG_PRE_ARGS=()
SCALE_FILTER=""

compute_encoding_config() {
    if [ "$GPU" = "1" ]; then
        if [ -e "$VAAPI_DEVICE" ] && command -v vainfo >/dev/null 2>&1; then
            USE_VAAPI=1
            FFMPEG_PRE_ARGS=(-init_hw_device "vaapi=va:${VAAPI_DEVICE}" -filter_hw_device va)
            ENC_VIDEO_ARGS=(-c:v h264_vaapi -qp 23)
            SCALE_FILTER="scale=${TARGET_W}:${TARGET_H}:force_original_aspect_ratio=increase,crop=${TARGET_W}:${TARGET_H},setsar=1,fps=30,format=nv12,hwupload"
            log_info "GPU mode enabled: encoding via VAAPI (${VAAPI_DEVICE})."
        else
            log_warn "GPU requested but VAAPI device/tools not found ($VAAPI_DEVICE, vainfo). Falling back to CPU."
            USE_VAAPI=0
            GPU=0
            FFMPEG_PRE_ARGS=()
            ENC_VIDEO_ARGS=(-c:v libx264 -preset medium -crf 23 -pix_fmt yuv420p -movflags +faststart)
            SCALE_FILTER="scale=${TARGET_W}:${TARGET_H}:force_original_aspect_ratio=increase,crop=${TARGET_W}:${TARGET_H},setsar=1,fps=30"
        fi
    else
        USE_VAAPI=0
        FFMPEG_PRE_ARGS=()
        ENC_VIDEO_ARGS=(-c:v libx264 -preset medium -crf 23 -pix_fmt yuv420p -movflags +faststart)
        SCALE_FILTER="scale=${TARGET_W}:${TARGET_H}:force_original_aspect_ratio=increase,crop=${TARGET_W}:${TARGET_H},setsar=1,fps=30"
    fi
}

# ---------------------------------------------------------------------------
# 7. Daemon process management
# ---------------------------------------------------------------------------
require_cmd() { command -v "$1" >/dev/null 2>&1 || die "Required command '$1' not found in PATH."; }

daemon_running() {
    [ -f "$PID_FILE" ] || return 1
    local pid; pid=$(cat "$PID_FILE" 2>/dev/null)
    [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null
}

stop_daemon() {
    if ! daemon_running; then
        echo "Fluidwall daemon is not running."
        rm -f "$PID_FILE"
        pkill -x xwinwrap 2>/dev/null
        pkill -x mpv 2>/dev/null
        cleanup_ram_cache
        return 0
    fi
    local pid; pid=$(cat "$PID_FILE")
    log_info "Stopping daemon (pgid $pid)."
    kill -TERM -- "-$pid" 2>/dev/null
    sleep 0.5
    kill -KILL -- "-$pid" 2>/dev/null
    rm -f "$PID_FILE" "$SOCK"
    pkill -x xwinwrap 2>/dev/null
    pkill -x mpv 2>/dev/null
    # Safety net: run_worker's own TERM trap already does this, but if it
    # was killed before the trap fired (KILL, crash, etc.) this guarantees
    # the RAM cache never lingers between runs.
    cleanup_ram_cache
    echo "Fluidwall daemon stopped."
}

status_daemon() {
    if daemon_running; then
        printf 'Fluidwall daemon: ACTIVE (pid %s)\n' "$(cat "$PID_FILE")"
        printf 'Interval: %ss   Live every: %s   Pic dir: %s   Live dir: %s\n' \
            "$INTERVAL" "$LIVE_EVERY" "$PIC_DIR" "$LIVE_DIR"
        printf 'Resolution: %sx%s   GPU (VAAPI): %s\n' "$TARGET_W" "$TARGET_H" "$([ "$GPU" = "1" ] && echo on || echo off)"
        printf 'Pregen buffer target: %s distinct steps\n' "$PREGEN_COUNT"
        [ -f "$LOG_FILE" ] && { printf '\nTail of log:\n'; tail -n 8 "$LOG_FILE"; }
    else
        printf 'Fluidwall daemon: INACTIVE\n'
    fi
    if generate_running; then
        printf 'Pregeneration worker: RUNNING (pid %s)\n' "$(cat "$GEN_PID_FILE")"
    fi
}

start_daemon() {
    local interval="${1:-}" gpu="${2:-0}" nogpu="${3:-0}"
    local resolved
    resolved=$(parse_interval "$interval") || {
        echo "Invalid or too-short duration. Minimum is ${MIN_INTERVAL}s. Examples: 5m, 30m, 2h, 1h-30m."
        return 1
    }
    if daemon_running; then
        echo "Fluidwall daemon already running. Use 'restart' or 'change' to update the interval."
        return 1
    fi
    set_config_key INTERVAL "$resolved"
    apply_gpu_flags "$gpu" "$nogpu"
    load_config
    log_info "Starting daemon (interval=${resolved}s, gpu=${GPU}, resolution=${TARGET_W}x${TARGET_H}, pregen_buffer=${PREGEN_COUNT} distinct steps)."
    setsid "$SCRIPT_PATH" --worker >> "$LOG_FILE" 2>&1 &
    local pid=$!
    echo "$pid" > "$PID_FILE"
    disown
    sleep 0.3
    if daemon_running; then
        printf 'Fluidwall daemon started (pid %s, interval=%ss, gpu=%s). Building initial buffer of %s distinct steps before playback starts — this may take a bit.\n' \
            "$pid" "$resolved" "$([ "$GPU" = "1" ] && echo on || echo off)" "$PREGEN_COUNT"
    else
        echo "Daemon failed to start — check $LOG_FILE"
        return 1
    fi
}

restart_daemon() {
    local interval="${1:-}" gpu="${2:-0}" nogpu="${3:-0}"
    stop_daemon
    sleep 0.3
    start_daemon "$interval" "$gpu" "$nogpu"
}

# Applies a config change live if the daemon is running, without a restart.
reload_running_daemon() {
    if daemon_running; then
        kill -USR1 "$(cat "$PID_FILE")" 2>/dev/null
        log_info "Sent reload signal to running daemon."
    fi
}

change_interval() {
    local dur="$1"
    local resolved
    resolved=$(parse_interval "$dur") || { echo "Invalid duration."; return 1; }
    set_config_key INTERVAL "$resolved"
    if daemon_running; then
        reload_running_daemon
        echo "Interval updated to ${resolved}s (applied live)."
    else
        echo "Interval saved (${resolved}s). Daemon not running."
    fi
}

set_live_every() {
    local n="$1"
    [[ "$n" =~ ^[0-9]+$ ]] || { echo "live-every must be a non-negative integer."; return 1; }
    set_config_key LIVE_EVERY "$n"
    if daemon_running; then
        reload_running_daemon
        echo "live-every updated to $n (applied live)."
    else
        echo "live-every saved ($n). Daemon not running."
    fi
}

set_pic_dir() {
    local dir="${1:-}"
    if [ -z "$dir" ]; then
        dir=$(pick_folder "Select picture directory")
        [ -z "$dir" ] && { echo "No folder selected."; return 1; }
    fi
    [ -d "$dir" ] || { echo "Not a directory: $dir"; return 1; }
    set_config_key PIC_DIR "$dir"
    if daemon_running; then
        reload_running_daemon
        echo "Picture directory updated to $dir (applied live)."
    else
        echo "Picture directory saved: $dir"
    fi
}

set_live_dir() {
    local dir="${1:-}"
    if [ -z "$dir" ]; then
        dir=$(pick_folder "Select live wallpaper directory")
        [ -z "$dir" ] && { echo "No folder selected."; return 1; }
    fi
    [ -d "$dir" ] || { echo "Not a directory: $dir"; return 1; }
    set_config_key LIVE_DIR "$dir"
    if daemon_running; then
        reload_running_daemon
        echo "Live wallpaper directory updated to $dir (applied live)."
    else
        echo "Live wallpaper directory saved: $dir"
    fi
}

# Folder picker, concept borrowed from folderer.sh
pick_folder() {
    local title="${1:-Select a folder}"
    local picked=""
    if command -v zenity &>/dev/null; then
        picked=$(zenity --file-selection --directory --title="$title")
    elif command -v yad &>/dev/null; then
        picked=$(yad --file-selection --directory --title="$title")
    fi
    printf '%s' "$picked"
}

# ---------------------------------------------------------------------------
# 8. ffmpeg wrapper — automatically prepends GPU-mode pre-args.
# ---------------------------------------------------------------------------
ffmpeg_run() {
    log_info "ffmpeg ${FFMPEG_PRE_ARGS[*]:-} $*"
    ffmpeg -y -hide_banner -loglevel error "${FFMPEG_PRE_ARGS[@]}" "$@" >> "$LOG_FILE" 2>&1
}

# ---------------------------------------------------------------------------
# 10. Static image -> 0.5s base video (cached, built once per image, lazily)
#
#     Cache-check uses `[ -s "$out" ]` (non-empty), not `[ -f "$out" ]`
#     (merely exists), so a failed encode's stale/empty leftover is never
#     mistaken for valid cache on a later run.
# ---------------------------------------------------------------------------
declare -A IMG_HASH_OF
declare -A IMG_BASE_OF

# Copies a just-built (or already-cached) disk base clip into the RAM cache
# and points IMG_BASE_OF at whichever copy is actually usable. This is the
# only place IMG_BASE_OF gets written, so every caller (transitions,
# queue_padded_image, etc.) automatically gets the RAM path for free.
#
# Fallback: if the RAM cache is unavailable (init failed, tmpfs full,
# /run/user/$UID missing on a non-systemd setup, ...), IMG_BASE_OF simply
# points at the disk path instead and everything else keeps working exactly
# as before RAM caching existed.
cache_to_ram() {
    local img="$1" disk_path="$2"
    if [ -n "$RAM_CACHE_DIR" ]; then
        local ram_path="$RAM_CACHE_DIR/$(basename "$disk_path")"
        local cp_err
        if cp_err=$(cp -f "$disk_path" "$ram_path" 2>&1) && [ -s "$ram_path" ]; then
            IMG_BASE_OF["$img"]="$ram_path"
            prune_ram_cache
            return 0
        fi
        log_err "RAM cache write failed for $(basename "$disk_path") (${cp_err:-empty result file}); falling back to disk path for this clip: $disk_path"
    else
        log_warn "RAM cache unavailable; serving $(basename "$disk_path") from disk: $disk_path"
    fi
    IMG_BASE_OF["$img"]="$disk_path"
}

# Keeps only the newest PREGEN_COUNT base clips in RAM (current step +
# lookahead buffer). At ~2-5MB each this caps RAM usage at well under 20MB.
# Anything evicted here just falls back to disk transparently: the next
# ensure_image_base call for that image will see its RAM copy missing,
# notice the disk copy already exists (so no re-encode), and re-mirror it
# into RAM via cache_to_ram.
prune_ram_cache() {
    [ -n "$RAM_CACHE_DIR" ] || return 0
    local files
    mapfile -t files < <(ls -1t "$RAM_CACHE_DIR"/*.mp4 2>/dev/null)
    local count=${#files[@]} i
    if [ "$count" -gt "$PREGEN_COUNT" ]; then
        for ((i=PREGEN_COUNT; i<count; i++)); do
            rm -f "${files[$i]}"
        done
    fi
}

build_image_base() {
    local img="$1"
    local h; h=$(hash_content "$img")
    IMG_HASH_OF["$img"]="$h"
    local out="$BASE_DIR/img_${h}_base.mp4"

    if [ -s "$out" ]; then
        # Disk cache already has it (either from an earlier run, or from
        # 'generate') — just mirror the existing bytes into RAM.
        cache_to_ram "$img" "$out"
        return 0
    fi

    log_info "Generating base video for image: $img"
    ffmpeg_run -loop 1 -i "$img" -t "$BASE_DUR" \
        -vf "$SCALE_FILTER" \
        "${ENC_VIDEO_ARGS[@]}" -an \
        "$out"
    if [ $? -ne 0 ] || [ ! -s "$out" ]; then
        rm -f "$out"
        log_err "Failed to generate base video for $img"
        return 1
    fi
    cache_to_ram "$img" "$out"
}

ensure_image_base() {
    local img="$1"
    [ -n "${IMG_BASE_OF[$img]:-}" ] && [ -s "${IMG_BASE_OF[$img]}" ] && return 0
    build_image_base "$img"
}

# ---------------------------------------------------------------------------
# 11. Live video -> head/tail clips (cached, built once per live file, lazily)
# ---------------------------------------------------------------------------
declare -A LIVE_HASH_OF
declare -A LIVE_HEAD_OF
declare -A LIVE_TAIL_OF
declare -A LIVE_DUR_OF

build_live_clips() {
    local vid="$1"
    local h; h=$(hash_identity "$vid")
    LIVE_HASH_OF["$vid"]="$h"

    local head="$CLIP_DIR/live_${h}_head.mp4"
    local tail="$CLIP_DIR/live_${h}_tail.mp4"
    LIVE_HEAD_OF["$vid"]="$head"
    LIVE_TAIL_OF["$vid"]="$tail"

    if [ ! -s "$head" ]; then
        log_info "Generating head clip for live wallpaper: $vid"
        ffmpeg_run -ss 0 -i "$vid" -t "$BASE_DUR" \
            -vf "$SCALE_FILTER" \
            "${ENC_VIDEO_ARGS[@]}" -an \
            "$head"
        if [ $? -ne 0 ] || [ ! -s "$head" ]; then
            rm -f "$head"
            log_err "Failed head clip for $vid"
        fi
    fi

    if [ ! -s "$tail" ]; then
        log_info "Generating tail clip for live wallpaper: $vid"
        ffmpeg_run -sseof "-${BASE_DUR}" -i "$vid" -t "$BASE_DUR" \
            -vf "$SCALE_FILTER" \
            "${ENC_VIDEO_ARGS[@]}" -an \
            "$tail"
        if [ $? -ne 0 ] || [ ! -s "$tail" ]; then
            rm -f "$tail"
            log_err "Failed tail clip for $vid"
        fi
    fi
}

ensure_live_clips() {
    local vid="$1"
    [ -n "${LIVE_HEAD_OF[$vid]:-}" ] && [ -s "${LIVE_HEAD_OF[$vid]}" ] && [ -s "${LIVE_TAIL_OF[$vid]}" ] && return 0
    build_live_clips "$vid"
}

get_live_duration() {
    local vid="$1"
    if [ -n "${LIVE_DUR_OF[$vid]:-}" ]; then
        printf '%s\n' "${LIVE_DUR_OF[$vid]}"
        return 0
    fi
    local d
    d=$(ffprobe -v error -show_entries format=duration -of default=noprint_wrappers=1:nokey=1 "$vid" 2>/dev/null)
    [[ "$d" =~ ^[0-9]+([.][0-9]+)?$ ]] || d="$BASE_DUR"
    LIVE_DUR_OF["$vid"]="$d"
    printf '%s\n' "$d"
}

schedule_live_segment() {
    local vid="$1" interval="$2" vidlen; vidlen=$(get_live_duration "$vid")
    local loops_needed
    loops_needed=$(awk -v i="$interval" -v l="$vidlen" 'BEGIN{
        if (l <= 0) { print 1; exit }
        n = i / l
        ceil = int(n)
        if (n > ceil) ceil++
        if (ceil < 1) ceil = 1
        print ceil
    }')

    # Trim off what the surrounding img<->live crossfade transitions already
    # showed, so the head/tail of the live video isn't played twice:
    #   - img->live transition uses the first BASE_DUR seconds (head clip)
    #   - live->img transition uses the last BASE_DUR seconds (tail clip)
    local end_ts
    end_ts=$(awk -v l="$vidlen" -v t="$BASE_DUR" 'BEGIN{e=l-t; if(e<0)e=0; printf "%.3f",e}')

    log_live "=== $(basename "$vid") | change_duration=${interval}s original_duration=${vidlen}s -> ${loops_needed} loop(s) ==="

    local n opts eff_start eff_end eff_dur total_dur=0
    for ((n=0; n<loops_needed; n++)); do
        opts=""
        eff_start="0.000"
        eff_end="$vidlen"
        if [ "$loops_needed" -eq 1 ]; then
            opts="start=${BASE_DUR},end=${end_ts}"
            eff_start="$BASE_DUR"; eff_end="$end_ts"
        elif [ "$n" -eq 0 ]; then
            opts="start=${BASE_DUR}"
            eff_start="$BASE_DUR"; eff_end="$vidlen"
        elif [ "$n" -eq $((loops_needed - 1)) ]; then
            opts="end=${end_ts}"
            eff_start="0.000"; eff_end="$end_ts"
        fi
        eff_dur=$(awk -v s="$eff_start" -v e="$eff_end" 'BEGIN{d=e-s; if(d<0)d=0; printf "%.3f", d}')
        total_dur=$(awk -v t="$total_dur" -v d="$eff_dur" 'BEGIN{printf "%.3f", t+d}')
        log_live "  loop $((n+1))/${loops_needed}: start=${eff_start}s end=${eff_end}s duration=${eff_dur}s"
        enqueue "$vid" "$opts" "$vid"
    done
    log_live "  total live playback this segment=${total_dur}s (requested change_duration=${interval}s, delta=$(awk -v t="$total_dur" -v i="$interval" 'BEGIN{printf "%.3f", t-i}')s)"
}

# ---------------------------------------------------------------------------
# 12. Transitions — built lazily, only for pairs actually used, cached by pair.
# ---------------------------------------------------------------------------
build_transition() {
    local from="$1" to="$2" out="$3"
    [ -s "$out" ] && { printf '%s\n' "$out"; return 0; }
    [ -s "$from" ] && [ -s "$to" ] || { log_err "Missing/invalid clip for transition -> $out"; return 1; }

    local xfade_filter="[0:v][1:v]xfade=transition=fade:duration=${TRANS_DUR}:offset=${TRANS_OFFSET},format=yuv420p"
    if [ "$USE_VAAPI" = "1" ]; then
        xfade_filter="${xfade_filter},format=nv12,hwupload"
    fi
    xfade_filter="${xfade_filter}[v]"

    log_info "Generating transition: $(basename "$out")"
    ffmpeg_run -i "$from" -i "$to" \
        -filter_complex "$xfade_filter" \
        -map "[v]" \
        "${ENC_VIDEO_ARGS[@]}" -an \
        "$out"
    if [ $? -ne 0 ] || [ ! -s "$out" ]; then
        rm -f "$out"
        log_err "Failed transition $out"
        return 1
    fi
    printf '%s\n' "$out"
}

img_to_img_transition() {
    local a="$1" b="$2"
    local ha="${IMG_HASH_OF[$a]}" hb="${IMG_HASH_OF[$b]}"
    build_transition "${IMG_BASE_OF[$a]}" "${IMG_BASE_OF[$b]}" "$TRANS_DIR/img_${ha}_to_img_${hb}_transition.mp4"
}

img_to_live_transition() {
    local img="$1" vid="$2"
    local hi="${IMG_HASH_OF[$img]}" hv="${LIVE_HASH_OF[$vid]}"
    build_transition "${IMG_BASE_OF[$img]}" "${LIVE_HEAD_OF[$vid]}" "$TRANS_DIR/img_${hi}_to_live_${hv}_transition.mp4"
}

live_to_img_transition() {
    local vid="$1" img="$2"
    local hv="${LIVE_HASH_OF[$vid]}" hi="${IMG_HASH_OF[$img]}"
    build_transition "${LIVE_TAIL_OF[$vid]}" "${IMG_BASE_OF[$img]}" "$TRANS_DIR/live_${hv}_to_img_${hi}_transition.mp4"
}

# ---------------------------------------------------------------------------
# 13. Scan sources
# ---------------------------------------------------------------------------
IMAGES=()
LIVES=()

scan_sources() {
    IMAGES=()
    LIVES=()
    while IFS= read -r -d '' f; do IMAGES+=("$f"); done < <(
find -L "$PIC_DIR" -maxdepth 1 -type f \( -iname '*.jpg' -o -iname '*.jpeg' -o -iname '*.png' -o -iname '*.webp' \) -print0 2>/dev/null
    )
    while IFS= read -r -d '' f; do LIVES+=("$f"); done < <(
        find -L "$LIVE_DIR" -maxdepth 1 -type f -iname '*.mkv' -print0 2>/dev/null
    )
    log_info "Found ${#IMAGES[@]} static image(s), ${#LIVES[@]} live wallpaper(s)."
}

# ---------------------------------------------------------------------------
# 14. Repeat-queue helper
#
#     CHANGE: previously this pushed (interval / BASE_DUR) separate
#     playlist entries (e.g. 3600 for a 30-minute interval at a 0.5s base
#     clip) so mpv would "hold" the picture by playing the same tiny clip
#     back-to-back that many times. Collapsed to a single playlist entry
#     using mpv's own per-file repeat count instead.
#
#     BUG (fixed here): the first version of this used the per-file options
#     "loop-file=inf,length=<seconds>", intending "loop the clip, but stop
#     and advance once <seconds> have played". That's not what mpv does:
#     per mpv's own docs, when a file has a start/end (or length) range set,
#     --loop-file loops *that trimmed segment*, not the file's true EOF —
#     so loop-file=inf + length=N loops the N-second segment forever and
#     the playlist NEVER advances. That's why the wallpaper looked frozen
#     no matter how long you waited on the interval.
#
#     Fix: use a FINITE --loop-file=<N>, which mpv defines as a genuine
#     per-file repeat count (play the file, then loop it N more times, i.e.
#     N+1 total plays, then normal playlist advance) — no "length" trimming
#     involved, so there's no segment for it to loop forever within. Since
#     every base clip is encoded to exactly BASE_DUR seconds (see
#     build_image_base), the repeat count needed to cover $interval is just
#     ceil(interval / BASE_DUR) plays, i.e. that minus 1 loops.
# ---------------------------------------------------------------------------
queue_repeated() {
    local src="$1" interval="$2" label="${3:-$src}"
    [ -s "$src" ] || { log_err "queue_repeated: missing/invalid source $src"; return 1; }

    local plays loops
    plays=$(awk -v i="$interval" -v d="$BASE_DUR" 'BEGIN{ r=i/d; if (r<1) r=1; printf "%d", (r==int(r)?r:int(r)+1) }')
    loops=$((plays - 1))
    [ "$loops" -lt 0 ] && loops=0

    enqueue "$src" "loop-file=${loops}" "$label"
}

# ---------------------------------------------------------------------------
# 15. mpv IPC helpers
# ---------------------------------------------------------------------------
mpv_send() {
    printf '%s\n' "$1" | socat -t 1 - "UNIX-CONNECT:$SOCK" >/dev/null 2>&1
}

mpv_loadfile() {
    local path="$1" opts="${2:-}"
    local esc="${path//\\/\\\\}"
    esc="${esc//\"/\\\"}"
    if [ -n "$opts" ]; then
        local esc_opts="${opts//\\/\\\\}"
        esc_opts="${esc_opts//\"/\\\"}"
        mpv_send "{\"command\":[\"loadfile\",\"${esc}\",\"append-play\",\"${esc_opts}\"]}"
    else
        mpv_send "{\"command\":[\"loadfile\",\"${esc}\",\"append-play\"]}"
    fi
}

mpv_get_property() {
    local prop="$1" resp
    resp=$(printf '%s\n' "{\"command\":[\"get_property\",\"${prop}\"]}" | socat -t 1 - "UNIX-CONNECT:$SOCK" 2>/dev/null)
    printf '%s' "$resp" | grep -oE '"data":-?[0-9]+' | head -n1 | grep -oE -- '-?[0-9]+$'
}

wait_for_socket() {
    local tries=0
    while [ ! -S "$SOCK" ]; do
        sleep 0.2
        tries=$((tries+1))
        [ "$tries" -gt 50 ] && die "mpv IPC socket never appeared: $SOCK"
    done
}

start_player() {
    require_cmd xwinwrap mpv socat
    pkill -x xwinwrap 2>/dev/null
    pkill -x mpv 2>/dev/null
    pkill feh 2>/dev/null
    rm -f "$SOCK"

    local hwdec_args=(--hwdec=no)
    if [ "$GPU" = "1" ] && [ "$USE_VAAPI" = "1" ]; then
        hwdec_args=(--hwdec=vaapi --hwdec-codecs=all)
    fi

    xwinwrap -ov -fs -b -nf -ni -- mpv -wid WID --no-audio --no-sub --no-osd-bar --no-osc \
        --no-input-default-bindings --vo=gpu "${hwdec_args[@]}" \
        --video-aspect-override="$TARGET_ASPECT" \
        --cache=yes --cache-secs=300 --no-terminal --idle=yes --loop-file=no \
        --input-ipc-server="$SOCK" &
    disown
    log_info "Launched xwinwrap+mpv (hwdec=${hwdec_args[0]}), waiting for IPC socket."
    wait_for_socket "$SOCK"
    log_info "mpv IPC socket ready: $SOCK"
}

# ---------------------------------------------------------------------------
# 16. Generator loop
# ---------------------------------------------------------------------------
RELOAD_REQUESTED=0

run_worker() {
    require_cmd ffmpeg ffprobe

    load_config
    recompute_cache_paths
    compute_encoding_config
    init_ram_cache
    log_info "Generator loop starting (interval=${INTERVAL}s, live_every=${LIVE_EVERY}, gpu=${GPU}, resolution=${TARGET_W}x${TARGET_H}, pregen_buffer=${PREGEN_COUNT} distinct steps)."

    trap 'log_info "Worker received termination signal, exiting."; pkill -x xwinwrap 2>/dev/null; pkill -x mpv 2>/dev/null; rm -f "$SOCK"; cleanup_ram_cache; exit 0' TERM INT
    trap 'RELOAD_REQUESTED=1' USR1

    scan_sources
    [ "${#IMAGES[@]}" -gt 0 ] || die "No static images found in $PIC_DIR."

    local have_live=0
    [ "${#LIVES[@]}" -gt 0 ] && have_live=1

    mapfile -t ORDER < <(printf '%s\n' "${IMAGES[@]}" | shuf)
    local n="${#ORDER[@]}"
    local idx=0
    local prev_img=""
    local static_count=0
    local first=1

    QUEUE_ARR=()
    QUEUE_OPTS_ARR=()
    TOTAL_QUEUED=0
    STEP_COUNT=0
    STEP_ENDS=()

    # ALL_LABELS is aligned to mpv playlist position: ALL_LABELS[i] is what
    # should be considered "currently displayed" while mpv is playing
    # playlist entry i. It grows in exactly the same order entries are
    # enqueued/flushed, so its indices always match playlist-pos.
    ALL_LABELS=()
    enqueue() { QUEUE_ARR+=("$1"); QUEUE_OPTS_ARR+=("${2:-}"); ALL_LABELS+=("${3:-$1}"); }

    flush_queue() {
        [ -S "$SOCK" ] || return 0
        local cnt=${#QUEUE_ARR[@]}
        [ "$cnt" -eq 0 ] && return 0
        local i
        for ((i=0; i<cnt; i++)); do
            mpv_loadfile "${QUEUE_ARR[$i]}" "${QUEUE_OPTS_ARR[$i]}"
        done
        TOTAL_QUEUED=$((TOTAL_QUEUED + cnt))
        QUEUE_ARR=()
        QUEUE_OPTS_ARR=()
    }

    get_remaining_buffer() {
        [ -S "$SOCK" ] || { printf '%s\n' "$STEP_COUNT"; return 0; }
        local pos
        pos=$(mpv_get_property "playlist-pos")
        [[ "$pos" =~ ^-?[0-9]+$ ]] || pos=0
        [ "$pos" -lt 0 ] && pos=0
        local remaining=0 end
        # STEP_ENDS holds the playlist index of the LAST entry belonging to
        # each step. With native mpv looping (queue_repeated -> a single
        # loop-file=inf entry) each step contributes exactly one playlist
        # entry, so this now walks by 1 per step instead of by
        # (INTERVAL/BASE_DUR) per step — but the comparison logic itself
        # (index > current playlist-pos => still ahead of playback) needed
        # no change, since it was always driven by however many entries
        # were actually queued, not a hardcoded count.
        for end in "${STEP_ENDS[@]}"; do
            [ "$end" -gt "$pos" ] && remaining=$((remaining + 1))
        done
        printf '%s\n' "$remaining"
    }

    # Writes STATE_FILE from mpv's ACTUAL playback position (playlist-pos),
    # not from whatever step was most recently built/queued. Since
    # PREGEN_COUNT steps are always buffered ahead, "most recently queued"
    # can be up to PREGEN_COUNT steps in the future relative to what's on
    # screen — this reads truth from mpv itself instead.
    LAST_STATE=""
    update_display_state() {
        [ -S "$SOCK" ] || return 0
        local pos
        pos=$(mpv_get_property "playlist-pos")
        [[ "$pos" =~ ^[0-9]+$ ]] || return 0
        local label="${ALL_LABELS[$pos]:-}"
        [ -n "$label" ] || return 0
        if [ "$label" != "$LAST_STATE" ]; then
            printf '%s\n' "$label" > "$STATE_FILE"
            LAST_STATE="$label"
        fi
    }

    queue_padded_image() {
        local img="$1"
        ensure_image_base "$img" || return 1
        queue_repeated "${IMG_BASE_OF[$img]}" "$INTERVAL" "$img"
    }

    build_and_queue_step() {
        local img="$1"
        ensure_image_base "$img" || return 1

        if [ "$first" -eq 1 ]; then
            queue_padded_image "$img" || log_err "Failed to queue first image."
            STEP_ENDS+=("$((TOTAL_QUEUED + ${#QUEUE_ARR[@]} - 1))")
            STEP_COUNT=$((STEP_COUNT + 1))
            first=0
            return 0
        fi

        static_count=$((static_count+1))
        if [ "$have_live" -eq 1 ] && [ "$LIVE_EVERY" -gt 0 ] && [ $((static_count % LIVE_EVERY)) -eq 0 ]; then
            local vid="${LIVES[$((RANDOM % ${#LIVES[@]}))]}"
            ensure_live_clips "$vid"
            local t1 t2
            t1=$(img_to_live_transition "$prev_img" "$vid") && enqueue "$t1" "" "$vid"
            schedule_live_segment "$vid" "$INTERVAL" || log_err "Failed to schedule live segment: $vid"
            t2=$(live_to_img_transition "$vid" "$img") && enqueue "$t2" "" "$img"
            queue_padded_image "$img" || log_err "Failed to queue image after live: $img"
        else
            local t
            t=$(img_to_img_transition "$prev_img" "$img") && enqueue "$t" "" "$img"
            queue_padded_image "$img" || log_err "Failed to queue image: $img"
        fi
        STEP_ENDS+=("$((TOTAL_QUEUED + ${#QUEUE_ARR[@]} - 1))")
        STEP_COUNT=$((STEP_COUNT + 1))
    }

    advance_idx() {
        idx=$((idx+1))
        if [ "$idx" -ge "$n" ]; then
            idx=0
            mapfile -t ORDER < <(printf '%s\n' "${IMAGES[@]}" | shuf)
            log_info "Completed a full pass, reshuffled order."
        fi
    }

    do_reload() {
        local old_pic="$PIC_DIR" old_live="$LIVE_DIR" old_gpu="$GPU"
        load_config
        log_info "Reload: interval=${INTERVAL}s live_every=${LIVE_EVERY} pic_dir=${PIC_DIR} live_dir=${LIVE_DIR} gpu=${GPU}"
        if [ "$GPU" != "$old_gpu" ]; then
            log_warn "GPU setting changed via reload (${old_gpu} -> ${GPU}). Restart the daemon ('fluidwall.sh restart') to apply it to playback and new encodes cleanly."
            compute_encoding_config
        fi
        if [ "$PIC_DIR" != "$old_pic" ] || [ "$LIVE_DIR" != "$old_live" ]; then
            recompute_cache_paths
            scan_sources
            [ "${#IMAGES[@]}" -gt 0 ] || { log_err "Reload: no images in new PIC_DIR, keeping old source list."; PIC_DIR="$old_pic"; LIVE_DIR="$old_live"; recompute_cache_paths; scan_sources; return; }
            mapfile -t ORDER < <(printf '%s\n' "${IMAGES[@]}" | shuf)
            n="${#ORDER[@]}"
            idx=0
            have_live=0
            [ "${#LIVES[@]}" -gt 0 ] && have_live=1
        fi
        RELOAD_REQUESTED=0
    }

    log_info "Pre-generating initial buffer of ${PREGEN_COUNT} distinct steps before starting player."
    while [ "$STEP_COUNT" -lt "$PREGEN_COUNT" ]; do
        build_and_queue_step "${ORDER[$idx]}"
        prev_img="${ORDER[$idx]}"
        advance_idx
    done
    log_info "Initial buffer ready (${STEP_COUNT} distinct steps staged). Starting player."

    start_player
    flush_queue
    log_info "Flushed initial buffer to mpv (total queued so far: ${TOTAL_QUEUED})."
    update_display_state

    while true; do
        [ "$RELOAD_REQUESTED" -eq 1 ] && do_reload
        local remaining
        remaining=$(get_remaining_buffer)
        if [ "$remaining" -lt "$PREGEN_COUNT" ]; then
            local next_img="${ORDER[$idx]}"
            log_info "Distinct-step buffer at ${remaining}/${PREGEN_COUNT}, building next step: $(basename "$next_img")"
            build_and_queue_step "$next_img"
            prev_img="$next_img"
            flush_queue
            advance_idx
            update_display_state
        else
            # Poll every second (rather than sleeping the full
            # BUFFER_POLL_INTERVAL in one shot) so STATE_FILE tracks actual
            # on-screen content promptly instead of lagging by up to
            # BUFFER_POLL_INTERVAL seconds.
            local waited=0
            while [ "$waited" -lt "$BUFFER_POLL_INTERVAL" ]; do
                update_display_state
                sleep 1
                waited=$((waited + 1))
            done
        fi
    done
}

# ---------------------------------------------------------------------------
# 16b. Pregeneration worker — builds every image base and every live
#      head/tail clip up front, in the background, with N jobs in parallel.
# ---------------------------------------------------------------------------
generate_running() {
    [ -f "$GEN_PID_FILE" ] || return 1
    local pid; pid=$(cat "$GEN_PID_FILE" 2>/dev/null)
    [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null
}

generate_worker() {
    require_cmd ffmpeg ffprobe
    local parallel="${1:-$DEFAULT_PARALLEL}"
    [[ "$parallel" =~ ^[0-9]+$ ]] && [ "$parallel" -ge 1 ] || parallel="$DEFAULT_PARALLEL"

    load_config
    recompute_cache_paths
    compute_encoding_config
    # generate must only populate the on-disk cache (BASE_DIR/CLIP_DIR). The
    # RAM cache dir is keyed per-UID, not per-session, so if we let
    # ensure_image_base/ensure_live_clips mirror our output into RAM_CACHE_DIR
    # here we'd be writing into the SAME tmpfs dir the active daemon is
    # playing from, and prune_ram_cache's mtime-based eviction would then
    # start deleting that live session's buffered clips out from under it.
    # Clearing RAM_CACHE_DIR makes cache_to_ram take its documented
    # disk-only fallback path for the lifetime of this worker, so generate
    # never touches RAM at all.
    RAM_CACHE_DIR=""
    log_info "Pregeneration worker starting (gpu=${GPU}, resolution=${TARGET_W}x${TARGET_H}, parallel=${parallel})."

    scan_sources
    local total=$(( ${#IMAGES[@]} + ${#LIVES[@]} ))
    local running=0 done_count=0 img vid

    for img in "${IMAGES[@]}"; do
        ( ensure_image_base "$img" ) &
        running=$((running+1))
        if [ "$running" -ge "$parallel" ]; then
            wait -n
            running=$((running-1))
            done_count=$((done_count+1))
            log_info "Pregeneration progress: ~${done_count}/${total} done."
        fi
    done
    for vid in "${LIVES[@]}"; do
        ( ensure_live_clips "$vid" ) &
        running=$((running+1))
        if [ "$running" -ge "$parallel" ]; then
            wait -n
            running=$((running-1))
            done_count=$((done_count+1))
            log_info "Pregeneration progress: ~${done_count}/${total} done."
        fi
    done
    wait

    log_info "Pregeneration worker finished: ${#IMAGES[@]} image base(s), ${#LIVES[@]} live wallpaper clip pair(s) targeted (parallel=${parallel})."
    rm -f "$GEN_PID_FILE"
}

# ---------------------------------------------------------------------------
# 16c. Cleanup worker — removes cached bases/clips/transitions belonging to
#      images/videos that no longer exist in PIC_DIR/LIVE_DIR (deleted,
#      renamed, or moved away). Shares GEN_PID_FILE with generate_worker so
#      the two can't stomp on each other by running at the same time.
# ---------------------------------------------------------------------------
clean_worker() {
    load_config
    recompute_cache_paths
    log_info "Cleanup worker starting: sweeping pregenerated files for deleted images/videos."

    scan_sources

    local -A valid_img_hash valid_live_hash
    local img vid h
    for img in "${IMAGES[@]}"; do
        h=$(hash_content "$img")
        valid_img_hash["$h"]=1
    done
    for vid in "${LIVES[@]}"; do
        h=$(hash_identity "$vid")
        valid_live_hash["$h"]=1
    done

    local removed=0 f base h_match

    # Orphaned image base clips
    for f in "$BASE_DIR"/img_*_base.mp4; do
        [ -e "$f" ] || continue
        base=$(basename "$f")
        if [[ "$base" =~ ^img_([0-9a-f]+)_base\.mp4$ ]]; then
            h_match="${BASH_REMATCH[1]}"
            if [ -z "${valid_img_hash[$h_match]:-}" ]; then
                rm -f "$f"
                removed=$((removed+1))
                log_info "Removed orphaned base clip: $base"
            fi
        fi
    done

    # Orphaned live head/tail clips
    for f in "$CLIP_DIR"/live_*_head.mp4 "$CLIP_DIR"/live_*_tail.mp4; do
        [ -e "$f" ] || continue
        base=$(basename "$f")
        if [[ "$base" =~ ^live_([0-9a-f]+)_(head|tail)\.mp4$ ]]; then
            h_match="${BASH_REMATCH[1]}"
            if [ -z "${valid_live_hash[$h_match]:-}" ]; then
                rm -f "$f"
                removed=$((removed+1))
                log_info "Removed orphaned live clip: $base"
            fi
        fi
    done

    # Stale transitions (any transition referencing a hash that's no longer
    # valid on either side, image or live).
    for f in "$TRANS_DIR"/*_transition.mp4; do
        [ -e "$f" ] || continue
        base=$(basename "$f")
        local scan="$base" stale=0 kind hh
        while [[ "$scan" =~ (img|live)_([0-9a-f]+) ]]; do
            kind="${BASH_REMATCH[1]}"
            hh="${BASH_REMATCH[2]}"
            if [ "$kind" = "img" ]; then
                [ -n "${valid_img_hash[$hh]:-}" ] || stale=1
            else
                [ -n "${valid_live_hash[$hh]:-}" ] || stale=1
            fi
            scan="${scan/${BASH_REMATCH[0]}/}"
        done
        if [ "$stale" -eq 1 ]; then
            rm -f "$f"
            removed=$((removed+1))
            log_info "Removed stale transition: $base"
        fi
    done

    log_info "Cleanup worker finished: removed ${removed} orphaned/stale pregenerated file(s)."
    rm -f "$GEN_PID_FILE"
}

start_generate() {
    local gpu="${1:-0}" nogpu="${2:-0}" parallel="${3:-$DEFAULT_PARALLEL}" clean="${4:-0}"
    [[ "$parallel" =~ ^[0-9]+$ ]] && [ "$parallel" -ge 1 ] || parallel="$DEFAULT_PARALLEL"
    if generate_running; then
        echo "Pregeneration/cleanup already running (pid $(cat "$GEN_PID_FILE")). Tail $LOG_FILE for progress."
        return 1
    fi
    if [ "$clean" = "1" ]; then
        load_config
        recompute_cache_paths
        setsid "$SCRIPT_PATH" --clean-worker >> "$LOG_FILE" 2>&1 &
        local pid=$!
        echo "$pid" > "$GEN_PID_FILE"
        disown
        echo "Cleanup started in background (pid $pid). Tail $LOG_FILE for progress."
        return 0
    fi
    apply_gpu_flags "$gpu" "$nogpu"
    load_config
    recompute_cache_paths
    setsid "$SCRIPT_PATH" --generate-worker "$parallel" >> "$LOG_FILE" 2>&1 &
    local pid=$!
    echo "$pid" > "$GEN_PID_FILE"
    disown
    echo "Pregeneration started in background (pid $pid, gpu=$([ "$GPU" = "1" ] && echo on || echo off), resolution=${TARGET_W}x${TARGET_H}, parallel=${parallel}). Tail $LOG_FILE for progress."
}

# ---------------------------------------------------------------------------
# 17. CLI dispatch
# ---------------------------------------------------------------------------
case "${1:-}" in
    --worker)
        run_worker
        ;;
    --generate-worker)
        generate_worker "${2:-$DEFAULT_PARALLEL}"
        ;;
    --clean-worker)
        clean_worker
        ;;
    start)
        shift
        extract_flags "$@"
        start_daemon "${interval_arg:-$INTERVAL}" "$gpu_flag" "$nogpu_flag"
        ;;
    stop)
        stop_daemon
        ;;
    restart)
        shift
        extract_flags "$@"
        restart_daemon "${interval_arg:-$INTERVAL}" "$gpu_flag" "$nogpu_flag"
        ;;
    status)
        status_daemon
        ;;
    log)
        tail -f "$LOG_FILE"
        ;;
    live-log)
        tail -f "$LIVE_LOG_FILE"
        ;;
    change)
        shift
        interval_arg="${1:-}"
        if [ -z "$interval_arg" ]; then
            echo "Missing duration for change."
            usage
            exit 1
        fi
        change_interval "$interval_arg"
        ;;
    set-live-every)
        shift
        set_live_every "${1:-}"
        ;;
    set-pic-dir)
        shift
        set_pic_dir "${1:-}"
        ;;
    set-live-dir)
        shift
        set_live_dir "${1:-}"
        ;;
    generate)
        shift
        extract_flags "$@"
        start_generate "$gpu_flag" "$nogpu_flag" "${parallel_arg:-$DEFAULT_PARALLEL}" "$clean_flag"
        ;;
    install)
        install_dependencies
        ;;
    -c|--change|--change=*)
        shift
        extract_flags "$0" "$@"
        start_daemon "${interval_arg:-$INTERVAL}" "$gpu_flag" "$nogpu_flag"
        ;;
    help|-h|--help|"")
        usage
        ;;
    *)
        usage
        exit 1
        ;;
esac