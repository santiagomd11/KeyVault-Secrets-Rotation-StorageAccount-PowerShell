param([object]$EventGridEvent, [object]$TriggerMetadata)

$DATA_PLANE_API_VERSION = "7.6-preview.1"
$EXPECTED_FUNCTION_APP_RG_NAME = $env:WEBSITE_RESOURCE_GROUP
$EXPECTED_FUNCTION_APP_NAME = "$EXPECTED_FUNCTION_APP_RG_NAME-App"
$storageAccountName = $env:STORAGE_ACCOUNT_NAME
Write-Host "Storage Account Name: $storageAccountName"

function Get-SecretValue([string]$SecretId) {
    Write-Host "Fetching secret value for SecretId: $SecretId"
    $token = (Get-AzAccessToken -ResourceTypeName KeyVault -AsSecureString).Token
    $headers = @{ "Authorization" = "Bearer $($token)" }
    $response = Invoke-RestMethod -Uri "$SecretId?api-version=$DATA_PLANE_API_VERSION" -Headers $headers -Method GET
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
        Set-AzFunctionAppSetting -Name $functionAppName -ResourceGroupName $resourceGroupName -AppSettings $appSettings
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