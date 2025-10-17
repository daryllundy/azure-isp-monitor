#!/bin/bash
set -e  # Exit on error

# Source environment variables from .env file
if [ -f .env ]; then
  set -a
  source .env
  set +a
fi

# Check if required variables are set
if [ -z "$RG" ] || [ -z "$LOCATION" ]; then
  echo "Error: RG and LOCATION must be set in the .env file."
  exit 1
fi

if [ -z "$ALERT_EMAIL" ]; then
  echo "Error: ALERT_EMAIL must be set in the .env file."
  exit 1
fi

# Derive PREFIX from RG (e.g., darylhome-rg -> darylhome)
PREFIX=$(echo $RG | sed 's/-rg$//')

echo "=========================================="
echo "Azure ISP Monitor - Deployment Script"
echo "=========================================="
echo "Resource Group: $RG"
echo "Location: $LOCATION"
echo "Prefix: $PREFIX"
echo "Alert Email: $ALERT_EMAIL"
echo "=========================================="
echo ""

# Check if resource group exists, create if not
echo "[1/3] Checking resource group..."
if ! az group show --name "$RG" &>/dev/null; then
  echo "Creating resource group $RG in $LOCATION..."
  az group create --name "$RG" --location "$LOCATION" --output none

  if [ $? -eq 0 ]; then
    echo "✓ Resource group $RG created successfully."
  else
    echo "Error: Failed to create resource group $RG."
    exit 1
  fi
else
  echo "✓ Resource group $RG already exists."
fi
echo ""

# Deploy infrastructure
# Note: Action Groups require location='global' (configured in main.bicep)
echo "[2/3] Deploying infrastructure..."
DEPLOYMENT_OUTPUT=$(az deployment group create \
  --resource-group "$RG" \
  --template-file main.bicep \
  --parameters prefix="$PREFIX" alertEmail="$ALERT_EMAIL" \
  --query 'properties.outputs' \
  --output json)

if [ $? -ne 0 ]; then
  echo "Error: Infrastructure deployment failed."
  exit 1
fi

echo "Infrastructure deployed successfully!"
echo ""

# Extract function app name and URL from outputs
FUNC_APP_NAME=$(echo "$DEPLOYMENT_OUTPUT" | jq -r '.functionAppName.value // empty')
FUNC_APP_URL=$(echo "$DEPLOYMENT_OUTPUT" | jq -r '.functionAppUrl.value // empty')

if [ -z "$FUNC_APP_NAME" ]; then
  # Fallback: construct name from prefix
  FUNC_APP_NAME="${PREFIX}-func"
  FUNC_APP_URL="https://${FUNC_APP_NAME}.azurewebsites.net/api/ping"
fi

# Verify alert configuration
echo "Verifying alert configuration..."
ALERT_CONFIG=$(az monitor scheduled-query show \
  --name "${PREFIX}-heartbeat-miss" \
  --resource-group "$RG" \
  --query "{muteActions:muteActionsDuration, autoMitigate:autoMitigate}" \
  --output json 2>/dev/null)

if [ $? -eq 0 ]; then
  MUTE_DURATION=$(echo "$ALERT_CONFIG" | jq -r '.muteActions')
  AUTO_MITIGATE=$(echo "$ALERT_CONFIG" | jq -r '.autoMitigate')

  if [ "$MUTE_DURATION" = "PT0M" ] && [ "$AUTO_MITIGATE" = "true" ]; then
    echo "✓ Alert configuration verified"
    echo "  - Mute Actions Duration: $MUTE_DURATION (continuous notifications enabled)"
    echo "  - Auto Mitigate: $AUTO_MITIGATE (automatic resolution enabled)"
  else
    echo "⚠ Alert configuration mismatch:"
    echo "  - Mute Actions Duration: $MUTE_DURATION (expected: PT0M)"
    echo "  - Auto Mitigate: $AUTO_MITIGATE (expected: true)"
  fi
else
  echo "⚠ Could not verify alert configuration. Alert rule may still be deploying."
fi
echo ""

