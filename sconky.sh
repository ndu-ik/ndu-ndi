#!/bin/bash
#distro=debian
#
# wallpaper_contrast.sh
#
# Watches ~/.local/run/fluidwall.current_img for changes.
#   - If it points to an image: sets it as wallpaper via feh --bg-scale
#   - If it points to a video: leaves wallpaper alone (assumed handled elsewhere)
#   - In both cases: samples average brightness of the image / a video frame,
#     and writes a shade of white/gray/black that contrasts with that
#     brightness to a state file that conky's lua hook reads. No .conkyrc
#     editing and no conky restart -- picked up on conky's next update cycle.
#
# Requires: inotify-tools, feh, imagemagick (convert/identify), ffmpeg (for video frames)
#
# Transition modes for the conky text color (mutually exclusive; random wins
# if both are set > 0):
#   --set-smooth N   (0-100, 0=off) Fade from the current color to the new
#                     one over a few steps instead of jumping instantly.
#                     N controls fade speed on the same scale as ctest.sh's
#                     -t option (1=fast, 100=slow).
#   --set-random N   (0-100, 0=off) Randomly shuffle grayscale colors for
#                     ~0.5s, then settle on the real target color. N controls
#                     how many flickers happen in that window.
#   --show-smooth / --show-random   print the current values.

set -u

WATCH_FILE="$HOME/.local/run/fluidwall.current_img"
STATE_DIR="$HOME/.local/run"
COLOR_STATE_FILE="$STATE_DIR/conky_color.txt"
TMP_FRAME="/tmp/.wallpaper_contrast_frame.png"

CONFIG_DIR="$HOME/.config/wallpaper_contrast"
SKEW_FILE="$CONFIG_DIR/skew.conf"
DEFAULT_SKEW=70   # 0 = linear (no skew), 100 = full polar skew (original behavior)
SKEW=$DEFAULT_SKEW

# --- Smooth transition mode ---
# When enabled (value > 0), instead of jumping straight to the new contrast
# color, sconky fades from the currently-displayed color to the new one in
# a series of steps. Value (1-100) controls the speed per step, same
# scale as ctest.sh's -t speed factor (1=fast/0.01s, 100=slow/1.0s per step).
SMOOTH_FILE="$CONFIG_DIR/smooth.conf"
DEFAULT_SMOOTH=0   # 0 = off (instant color change)
SMOOTH=$DEFAULT_SMOOTH
SMOOTH_STEPS=15     # number of interpolation steps used for a fade

# --- Random flicker mode ---
# When enabled (value > 0), instead of jumping straight to the new contrast
# color, sconky randomly shuffles between grayscale colors for ~0.5s and
# then settles on the actual target color. Value (1-100) controls how many
# random flickers happen in that window (higher = more/faster flickers).
RANDOM_FILE="$CONFIG_DIR/random.conf"
DEFAULT_RANDOMNESS=0   # 0 = off (instant color change)
RAND_VAL=$DEFAULT_RANDOMNESS
RANDOM_DURATION=0.5

LOG_DIR="$HOME/.log"
LOG_FILE="$LOG_DIR/srwbg.log"

IMG_EXTS="jpg|jpeg|png|bmp|webp|gif|tiff"
VID_EXTS="mp4|mkv|webm|mov|avi|m4v"

log() {
    local ts msg
    ts=$(date '+%Y-%m-%d %H:%M:%S')
    msg="[$ts] [wallpaper_contrast] $*"
    echo "$msg" >&2
    mkdir -p "$LOG_DIR" 2>/dev/null
    echo "$msg" >> "$LOG_FILE" 2>/dev/null
}

