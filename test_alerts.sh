#!/bin/bash

# Alert Testing and Validation Script
# This script verifies that the alert configuration is correct after deployment

set -e

# Colors for output
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m' # No Color

# Load environment variables
if [ -f .env ]; then
    source .env
else
    echo -e "${RED}Error: .env file not found${NC}"
    echo "Please create a .env file with RG and other required variables"
    exit 1
fi

# Check required variables
if [ -z "$RG" ]; then
    echo -e "${RED}Error: RG (Resource Group) not set in .env${NC}"
    exit 1
fi

# Extract prefix from resource group name (assumes format: {prefix}-rg)
PREFIX="${RG%-rg}"

echo "=========================================="
echo "Alert Configuration Validation"
echo "=========================================="
echo ""
echo "Resource Group: $RG"
echo "Prefix: $PREFIX"
echo ""

# Function to print success
print_success() {
    echo -e "${GREEN}✓${NC} $1"
}

# Function to print warning
print_warning() {
    echo -e "${YELLOW}⚠${NC} $1"
}

# Function to print error
print_error() {
    echo -e "${RED}✗${NC} $1"
}

# Check if resource group exists
echo "Checking resource group..."
if az group show --name "$RG" &>/dev/null; then
    print_success "Resource group exists"
else
    print_error "Resource group not found"
    exit 1
fi

echo ""
echo "=========================================="
echo "Alert Rule Configuration"
echo "=========================================="
echo ""

# Verify alert rule configuration
ALERT_NAME="${PREFIX}-heartbeat-miss"
echo "Checking alert rule: $ALERT_NAME"

if ! az monitor scheduled-query show --name "$ALERT_NAME" --resource-group "$RG" &>/dev/null; then
    print_error "Alert rule not found"
    exit 1
fi

ALERT_CONFIG=$(az monitor scheduled-query show \
    --name "$ALERT_NAME" \
    --resource-group "$RG" \
    --query "{muteActions:muteActionsDuration, autoMitigate:autoMitigate, enabled:enabled, evaluationFrequency:evaluationFrequency, windowSize:windowSize, severity:severity}" \
    --output json)

MUTE_DURATION=$(echo "$ALERT_CONFIG" | jq -r '.muteActions')
AUTO_MITIGATE=$(echo "$ALERT_CONFIG" | jq -r '.autoMitigate')
ENABLED=$(echo "$ALERT_CONFIG" | jq -r '.enabled')
EVAL_FREQ=$(echo "$ALERT_CONFIG" | jq -r '.evaluationFrequency')
WINDOW_SIZE=$(echo "$ALERT_CONFIG" | jq -r '.windowSize')
SEVERITY=$(echo "$ALERT_CONFIG" | jq -r '.severity')

echo ""
echo "Alert Rule Settings:"
echo "  Enabled: $ENABLED"
echo "  Evaluation Frequency: $EVAL_FREQ"
echo "  Window Size: $WINDOW_SIZE"
echo "  Severity: $SEVERITY"
echo "  Mute Actions Duration: $MUTE_DURATION"
echo "  Auto Mitigate: $AUTO_MITIGATE"
echo ""

# Validate critical settings
VALIDATION_PASSED=true

if [ "$ENABLED" = "true" ]; then
    print_success "Alert rule is enabled"
else
    print_error "Alert rule is disabled"
    VALIDATION_PASSED=false
fi

if [ "$MUTE_DURATION" = "PT0M" ]; then
    print_success "Mute actions duration is PT0M (continuous notifications enabled)"
else
    print_warning "Mute actions duration is $MUTE_DURATION (expected: PT0M)"
    echo "  This means notifications will be suppressed for $MUTE_DURATION after the first alert"
    VALIDATION_PASSED=false
fi

if [ "$AUTO_MITIGATE" = "true" ]; then
    print_success "Auto mitigate is enabled (alerts will auto-resolve)"
else
    print_warning "Auto mitigate is disabled (expected: true)"
    echo "  This means alerts will not automatically resolve when connectivity is restored"
    VALIDATION_PASSED=false
fi

echo ""
echo "=========================================="
echo "Action Group Configuration"
echo "=========================================="
echo ""

# Verify action group configuration
ACTION_GROUP_NAME="${PREFIX}-ag"
echo "Checking action group: $ACTION_GROUP_NAME"

if ! az monitor action-group show --name "$ACTION_GROUP_NAME" --resource-group "$RG" &>/dev/null; then
    print_error "Action group not found"
    exit 1
fi

ACTION_GROUP_CONFIG=$(az monitor action-group show \
    --name "$ACTION_GROUP_NAME" \
    --resource-group "$RG" \
    --query "{name:name, enabled:enabled, location:location, emailReceivers:emailReceivers}" \
    --output json)

AG_ENABLED=$(echo "$ACTION_GROUP_CONFIG" | jq -r '.enabled')
AG_LOCATION=$(echo "$ACTION_GROUP_CONFIG" | jq -r '.location')
EMAIL_COUNT=$(echo "$ACTION_GROUP_CONFIG" | jq '.emailReceivers | length')

echo ""
echo "Action Group Settings:"
echo "  Enabled: $AG_ENABLED"
echo "  Location: $AG_LOCATION"
echo "  Email Receivers: $EMAIL_COUNT"
echo ""

if [ "$AG_ENABLED" = "true" ]; then
    print_success "Action group is enabled"
else
    print_error "Action group is disabled"
    VALIDATION_PASSED=false
fi

if [ "$AG_LOCATION" = "global" ]; then
    print_success "Action group location is global"
else
    print_warning "Action group location is $AG_LOCATION (expected: global)"
fi

# Display email receivers
if [ "$EMAIL_COUNT" -gt 0 ]; then
    echo ""
    echo "Email Receivers:"
    echo "$ACTION_GROUP_CONFIG" | jq -r '.emailReceivers[] | "  • \(.name): \(.emailAddress) (Status: \(.status // "NotSpecified"))"'
    echo ""
    
    # Check if any email is not confirmed
    UNCONFIRMED=$(echo "$ACTION_GROUP_CONFIG" | jq -r '.emailReceivers[] | select(.status != "Enabled") | .emailAddress' | wc -l)
    if [ "$UNCONFIRMED" -gt 0 ]; then
        print_warning "Some email addresses may not be confirmed"
        echo "  Check your inbox for confirmation emails from Azure"
    else
        print_success "All email receivers are enabled"
    fi
else
    print_error "No email receivers configured"
    VALIDATION_PASSED=false
fi

echo ""
echo "=========================================="
echo "Validation Summary"
echo "=========================================="
echo ""

if [ "$VALIDATION_PASSED" = true ]; then
    print_success "All critical settings are configured correctly"
    echo ""
    echo "Next Steps:"
    echo "  1. Test the alert system by stopping the heartbeat agent:"
    echo "     ./stop_heartbeat.sh"
    echo ""
    echo "  2. Wait 6-7 minutes for the alert to fire"
    echo ""
    echo "  3. Check your email (including spam folder)"
    echo ""
    echo "  4. Resume the heartbeat agent:"
    echo "     ./start_heartbeat.sh"
    echo ""
    echo "  5. Wait 6-7 minutes for the resolution email"
else
    print_warning "Some settings need attention"
    echo ""
    echo "Recommended Actions:"
    echo "  • Review the warnings above"
    echo "  • Re-run deployment if critical settings are incorrect: ./deploy.sh"
    echo "  • Check email confirmation status in Azure Portal"
fi

echo ""
