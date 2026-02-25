#!/bin/bash
#
# reset_audio.sh - Audio troubleshooting script
# Author: Paul Asadoorian (paul@psw.io)
#
# Rescans USB, reloads ALSA, clears audio config, and restarts audio services.
# Automatically detects whether PulseAudio or PipeWire is in use.

set -e

usage() {
    cat <<EOF
Usage: $(basename "$0") [OPTIONS]

Reset and troubleshoot audio on Manjaro/Arch Linux.
Automatically detects PulseAudio vs PipeWire.

Options:
    -y, --yes            Skip confirmation prompts
    -v, --verbose        Show detailed output
    -s, --status-only    Only show audio status, don't reset anything
    -h, --help           Show this help message

Examples:
    $(basename "$0")              # Interactive reset with prompts
    $(basename "$0") -y           # Reset without prompts
    $(basename "$0") --status-only  # Just check audio status
EOF
}

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"
}

log_section() {
    echo ""
    echo "**********************************************************"
    echo "$*"
    echo "**********************************************************"
}

# Parse arguments
SKIP_CONFIRM=false
VERBOSE=false
STATUS_ONLY=false

while [[ $# -gt 0 ]]; do
    case "$1" in
        -y|--yes)
            SKIP_CONFIRM=true
            shift
            ;;
        -v|--verbose)
            VERBOSE=true
            shift
            ;;
        -s|--status-only)
            STATUS_ONLY=true
            shift
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            echo "Unknown option: $1" >&2
            usage >&2
            exit 1
            ;;
    esac
done

# Detect audio system
detect_audio_system() {
    if systemctl --user is-active --quiet pipewire 2>/dev/null; then
        echo "pipewire"
    elif systemctl --user is-active --quiet pulseaudio 2>/dev/null; then
        echo "pulseaudio"
    elif pgrep -x pipewire >/dev/null 2>&1; then
        echo "pipewire"
    elif pgrep -x pulseaudio >/dev/null 2>&1; then
        echo "pulseaudio"
    else
        echo "unknown"
    fi
}

confirm() {
    if [[ "$SKIP_CONFIRM" == true ]]; then
        return 0
    fi
    local prompt="$1"
    read -r -p "$prompt [y/N] " response
    case "$response" in
        [yY][eE][sS]|[yY]) return 0 ;;
        *) return 1 ;;
    esac
}

# Show audio status
show_status() {
    log_section "USB Audio Devices"
    # Fixed regex - properly quote the pattern
    lsusb 2>/dev/null | grep -i audio || echo "No USB audio devices found"

    if [[ "$VERBOSE" == true ]]; then
        log_section "Detailed USB Info"
        sudo lsusb -v 2>/dev/null | grep -E '^Bus|Audio' || true
    fi

    log_section "ALSA Devices"
    aplay -l 2>/dev/null || echo "No ALSA playback devices found"

    log_section "Audio System Detection"
    AUDIO_SYSTEM=$(detect_audio_system)
    log "Detected audio system: $AUDIO_SYSTEM"
    inxi -Ax 2>/dev/null | grep -E 'PulseAudio|PipeWire' || true

    if [[ "$AUDIO_SYSTEM" == "pulseaudio" ]]; then
        log_section "PulseAudio Status"
        pactl info 2>/dev/null || echo "PulseAudio not responding"
        if [[ "$VERBOSE" == true ]]; then
            echo ""
            echo "--- Sinks ---"
            pactl list sinks short 2>/dev/null || true
            echo ""
            echo "--- Sources ---"
            pactl list sources short 2>/dev/null || true
        fi
    elif [[ "$AUDIO_SYSTEM" == "pipewire" ]]; then
        log_section "PipeWire Status"
        if command -v wpctl &>/dev/null; then
            wpctl status 2>/dev/null || echo "PipeWire not responding"
        else
            systemctl --user status pipewire --no-pager 2>/dev/null || true
        fi
    fi
}

