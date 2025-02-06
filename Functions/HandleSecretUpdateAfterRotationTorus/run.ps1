param([object]$EventGridEvent, [object]$TriggerMetadata)

$AZURE_FUNCTION_NAME = "HandleSecretUpdateAfterRotation"
$DATA_PLANE_API_VERSION = "7.6-preview.1"
$EXPECTED_FUNCTION_APP_RG_NAME = $env:WEBSITE_RESOURCE_GROUP
$EXPECTED_FUNCTION_APP_NAME = $env:FUNCTION_APP_TO_UPDATE
$storageAccountName = $env:STORAGE_ACCOUNT_NAME
Write-Host "Storage Account Name: $storageAccountName"

function Get-SecretValue([string]$SecretId) {
    Write-Host "Fetching secret value for SecretId: $SecretId"

    $clientRequestId = [Guid]::NewGuid().ToString()
    $token = (Get-AzAccessToken -ResourceTypeName KeyVault -AsSecureString).Token

    Write-Host "Attempt #$i with x-ms-client-request-id: '$clientRequestId'"

    $headers = @{
        "User-Agent"             = "$AZURE_FUNCTION_NAME/1.0 ($CallerName; Step 1; Attempt $i)"
        "x-ms-client-request-id" = $clientRequestId
    }

    $response = Invoke-WebRequest -Uri "${SecretId}?api-version=$DATA_PLANE_API_VERSION" `
        -Method "GET" `
        -Authentication OAuth `
        -Token $token `
        -ContentType "application/json" `
        -Headers $headers
    
    $secret = $response.Content | ConvertFrom-Json
    $secretValue = $secret.value

    return $secretValue
}

function Update-FunctionAppSettings([string]$SecretValue) {
    $functionAppName = $EXPECTED_FUNCTION_APP_NAME
    $resourceGroupName = $EXPECTED_FUNCTION_APP_RG_NAME

    $token = (Get-AzAccessToken -ResourceTypeName "Arm").Token
    $headers = @{
        "Authorization" = "Bearer $token"
        "Content-Type"  = "application/json"
    }

    $getUrl = "https://management.azure.com/subscriptions/$env:AZURE_SUBSCRIPTION_ID/resourceGroups/$resourceGroupName/providers/Microsoft.Web/sites/$functionAppName/config/appsettings/list?api-version=2023-12-01"


    Write-Host "Fetching current app settings..."

    $currentSettingsResponse = Invoke-WebRequest -Uri $getUrl -Method "POST" -Headers $headers
    $currentSettingsObject = ($currentSettingsResponse.Content | ConvertFrom-Json).properties

    $currentSettings = @{}
    foreach ($key in $currentSettingsObject.PSObject.Properties.Name) {
        $currentSettings[$key] = $currentSettingsObject.$key
    }

    Write-Host "Merge new settings with existing settings..."

    $newSettings = @{
        "AzureWebJobsStorage" = "DefaultEndpointsProtocol=https;AccountName=$storageAccountName;AccountKey=$SecretValue;EndpointSuffix=core.windows.net"
    }

    foreach ($key in $newSettings.Keys) {
        $currentSettings[$key] = $newSettings[$key]
    }

    $body = @{
        "properties" = $currentSettings
    } | ConvertTo-Json

    $updateUrl = "https://management.azure.com/subscriptions/$env:AZURE_SUBSCRIPTION_ID/resourceGroups/$resourceGroupName/providers/Microsoft.Web/sites/$functionAppName/config/appsettings?api-version=2023-12-01"

    Write-Host "Sending update request to Azure with merged settings..."
    try {
        $response = Invoke-WebRequest -Uri $updateUrl `
            -Method "PUT" `
            -Headers $headers `
            -Body $body
        Write-Host "Function App settings updated successfully."
    } catch {
        Write-Error "Failed to update Function App settings: $_"
        throw $_
    }
}


Write-Host "Processing Event Grid event..."
$eventType = $EventGridEvent.eventType
$secretId = $EventGridEvent.data.Id

if ($eventType -eq "Microsoft.KeyVault.SecretNewVersionCreated") {
    Write-Host "New secret version detected: $secretId"

    $secretValue = Get-SecretValue -SecretId $secretId
    Write-Host "Secret for $SecretId got successfully."

    Update-FunctionAppSettings -SecretValue $secretValue
} else {
    Write-Error "Unsupported Event Type: $eventType"
    throw "The Event Grid event '$eventType' is unsupported. Expected 'Microsoft.KeyVault.SecretNewVersionCreated'."
}

Write-Host "Script execution completed."