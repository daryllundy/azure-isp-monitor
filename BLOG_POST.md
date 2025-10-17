# Building a Serverless ISP Outage Monitor with Azure Functions

*How I built a reliable internet monitoring system that sends real-time alerts when my ISP goes down*

---

## The Problem: ISP Outages Going Unnoticed

As someone who works from home, internet connectivity isn't just a convenience—it's critical infrastructure. But here's the frustrating part: when my ISP goes down, I often don't know about it until I'm actively trying to use the internet. Even worse, I have no way to track how often outages occur or how long they last.

I needed a solution that would:
- Monitor my internet connection 24/7
- Send immediate notifications when connectivity is lost
- Alert me again when service is restored
- Be cost-effective (ideally free or near-free)
- Require minimal maintenance

That's when I decided to build a serverless ISP outage monitor using Azure Functions.

---

## The Solution: Azure Functions + Application Insights Alerts

The architecture is beautifully simple:

**[Image: Architecture diagram showing: Home Device → Azure Function → Application Insights → Alert Rule → Email Notification]**

1. **Heartbeat Agent** - A Python script running on my home network that sends a "ping" to an Azure Function every minute
2. **Azure Function** - A simple HTTP endpoint that logs each heartbeat to Application Insights
3. **Alert Rule** - Monitors Application Insights for missing heartbeats and triggers notifications
4. **Email Notifications** - Action Group that sends emails when alerts fire and resolve

The beauty of this approach is that it's completely serverless and costs virtually nothing to run. Azure Functions on the Consumption plan provides 1 million free executions per month, and Application Insights has a generous free tier.

---

## Part 1: Building the Heartbeat Function

The core of the system is a simple Azure Function that accepts HTTP requests and logs them. Here's what the function does:

**[Code snippet: Ping/__init__.py - the main function]**

```python
import json
import re
import time
import azure.functions as func

def main(req: func.HttpRequest) -> func.HttpResponse:
    try:
        body = req.get_json()
    except (ValueError, TypeError):
        body = {}

    # Validate and sanitize inputs
    device = sanitize_string(
        body.get("device") or req.headers.get("X-Device"),
        MAX_DEVICE_LENGTH,
        "unknown"
    )

    note = sanitize_string(
        body.get("note"),
        MAX_NOTE_LENGTH,
        ""
    )

    ip = validate_ip(
        req.headers.get("X-Forwarded-For") or req.headers.get("X-Client-IP")
    )

    payload = {
        "ts": int(time.time()),
        "device": device,
        "ip": ip,
        "note": note
    }

    # Log to Application Insights (structured logging)
    print(f"[heartbeat] {json.dumps(payload)}")

    return func.HttpResponse("ok", status_code=200, headers={"Content-Type":"text/plain"})
```

The function:
- Accepts both GET and POST requests
- Extracts device name, IP address, and optional notes
- Sanitizes all inputs to prevent injection attacks
- Logs structured data to Application Insights
- Returns a simple "ok" response

**[Screenshot: Azure Portal showing the Function App with the Ping function]**

---

## Part 2: Infrastructure as Code with Bicep

