#!/bin/bash
# The Spire — Steam Deck Auto-Updater Launcher
# Add this as the non-Steam game entry point instead of TheSpire.x86_64

GAME_DIR="$(cd "$(dirname "$0")" && pwd)"
GAME_BIN="TheSpire.x86_64"
VERSION_FILE="$GAME_DIR/.version"
REPO="claude-mb/thespire"
BRANCH="main"
API_URL="https://api.github.com/repos/$REPO/commits/$BRANCH"
ZIP_URL="https://github.com/$REPO/archive/refs/heads/$BRANCH.zip"
TMP_DIR="/tmp/thespire-update"

cd "$GAME_DIR" || exit 1

# ── Self-update: apply staged launcher from previous run ──
if [ -f ".update_launch.sh" ]; then
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

# ── Check remote version (timeout 5s, fail silently) ──
REMOTE_SHA=""
API_RESPONSE="$(curl -sf --max-time 5 "$API_URL" 2>/dev/null)"
if [ $? -eq 0 ] && [ -n "$API_RESPONSE" ]; then
    # Extract SHA without jq — look for "sha": "..." at the top level
    REMOTE_SHA="$(echo "$API_RESPONSE" | sed -n 's/^  "sha": "\([a-f0-9]\{40\}\)".*/\1/p' | head -n1)"
fi

# ── Compare versions ──
NEED_UPDATE=false
if [ -z "$REMOTE_SHA" ]; then
    # Offline or API error — skip silently
    :
elif [ -z "$LOCAL_SHA" ]; then
    NEED_UPDATE=true
elif [ "$LOCAL_SHA" != "$REMOTE_SHA" ]; then
    NEED_UPDATE=true
fi

# ── Prompt and update ──
if [ "$NEED_UPDATE" = true ]; then
    SHORT_LOCAL="${LOCAL_SHA:0:7}"
    SHORT_REMOTE="${REMOTE_SHA:0:7}"

    if [ -z "$LOCAL_SHA" ]; then
        MSG="A game update is available.\n\nLatest: $SHORT_REMOTE\n\nUpdate now?"
    else
        MSG="A game update is available.\n\nInstalled: $SHORT_LOCAL\nLatest: $SHORT_REMOTE\n\nUpdate now?"
    fi

    zenity --question \
        --title="The Spire — Update Available" \
        --text="$MSG" \
        --ok-label="Update" \
        --cancel-label="Play Current" \
        --width=360 2>/dev/null

    if [ $? -eq 0 ]; then
        # ── Download ──
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

        # Pulsating progress bar while downloading
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
            zenity --error \
                --title="The Spire — Update Failed" \
                --text="Download failed. Launching current version." \
                --width=300 2>/dev/null
        else
            # ── Extract ──
            (
                cd "$TMP_DIR" || exit 1
                unzip -qo update.zip 2>/dev/null

                # GitHub ZIPs extract into a repo-branch/ subfolder
                EXTRACT_DIR="$(find . -maxdepth 1 -type d -name 'thespire-*' | head -n1)"
                if [ -z "$EXTRACT_DIR" ]; then
                    echo "error" > .extract_status
                    exit 1
                fi

                # Copy new files over game directory (preserve launch.sh handling)
                NEW_LAUNCHER="$EXTRACT_DIR/launch.sh"
                if [ -f "$NEW_LAUNCHER" ]; then
                    # Stage new launcher for next run (can't overwrite running script)
                    cp -f "$NEW_LAUNCHER" "$GAME_DIR/.update_launch.sh"
                    chmod +x "$GAME_DIR/.update_launch.sh"
                    rm -f "$NEW_LAUNCHER"
                fi

                # Sync everything else
                rsync -a --exclude='launch.sh' --exclude='.version' "$EXTRACT_DIR/" "$GAME_DIR/" 2>/dev/null
                if [ $? -ne 0 ]; then
                    # Fallback if rsync not available
                    cp -rf "$EXTRACT_DIR/"* "$GAME_DIR/" 2>/dev/null
                fi

                # Make game binary executable
                chmod +x "$GAME_DIR/$GAME_BIN" 2>/dev/null

                echo "done" > .extract_status
            )

            EXTRACT_STATUS="$(cat "$TMP_DIR/.extract_status" 2>/dev/null)"

            if [ "$EXTRACT_STATUS" = "done" ]; then
                # Write new version
                echo "$REMOTE_SHA" > "$VERSION_FILE"

                zenity --info \
                    --title="The Spire — Updated" \
                    --text="Update complete! Launching game." \
                    --timeout=2 \
                    --width=280 2>/dev/null
            else
                zenity --error \
                    --title="The Spire — Update Failed" \
                    --text="Extraction failed. Launching current version." \
                    --width=300 2>/dev/null
            fi
        fi

        rm -rf "$TMP_DIR"
    fi
fi

# ── Launch game ──
exec "./$GAME_BIN" "$@"
