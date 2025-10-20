#!/bin/bash

# Alert Notification Diagnostic Script
# This script checks all components of the alert system to identify why emails aren't being sent

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Load environment variables
if [ -f .env ]; then
    echo -e "${BLUE}Loading configuration from .env...${NC}"
    export $(grep -v '^#' .env | xargs)
else
    echo -e "${RED}Error: .env file not found${NC}"
    exit 1
fi

# Extract prefix from RG name (assumes format: prefix-rg)
PREFIX=${RG%-rg}
FUNC_APP_NAME="${PREFIX}-func"
APPI_NAME="${PREFIX}-appi"
AG_NAME="${PREFIX}-ag"
ALERT_NAME="${PREFIX}-heartbeat-miss"

echo -e "\n${BLUE}═══════════════════════════════════════════════════════════${NC}"
echo -e "${BLUE}  Azure ISP Monitor - Alert Notification Diagnostics${NC}"
echo -e "${BLUE}═══════════════════════════════════════════════════════════${NC}\n"

echo -e "Configuration:"
echo -e "  Resource Group: ${GREEN}${RG}${NC}"
echo -e "  Function App:   ${GREEN}${FUNC_APP_NAME}${NC}"
echo -e "  App Insights:   ${GREEN}${APPI_NAME}${NC}"
echo -e "  Action Group:   ${GREEN}${AG_NAME}${NC}"
echo -e "  Alert Rule:     ${GREEN}${ALERT_NAME}${NC}\n"

# Check 1: Verify resources exist
echo -e "${YELLOW}[1/8] Checking if resources exist...${NC}"
if az group show --name "$RG" &>/dev/null; then
    echo -e "${GREEN}✓ Resource group exists${NC}"
else
    echo -e "${RED}✗ Resource group not found${NC}"
    exit 1
fi

if az functionapp show --name "$FUNC_APP_NAME" --resource-group "$RG" &>/dev/null; then
    echo -e "${GREEN}✓ Function app exists${NC}"
else
    echo -e "${RED}✗ Function app not found${NC}"
    exit 1
fi

# Check 2: Action Group Configuration
echo -e "\n${YELLOW}[2/8] Checking Action Group configuration...${NC}"
AG_CONFIG=$(az monitor action-group show \
    --name "$AG_NAME" \
    --resource-group "$RG" \
    --query "{enabled:enabled, shortName:groupShortName, emailReceivers:emailReceivers}" \
    --output json 2>/dev/null)

if [ $? -eq 0 ]; then
    echo -e "${GREEN}✓ Action group found${NC}"
    echo "$AG_CONFIG" | jq '.'

    # Check email receiver status
    EMAIL_STATUS=$(echo "$AG_CONFIG" | jq -r '.emailReceivers[0].status // "unknown"')
    EMAIL_ADDRESS=$(echo "$AG_CONFIG" | jq -r '.emailReceivers[0].emailAddress // "unknown"')

    echo -e "\nEmail Receiver:"
    echo -e "  Address: ${GREEN}${EMAIL_ADDRESS}${NC}"
    echo -e "  Status:  ${GREEN}${EMAIL_STATUS}${NC}"

    if [ "$EMAIL_STATUS" != "Enabled" ]; then
        echo -e "${RED}⚠ Warning: Email receiver status is not 'Enabled'${NC}"
    fi
else
    echo -e "${RED}✗ Action group not found${NC}"
    exit 1
fi

# Check 3: Alert Rule Configuration
echo -e "\n${YELLOW}[3/8] Checking Alert Rule configuration...${NC}"
ALERT_CONFIG=$(az monitor scheduled-query show \
    --name "$ALERT_NAME" \
    --resource-group "$RG" \
    --output json 2>/dev/null)

