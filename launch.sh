#!/bin/bash
# The Spire — Steam Deck Auto-Updater Launcher
# Add this as the non-Steam game entry point instead of TheSpire.x86_64

GAME_DIR="$(cd "$(dirname "$0")" && pwd)"
GAME_BIN="TheSpire.x86_64"
VERSION_FILE="$GAME_DIR/.version"
LOG_FILE="$GAME_DIR/.launcher.log"
REPO="claude-mb/thespire"
BRANCH="main"
API_URL="https://api.github.com/repos/$REPO/commits/$BRANCH"
ZIP_URL="https://github.com/$REPO/archive/refs/heads/$BRANCH.zip"
TMP_DIR="/tmp/thespire-update"

log() { echo "[$(date '+%H:%M:%S')] $*" >> "$LOG_FILE"; }

cd "$GAME_DIR" || exit 1
log "=== Launcher started ==="

# ── Self-update: apply staged launcher from previous run ──
if [ -f ".update_launch.sh" ]; then
    log "Applying staged launcher update"
    cp -f ".update_launch.sh" "launch.sh"
    chmod +x "launch.sh"
    rm -f ".update_launch.sh"
    exec "./launch.sh" "$@"
fi

# ── Read local version ──
LOCAL_SHA=""
if [ -f "$VERSION_FILE" ]; then
    LOCAL_SHA="$(tr -d '[:space:]' < "$VERSION_FILE")"
fi
log "Local SHA: ${LOCAL_SHA:-<none>}"

# ── Check remote version (timeout 5s, fail silently) ──
REMOTE_SHA=""
API_RESPONSE="$(curl -sf --max-time 5 "$API_URL" 2>/dev/null)"
if [ $? -eq 0 ] && [ -n "$API_RESPONSE" ]; then
    REMOTE_SHA="$(echo "$API_RESPONSE" | sed -n 's/^  "sha": "\([a-f0-9]\{40\}\)".*/\1/p' | head -n1)"
fi
log "Remote SHA: ${REMOTE_SHA:-<offline>}"

# ── Compare versions ──
NEED_UPDATE=false
if [ -z "$REMOTE_SHA" ]; then
    :
elif [ -z "$LOCAL_SHA" ]; then
    NEED_UPDATE=true
elif [ "$LOCAL_SHA" != "$REMOTE_SHA" ]; then
    NEED_UPDATE=true
fi

# ── Prompt and update ──
if [ "$NEED_UPDATE" = true ]; then
    log "Update available"
    SHORT_LOCAL="${LOCAL_SHA:0:7}"
    SHORT_REMOTE="${REMOTE_SHA:0:7}"

    if [ -z "$LOCAL_SHA" ]; then
        MSG="A game update is available.\n\nLatest: $SHORT_REMOTE\n\nUpdate now?"
    else
        MSG="A game update is available.\n\nInstalled: $SHORT_LOCAL\nLatest: $SHORT_REMOTE\n\nUpdate now?"
    fi

    # Timeout after 15s — default to launching current version
    zenity --question \
        --title="The Spire — Update Available" \
        --text="$MSG" \
        --ok-label="Update" \
        --cancel-label="Play Current" \
        --timeout=15 \
        --width=360 2>/dev/null
    DIALOG_RC=$?

    if [ "$DIALOG_RC" -eq 0 ]; then
        log "User chose Update"

        rm -rf "$TMP_DIR"
        mkdir -p "$TMP_DIR"

        (
            curl -fL --max-time 120 -o "$TMP_DIR/update.zip" "$ZIP_URL" 2>/dev/null
            if [ $? -ne 0 ]; then
                echo "error" > "$TMP_DIR/.status"
                exit 1
            fi
            echo "done" > "$TMP_DIR/.status"
        ) &
        CURL_PID=$!

        (
            while kill -0 "$CURL_PID" 2>/dev/null; do
                echo "#Downloading update..."
                sleep 1
            done
        ) | zenity --progress \
            --title="The Spire — Updating" \
            --text="Downloading update..." \
            --pulsate \
            --auto-close \
            --no-cancel \
            --width=320 2>/dev/null

        wait "$CURL_PID"
        DL_STATUS="$(cat "$TMP_DIR/.status" 2>/dev/null)"

        if [ "$DL_STATUS" != "done" ] || [ ! -f "$TMP_DIR/update.zip" ]; then
            log "Download failed"
            zenity --error \
                --title="The Spire — Update Failed" \
                --text="Download failed. Launching current version." \
                --timeout=5 \
                --width=300 2>/dev/null
        else
            log "Download complete, extracting"
            (
                cd "$TMP_DIR" || exit 1
                unzip -qo update.zip 2>/dev/null

                EXTRACT_DIR="$(find . -maxdepth 1 -type d -name 'thespire-*' | head -n1)"
                if [ -z "$EXTRACT_DIR" ]; then
                    echo "error" > .extract_status
                    exit 1
                fi

                NEW_LAUNCHER="$EXTRACT_DIR/launch.sh"
                if [ -f "$NEW_LAUNCHER" ]; then
                    cp -f "$NEW_LAUNCHER" "$GAME_DIR/.update_launch.sh"
                    chmod +x "$GAME_DIR/.update_launch.sh"
                    rm -f "$NEW_LAUNCHER"
                fi

                rsync -a --exclude='launch.sh' --exclude='.version' "$EXTRACT_DIR/" "$GAME_DIR/" 2>/dev/null
                if [ $? -ne 0 ]; then
                    cp -rf "$EXTRACT_DIR/"* "$GAME_DIR/" 2>/dev/null
                fi

                chmod +x "$GAME_DIR/$GAME_BIN" 2>/dev/null

                echo "done" > .extract_status
            )

            EXTRACT_STATUS="$(cat "$TMP_DIR/.extract_status" 2>/dev/null)"

            if [ "$EXTRACT_STATUS" = "done" ]; then
                echo "$REMOTE_SHA" > "$VERSION_FILE"
                log "Update applied: $REMOTE_SHA"
                zenity --info \
                    --title="The Spire — Updated" \
                    --text="Update complete! Launching game." \
                    --timeout=2 \
                    --width=280 2>/dev/null
            else
                log "Extraction failed"
                zenity --error \
                    --title="The Spire — Update Failed" \
                    --text="Extraction failed. Launching current version." \
                    --timeout=5 \
                    --width=300 2>/dev/null
            fi
        fi

        rm -rf "$TMP_DIR"
    else
        log "User chose Play Current (rc=$DIALOG_RC)"
    fi
else
    log "Up to date, launching"
fi

# ── Launch game ──
chmod +x "./$GAME_BIN" 2>/dev/null
log "Launching $GAME_BIN"
exec "./$GAME_BIN" "$@"

# exec failed if we reach here
log "ERROR: exec failed for $GAME_BIN"
zenity --error \
    --title="The Spire — Launch Failed" \
    --text="Could not launch $GAME_BIN.\nCheck file permissions." \
    --timeout=10 \
    --width=300 2>/dev/null
exit 1
