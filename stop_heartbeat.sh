#!/bin/bash
#
# Stop the heartbeat agent tmux session
#

SESSION_NAME="isp-monitor"

if tmux has-session -t "$SESSION_NAME" 2>/dev/null; then
    echo "Stopping heartbeat agent (session: $SESSION_NAME)..."

    # Show last few lines before stopping
    echo ""
    echo "Last 10 lines of output:"
    echo "---"
    tmux capture-pane -pt "$SESSION_NAME" -S -10
    echo "---"
    echo ""

    tmux kill-session -t "$SESSION_NAME"
    echo "✓ Heartbeat agent stopped"
else
    echo "No active heartbeat session found (session: $SESSION_NAME)"
    echo ""
    echo "Active tmux sessions:"
    tmux ls 2>/dev/null || echo "  (none)"
fi
