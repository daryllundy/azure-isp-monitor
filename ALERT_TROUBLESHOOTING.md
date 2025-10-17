# Alert Notification Troubleshooting

## Issue Summary

**Problem:** Azure Monitor alert rule is configured and enabled, but email notifications are not being received when the heartbeat stops for more than 5 minutes.

**Date:** 2025-10-17
**Environment:** Azure Functions (darylhome-func) with Application Insights monitoring

---

## Investigation Results

### 1. Alert Rule Status ✅

The alert rule `darylhome-heartbeat-miss` is properly configured and enabled:

```bash
az monitor scheduled-query show --name darylhome-heartbeat-miss --resource-group darylhome-rg
```

**Configuration:**
- **Name:** darylhome-heartbeat-miss
- **Status:** Enabled
- **Evaluation Frequency:** 5 minutes
- **Window Size:** 5 minutes
- **Severity:** 2 (Warning)
- **Query:**
  ```kusto
  requests
  | where cloud_RoleName == "darylhome-func"
  | where name == "Ping"
  | where timestamp > ago(5m)
  | summarize count()
  ```
- **Condition:** Alert when count < 1
- **Auto Mitigate:** false
- **Mute Actions Duration:** 5 minutes

### 2. Action Group Status ✅

The action group `darylhome-ag` is configured correctly:

```bash
az monitor action-group show --name darylhome-ag --resource-group darylhome-rg
```

**Configuration:**
- **Name:** darylhome-ag
- **Status:** Enabled
- **Email Receiver:**
  - **Name:** primary
  - **Email:** daryl.lundy@gmail.com
  - **Status:** Enabled
  - **Use Common Alert Schema:** true

### 3. Data Verification ✅

Heartbeat data is being logged correctly to Application Insights:

```bash
az monitor app-insights query --app darylhome-appi --resource-group darylhome-rg \
  --analytics-query "requests | where name == 'Ping' | where timestamp > ago(2h) | summarize count() by bin(timestamp, 5m)"
```

**Observations:**
- Pings are successfully reaching the Azure Function
- Application Insights is capturing the requests with `name="Ping"`
- There was a documented gap from **02:10 UTC to 02:53 UTC** (43 minutes without pings)
- Alert query correctly returns 0 when no pings are present in the last 5 minutes

### 4. Alert Query Test ✅

The alert query executes correctly and returns the expected results:

```bash
az monitor app-insights query --app darylhome-appi --resource-group darylhome-rg \
  --analytics-query 'requests | where cloud_RoleName == "darylhome-func" | where name == "Ping" | where timestamp > ago(5m) | summarize count()'
```

When no pings exist in the last 5 minutes, the query returns `count=0`, which should trigger the alert (threshold: LessThan 1).

---

## Root Cause Analysis

After thorough investigation, the alert rule is **functioning correctly** from a configuration standpoint. However, there are several reasons why email notifications might not be received:

### Issue #1: Mute Actions Duration (Most Likely)

**Problem:** The alert has `muteActionsDuration: "PT5M"` (5 minutes) configured in main.bicep:164.

**Impact:**
- When the alert first fires, it sends an email notification
- For the next 5 minutes, even if the alert continues to evaluate as "firing", **no additional emails are sent**
- During a 43-minute outage, you would only receive **1 email** at the beginning, then silence

**Example Timeline:**
```
02:10 - Heartbeat stops
02:15 - Alert fires → Email sent ✅
02:20 - Alert still firing → Email suppressed (muted)
02:25 - Alert still firing → Email suppressed (muted)
02:30 - Alert still firing → Email suppressed (muted)
...
02:53 - Heartbeat resumes
```

### Issue #2: Auto Mitigate Disabled

**Problem:** The alert has `autoMitigate: false` (main.bicep:165).

**Impact:**
- Once the alert fires, it stays in "fired" state until manually resolved
- Combined with mute duration, this can suppress subsequent notifications
- The alert won't automatically clear when pings resume

### Issue #3: Email Delivery Issues

**Possible Causes:**
1. **Email in spam folder** - Azure Monitor emails from `azure-noreply@microsoft.com` may be filtered
2. **Gmail Promotions/Updates tab** - Notification emails might be categorized incorrectly
3. **Email confirmation not completed** - When first setting up an action group, Azure sends a confirmation email that must be clicked
4. **Corporate email filters** - Enterprise email systems may block automated Azure notifications

### Issue #4: Alert Evaluation Timing

**Problem:** Alerts evaluate every 5 minutes on Azure's schedule, not synchronized with your heartbeat interval.

**Impact:**
- If heartbeat stops at 02:12 and alert evaluates at 02:15, 02:20, etc., there might be timing gaps
- First evaluation after outage might not catch the exact moment heartbeat stops

---

## Recommended Fixes

### Fix #1: Remove or Reduce Mute Duration (Recommended)

**Change main.bicep line 164:**

```bicep
// Before
muteActionsDuration: 'PT5M'

// After - Option A: No muting (send email every 5 minutes while down)
muteActionsDuration: 'PT0M'

// After - Option B: Reduce to 1 minute
muteActionsDuration: 'PT1M'
```

**Pros:**
- Receive multiple notifications during extended outages
- Clear indication that the issue persists

