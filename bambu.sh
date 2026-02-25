#!/bin/bash
#
# bambu.sh - Launcher for Bambu Studio with Mesa/EGL workarounds
# Author: Paul Asadoorian (paul@psw.io)
#
# Environment workarounds are needed for graphics compatibility on some systems.

set -e

CACHE_DIR="$HOME/.cache/bambu-studio"

usage() {
    cat <<EOF
Usage: $(basename "$0") [OPTIONS]

Launch Bambu Studio with Mesa/EGL environment workarounds.

Options:
    -c, --clear-cache    Clear Bambu Studio cache before launching
    -d, --debug          Enable debug output (level 4)
    -v, --verbose        Show environment variables being set
    -h, --help           Show this help message

Examples:
    $(basename "$0")                 # Normal launch
    $(basename "$0") --clear-cache   # Clear cache and launch
    $(basename "$0") -c -d           # Clear cache and launch with debug
EOF
}

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"
}

# Parse arguments
CLEAR_CACHE=false
DEBUG_MODE=false
VERBOSE=false

while [[ $# -gt 0 ]]; do
    case "$1" in
        -c|--clear-cache)
            CLEAR_CACHE=true
            shift
            ;;
        -d|--debug)
            DEBUG_MODE=true
            shift
            ;;
        -v|--verbose)
            VERBOSE=true
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

# Check if bambu-studio is installed
if ! command -v bambu-studio &>/dev/null; then
    log "ERROR: bambu-studio is not installed or not in PATH"
    exit 1
fi

# Set environment variables for Mesa/EGL compatibility
# Alternative options that may help with graphics issues (uncomment as needed):
#export WEBKIT_DISABLE_DMABUF_RENDERER=1
#export GALLIUM_DRIVER=zink
#export MESA_LOADER_DRIVER_OVERRIDE=zink
#export __GLX_VENDOR_LIBRARY_NAME=mesa
export __EGL_VENDOR_LIBRARY_FILENAMES=/usr/share/glvnd/egl_vendor.d/50_mesa.json
export GTK_THEME=Adwaita:light

if [[ "$VERBOSE" == true ]]; then
    log "Environment variables set:"
    log "  __EGL_VENDOR_LIBRARY_FILENAMES=$__EGL_VENDOR_LIBRARY_FILENAMES"
    log "  GTK_THEME=$GTK_THEME"
fi

# Clear cache if requested
if [[ "$CLEAR_CACHE" == true ]]; then
    if [[ -d "$CACHE_DIR" ]]; then
        log "Clearing Bambu Studio cache: $CACHE_DIR"
        rm -rf "$CACHE_DIR"
    else
        log "Cache directory does not exist, skipping: $CACHE_DIR"
    fi
fi

# Launch Bambu Studio
# Alternative launch commands for troubleshooting (uncomment as needed):
#__EGL_VENDOR_LIBRARY_FILENAMES=/usr/share/glvnd/egl_vendor.d/50_mesa.json WEBKIT_DISABLE_DMABUF_RENDERER=1 WEBKIT_FORCE_COMPOSITING_MODE=1 WEBKIT_DISABLE_COMPOSITING_MODE=1 bambu-studio
#__EGL_VENDOR_LIBRARY_FILENAMES=/usr/share/glvnd/egl_vendor.d/50_mesa.json WEBKIT_DISABLE_DMABUF_RENDERER=1 WEBKIT_FORCE_COMPOSITING_MODE=1 WEBKIT_DISABLE_COMPOSITING_MODE=1 GTK_THEME=Adwaita:light bambu-studio
#__EGL_VENDOR_LIBRARY_FILENAMES=/usr/share/glvnd/egl_vendor.d/50_mesa.json WEBKIT_DISABLE_DMABUF_RENDERER=1 WEBKIT_FORCE_COMPOSITING_MODE=1 WEBKIT_DISABLE_COMPOSITING_MODE=1 GTK_THEME=Adwaita:light bambu-studio --debug 4

if [[ "$DEBUG_MODE" == true ]]; then
    log "Launching Bambu Studio with debug level 4..."
    exec bambu-studio --debug 4
else
    log "Launching Bambu Studio..."
    exec bambu-studio
fi