show_help() {
    cat << 'EOF'
sconky.sh - Dynamic wallpaper contrast-based Conky color updater

USAGE:
    sconky.sh [OPTIONS]

DESCRIPTION:
    Watches ~/.local/run/fluidwall.current_img for changes. When a new wallpaper
    (image or video) is set, it samples the average brightness and calculates a
    contrasting grayscale color for Conky text. The color is written to a state
    file that Conky's Lua hook reads, updating without restarting Conky.

    - Images: Sets wallpaper via feh --bg-scale and samples brightness
    - Videos: Leaves wallpaper alone (assumed handled elsewhere), samples
              brightness from a video frame

OPTIONS:
    --set-skew <0-100>      Set the contrast skew (0=linear inversion,
                            100=hard black/white step). Default: 70
    --show-skew             Display the current skew value
    --set-smooth <0-100>    Enable smooth fading between color changes.
                            0=off/instant, 1=fast fade, 100=slow fade.
                            Default: 0 (off)
    --show-smooth           Display the current smooth speed value
    --set-random <0-100>    Enable random flicker before settling on target color.
                            0=off/instant, 1=few flickers, 100=rapid flickers.
                            Default: 0 (off)
    --show-random           Display the current random flicker value
    --foreground, -f        Run in foreground mode (output goes to terminal
                            and log file). Useful for debugging.
    --help, -h              Display this help message

FILES:
    ~/.local/run/fluidwall.current_img   Watched file containing wallpaper path
    ~/.local/run/conky_color.txt         State file written for Conky
    ~/.config/wallpaper_contrast/skew.conf    Skew configuration
    ~/.config/wallpaper_contrast/smooth.conf  Smooth transition config
    ~/.config/wallpaper_contrast/random.conf  Random flicker config
    ~/.log/srwbg.log                     Log file

REQUIREMENTS:
    inotify-tools, feh, ImageMagick (convert/identify), ffmpeg

EXAMPLES:
    sconky.sh                 Run as a daemon (default)
    sconky.sh --foreground    Run in foreground for debugging
    sconky.sh --set-skew 50   Set contrast skew to 50
    sconky.sh --set-smooth 50 Enable smooth fading with medium speed
    sconky.sh --set-random 50 Enable random flicker with moderate flickering
    sconky.sh --show-skew --show-smooth --show-random

NOTES:
    Smooth and random modes are mutually exclusive; random wins if both are enabled.
    The script auto-detaches to the background when run without --foreground.
EOF
}

# Clamp an integer to the 0-100 range
clamp_skew() {
    local v="$1"
    (( v < 0 ))   && v=0
    (( v > 100 )) && v=100
    echo "$v"
}

# Load skew value (0-100) from config file, falling back to DEFAULT_SKEW.
load_skew() {
    if [[ -f "$SKEW_FILE" ]]; then
        local raw
        raw=$(tr -dc '0-9\-' < "$SKEW_FILE" | head -n1)
        if [[ "$raw" =~ ^-?[0-9]+$ ]]; then
            SKEW=$(clamp_skew "$raw")
            return
        fi
        log "config file '$SKEW_FILE' had invalid content, using default ($DEFAULT_SKEW)"
    fi
    SKEW=$DEFAULT_SKEW
}

# Write a new skew value (0-100) to the config file
set_skew() {
    local val="$1"
    if [[ ! "$val" =~ ^-?[0-9]+$ ]]; then
        echo "skew value must be an integer 0-100, got: '$val'" >&2
        exit 1
    fi
    val=$(clamp_skew "$val")
    mkdir -p "$CONFIG_DIR"
    echo "$val" > "$SKEW_FILE"
    echo "skew set to $val (0=linear, 100=full polar skew) in $SKEW_FILE"
}

# Clamp an integer to the 0-100 range (shared helper, same rule as skew)
clamp_0_100() {
    local v="$1"
    (( v < 0 ))   && v=0
    (( v > 100 )) && v=100
    echo "$v"
}

# Load smooth-transition speed (0-100) from config file, falling back to DEFAULT_SMOOTH.
load_smooth() {
    if [[ -f "$SMOOTH_FILE" ]]; then
        local raw
        raw=$(tr -dc '0-9\-' < "$SMOOTH_FILE" | head -n1)
        if [[ "$raw" =~ ^-?[0-9]+$ ]]; then
            SMOOTH=$(clamp_0_100 "$raw")
            return
        fi
        log "config file '$SMOOTH_FILE' had invalid content, using default ($DEFAULT_SMOOTH)"
    fi
    SMOOTH=$DEFAULT_SMOOTH
}