**Cons:**
- More emails during long outages (but this is usually desired for critical monitoring)

### Fix #2: Enable Auto Mitigate

**Change main.bicep line 165:**

```bicep
// Before
autoMitigate: false

// After
autoMitigate: true
```

**Pros:**
- Alert automatically resolves when pings resume
- Can receive "resolved" notification
- Better alert lifecycle management

**Cons:**
- None significant for this use case

### Fix #3: Verify Email Delivery

**Immediate Actions:**

1. **Check spam/junk folder** for emails from:
   - `azure-noreply@microsoft.com`
   - `azure-noreply@azure.microsoft.com`
   - `noreply@email.azure.com`

2. **Check Gmail tabs:**
   - Promotions tab
   - Updates tab
   - Social tab

3. **Add Azure to safe senders list:**
   - Gmail: Create filter for `@*.azure.com` and `@microsoft.com`
   - Mark as "Never send to Spam"

4. **Verify email confirmation:**
   - Check inbox for initial action group confirmation email
   - If not confirmed, the action group won't send notifications

### Fix #4: Add Additional Notification Channels (Optional)

Consider adding redundant notification methods to the action group:

```bicep
resource ag 'Microsoft.Insights/actionGroups@2022-06-01' = {
  name: agName
  location: 'global'
  properties: {
    enabled: true
    groupShortName: prefix
    emailReceivers: [
      {
        name: 'primary'
        emailAddress: alertEmail
        useCommonAlertSchema: true
      }
    ]
    // Optional: Add SMS notifications
    smsReceivers: [
      {
        name: 'sms-alert'
        countryCode: '1'
        phoneNumber: 'YOUR_PHONE_NUMBER'
      }
    ]
  }
}
```

---

## Testing Plan

### Test 1: Manual Alert Trigger

1. **Stop the heartbeat agent:**
   ```bash
   ./stop_heartbeat.sh
   ```

2. **Wait 6-7 minutes** (longer than the 5-minute evaluation window)

3. **Check email** (including spam folder)

4. **Verify alert fired:**
   ```bash
   az monitor app-insights query --app darylhome-appi --resource-group darylhome-rg \
     --analytics-query "requests | where name == 'Ping' | where timestamp > ago(10m) | summarize count()"
   ```
   Should return `count=0`

5. **Resume heartbeat:**
   ```bash
   ./start_heartbeat.sh
   ```

### Test 2: Action Group Test Notification

Unfortunately, Azure CLI doesn't support testing action groups with email receivers via the standard test-notifications command. However, you can:

1. **Temporarily create a test metric alert** that fires immediately
2. **Trigger it manually** to verify email delivery
3. **Delete the test alert** after verification

---

## Deployment Instructions

After making changes to `main.bicep`:

```bash
# 1. Ensure you're on the troubleshooting branch
git checkout troubleshoot-alert-notifications

# 2. Edit main.bicep with recommended fixes

# 3. Deploy the updated infrastructure
./deploy.sh

# 4. Verify the changes
az monitor scheduled-query show --name darylhome-heartbeat-miss --resource-group darylhome-rg \
  --query "{muteActions:muteActionsDuration, autoMitigate:autoMitigate}" -o table

# 5. Test the alert (stop heartbeat for 6+ minutes)
./stop_heartbeat.sh
```

---

## Monitoring and Validation

### Check Alert Firing History

```bash
# View recent activity logs related to alerts
az monitor activity-log list --resource-group darylhome-rg \
  --max-events 50 \
  --query "[?contains(operationName.value, 'Alert')].{Time:eventTimestamp, Operation:operationName.value, Status:status.value}" \
  -o table
```

### Verify Current Alert State

```bash
# Check if alerts are currently firing
az monitor scheduled-query list --resource-group darylhome-rg --output table
```

### Query Alert Condition

```bash
# Run the exact query used by the alert rule
az monitor app-insights query --app darylhome-appi --resource-group darylhome-rg \
  --analytics-query 'requests | where cloud_RoleName == "darylhome-func" | where name == "Ping" | where timestamp > ago(5m) | summarize count()'
```

**Expected Results:**
- If heartbeat is running: `count >= 1` (alert not firing)
- If heartbeat is stopped for 5+ minutes: `count = 0` (alert should be firing)

---

## Additional Resources

- [Azure Monitor Alert Rules Documentation](https://docs.microsoft.com/azure/azure-monitor/alerts/alerts-overview)
- [Scheduled Query Rules API Reference](https://docs.microsoft.com/azure/templates/microsoft.insights/scheduledqueryrules)
- [Action Groups Documentation](https://docs.microsoft.com/azure/azure-monitor/alerts/action-groups)
- [Troubleshooting Azure Monitor Alerts](https://docs.microsoft.com/azure/azure-monitor/alerts/alerts-troubleshoot)

---

## Summary

**Most Likely Issue:** The 5-minute mute duration is suppressing subsequent email notifications during extended outages.

**Immediate Action:** Check your spam folder for Azure Monitor emails.

**Recommended Fix:** Update `main.bicep` to set `muteActionsDuration: 'PT0M'` and `autoMitigate: true`, then redeploy.

**Test:** Stop heartbeat for 6+ minutes and verify email delivery before considering the issue resolved.
