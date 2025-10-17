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
echo "Test your deployment:"
echo "  curl $FUNC_APP_URL"
echo "=========================================="
