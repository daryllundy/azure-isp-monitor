# Azure ISP Monitor

A simple ISP/internet connectivity monitoring system using Azure Functions and Azure Monitor alerts. This system sends email alerts when your internet connection goes down by detecting missing heartbeat pings.

## Architecture

```
┌─────────────────┐         ┌──────────────────┐         ┌─────────────────┐
│  Your Device    │         │  Azure Function  │         │ Azure Monitor   │
│  (dl-home)      │  POST   │  /api/ping       │  Logs   │ Alert Rule      │
│                 │────────>│  (Python 3.11)   │────────>│ (5min window)   │
│  heartbeat_     │         │                  │         │                 │
│  agent.py       │         └──────────────────┘         └─────────────────┘
└─────────────────┘                  │                            │
                                     │                            │
                                     v                            v
                            ┌─────────────────┐         ┌─────────────────┐
                            │ App Insights    │         │ Action Group    │
                            │ (Logs/Metrics)  │         │ (Email Alert)   │
                            └─────────────────┘         └─────────────────┘
```

## Features

- ✅ **Serverless** - Runs on Azure Functions Consumption Plan (Linux Python 3.11)
- ✅ **Automatic Alerts** - Email notifications when no pings received for 5 minutes
- ✅ **Low Cost** - Free tier eligible for most usage patterns (~$2-10/month)
- ✅ **Simple Agent** - Lightweight Python script with zero external dependencies
- ✅ **Persistent Monitoring** - tmux-based agent runs in background, survives disconnects
- ✅ **Infrastructure as Code** - Everything deployed via Bicep templates
- ✅ **Easy Management** - Simple start/stop scripts with status monitoring

## Quick Start

### 1. Deploy Infrastructure

```bash
# Configure environment
cp .env.example .env
# Edit .env with your settings

# Deploy
./deploy.sh
```

This creates:
- Azure Function App (Python 3.11 on Linux)
- Application Insights for monitoring
- Storage Account for function data
- Action Group for email alerts
- Alert Rule to detect missing pings

### 2. Start Monitoring Agent

On the machine you want to monitor:

```bash
# Configure agent (same .env file)
# Set HEARTBEAT_URL, HEARTBEAT_DEVICE, HEARTBEAT_INTERVAL

# Make scripts executable
chmod +x heartbeat_agent.py start_heartbeat.sh stop_heartbeat.sh

# Start agent in detached tmux session
./start_heartbeat.sh

# Check agent status
tmux ls
tmux attach -t isp-monitor  # Attach to view logs (Ctrl+B then D to detach)

# Stop agent
./stop_heartbeat.sh

# Or run manually (foreground)
python3 heartbeat_agent.py \
  --url https://your-func.azurewebsites.net/api/ping \
  --device your-device-name \
  --interval 60 \
  --daemon \
  --verbose
```

See [AGENT_README.md](AGENT_README.md) for detailed agent documentation.

### 3. Test the System

```bash
# Send a test ping
curl https://your-func.azurewebsites.net/api/ping

# Stop the agent for 6+ minutes to trigger an alert
./stop_heartbeat.sh
```

## Project Structure

```
.
├── main.bicep              # Infrastructure as Code (Bicep)
├── deploy.sh               # Deployment script
├── .env                    # Environment configuration (gitignored)
├── .env.example            # Example configuration
│
├── Ping/                   # Azure Function
│   ├── __init__.py         # Function handler
│   └── function.json       # Function configuration
│
├── heartbeat_agent.py      # Monitoring agent (runs on your device)
├── start_heartbeat.sh      # Start agent in tmux
├── stop_heartbeat.sh       # Stop agent
│
├── host.json               # Function app configuration
├── requirements.txt        # Python dependencies
├── README.md               # This file
└── AGENT_README.md         # Agent documentation
```

## Configuration

### Environment Variables (.env)

```bash
# Resource Group Configuration
RG=your-project-rg
LOCATION=westus2

# Alert Configuration
ALERT_EMAIL=your-email@example.com

# Heartbeat Agent Configuration
HEARTBEAT_URL=https://your-func.azurewebsites.net/api/ping
HEARTBEAT_DEVICE=your-device-name
HEARTBEAT_INTERVAL=60
```

### Alert Settings (main.bicep)

