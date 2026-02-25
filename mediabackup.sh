#!/bin/bash
#
# mediabackup.sh - Rsync-based backup script for media directory
# Author: Paul Asadoorian (paul@psw.io)
#
# Syncs media directory to two backup destinations (NAS and external drive).

set -e

# Variables - set these to your actual mount points/paths
SRC_DIR="$HOME/media"
BACKUP1="$HOME/terramaster"
BACKUP2="$HOME/WD20TB"
LOGFILE="$HOME/mediasync_errors.log"

# Rsync options
RSYNC_BASE_OPTS="-a --progress"

usage() {
    cat <<EOF
Usage: $(basename "$0") [OPTIONS]

Backup media directory to NAS and external drive using rsync.

Options:
    -n, --dry-run        Show what would be transferred without making changes
    -d, --delete         Delete files in destination that don't exist in source
    -1, --backup1-only   Only sync to first backup destination (NAS)
    -2, --backup2-only   Only sync to second backup destination (external)
    -v, --verbose        Show verbose rsync output
    -q, --quiet          Suppress progress output
    -h, --help           Show this help message

Destinations:
    Backup 1 (NAS):      $BACKUP1
    Backup 2 (External): $BACKUP2

Examples:
    $(basename "$0")              # Normal backup to both destinations
    $(basename "$0") --dry-run    # Preview what would be synced
    $(basename "$0") -d           # Sync and delete removed files
    $(basename "$0") -1           # Only backup to NAS
EOF
}

log() {
    local msg="[$(date '+%Y-%m-%d %H:%M:%S')] $*"
    echo "$msg"
    echo "$msg" >> "$LOGFILE"
}

log_error() {
    local msg="[$(date '+%Y-%m-%d %H:%M:%S')] ERROR: $*"
    echo "$msg" >&2
    echo "$msg" >> "$LOGFILE"
}

# Parse arguments
DRY_RUN=false
DELETE_MODE=false
BACKUP1_ONLY=false
BACKUP2_ONLY=false
VERBOSE=false
QUIET=false

while [[ $# -gt 0 ]]; do
    case "$1" in
        -n|--dry-run)
            DRY_RUN=true
            shift
            ;;
        -d|--delete)
            DELETE_MODE=true
            shift
            ;;
        -1|--backup1-only)
            BACKUP1_ONLY=true
            shift
            ;;
        -2|--backup2-only)
            BACKUP2_ONLY=true
            shift
            ;;
        -v|--verbose)
            VERBOSE=true
            shift
            ;;
        -q|--quiet)
            QUIET=true
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

# Validate mutually exclusive options
if [[ "$BACKUP1_ONLY" == true && "$BACKUP2_ONLY" == true ]]; then
    log_error "Cannot specify both --backup1-only and --backup2-only"
    exit 1
fi

if [[ "$VERBOSE" == true && "$QUIET" == true ]]; then
    log_error "Cannot specify both --verbose and --quiet"
    exit 1
fi

# Build rsync options
RSYNC_OPTS="$RSYNC_BASE_OPTS"

if [[ "$DRY_RUN" == true ]]; then
    RSYNC_OPTS="$RSYNC_OPTS --dry-run"
    log "DRY RUN MODE - No changes will be made"
fi

if [[ "$DELETE_MODE" == true ]]; then
    RSYNC_OPTS="$RSYNC_OPTS --delete"
    log "DELETE MODE - Files not in source will be removed from destination"
fi

if [[ "$VERBOSE" == true ]]; then
    RSYNC_OPTS="$RSYNC_OPTS -v"
fi

if [[ "$QUIET" == true ]]; then
    RSYNC_OPTS="${RSYNC_OPTS/--progress/}"
fi

# Check source directory
check_source() {
    if [[ ! -d "$SRC_DIR" ]]; then
        log_error "Source directory does not exist: $SRC_DIR"
        exit 1
    fi
    if [[ ! -r "$SRC_DIR" ]]; then
        log_error "Source directory is not readable: $SRC_DIR"
        exit 1
    fi
    log "Source directory OK: $SRC_DIR"
}

# Check if destination is accessible
check_destination() {
    local dest="$1"
    local name="$2"

    if [[ ! -d "$dest" ]]; then
        log_error "$name not accessible (not mounted or doesn't exist): $dest"
        return 1
    fi
    if [[ ! -w "$dest" ]]; then
        log_error "$name is not writable: $dest"
        return 1
    fi
    log "$name OK: $dest"
    return 0
}

# Perform sync to a destination
sync_to_dest() {
    local dest="$1"
    local name="$2"

    log "Syncing to $name ($dest)..."

    # Use eval to properly handle quoted options
    if rsync $RSYNC_OPTS "$SRC_DIR/" "$dest/" 2>> "$LOGFILE"; then
        log "SUCCESS: Sync to $name completed"
        return 0
    else
        local exit_code=$?
        log_error "FAILED: Sync to $name failed with exit code $exit_code"
        return $exit_code
    fi
}

# Initialize log
log "=========================================="
log "Media Backup Started"
log "=========================================="

# Check source
check_source

# Track results
BACKUP1_RESULT="skipped"
BACKUP2_RESULT="skipped"

# Sync to first backup if not backup2-only
if [[ "$BACKUP2_ONLY" != true ]]; then
    if check_destination "$BACKUP1" "Backup 1 (NAS)"; then
        if sync_to_dest "$BACKUP1" "Backup 1 (NAS)"; then
            BACKUP1_RESULT="success"
        else
            BACKUP1_RESULT="failed"
        fi
    else
        BACKUP1_RESULT="unavailable"
    fi
fi

# Sync to second backup if not backup1-only
if [[ "$BACKUP1_ONLY" != true ]]; then
    if check_destination "$BACKUP2" "Backup 2 (External)"; then
        if sync_to_dest "$BACKUP2" "Backup 2 (External)"; then
            BACKUP2_RESULT="success"
        else
            BACKUP2_RESULT="failed"
        fi
    else
        BACKUP2_RESULT="unavailable"
    fi
fi

# Summary
log "=========================================="
log "Backup Summary"
log "=========================================="
log "Backup 1 (NAS):      $BACKUP1_RESULT"
log "Backup 2 (External): $BACKUP2_RESULT"
log "Log file: $LOGFILE"

if [[ "$DRY_RUN" == true ]]; then
    log "NOTE: This was a dry run - no files were actually transferred"
fi

# Exit with error if any backup failed
if [[ "$BACKUP1_RESULT" == "failed" || "$BACKUP2_RESULT" == "failed" ]]; then
    log_error "One or more backups failed - check log for details"
    exit 1
fi

log "Backup complete!"