# Write a new smooth speed value (0-100) to the config file. 0 disables smoothing.
set_smooth() {
    local val="$1"
    if [[ ! "$val" =~ ^-?[0-9]+$ ]]; then
        echo "smooth value must be an integer 0-100, got: '$val'" >&2
        exit 1
    fi
    val=$(clamp_0_100 "$val")
    mkdir -p "$CONFIG_DIR"
    echo "$val" > "$SMOOTH_FILE"
    echo "smooth set to $val (0=off/instant, 1=fast fade, 100=slow fade) in $SMOOTH_FILE"
}

# Load randomness (0-100) from config file, falling back to DEFAULT_RANDOMNESS.
load_randomness() {
    if [[ -f "$RANDOM_FILE" ]]; then
        local raw
        raw=$(tr -dc '0-9\-' < "$RANDOM_FILE" | head -n1)
        if [[ "$raw" =~ ^-?[0-9]+$ ]]; then
            RAND_VAL=$(clamp_0_100 "$raw")
            return
        fi
        log "config file '$RANDOM_FILE' had invalid content, using default ($DEFAULT_RANDOMNESS)"
    fi
    RAND_VAL=$DEFAULT_RANDOMNESS
}

# Write a new randomness value (0-100) to the config file. 0 disables flicker.
set_randomness() {
    local val="$1"
    if [[ ! "$val" =~ ^-?[0-9]+$ ]]; then
        echo "random value must be an integer 0-100, got: '$val'" >&2
        exit 1
    fi
    val=$(clamp_0_100 "$val")
    mkdir -p "$CONFIG_DIR"
    echo "$val" > "$RANDOM_FILE"
    echo "randomness set to $val (0=off/instant, 1=few flickers, 100=rapid flickers) in $RANDOM_FILE"
}

# Return 0 if path has an image extension
is_image() {
    [[ "$1" =~ \.(${IMG_EXTS})$ ]]
}

# Return 0 if path has a video extension
is_video() {
    [[ "$1" =~ \.(${VID_EXTS})$ ]]
}

# Get average brightness (0-255) of an image file using ImageMagick
get_image_brightness() {
    local path="$1"
    # Resize down for speed, convert to grayscale, get mean brightness (0-1 scale from `convert -format "%[fx:mean]"`)
    local mean
    mean=$(convert "$path" -resize 64x64 -colorspace Gray -format "%[fx:mean]" info: 2>/dev/null)
    if [[ -z "$mean" ]]; then
        echo ""
        return 1
    fi
    # mean is 0.0 - 1.0, scale to 0-255
    awk -v m="$mean" 'BEGIN { printf "%d", m * 255 }'
}

# Grab a frame from a video (a few seconds in, to skip black intros) and get its brightness
get_video_brightness() {
    local path="$1"
    rm -f "$TMP_FRAME"
    # Try grabbing frame at 2s in; fall back to 0s if video is shorter
    ffmpeg -y -ss 2 -i "$path" -frames:v 1 -q:v 4 "$TMP_FRAME" -loglevel error 2>/dev/null
    if [[ ! -s "$TMP_FRAME" ]]; then
        ffmpeg -y -ss 0 -i "$path" -frames:v 1 -q:v 4 "$TMP_FRAME" -loglevel error 2>/dev/null
    fi
    if [[ ! -s "$TMP_FRAME" ]]; then
        echo ""
        return 1
    fi
    get_image_brightness "$TMP_FRAME"
}