if [ $? -eq 0 ] && [ -n "$ALERT_CONFIG" ]; then
    # Validate that we got valid JSON
    if ! echo "$ALERT_CONFIG" | jq empty 2>/dev/null; then
        echo -e "${RED}✗ Alert rule found but returned invalid JSON${NC}"
        echo -e "${YELLOW}Raw output (first 500 chars):${NC}"
        echo "$ALERT_CONFIG" | head -c 500
        echo ""
        exit 1
    fi

    echo -e "${GREEN}✓ Alert rule found${NC}"

    # Extract key configuration
    ENABLED=$(echo "$ALERT_CONFIG" | jq -r '.enabled')
    EVAL_FREQ=$(echo "$ALERT_CONFIG" | jq -r '.evaluationFrequency')
    WINDOW_SIZE=$(echo "$ALERT_CONFIG" | jq -r '.windowSize')
    AUTO_MITIGATE=$(echo "$ALERT_CONFIG" | jq -r '.autoMitigate')
    MUTE_DURATION=$(echo "$ALERT_CONFIG" | jq -r '.muteActionsDuration // "not set"')
    QUERY=$(echo "$ALERT_CONFIG" | jq -r '.criteria.allOf[0].query')
    THRESHOLD=$(echo "$ALERT_CONFIG" | jq -r '.criteria.allOf[0].threshold')
    OPERATOR=$(echo "$ALERT_CONFIG" | jq -r '.criteria.allOf[0].operator')
    ACTION_GROUPS=$(echo "$ALERT_CONFIG" | jq -r '.actions.actionGroups | length')

    echo -e "\nAlert Configuration:"
    echo -e "  Enabled:          ${GREEN}${ENABLED}${NC}"
    echo -e "  Evaluation Freq:  ${GREEN}${EVAL_FREQ}${NC}"
    echo -e "  Window Size:      ${GREEN}${WINDOW_SIZE}${NC}"
    echo -e "  Auto Mitigate:    ${GREEN}${AUTO_MITIGATE}${NC}"
    echo -e "  Mute Duration:    ${GREEN}${MUTE_DURATION}${NC}"
    echo -e "  Threshold:        ${GREEN}${OPERATOR} ${THRESHOLD}${NC}"
    echo -e "  Action Groups:    ${GREEN}${ACTION_GROUPS}${NC}"

    echo -e "\nAlert Query:"
    echo -e "${BLUE}${QUERY}${NC}"

    if [ "$ENABLED" != "true" ]; then
        echo -e "${RED}⚠ Warning: Alert rule is not enabled!${NC}"
    fi

    if [ "$ACTION_GROUPS" -eq 0 ]; then
        echo -e "${RED}⚠ Warning: No action groups attached to alert!${NC}"
    fi
else
    echo -e "${RED}✗ Alert rule not found${NC}"
    exit 1
fi

# Check 4: Recent heartbeat data
echo -e "\n${YELLOW}[4/8] Checking recent heartbeat data...${NC}"
RECENT_PINGS=$(az monitor app-insights query \
    --app "$APPI_NAME" \
    --resource-group "$RG" \
    --analytics-query "requests | where name == 'Ping' | where timestamp > ago(15m) | summarize count(), LastPing=max(timestamp), FirstPing=min(timestamp)" \
    --output json 2>/dev/null)

if [ $? -eq 0 ]; then
    PING_COUNT=$(echo "$RECENT_PINGS" | jq -r '.tables[0].rows[0][0] // 0')
    LAST_PING=$(echo "$RECENT_PINGS" | jq -r '.tables[0].rows[0][1] // "none"')
    FIRST_PING=$(echo "$RECENT_PINGS" | jq -r '.tables[0].rows[0][2] // "none"')

    echo -e "${GREEN}✓ Application Insights query successful${NC}"
    echo -e "\nPing Statistics (last 15 minutes):"
    echo -e "  Total Pings:  ${GREEN}${PING_COUNT}${NC}"
    echo -e "  First Ping:   ${GREEN}${FIRST_PING}${NC}"
    echo -e "  Last Ping:    ${GREEN}${LAST_PING}${NC}"

    if [ "$PING_COUNT" -eq 0 ]; then
        echo -e "${YELLOW}⚠ No pings in last 15 minutes - alert should be firing!${NC}"
    fi
else
    echo -e "${RED}✗ Failed to query Application Insights${NC}"
fi

# Check 5: Verify cloud_RoleName in logs
echo -e "\n${YELLOW}[5/8] Checking cloud_RoleName in Application Insights...${NC}"
ROLE_NAME_DATA=$(az monitor app-insights query \
    --app "$APPI_NAME" \
    --resource-group "$RG" \
    --analytics-query "requests | where name == 'Ping' | where timestamp > ago(1h) | project timestamp, cloud_RoleName, name, resultCode | take 5" \
    --output json 2>/dev/null)

