param([object]$EventGridEvent, [object]$TriggerMetadata)

$AZURE_FUNCTION_NAME = "HandleSecretUpdateAfterRotation"
$DATA_PLANE_API_VERSION = "7.6-preview.1"
$EXPECTED_FUNCTION_APP_RG_NAME = $env:WEBSITE_RESOURCE_GROUP
$EXPECTED_FUNCTION_APP_NAME = "$EXPECTED_FUNCTION_APP_RG_NAME-App"
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
    return $response.value
}

function Update-FunctionAppSettings([string]$SecretValue) {
    Write-Host "Updating Function App settings with the new secret value..."

    $functionAppName = $EXPECTED_FUNCTION_APP_NAME
    $resourceGroupName = $EXPECTED_FUNCTION_APP_RG_NAME

    $appSettings = @{
        "AzureWebJobsDashboard" = "DefaultEndpointsProtocol=https;AccountName=$storageAccountName;AccountKey=$secretValue;"
        "AzureWebJobsStorage" = "DefaultEndpointsProtocol=https;AccountName=$storageAccountName;AccountKey=$secretValue;"
        "WEBSITE_CONTENTAZUREFILECONNECTIONSTRING" = "DefaultEndpointsProtocol=https;AccountName=$storageAccountName;AccountKey=$secretValue;"
    }

    foreach ($key in $appSettings.Keys) {
        Write-Host "Setting $key = $($appSettings[$key])"
    }

    try {
        Update-AzFunctionAppSetting -Name $functionAppName -ResourceGroupName $resourceGroupName -AppSetting $appSettings -Force
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
    Update-FunctionAppSettings -SecretValue $secretValue
} else {
    Write-Error "Unsupported Event Type: $eventType"
    throw "The Event Grid event '$eventType' is unsupported. Expected 'Microsoft.KeyVault.SecretNewVersionCreated'."
}

Write-Host "Script execution completed."