# Map a background brightness (0-255) to a contrasting text color on a
# white -> gray -> black gradient.
#
# SKEW (0-100, from config) acts as an inverse temperature for a logistic
# sigmoid centered at the midpoint brightness:
#   - skew = 0   -> sigmoid steepness is 0, which collapses to a pure
#                   linear inversion (text = 255 - bg).
#   - skew = 100 -> hard step function: output is exactly #000000 or
#                   #ffffff, nothing in between.
#   - in between -> smoothly increasing steepness, i.e. a "softer" step
#                   that still passes through every gray value near the
#                   midpoint but saturates to the poles faster as skew rises.
brightness_to_contrast_hex() {
    local bg="$1"

    # Hard step at max skew: exactly black or white, no sigmoid needed.
    if (( SKEW >= 100 )); then
        if (( bg < 128 )); then
            printf "#ffffff"
        else
            printf "#000000"
        fi
        return
    fi

    local skew_frac
    skew_frac=$(awk -v s="$SKEW" 'BEGIN { printf "%.6f", s / 100 }')

    local text_val
    text_val=$(awk -v bg="$bg" -v skew="$skew_frac" '
        function sigmoid(x, k) { return 1.0 / (1.0 + exp(-k * x)) }
        BEGIN {
            norm = bg / 255.0
            y = 1.0 - norm            # linear inversion, 0..1 (skew=0 result)

            K_MAX = 40.0              # steepness at skew=1 -- large enough
                                       # to visually saturate to the poles
            k = skew * K_MAX

            if (k < 0.0001) {
                f = y
            } else {
                lo = sigmoid(0.0 - 0.5, k)
                hi = sigmoid(1.0 - 0.5, k)
                s  = sigmoid(y - 0.5, k)
                f = (s - lo) / (hi - lo)   # renormalize so f(0)=0, f(1)=1
            }

            val = f * 255.0
            if (val < 0)   val = 0
            if (val > 255) val = 255
            printf "%d", val
        }
    ')

    printf "#%02x%02x%02x" "$text_val" "$text_val" "$text_val"
}

# Map a speed factor (1-100) to a per-step interval in seconds (0.01s-1.0s),
# same logarithmic mapping used by ctest.sh's -t option so the "speed" scale
# feels consistent between the test script and the real daemon.
get_transition_interval() {
    local factor="$1"
    (( factor < 1 ))   && factor=1
    (( factor > 100 )) && factor=100
    awk -v f="$factor" 'BEGIN {
        interval = 0.01 * (1.047128^(f - 1))
        printf "%.3f", interval
    }'
}

# Raw, unconditional write of a color to the conky state file (no fading,
# no flicker -- just write it now).
update_conky_color() {
    local hex="$1"

    mkdir -p "$STATE_DIR"
    echo "${hex#\#}" > "$COLOR_STATE_FILE"

    log "wrote color ${hex#\#} to $COLOR_STATE_FILE (conky lua hook will pick it up, no restart needed)"
}

# Split a #rrggbb hex color into three decimal components (via a nameref-free
# approach: prints "r g b" separated by spaces).
hex_to_rgb() {
    local hex="${1#\#}"
    printf "%d %d %d" "0x${hex:0:2}" "0x${hex:2:2}" "0x${hex:4:2}"
}

# Smoothly fade the conky text color from $1 (old hex) to $2 (new hex) over
# SMOOTH_STEPS steps, with the per-step delay controlled by speed factor $3
# (1-100, same scale as ctest.sh). Writes each intermediate color to the
# state file as it goes, and finishes on the exact target color.
smooth_transition() {
    local old_hex="$1" new_hex="$2" factor="$3"
    local steps="$SMOOTH_STEPS"
    local interval
    interval=$(get_transition_interval "$factor")

    read -r or og ob <<< "$(hex_to_rgb "$old_hex")"
    read -r nr ng nb <<< "$(hex_to_rgb "$new_hex")"

    log "starting smooth transition ${old_hex} -> ${new_hex} over ${steps} steps (${interval}s/step)"

    local i
    for (( i=1; i<=steps; i++ )); do
        local r g b
        r=$(awk -v a="$or" -v b="$nr" -v i="$i" -v s="$steps" 'BEGIN { printf "%d", a + (b - a) * i / s }')
        g=$(awk -v a="$og" -v b="$ng" -v i="$i" -v s="$steps" 'BEGIN { printf "%d", a + (b - a) * i / s }')
        b=$(awk -v a="$ob" -v b="$nb" -v i="$i" -v s="$steps" 'BEGIN { printf "%d", a + (b - a) * i / s }')
        local step_hex
        step_hex=$(printf "#%02x%02x%02x" "$r" "$g" "$b")
        update_conky_color "$step_hex"
        sleep "$interval"
    done

    # Make sure we land exactly on the target (avoids rounding drift)
    update_conky_color "$new_hex"
}