# Display action group configuration
echo "Action Group Configuration:"
ACTION_GROUP_CONFIG=$(az monitor action-group show \
  --name "${PREFIX}-ag" \
  --resource-group "$RG" \
  --query "{Name:name, Enabled:enabled, Email:emailReceivers[0].emailAddress, Status:emailReceivers[0].status}" \
  --output table 2>/dev/null)

if [ $? -eq 0 ]; then
  echo "$ACTION_GROUP_CONFIG"
else
  echo "⚠ Could not retrieve action group configuration."
fi
echo ""

echo "[3/3] Deploying function app code..."
echo "Building and deploying to $FUNC_APP_NAME..."

# Create deployment package
rm -f function.zip
zip -r function.zip . -x ".git/*" ".venv/*" ".history/*" "*.pyc" "__pycache__/*" ".DS_Store" "*.sh" "main.bicep" ".env" "*.zip" ".env.example"

if [ ! -f function.zip ]; then
  echo "Error: Failed to create deployment package."
  exit 1
fi

echo "Package size: $(du -h function.zip | cut -f1)"

# Deploy function code using OneDeploy API
# Get publishing credentials
CREDS=$(az functionapp deployment list-publishing-credentials \
  --resource-group "$RG" \
  --name "$FUNC_APP_NAME" \
  --query "{username:publishingUserName, password:publishingPassword}" \
  --output json)

USERNAME=$(echo "$CREDS" | jq -r '.username')
PASSWORD=$(echo "$CREDS" | jq -r '.password')

# Deploy using OneDeploy API (newer recommended method)
HTTP_STATUS=$(curl -X POST \
  -u "$USERNAME:$PASSWORD" \
  -H "Content-Type: application/zip" \
  --data-binary @function.zip \
  -w "%{http_code}" \
  -o /dev/null \
  -s \
  https://$FUNC_APP_NAME.scm.azurewebsites.net/api/publish?type=zip)

if [ "$HTTP_STATUS" != "200" ] && [ "$HTTP_STATUS" != "202" ]; then
  echo "Error: Function code deployment failed with HTTP status $HTTP_STATUS"
  rm -f function.zip
  exit 1
fi

# Clean up
rm -f function.zip

echo "Waiting for function host to start..."
sleep 10

# Test if function is responding
echo "Testing function endpoint..."
HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" "$FUNC_APP_URL" || echo "000")

if [ "$HTTP_CODE" = "200" ] || [ "$HTTP_CODE" = "204" ]; then
  echo "✓ Function is responding (HTTP $HTTP_CODE)"
elif [ "$HTTP_CODE" = "503" ]; then
  echo "⚠ Function host is still starting up. Wait a minute and try: curl $FUNC_APP_URL"
else
  echo "⚠ Function returned HTTP $HTTP_CODE. Check logs with: az webapp log tail --name $FUNC_APP_NAME --resource-group $RG"
fi

echo ""
echo "=========================================="
echo "Deployment Complete!"
echo "=========================================="
echo "Function App: $FUNC_APP_NAME"
echo "Function URL: $FUNC_APP_URL"
echo ""
echo "Alert Configuration:"
echo "  - Evaluation Frequency: Every 5 minutes"
echo "  - Notification Frequency: Every 5 minutes during outages"
echo "  - Auto-Resolution: Enabled (resolves when connectivity restored)"
echo ""
echo "Test your deployment:"
echo "  curl $FUNC_APP_URL"
echo ""
echo "Test alert notifications:"
echo "  1. Stop heartbeat: ./stop_heartbeat.sh"
echo "  2. Wait 6-7 minutes for alert to fire"
echo "  3. Check email (including spam folder)"
echo "  4. Resume heartbeat: ./start_heartbeat.sh"
echo "  5. Wait 6-7 minutes for resolution email"
echo ""
echo "Manually verify alert settings:"
echo "  az monitor scheduled-query show \\"
echo "    --name ${PREFIX}-heartbeat-miss \\"
echo "    --resource-group $RG \\"
echo "    --query \"{mute:muteActionsDuration, auto:autoMitigate}\" \\"
echo "    --output table"
echo "=========================================="
