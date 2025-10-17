#!/bin/bash
#
# Start the heartbeat agent in a detached tmux session
#
# This script will start the heartbeat agent in a tmux session that persists
# even after you log out. The agent will keep running until explicitly stopped.
#

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SESSION_NAME="isp-monitor"

# Load configuration from .env file
if [ -f "$SCRIPT_DIR/.env" ]; then
    source "$SCRIPT_DIR/.env"
fi

# Configuration (can be overridden by .env)
HEARTBEAT_URL="${HEARTBEAT_URL:-}"
DEVICE_NAME="${HEARTBEAT_DEVICE:-dl-home}"
INTERVAL="${HEARTBEAT_INTERVAL:-60}"  # seconds

# Validate required configuration
if [ -z "$HEARTBEAT_URL" ]; then
    echo "Error: HEARTBEAT_URL not set. Please set it in .env file or environment variable."
    echo "Example: HEARTBEAT_URL=https://your-func.azurewebsites.net/api/ping"
    exit 1
fi

# Check if session already exists
if tmux has-session -t "$SESSION_NAME" 2>/dev/null; then
    echo "Session '$SESSION_NAME' already exists!"
    echo ""
    echo "Options:"
    echo "  1. Attach to existing session:  tmux attach -t $SESSION_NAME"
    echo "  2. Stop existing session:       tmux kill-session -t $SESSION_NAME"
    echo "  3. View logs:                   tmux capture-pane -pt $SESSION_NAME"
    exit 1
fi

# Start new tmux session with heartbeat agent
echo "Starting heartbeat agent in tmux session '$SESSION_NAME'..."
echo "  Device: $DEVICE_NAME"
echo "  URL: $HEARTBEAT_URL"
echo "  Interval: $INTERVAL seconds"
echo ""

tmux new-session -d -s "$SESSION_NAME" \
    "cd '$SCRIPT_DIR' && python3 heartbeat_agent.py --url '$HEARTBEAT_URL' --device '$DEVICE_NAME' --interval $INTERVAL --daemon --verbose"

if [ $? -eq 0 ]; then
    echo "✓ Heartbeat agent started successfully!"
    echo ""
    echo "Useful commands:"
    echo "  Attach to session:     tmux attach -t $SESSION_NAME"
    echo "  View output:           tmux capture-pane -pt $SESSION_NAME -S -50"
    echo "  Stop agent:            tmux kill-session -t $SESSION_NAME"
    echo "  List sessions:         tmux ls"
    echo ""
    echo "Detach from session:   Press Ctrl+B, then D"

    # Show initial output
    sleep 2
    echo "Recent output:"
    echo "---"
    tmux capture-pane -pt "$SESSION_NAME" -S -10
else
    echo "✗ Failed to start tmux session"
    exit 1
fi
