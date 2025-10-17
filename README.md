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

## Requirements

- **Python 3.8 or higher** (Python 3.11+ recommended)
- **macOS/Linux** (tested on macOS, should work on Linux)
- **tmux** - For persistent background monitoring (install via `brew install tmux` on macOS)
- **Azure CLI** - For deployment

### Python Setup (macOS)

The heartbeat agent requires Python 3 with SSL support. If you're using Python installed from python.org on macOS, you must install SSL certificates:

```bash
# Check Python version
python3 --version  # Should be 3.8 or higher

# Install SSL certificates (required for HTTPS connections)
# Replace "3.12" with your Python version
/Applications/Python\ 3.12/Install\ Certificates.command

# Or find the correct path
ls -d /Applications/Python\ 3.*/Install\ Certificates.command
```

**Common Issues:**
- `[SSL: CERTIFICATE_VERIFY_FAILED]` error - Run the Install Certificates command above
- `python3: command not found` - Install Python 3 from [python.org](https://www.python.org/downloads/) or via Homebrew

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

- **Evaluation Frequency**: 5 minutes (line 143)
- **Window Size**: 5 minutes (line 144)
- **Query**: Looks for "Ping" function requests in last 5 minutes (line 148)
- **Threshold**: Alert if count < 1 (line 150)
- **Severity**: 2 - Warning (line 142)

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

# Deploy function code only (manual deployment)
# Get credentials first
CREDS=$(az functionapp deployment list-publishing-credentials \
  --resource-group $RG \
  --name $FUNC_APP_NAME \
  --query "{username:publishingUserName, password:publishingPassword}" \
  --output json)

# Then deploy using OneDeploy API
curl -X POST \
  -u "$(echo $CREDS | jq -r '.username'):$(echo $CREDS | jq -r '.password')" \
  -H "Content-Type: application/zip" \
  --data-binary @function.zip \
  https://$FUNC_APP_NAME.scm.azurewebsites.net/api/publish?type=zip

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

## Alert Configuration

The alert system is configured to provide continuous monitoring and timely notifications:

### How Alerts Work

- **Evaluation Frequency**: The alert rule checks for missing pings every 5 minutes
- **Detection Window**: Looks for at least 1 ping in the last 5 minutes
- **Notification Timing**: 
  - First email sent immediately when connectivity is lost (after 5-minute evaluation)
  - Additional emails sent every 5 minutes while the outage persists
  - Resolution email sent automatically when connectivity is restored
- **Auto-Resolution**: When your device reconnects and pings resume, the alert automatically resolves within one evaluation cycle (5 minutes)

### Example Timeline

```
02:10 - Internet connection lost
02:15 - Alert evaluates, detects missing pings → Email #1 sent ✉️
02:20 - Alert still firing → Email #2 sent ✉️
02:25 - Alert still firing → Email #3 sent ✉️
02:30 - Internet connection restored, pings resume
02:35 - Alert evaluates, detects pings → Resolution email sent ✉️
```

This configuration ensures you're continuously aware of ongoing outages and receive clear confirmation when connectivity is restored.

## Testing Alerts

To verify the alert system is working correctly after deployment:

### Manual Alert Test

1. **Stop the heartbeat agent:**
   ```bash
   ./stop_heartbeat.sh
   ```

2. **Wait 6-7 minutes** for the alert to fire
   - The alert evaluates every 5 minutes
   - Allow extra time for evaluation and email delivery

3. **Check your email** (including spam folder) for an alert notification from Azure Monitor
   - Subject will include "Fired: Sev 2 Azure Monitor Alert"
   - Sender: `azure-noreply@microsoft.com`

4. **Verify alert fired** (optional):
   ```bash
   az monitor app-insights query \
     --app darylhome-appi \
     --resource-group $RG \
     --analytics-query "requests | where name == 'Ping' | where timestamp > ago(15m) | summarize count()"
   ```
   If count is 0, the alert should have fired.

5. **Resume the heartbeat agent:**
   ```bash
   ./start_heartbeat.sh
   ```

6. **Wait 6-7 minutes** for the resolution email
   - Subject will include "Resolved: Sev 2 Azure Monitor Alert"
   - Confirms the alert system detected connectivity restoration

### Expected Behavior

- ✅ Alert fires within 7 minutes of stopping the agent
- ✅ Multiple emails received during extended outages (every 5 minutes)
- ✅ Resolution email received within 7 minutes of restarting the agent
- ✅ No manual intervention required to clear alerts

## Email Delivery Troubleshooting

If you're not receiving alert emails, check these common issues:

### Check Spam/Junk Folders

Azure Monitor emails may be filtered by email providers:

1. **Check spam folder** for emails from `azure-noreply@microsoft.com`
2. **Check Gmail tabs** (Promotions, Updates, Social) if using Gmail
3. **Search your inbox** for "Azure Monitor Alert" or "Fired: Sev"

### Verify Action Group Email

Confirm your email address is correctly configured:

```bash
az monitor action-group show \
  --name darylhome-ag \
  --resource-group $RG \
  --query "{enabled:enabled, email:emailReceivers[0].emailAddress, status:emailReceivers[0].status}" \
  --output table
```

**Expected output:**
- `enabled`: true
- `email`: Your email address
- `status`: Enabled

### Email Confirmation Requirement

When you first deploy the action group, Azure sends a confirmation email:

1. **Check your inbox** for "Azure: Activate this action group" email
2. **Click the confirmation link** in the email
3. **Verify status** shows "Enabled" (not "NotSpecified") using the command above
4. **Re-deploy if needed**: If you missed the confirmation, update `.env` and run `./deploy.sh` again

### Add Azure to Safe Senders

To prevent future filtering:

**Gmail:**
1. Open an Azure email
2. Click the three dots menu → "Filter messages like this"
3. Create filter with From: `azure-noreply@microsoft.com`
4. Check "Never send it to Spam"

**Outlook/Hotmail:**
1. Settings → Mail → Junk email
2. Add `azure-noreply@microsoft.com` to Safe senders

**Apple Mail:**
1. Open an Azure email
2. Right-click sender → "Add to Contacts"

### Verify Alert Configuration

Check that alert settings are correct:

```bash
az monitor scheduled-query show \
  --name darylhome-heartbeat-miss \
  --resource-group $RG \
  --query "{muteActions:muteActionsDuration, autoMitigate:autoMitigate, enabled:enabled}" \
  --output table
```

**Expected values:**
- `muteActions`: PT0M (zero minutes - enables continuous notifications)
- `autoMitigate`: true (enables automatic resolution)
- `enabled`: true

If values don't match, re-run `./deploy.sh` to apply the correct configuration.

## Troubleshooting

### Function returns 503 "Function host is not running"
- Check function app is on Linux (not Windows)
- Verify `linuxFxVersion` is set to `Python|3.11`
- Restart function app: `az functionapp restart --name $FUNC_APP_NAME --resource-group $RG`

### No alerts received
- Verify alert email in Action Group: Check Azure Portal > Monitor > Alerts > Action Groups
- Check alert rule is enabled: `az monitor scheduled-query list --resource-group $RG`
- Verify alert query syntax: The query looks for `name == "Ping"` in Application Insights requests
- Confirm emails aren't in spam folder
- Test alert query manually: `az monitor app-insights query --app <app-name> --resource-group $RG --analytics-query "requests | where name == 'Ping' | where timestamp > ago(1h) | summarize count()"`

### Agent connection failures
- Verify function URL is correct: `curl https://your-func.azurewebsites.net/api/ping`
- Check firewall isn't blocking outbound HTTPS
- Verify internet connectivity on agent machine
- Check .env file has correct HEARTBEAT_URL

### SSL Certificate errors
- **Error**: `[SSL: CERTIFICATE_VERIFY_FAILED] certificate verify failed`
- **Solution**: Install Python SSL certificates (see [Python Setup](#python-setup-macos) section above)
- **macOS**: Run `/Applications/Python 3.XX/Install Certificates.command` (replace XX with your version)
- **Alternative**: Use Python from Homebrew which includes certificates: `brew install python3`

### Agent script issues
- Verify tmux is installed: `which tmux` or `brew install tmux` (macOS)
- Check if session already exists: `tmux ls`
- View agent logs: `tmux capture-pane -pt isp-monitor -S -50`
- Kill stuck session: `tmux kill-session -t isp-monitor`

### Deployment failures
- **Error**: "The Azure CLI does not support this deployment path"
- **Solution**: The deploy.sh script now uses the OneDeploy API (`/api/publish?type=zip`) which is the current recommended method
- If deployment fails, check function app logs: `az webapp log tail --name $FUNC_APP_NAME --resource-group $RG`
- Ensure storage account connection is working (the script uses standard connection strings)

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