# Randomly flicker between grayscale colors for RANDOM_DURATION seconds,
# then settle on the exact target color $1. Randomness factor $2 (1-100)
# controls how many flickers happen in that window.
random_flicker() {
    local target_hex="$1" factor="$2"
    local count
    count=$(awk -v f="$factor" 'BEGIN { c = 3 + (f * 20 / 100); printf "%d", c }')
    (( count < 1 )) && count=1
    local interval
    interval=$(awk -v d="$RANDOM_DURATION" -v c="$count" 'BEGIN { printf "%.3f", d / c }')

    log "starting random flicker toward ${target_hex}, ${count} flickers over ${RANDOM_DURATION}s (${interval}s each)"

    local i
    for (( i=0; i<count; i++ )); do
        local gray_val=$(( RANDOM % 256 ))
        local hex
        hex=$(printf "#%02x%02x%02x" "$gray_val" "$gray_val" "$gray_val")
        update_conky_color "$hex"
        sleep "$interval"
    done

    update_conky_color "$target_hex"
}

LAST_BRIGHTNESS=""
LAST_HEX=""

# Decide how to move the conky text color to $1 (target hex), based on the
# current random/smooth config, then update LAST_HEX for next time.
#   - RAND_VAL  > 0 -> random flicker for ~0.5s, then settle on target
#   - SMOOTH    > 0 -> fade from the last color to the target
#   - otherwise      -> instant jump (original behavior)
apply_color() {
    local target_hex="$1"

    if (( RAND_VAL > 0 )); then
        random_flicker "$target_hex" "$RAND_VAL"
    elif (( SMOOTH > 0 )) && [[ -n "$LAST_HEX" && "$LAST_HEX" != "$target_hex" ]]; then
        smooth_transition "$LAST_HEX" "$target_hex" "$SMOOTH"
    else
        update_conky_color "$target_hex"
    fi

    LAST_HEX="$target_hex"
}

process_path() {
    local path="$1"

    if [[ ! -f "$path" ]]; then
        log "path '$path' does not exist, skipping"
        return
    fi

    local brightness=""

    if is_image "$path"; then
        log "image detected: $path"
        feh --bg-scale "$path"
        brightness=$(get_image_brightness "$path")
    elif is_video "$path"; then
        log "video detected: $path (skipping feh, sampling frame for brightness)"
        brightness=$(get_video_brightness "$path")
    else
        log "unrecognized file type for '$path', skipping"
        return
    fi

    if [[ -z "$brightness" ]]; then
        log "could not determine brightness for '$path'"
        return
    fi

    log "brightness for '$path' = $brightness / 255"
    LAST_BRIGHTNESS="$brightness"

    local hex
    hex=$(brightness_to_contrast_hex "$brightness")
    apply_color "$hex"
}

# Recompute and rewrite the conky color for the last-seen brightness,
# without touching feh or re-sampling the wallpaper. Used when the skew
# config changes so the color updates immediately, not just on next media.
reapply_color() {
    if [[ -z "$LAST_BRIGHTNESS" ]]; then
        log "skew changed but no wallpaper processed yet, nothing to reapply"
        return
    fi
    local hex
    hex=$(brightness_to_contrast_hex "$LAST_BRIGHTNESS")
    log "reapplying color for cached brightness $LAST_BRIGHTNESS / 255 (skew=$SKEW)"
    apply_color "$hex"
}

