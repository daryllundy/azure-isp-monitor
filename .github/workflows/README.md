# GitHub Actions Workflows

## Setup Instructions

To enable automatic deployment from GitHub Actions, you need to configure the following secrets in your GitHub repository:

### Required Secrets

1. **AZURE_CREDENTIALS** - Azure Service Principal credentials for authentication
2. **AZURE_RG** - Azure Resource Group name (e.g., `darylhome-rg`)

### Creating Azure Service Principal

Run the following command to create a service principal with Contributor access:

```bash
az ad sp create-for-rbac \
  --name "github-actions-azure-isp-monitor" \
  --role contributor \
  --scopes /subscriptions/<SUBSCRIPTION_ID>/resourceGroups/<RESOURCE_GROUP> \
  --sdk-auth
```

This will output JSON credentials that should be added as the `AZURE_CREDENTIALS` secret.

### Adding Secrets to GitHub

1. Go to your repository on GitHub
2. Navigate to **Settings** > **Secrets and variables** > **Actions**
3. Click **New repository secret**
4. Add each secret:
   - Name: `AZURE_CREDENTIALS`
   - Value: The JSON output from the `az ad sp create-for-rbac` command
   - Name: `AZURE_RG`
   - Value: Your resource group name (e.g., `darylhome-rg`)

### Workflow Details

**File:** `.github/workflows/deploy.yml`

**Triggers:**
- Push to `main` branch only
- Manual trigger via `workflow_dispatch`

**Steps:**
1. Checkout code
2. Setup Python 3.11
3. Create deployment package (zip)
4. Login to Azure
5. Upload package to blob storage
6. Generate SAS token
7. Configure function app with package URL
8. Restart function app
9. Test endpoint
10. Cleanup

**Note:** This workflow uses the same deployment method as `deploy.sh` - uploading to blob storage and setting `WEBSITE_RUN_FROM_PACKAGE` to the blob URL with SAS token (compatible with Linux Consumption plans).