Rather than clicking through the Azure Portal, I used Bicep (Azure's declarative infrastructure language) to define all the resources. This makes the entire setup reproducible and version-controlled.

**[Code snippet: main.bicep - key resources]**

```bicep
// Function App on Linux Consumption Plan
resource func 'Microsoft.Web/sites@2023-12-01' = {
  name: appName
  location: location
  kind: 'functionapp,linux'
  identity: {
    type: 'SystemAssigned'
  }
  properties: {
    serverFarmId: plan.id
    httpsOnly: true
    reserved: true  // Required for Linux
    siteConfig: {
      linuxFxVersion: 'Python|3.11'
      appSettings: [
        { name: 'FUNCTIONS_WORKER_RUNTIME', value: 'python' }
        { name: 'FUNCTIONS_EXTENSION_VERSION', value: '~4' }
        { name: 'APPLICATIONINSIGHTS_CONNECTION_STRING', value: appi.properties.ConnectionString }
        { name: 'SCM_DO_BUILD_DURING_DEPLOYMENT', value: 'true' }
        { name: 'ENABLE_ORYX_BUILD', value: 'true' }
      ]
    }
  }
}

// Alert Rule - fires when no heartbeats for 5 minutes
resource rule 'Microsoft.Insights/scheduledQueryRules@2023-12-01' = {
  name: alertName
  location: location
  properties: {
    displayName: alertName
    enabled: true
    scopes: [appi.id]
    severity: 2
    evaluationFrequency: 'PT5M'
    windowSize: 'PT5M'
    criteria: {
      allOf: [
        {
          query: 'requests | where cloud_RoleName == "${appName}" | where name == "Ping" | where timestamp > ago(5m) | summarize count()'
          timeAggregation: 'Count'
          operator: 'LessThan'
          threshold: 1
        }
      ]
    }
    actions: {
      actionGroups: [ag.id]
    }
    autoMitigate: true  // Automatically resolve when heartbeats resume
  }
}
```

The Bicep template creates:
- Storage Account (with managed identity for security)
- Application Insights workspace
- Consumption Plan (Linux)
- Function App
- Action Group (email notifications)
- Alert Rule (monitors for missing heartbeats)

**[Screenshot: Azure Portal showing deployed resources in the resource group]**

---

## Part 3: The Heartbeat Agent

On my home network, I run a simple Python script that sends heartbeats every minute:

**[Code snippet: heartbeat_agent.py]**

```python
import os
import requests
import time
from dotenv import load_dotenv

load_dotenv()

HEARTBEAT_URL = os.getenv("HEARTBEAT_URL")
HEARTBEAT_DEVICE = os.getenv("HEARTBEAT_DEVICE")
HEARTBEAT_INTERVAL = int(os.getenv("HEARTBEAT_INTERVAL", "60"))

while True:
    try:
        response = requests.post(
            HEARTBEAT_URL,
            json={
                "device": HEARTBEAT_DEVICE,
                "note": "scheduled heartbeat"
            },
            timeout=10
        )
        if response.status_code == 200:
            print(f"✓ Heartbeat sent successfully")
        else:
            print(f"⚠ Heartbeat failed: HTTP {response.status_code}")
    except Exception as e:
        print(f"✗ Error sending heartbeat: {e}")

    time.sleep(HEARTBEAT_INTERVAL)
```

I run this in a tmux session so it continues running even when I'm not logged in. Helper scripts make this easy:

**[Code snippet: start_heartbeat.sh and stop_heartbeat.sh]**

```bash
# start_heartbeat.sh
#!/bin/bash
tmux new-session -d -s heartbeat "python3 heartbeat_agent.py"
echo "✓ Heartbeat agent started in tmux session 'heartbeat'"

# stop_heartbeat.sh
#!/bin/bash
tmux kill-session -t heartbeat 2>/dev/null
echo "✓ Heartbeat agent stopped"
```

---

## Part 4: Setting Up Alerts

The alert configuration is where the magic happens. Here's how it works:

**Alert Query:**
```kusto
requests
| where cloud_RoleName == "darylhome-func"
| where name == "Ping"
| where timestamp > ago(5m)
| summarize count()
```

**Alert Logic:**
- **Evaluation Frequency:** Every 5 minutes
- **Threshold:** Less than 1 request in the last 5 minutes
- **Auto-Mitigate:** Enabled (automatically resolves when heartbeats resume)

This means:
- If my internet goes down, the heartbeat agent can't reach Azure
- After 5 minutes of no heartbeats, the alert fires
- I receive an email notification immediately
- When connectivity is restored, the alert auto-resolves
- I receive another email confirming service is back

**[Screenshot: Email notification showing "Fired" alert]**
**[Screenshot: Email notification showing "Resolved" alert]**

---

## The Deployment Challenge: Linux Consumption Plans

Building this was straightforward, but deploying it revealed an interesting Azure Functions quirk that cost me several hours of troubleshooting.

Initially, my deployment script wasn't working. The function would deploy but return 404 errors, or worse, deploy successfully but not send telemetry to Application Insights. After extensive research and testing, I discovered the root cause:

**Linux Consumption Plan functions DO NOT support `WEBSITE_RUN_FROM_PACKAGE=1`**

This is a critical platform limitation. The solution requires a specific deployment approach:

**[Code snippet: deploy.sh - the working deployment method]**

```bash
# Upload package to blob storage
az storage blob upload \
  --account-name "$STORAGE_ACCOUNT" \
  --account-key "$ACCOUNT_KEY" \
  --container-name "function-releases" \
  --name "$BLOB_NAME" \
  --file function.zip

# Generate SAS token
SAS_TOKEN=$(az storage blob generate-sas \
  --account-name "$STORAGE_ACCOUNT" \
  --account-key "$ACCOUNT_KEY" \
  --container-name "function-releases" \
  --name "$BLOB_NAME" \
  --permissions r \
  --expiry "$EXPIRY" \
  --https-only)

# Set WEBSITE_RUN_FROM_PACKAGE to the full blob URL (not "1")
PACKAGE_URL="https://${STORAGE_ACCOUNT}.blob.core.windows.net/function-releases/${BLOB_NAME}?${SAS_TOKEN}"

az functionapp config appsettings set \
  --settings WEBSITE_RUN_FROM_PACKAGE="$PACKAGE_URL"
```

The key differences:
- Upload to blob storage using account keys
- Generate a SAS token for the blob
- Set `WEBSITE_RUN_FROM_PACKAGE` to the **full blob URL with SAS token** (not just "1")
- Ensure `SCM_DO_BUILD_DURING_DEPLOYMENT=true` and `ENABLE_ORYX_BUILD=true` are set

**[Screenshot: Azure Portal showing successful deployment logs]**

---

## Part 5: Continuous Deployment with GitHub Actions

To make deployments even easier, I set up GitHub Actions to automatically deploy whenever I push to the main branch:

**[Code snippet: .github/workflows/deploy.yml - key parts]**

```yaml
name: Deploy Azure ISP Monitor

on:
  push:
    branches:
      - main
  workflow_dispatch:

jobs:
  deploy:
    runs-on: ubuntu-latest
    steps:
    - name: Checkout code
      uses: actions/checkout@v4

    - name: Setup Python 3.11
      uses: actions/setup-python@v5
      with:
        python-version: 3.11

    - name: Deploy to Azure Function App
      run: |
        # Same deployment logic as deploy.sh
        # Upload to blob storage, generate SAS token, configure function app
```

Now every commit to main automatically deploys to Azure. The workflow:
1. Builds the deployment package
2. Uploads to blob storage
3. Configures the function app
4. Tests the endpoint
5. Reports success/failure

**[Screenshot: GitHub Actions workflow run showing successful deployment]**

---

## Testing the System

To test the complete system:

```bash
# Start the heartbeat agent
./start_heartbeat.sh

# Wait a minute, verify it's working
curl https://darylhome-func.azurewebsites.net/api/ping
# Response: ok

# Stop the heartbeat to simulate an outage
./stop_heartbeat.sh

# Wait 6-7 minutes...
# → Email received: "Fired - Heartbeat Missing"

# Resume the heartbeat
./start_heartbeat.sh

# Wait 6-7 minutes...
# → Email received: "Resolved - Heartbeat Restored"
```

**[Screenshot: Application Insights showing the heartbeat requests over time with a gap]**

---

## Cost Analysis

One of my key requirements was keeping costs low. Here's how this solution performs:

**Monthly Costs (estimated):**
- **Azure Function Executions:** ~43,800 per month (1 per minute)
  - Cost: $0.00 (well under the 1M free tier)
- **Application Insights:** ~130 MB of data per month
  - Cost: $0.00 (under the 5GB free tier)
- **Storage Account:** Minimal blob storage for function packages
  - Cost: < $0.10 per month
- **Alert Rules:** 1 scheduled query rule
  - Cost: $0.00 (first rule is free)

**Total: ~$0.10 per month** 🎉

This is essentially free, especially compared to commercial monitoring services that can cost $10-50/month.

---

## Lessons Learned

Building this project taught me several valuable lessons:

1. **Platform Constraints Matter:** Always check Azure documentation for platform-specific limitations. What works on Windows Functions or Premium plans may not work on Linux Consumption plans.

2. **Serverless is Cost-Effective:** For low-volume, periodic tasks like this, serverless architectures are incredibly economical.

3. **Infrastructure as Code is Essential:** Using Bicep made the entire setup reproducible. I can tear down and rebuild this entire system in minutes.

4. **Telemetry is Critical:** The function can work perfectly but be useless without proper Application Insights integration. Always verify telemetry is flowing.

5. **Auto-Remediation is Powerful:** Using `autoMitigate: true` means I get both "service down" and "service restored" notifications automatically, providing complete visibility into outages.

---

## What's Next?

Potential enhancements I'm considering:

- **Dashboard:** Build a web dashboard showing uptime statistics and outage history
- **Multiple Locations:** Add heartbeat agents from different networks to detect location-specific issues
- **SMS Alerts:** Add Twilio integration for critical outages when email isn't fast enough
- **Metrics Export:** Export metrics to Power BI for long-term trend analysis
- **Slack Integration:** Send notifications to a Slack channel instead of (or in addition to) email

---

## Try It Yourself

The complete source code is available on GitHub: [link to repo]

To deploy this yourself:

1. Clone the repository
2. Copy `.env.example` to `.env` and fill in your values
3. Run `./deploy.sh` to deploy the infrastructure and function
4. Set up the heartbeat agent on your home network
5. Test by stopping/starting the heartbeat

The entire setup takes less than 10 minutes and costs essentially nothing to run.

---

## Conclusion

What started as a simple need—knowing when my internet goes down—turned into a great learning experience with Azure Functions, Application Insights, and Infrastructure as Code. The final solution is elegant, cost-effective, and reliable.

The serverless architecture means I don't have to manage any servers, and the Azure free tiers mean I get enterprise-grade monitoring for free. Plus, I now have historical data on my ISP's reliability, which could be useful if I ever need to file a complaint or switch providers.

If you're looking for a practical project to learn Azure Functions or need to monitor your own internet connection, I highly recommend building something similar. The skills you'll learn—serverless architectures, monitoring, alerting, IaC—are all highly valuable in modern cloud development.

**[Image: Final architecture diagram with all components connected and labeled]**

---

*Have questions or suggestions? Feel free to open an issue on GitHub or reach out to me directly!*