- **Evaluation Frequency**: 5 minutes (line 88)
- **Window Size**: 5 minutes (line 89)
- **Query**: Looks for POST/GET requests to `/api/ping` (lines 93-97)
- **Threshold**: Alert if count < 1 (line 100)
- **Severity**: 2 - Warning (line 87)

## API Endpoint

### `POST /api/ping`

**Request:**
```bash
curl -X POST https://your-func.azurewebsites.net/api/ping \
  -H "Content-Type: application/json" \
  -d '{"device":"dl-home","note":"test ping"}'
```

**Response:**
```
ok
```

**Headers:**
- `X-Device`: Device identifier (optional)
- `X-Forwarded-For`: Client IP (captured automatically)

**Body (JSON, optional):**
```json
{
  "device": "dl-home",
  "note": "any string"
}
```

## Local Development

```bash
# Create virtual environment
python3 -m venv .venv
source .venv/bin/activate

# Install dependencies
pip install -r requirements.txt

# Start local function runtime
func start

# Test locally
curl http://localhost:7071/api/ping
```

## Deployment Commands

```bash
# Deploy infrastructure and function code
./deploy.sh

# Deploy infrastructure only
az deployment group create \
  -g $RG \
  -f main.bicep \
  -p prefix=$PREFIX alertEmail=$ALERT_EMAIL

# Deploy function code only
az functionapp deployment source config-zip \
  --resource-group $RG \
  --name $FUNC_APP_NAME \
  --src function.zip \
  --build-remote true

# View logs
az webapp log tail --name $FUNC_APP_NAME --resource-group $RG
```

## Monitoring

### View Application Insights Logs

```bash
az monitor app-insights query \
  --app darylhome-appi \
  --resource-group $RG \
  --analytics-query "requests | where timestamp > ago(1h) | project timestamp, name, resultCode"
```

### Check Alert Rule Status

```bash
az monitor scheduled-query list \
  --resource-group $RG \
  --output table
```

### Test Alert Manually

1. Stop the heartbeat agent: `./stop_heartbeat.sh`
2. Wait 6 minutes
3. Check your email for an alert from Azure Monitor

## Troubleshooting

### Function returns 503 "Function host is not running"
- Check function app is on Linux (not Windows)
- Verify `linuxFxVersion` is set to `Python|3.11`
- Restart function app: `az functionapp restart --name $FUNC_APP_NAME --resource-group $RG`

### No alerts received
- Verify alert email in Action Group: Check Azure Portal > Monitor > Alerts > Action Groups
- Check alert rule is enabled: `az monitor scheduled-query list --resource-group $RG`
- Confirm emails aren't in spam folder
- Test with manual alert: Azure Portal > Monitor > Alerts > Create > Alert rule

### Agent connection failures
- Verify function URL is correct: `curl https://your-func.azurewebsites.net/api/ping`
- Check firewall isn't blocking outbound HTTPS
- Verify internet connectivity on agent machine
- Check .env file has correct HEARTBEAT_URL

### Agent script issues
- Verify tmux is installed: `which tmux` or `brew install tmux` (macOS)
- Check if session already exists: `tmux ls`
- View agent logs: `tmux capture-pane -pt isp-monitor -S -50`
- Kill stuck session: `tmux kill-session -t isp-monitor`

## Cost Estimate

**Azure Resources (US West 2):**
- Function App (Consumption): ~$0-5/month (1M executions free)
- Storage Account: ~$0.50/month
- Application Insights: ~$2-5/month (5GB free)
- **Total: ~$2-10/month** depending on usage

## Notes

- **Action Groups** must use `location='global'` (not regional)
- **Evaluation Frequency** minimum is 5 minutes for scheduled query rules
- **Python on Windows** is deprecated; use Linux Consumption plan
- **Auth Level** is set to `anonymous` for easy testing; consider changing to `function` for production

## Resources

- [Azure Functions Python Developer Guide](https://docs.microsoft.com/azure/azure-functions/functions-reference-python)
- [Azure Monitor Alert Rules](https://docs.microsoft.com/azure/azure-monitor/alerts/alerts-overview)
- [Bicep Documentation](https://docs.microsoft.com/azure/azure-resource-manager/bicep/)

## License

MIT