main() {
    load_skew
    load_smooth
    load_randomness
    log "startup: logging to $LOG_FILE, skew=$SKEW, smooth=$SMOOTH, random=$RAND_VAL"

    if [[ ! -f "$WATCH_FILE" ]]; then
        log "watch file '$WATCH_FILE' does not exist yet; waiting for it to appear"
        # Wait for the parent dir to have the file created
        local watch_dir
        watch_dir=$(dirname "$WATCH_FILE")
        mkdir -p "$watch_dir"
    fi
    mkdir -p "$CONFIG_DIR"

    # Process whatever is currently in the file on startup
    if [[ -s "$WATCH_FILE" ]]; then
        process_path "$(cat "$WATCH_FILE")"
    fi

    log "watching $WATCH_FILE for changes, and $SKEW_FILE for live skew updates..."

    local watch_dir_img watch_dir_cfg
    watch_dir_img=$(dirname "$WATCH_FILE")
    watch_dir_cfg=$(dirname "$SKEW_FILE")

    # -e close_write handles the common case of a script writing+closing the file
    # -e create/moved_to handles the case where it's replaced via rename
    inotifywait -m -e close_write -e create -e moved_to \
        --format '%w%f' "$watch_dir_img" "$watch_dir_cfg" 2>/dev/null |
    while read -r changed_file; do
        if [[ "$changed_file" == "$SKEW_FILE" ]]; then
            local old_skew=$SKEW
            load_skew
            if [[ "$SKEW" != "$old_skew" ]]; then
                log "skew config changed: $old_skew -> $SKEW"
                reapply_color
            fi
            continue
        fi
        if [[ "$changed_file" == "$SMOOTH_FILE" ]]; then
            local old_smooth=$SMOOTH
            load_smooth
            [[ "$SMOOTH" != "$old_smooth" ]] && log "smooth config changed: $old_smooth -> $SMOOTH"
            continue
        fi
        if [[ "$changed_file" == "$RANDOM_FILE" ]]; then
            local old_rand=$RAND_VAL
            load_randomness
            [[ "$RAND_VAL" != "$old_rand" ]] && log "random config changed: $old_rand -> $RAND_VAL"
            continue
        fi
        [[ "$changed_file" == "$WATCH_FILE" ]] || continue
        local content
        content=$(cat "$WATCH_FILE" 2>/dev/null)
        [[ -z "$content" ]] && continue
        process_path "$content"
    done
}

case "${1:-}" in
    --help|-h)
        show_help
        exit 0
        ;;
    --set-skew)
        set_skew "${2:?usage: $0 --set-skew <0-100>}"
        exit 0
        ;;
    --show-skew)
        load_skew
        echo "$SKEW"
        exit 0
        ;;
    --set-smooth)
        set_smooth "${2:?usage: $0 --set-smooth <0-100> (0=off, 1=fast fade, 100=slow fade)}"
        exit 0
        ;;
    --show-smooth)
        load_smooth
        echo "$SMOOTH"
        exit 0
        ;;
    --set-random)
        set_randomness "${2:?usage: $0 --set-random <0-100> (0=off, 1=few flickers, 100=rapid flickers)}"
        exit 0
        ;;
    --show-random)
        load_randomness
        echo "$RAND_VAL"
        exit 0
        ;;
    --foreground|-f)
        # Explicit foreground/debug mode: run normally, logging still goes
        # to both the terminal and the log file.
        main
        exit 0
        ;;
esac

if [[ "${_SRWBG_DAEMONIZED:-}" != "1" ]]; then
    # Plain invocation from a terminal: re-exec detached in the background,
    # silent on the terminal, everything routed to the log file only.
    mkdir -p "$LOG_DIR"
    _SRWBG_DAEMONIZED=1 setsid "$0" --foreground >/dev/null 2>/dev/null < /dev/null &
    disown
    exit 0
fi

main "$@"
