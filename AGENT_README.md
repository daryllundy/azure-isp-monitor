# Heartbeat Agent

Python agent that sends periodic pings to the Azure Function to monitor internet connectivity.

## Quick Start (macOS with tmux)

### 1. Start the Agent

```bash
chmod +x start_heartbeat.sh stop_heartbeat.sh heartbeat_agent.py
./start_heartbeat.sh
```

This starts the agent in a detached tmux session named `isp-monitor`.

### 2. Check Status

```bash
# View recent output
tmux capture-pane -pt isp-monitor -S -50

# Attach to the session (press Ctrl+B then D to detach)
tmux attach -t isp-monitor
```

### 3. Stop the Agent

```bash
./stop_heartbeat.sh
```

## Manual Usage

### Send a Single Ping

```bash
python3 heartbeat_agent.py \
  --url https://darylhome-func.azurewebsites.net/api/ping \
  --device dl-home \
  --once
```

### Run Continuously (foreground)

```bash
python3 heartbeat_agent.py \
  --url https://darylhome-func.azurewebsites.net/api/ping \
  --device dl-home \
  --interval 60 \
  --daemon \
  --verbose
```

### Using Environment Variables

```bash
export HEARTBEAT_URL="https://darylhome-func.azurewebsites.net/api/ping"
export HEARTBEAT_DEVICE="dl-home"

python3 heartbeat_agent.py --daemon
```

## Command Line Options

- `--url URL` - Function endpoint URL (required, or set `HEARTBEAT_URL`)
- `--device NAME` - Device identifier (default: hostname or `HEARTBEAT_DEVICE`)
- `--interval SECONDS` - Ping interval in seconds (default: 60)
- `--daemon` - Run continuously
- `--once` - Send single ping and exit
- `--verbose` - Show detailed output

## Tmux Commands

```bash
# List all sessions
tmux ls

# Attach to session
tmux attach -t isp-monitor

# View output without attaching
tmux capture-pane -pt isp-monitor -S -100

# Kill session
tmux kill-session -t isp-monitor

# Detach from session (when attached)
# Press: Ctrl+B, then D
```

## Running on Boot (macOS LaunchAgent)

Create `~/Library/LaunchAgents/com.user.isp-monitor.plist`:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>com.user.isp-monitor</string>
    <key>ProgramArguments</key>
    <array>
        <string>/usr/bin/python3</string>
        <string>/Users/daryl/work/azure-isp-monitor/heartbeat_agent.py</string>
        <string>--url</string>
        <string>https://darylhome-func.azurewebsites.net/api/ping</string>
        <string>--device</string>
        <string>dl-home</string>
        <string>--interval</string>
        <string>60</string>
        <string>--daemon</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <true/>
    <key>StandardOutPath</key>
    <string>/tmp/isp-monitor.log</string>
    <key>StandardErrorPath</key>
    <string>/tmp/isp-monitor.err</string>
</dict>
</plist>
```

Then load it:

```bash
launchctl load ~/Library/LaunchAgents/com.user.isp-monitor.plist
launchctl start com.user.isp-monitor

# Check status
launchctl list | grep isp-monitor

# View logs
tail -f /tmp/isp-monitor.log

# Stop
launchctl stop com.user.isp-monitor
launchctl unload ~/Library/LaunchAgents/com.user.isp-monitor.plist
```

## Troubleshooting

### Agent won't start
- Check Python 3 is installed: `python3 --version`
- Verify URL is reachable: `curl https://darylhome-func.azurewebsites.net/api/ping`

### Consecutive failures warning
- Check internet connection
- Verify function is running: `curl https://darylhome-func.azurewebsites.net/api/ping`
- Check for network firewall blocking outbound HTTPS

### tmux session not found
- List sessions: `tmux ls`
- Make sure tmux is installed: `brew install tmux`