if [ $? -eq 0 ]; then
    ROW_COUNT=$(echo "$ROLE_NAME_DATA" | jq -r '.tables[0].rows | length')

    if [ "$ROW_COUNT" -gt 0 ]; then
        echo -e "${GREEN}✓ Found recent ping requests${NC}\n"
        echo "Recent requests (showing cloud_RoleName):"
        echo "$ROLE_NAME_DATA" | jq -r '.tables[0].rows[] | @tsv' | while IFS=$'\t' read -r timestamp role name code; do
            echo -e "  ${timestamp} | Role: ${GREEN}${role}${NC} | ${name} | ${code}"
        done

        # Check if role name matches expected
        ACTUAL_ROLE=$(echo "$ROLE_NAME_DATA" | jq -r '.tables[0].rows[0][1]')
        EXPECTED_ROLE=$(echo "$FUNC_APP_NAME" | tr '[:upper:]' '[:lower:]')

        echo -e "\nRole Name Comparison:"
        echo -e "  Expected: ${GREEN}${EXPECTED_ROLE}${NC}"
        echo -e "  Actual:   ${GREEN}${ACTUAL_ROLE}${NC}"

        if [ "$ACTUAL_ROLE" != "$EXPECTED_ROLE" ]; then
            echo -e "${RED}⚠ MISMATCH: The query in your alert rule may not match the actual cloud_RoleName!${NC}"
            echo -e "${RED}  This is likely why alerts aren't firing.${NC}"
        fi
    else
        echo -e "${YELLOW}⚠ No ping requests found in last hour${NC}"
    fi
else
    echo -e "${RED}✗ Failed to query cloud_RoleName data${NC}"
fi

# Check 6: Test the actual alert query
echo -e "\n${YELLOW}[6/8] Testing the actual alert query (last 5 minutes)...${NC}"
ALERT_QUERY_RESULT=$(az monitor app-insights query \
    --app "$APPI_NAME" \
    --resource-group "$RG" \
    --analytics-query "requests | where cloud_RoleName == \"${FUNC_APP_NAME}\" | where name == \"Ping\" | where timestamp > ago(5m) | summarize count()" \
    --output json 2>/dev/null)

if [ $? -eq 0 ]; then
    QUERY_COUNT=$(echo "$ALERT_QUERY_RESULT" | jq -r '.tables[0].rows[0][0] // 0')
    echo -e "${GREEN}✓ Alert query executed successfully${NC}"
    echo -e "\nQuery Result: ${GREEN}${QUERY_COUNT}${NC} requests"

    if [ "$QUERY_COUNT" -lt 1 ]; then
        echo -e "${YELLOW}⚠ Query returns < 1, alert SHOULD be firing${NC}"
    else
        echo -e "${GREEN}✓ Query returns ≥ 1, alert should NOT fire (heartbeat is working)${NC}"
    fi
else
    echo -e "${RED}✗ Failed to execute alert query${NC}"
fi

# Check 7: Alert firing history
echo -e "\n${YELLOW}[7/8] Checking alert firing history (last 24 hours)...${NC}"
ALERT_HISTORY=$(az monitor activity-log list \
    --resource-group "$RG" \
    --start-time "$(date -u -v-24H '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || date -u -d '24 hours ago' '+%Y-%m-%dT%H:%M:%SZ')" \
    --query "[?contains(operationName.value, 'Alert') || contains(operationName.value, 'alert')].{Time:eventTimestamp, Operation:operationName.localizedValue, Status:status.value, Resource:resourceId}" \
    --output json 2>/dev/null)

if [ $? -eq 0 ]; then
    ALERT_COUNT=$(echo "$ALERT_HISTORY" | jq 'length')

    if [ "$ALERT_COUNT" -gt 0 ]; then
        echo -e "${GREEN}✓ Found ${ALERT_COUNT} alert-related activities${NC}\n"
        echo "$ALERT_HISTORY" | jq -r '.[] | "\(.Time) | \(.Operation) | \(.Status)"' | head -10
    else
        echo -e "${YELLOW}⚠ No alert activities found in last 24 hours${NC}"
        echo -e "  This could mean:"
        echo -e "  - Alert has not fired"
        echo -e "  - Alert is firing but activities aren't logged yet"
        echo -e "  - Heartbeat has been consistently running"
    fi