# Reset PulseAudio
reset_pulseaudio() {
    log_section "Resetting PulseAudio"

    # Clear PulseAudio config if confirmed
    PULSE_CONFIG="$HOME/.config/pulse"
    if [[ -d "$PULSE_CONFIG" ]]; then
        if confirm "Delete PulseAudio config ($PULSE_CONFIG)?"; then
            log "Removing PulseAudio config..."
            rm -rf "$PULSE_CONFIG"
        else
            log "Skipping config removal"
        fi
    fi

    log "Restarting PulseAudio service..."
    # Use systemctl for clean restart (preferred over killall)
    systemctl --user restart pulseaudio.service 2>/dev/null || {
        # Fallback: manual restart if systemctl fails
        log "systemctl restart failed, trying manual restart..."
        pulseaudio --kill 2>/dev/null || true
        sleep 1
        pulseaudio --start 2>/dev/null || log "WARNING: Could not start PulseAudio"
    }

    # Alternative: using killall (legacy approach)
    #sudo killall pulseaudio
    #sleep 2
    #systemctl --user restart pulseaudio
}

# Reset PipeWire
reset_pipewire() {
    log_section "Resetting PipeWire"

    # Clear PipeWire config if confirmed
    PIPEWIRE_CONFIG="$HOME/.config/pipewire"
    if [[ -d "$PIPEWIRE_CONFIG" ]]; then
        if confirm "Delete PipeWire config ($PIPEWIRE_CONFIG)?"; then
            log "Removing PipeWire config..."
            rm -rf "$PIPEWIRE_CONFIG"
        else
            log "Skipping config removal"
        fi
    fi

    log "Restarting PipeWire services..."
    systemctl --user restart pipewire.service pipewire-pulse.service 2>/dev/null || {
        log "WARNING: Could not restart PipeWire services"
    }

    # Restart WirePlumber if present
    if systemctl --user is-enabled wireplumber.service &>/dev/null; then
        systemctl --user restart wireplumber.service 2>/dev/null || true
    fi

    # Alternative: manual restart (legacy approach)
    #sudo killall pipewire pipewire-media-session pipewire-pulse
    #systemctl --user start pipewire pipewire-pulse
    #sudo systemctl start pipewire pipewire-pulse
    #sleep 2
    #systemctl --user daemon-reload
}

# Main execution
log "Audio Reset Script Started"

# Always show status first
show_status

if [[ "$STATUS_ONLY" == true ]]; then
    log "Status-only mode, exiting"
    exit 0
fi

AUDIO_SYSTEM=$(detect_audio_system)

if ! confirm "Proceed with audio reset?"; then
    log "Aborted by user"
    exit 0
fi

log_section "Re-scanning USB Bus"
# Trigger USB rescan
for usb_host in /sys/bus/usb/devices/usb*/authorized; do
    if [[ -w "$usb_host" ]]; then
        echo 0 | sudo tee "$usb_host" >/dev/null 2>&1 || true
        sleep 0.5
        echo 1 | sudo tee "$usb_host" >/dev/null 2>&1 || true
    fi
done
log "USB bus rescanned"

# Original USB scan approach (less reliable):
#sudo lsusb -v 2> /dev/null | egrep '^Bus'

sleep 2

log_section "Reloading ALSA"
# Manjaro/Arch
sudo systemctl restart alsa-restore.service 2>/dev/null || {
    log "WARNING: Could not restart alsa-restore.service"
}
# Ubuntu alternative:
#sudo alsa force-reload

sleep 2

# Reset appropriate audio system
case "$AUDIO_SYSTEM" in
    pulseaudio)
        reset_pulseaudio
        ;;
    pipewire)
        reset_pipewire
        ;;
    *)
        log "WARNING: Could not detect audio system, attempting PulseAudio reset"
        reset_pulseaudio
        ;;
esac

sleep 2

log_section "Audio Reset Complete"
log "Showing final status..."
show_status

log "Done!"