else
    echo -e "${YELLOW}⚠ Could not retrieve alert history${NC}"
fi

# Check 8: Function app health
echo -e "\n${YELLOW}[8/8] Checking function app health...${NC}"
FUNC_STATE=$(az functionapp show \
    --name "$FUNC_APP_NAME" \
    --resource-group "$RG" \
    --query "{state:state, hostNames:defaultHostName}" \
    --output json 2>/dev/null)

if [ $? -eq 0 ]; then
    STATE=$(echo "$FUNC_STATE" | jq -r '.state')
    HOSTNAME=$(echo "$FUNC_STATE" | jq -r '.hostNames')

    echo -e "${GREEN}✓ Function app is ${STATE}${NC}"
    echo -e "  URL: https://${HOSTNAME}/api/ping"

    # Try to ping the function
    echo -e "\nTesting function endpoint..."
    RESPONSE=$(curl -s -o /dev/null -w "%{http_code}" "https://${HOSTNAME}/api/ping" -m 10)

    if [ "$RESPONSE" == "200" ]; then
        echo -e "${GREEN}✓ Function endpoint returned HTTP 200${NC}"
    else
        echo -e "${YELLOW}⚠ Function endpoint returned HTTP ${RESPONSE}${NC}"
    fi
else
    echo -e "${RED}✗ Failed to check function app status${NC}"
fi

# Summary and recommendations
echo -e "\n${BLUE}═══════════════════════════════════════════════════════════${NC}"
echo -e "${BLUE}  Diagnostic Summary${NC}"
echo -e "${BLUE}═══════════════════════════════════════════════════════════${NC}\n"

echo -e "${YELLOW}Key Findings:${NC}"
echo -e "1. Alert Rule Enabled: ${ENABLED}"
echo -e "2. Action Group Attached: ${ACTION_GROUPS} group(s)"
echo -e "3. Email Receiver Status: ${EMAIL_STATUS}"
echo -e "4. Recent Pings (15min): ${PING_COUNT}"
echo -e "5. Alert Query Result (5min): ${QUERY_COUNT}"

echo -e "\n${YELLOW}Recommendations:${NC}"

if [ "$ENABLED" != "true" ]; then
    echo -e "${RED}• Enable the alert rule${NC}"
fi

if [ "$ACTION_GROUPS" -eq 0 ]; then
    echo -e "${RED}• Attach action group to alert rule${NC}"
fi

if [ "$EMAIL_STATUS" != "Enabled" ]; then
    echo -e "${RED}• Activate email receiver in action group${NC}"
fi

if [ "$PING_COUNT" -eq 0 ] && [ "$QUERY_COUNT" -eq 0 ]; then
    echo -e "${YELLOW}• No recent pings detected - stop heartbeat agent for 6+ minutes to test alert${NC}"
fi

if [ "$ACTUAL_ROLE" != "" ] && [ "$ACTUAL_ROLE" != "$EXPECTED_ROLE" ]; then
    echo -e "${RED}• UPDATE ALERT QUERY: cloud_RoleName mismatch detected!${NC}"
    echo -e "  Expected: ${EXPECTED_ROLE}"
    echo -e "  Actual:   ${ACTUAL_ROLE}"
fi

if [ "$PING_COUNT" -gt 0 ]; then
    echo -e "${GREEN}• Heartbeat is working - to test alerts, run: ./stop_heartbeat.sh${NC}"
    echo -e "  Then wait 6-7 minutes for alert to fire"
fi

echo -e "\n${BLUE}═══════════════════════════════════════════════════════════${NC}\n"

echo -e "For more details, check:"
echo -e "  • Azure Portal: Monitor > Alerts > Alert Rules"
echo -e "  • Action Groups: Monitor > Alerts > Action Groups"
echo -e "  • Application Insights: Monitor > Application Insights > ${APPI_NAME}"
