param([object]$EventGridEvent, [object]$TriggerMetadata)

$MAX_RETRY_ATTEMPTS = 30
$MAX_JSON_DEPTH = 10
$DATA_PLANE_API_VERSION = "7.6-preview.1"

function Get-CredentialValue([string]$ActiveCredentialId, [string]$ProviderAddress) {
    if (-not ($ActiveCredentialId)) {
        throw "The active credential ID is missing."
    }
    if ($ActiveCredentialId -notin @("key1", "key2")) {
        throw "The active credential ID '$ActiveCredentialId' didn't match the expected pattern. Expected 'key1' or 'key2'."
    }
    if (-not ($ProviderAddress)) {
        throw "The provider address is missing."
    }
    if (-not ($ProviderAddress -match "/subscriptions/([^/]+)/resourceGroups/([^/]+)/providers/Microsoft.Storage/storageAccounts/([^/]+)")) {
        throw "The provider address '$ProviderAddress' didn't match the expected pattern."
    }
    $subscriptionId = $Matches[1]
    $resourceGroupName = $Matches[2]
    $storageAccountName = $Matches[3]

    $null = Select-AzSubscription -SubscriptionId $subscriptionId
    return (Get-AzStorageAccountKey -ResourceGroupName $resourceGroupName -AccountName $storageAccountName | Where-Object KeyName -eq $ActiveCredentialId).value
}

function Invoke-CredentialRegeneration([string]$InactiveCredentialId, [string]$ProviderAddress) {
    if (-not ($ProviderAddress)) {
        throw "The provider address is missing."
    }
    if (-not ($ProviderAddress -match "/subscriptions/([^/]+)/resourceGroups/([^/]+)/providers/Microsoft.Storage/storageAccounts/([^/]+)")) {
        throw "The provider address '$ProviderAddress' didn't match the expected pattern."
    }
    $subscriptionId = $Matches[1]
    $resourceGroupName = $Matches[2]
    $storageAccountName = $Matches[3]

    $null = Select-AzSubscription -SubscriptionId $subscriptionId
    $null = New-AzStorageAccountKey -ResourceGroupName $resourceGroupName -Name $storageAccountName -KeyName $InactiveCredentialId
    return (Get-AzStorageAccountKey -ResourceGroupName $resourceGroupName -AccountName $storageAccountName | Where-Object KeyName -eq $InactiveCredentialId).value
}

function Get-InactiveCredentialId([string]$ActiveCredentialId) {
    $inactiveCredentialId = switch ($ActiveCredentialId) {
        "key1" { "key2" }
        "key2" { "key1" }
        default { throw "The active credential ID '$ActiveCredentialId' didn't match the expected pattern. Expected 'key1' or 'key2'." }
    }
    return $inactiveCredentialId
}

function Invoke-PendingSecretImport([string]$VersionedSecretId, [string]$UnversionedSecretId) {
    $expectedLifecycleState = "ImportPending"
    $akvResourceUrl = (Get-AzContext).Environment.AzureKeyVaultServiceEndpointResourceId
    $token = (Get-AzAccessToken -ResourceUrl $akvResourceUrl).Token

    # In rare cases, this handler might receive the published event before AKV has finished committing to storage.
    # To mitigate this, poll the current secret for up to 30s until its current lifecycle state matches that of the published event.
    Write-Host "[Step 1] Get the current secret for validation and the ground truth."
    $secret = $null
    $actualSecretId = $null
    $actualLifecycleState = $null
    foreach ($i in 1..$MAX_RETRY_ATTEMPTS) {
        $clientRequestId = [Guid]::NewGuid().ToString()
        Write-Host "  Attempt #$i with x-ms-client-request-id: '$clientRequestId'"
        $headers = @{
            "Authorization"          = "Bearer $token"
            "User-Agent"             = "AkvStorageAccountConnector/1.0 (Invoke-PendingSecretImport; Step 1; Attempt $i)"
            "x-ms-client-request-id" = $clientRequestId
        }
        $response = Invoke-WebRequest -Uri "${UnversionedSecretId}?api-version=$DATA_PLANE_API_VERSION" `
            -Method "GET" `
            -Headers $headers `
            -ContentType "application/json"
        $secret = $response.Content | ConvertFrom-Json
        $actualSecretId = $secret.id
        $actualLifecycleState = $secret.attributes.lifecycleState
        if (($actualSecretId -eq $VersionedSecretId) -and ($actualLifecycleState -eq $expectedLifecycleState)) {
            break
        }
        Start-Sleep -Seconds 1
    }
    if (-not ($actualSecretId -eq $VersionedSecretId)) {
        throw "The secret '$actualSecretId' did not transition to '$VersionedSecretId' after approximately $MAX_RETRY_ATTEMPTS seconds."
    }
    if (-not ($actualLifecycleState -eq $expectedLifecycleState)) {
        throw "The secret '$actualSecretId' still has a lifecycle state of '$actualLifecycleState' and did not transition to '$expectedLifecycleState' after approximately $MAX_RETRY_ATTEMPTS seconds."
    }
    $lifecycleDescription = $secret.attributes.lifecycleDescription
    $validityPeriod = $secret.rotationPolicy.validityPeriod
    $activeCredentialId = $secret.providerConfig.activeCredentialId
    $providerAddress = $secret.providerConfig.providerAddress
    $functionResourceId = $secret.providerConfig.functionResourceId
    Write-Host "  lifecycleDescription: '$lifecycleDescription'"
    Write-Host "  validityPeriod: '$validityPeriod'"
    Write-Host "  activeCredentialId: '$activeCredentialId'"
    Write-Host "  providerAddress: '$providerAddress'"
    Write-Host "  functionResourceId: '$functionResourceId'"

    Write-Host "[Step 2] Import the secret from the provider and prepare the new secret in-memory."
    $activeCredentialValue = Get-CredentialValue -ActiveCredentialId $activeCredentialId -ProviderAddress $providerAddress
    $secret | Add-Member -NotePropertyName "value" -NotePropertyValue $activeCredentialValue -Force
    $secret.providerConfig.activeCredentialId = $activeCredentialId
    $updatePendingSecretRequestBody = ConvertTo-Json $secret -Depth $MAX_JSON_DEPTH -Compress

    Write-Host "[Step 3] Update the pending secret."
    $clientRequestId = [Guid]::NewGuid().ToString()
    Write-Host "  x-ms-client-request-id: '$clientRequestId'"
    $headers = @{
        "Authorization"          = "Bearer $token"
        "User-Agent"             = "AkvStorageAccountConnector/1.0 (Invoke-PendingSecretImport; Step 3)"
        "x-ms-client-request-id" = $clientRequestId
    }
    $response = Invoke-WebRequest -Uri "${UnversionedSecretId}/pending?api-version=$DATA_PLANE_API_VERSION" `
        -Method "PUT" `
        -Headers $headers `
        -ContentType "application/json" `
        -Body $updatePendingSecretRequestBody
    $updatedSecret = $response.Content | ConvertFrom-Json
    $lifecycleState = $updatedSecret.attributes.lifecycleState
    $lifecycleDescription = $updatedSecret.attributes.lifecycleDescription
    $activeCredentialId = $updatedSecret.providerConfig.activeCredentialId
    Write-Host "  lifecycleState: '$lifecycleState'"
    Write-Host "  lifecycleDescription: '$lifecycleDescription'"
    Write-Host "  activeCredentialId: '$activeCredentialId'"
}

function Invoke-PendingSecretRotation([string]$VersionedSecretId, [string]$UnversionedSecretId) {
    $expectedLifecycleState = "RotationPending"
    $akvResourceUrl = (Get-AzContext).Environment.AzureKeyVaultServiceEndpointResourceId
    $token = (Get-AzAccessToken -ResourceUrl $akvResourceUrl).Token

    # In rare cases, this handler might receive the published event before AKV has finished committing to storage.
    # To mitigate this, poll the current secret for up to 30s until its current lifecycle state matches that of the published event.
    Write-Host "Step 1: Get the current secret for validation and the ground truth."
    $secret = $null
    $actualSecretId = $null
    $actualLifecycleState = $null
    foreach ($i in 1..$MAX_RETRY_ATTEMPTS) {
        $clientRequestId = [Guid]::NewGuid().ToString()
        Write-Host "  Attempt #$i with x-ms-client-request-id: '$clientRequestId'"
        $headers = @{
            "Authorization"          = "Bearer $token"
            "User-Agent"             = "AkvStorageAccountConnector/1.0 (Invoke-PendingSecretRotation; Step 1; Attempt $i)"
            "x-ms-client-request-id" = $clientRequestId
        }
        $response = Invoke-WebRequest -Uri "${UnversionedSecretId}?api-version=$DATA_PLANE_API_VERSION" `
            -Method "GET" `
            -Headers $headers `
            -ContentType "application/json"
        $secret = $response.Content | ConvertFrom-Json
        $actualSecretId = $secret.id
        $actualLifecycleState = $secret.attributes.lifecycleState
        if (($actualSecretId -eq $VersionedSecretId) -and ($actualLifecycleState -eq $expectedLifecycleState)) {
            break
        }
        Start-Sleep -Seconds 1
    }
    if (-not ($actualSecretId -eq $VersionedSecretId)) {
        throw "The secret '$actualSecretId' did not transition to '$VersionedSecretId' after approximately $MAX_RETRY_ATTEMPTS seconds."
    }
    if (-not ($actualLifecycleState -eq $expectedLifecycleState)) {
        throw "The secret '$actualSecretId' still has a lifecycle state of '$actualLifecycleState' and did not transition to '$expectedLifecycleState' after approximately $MAX_RETRY_ATTEMPTS seconds."
    }
    $lifecycleDescription = $secret.attributes.lifecycleDescription
    $validityPeriod = $secret.rotationPolicy.validityPeriod
    $activeCredentialId = $secret.providerConfig.activeCredentialId
    $providerAddress = $secret.providerConfig.providerAddress
    $functionResourceId = $secret.providerConfig.functionResourceId
    Write-Host "  lifecycleDescription: '$lifecycleDescription'"
    Write-Host "  validityPeriod: '$validityPeriod'"
    Write-Host "  activeCredentialId: '$activeCredentialId'"
    Write-Host "  providerAddress: '$providerAddress'"
    Write-Host "  functionResourceId: '$functionResourceId'"

    Write-Host "Step 2: Regenerate the inactive credential via the provider and prepare the new secret in-memory."
    $inactiveCredentialId = Get-InactiveCredentialId -ActiveCredentialId $activeCredentialId
    $inactiveCredentialValue = Invoke-CredentialRegeneration -InactiveCredentialId $inactiveCredentialId -ProviderAddress $providerAddress
    $secret | Add-Member -NotePropertyName "value" -NotePropertyValue $inactiveCredentialValue -Force
    $secret.providerConfig.activeCredentialId = $inactiveCredentialId
    $updatePendingSecretRequestBody = ConvertTo-Json $secret -Depth $MAX_JSON_DEPTH -Compress

    Write-Host "Step 3: Update the pending secret."
    $clientRequestId = [Guid]::NewGuid().ToString()
    Write-Host "  x-ms-client-request-id: '$clientRequestId'"
    $headers = @{
        "Authorization"          = "Bearer $token"
        "User-Agent"             = "AkvStorageAccountConnector/1.0 (Invoke-PendingSecretRotation; Step 3)"
        "x-ms-client-request-id" = $clientRequestId
    }
    $response = Invoke-WebRequest -Uri "${UnversionedSecretId}/pending?api-version=$DATA_PLANE_API_VERSION" `
        -Method "PUT" `
        -Headers $headers `
        -ContentType "application/json" `
        -Body $updatePendingSecretRequestBody
    $updatedSecret = $response.Content | ConvertFrom-Json
    $lifecycleState = $updatedSecret.attributes.lifecycleState
    $lifecycleDescription = $updatedSecret.attributes.lifecycleDescription
    $activeCredentialId = $updatedSecret.providerConfig.activeCredentialId
    Write-Host "  lifecycleState: '$lifecycleState'"
    Write-Host "  lifecycleDescription: '$lifecycleDescription'"
    Write-Host "  activeCredentialId: '$activeCredentialId'"
}

$ErrorActionPreference = "Stop"

$EventGridEvent | ConvertTo-Json -Depth $MAX_JSON_DEPTH -Compress | Write-Host
$eventType = $EventGridEvent.eventType
$versionedSecretId = $EventGridEvent.data.Id
if (-not ($versionedSecretId -match "(https://[^/]+/[^/]+/[^/]+)/[0-9a-f]{32}")) {
    throw "The versioned secret ID '$versionedSecretId' didn't match the expected pattern."
}
$unversionedSecretId = $Matches[1]

switch ($eventType) {
    "Microsoft.KeyVault.SecretImportPending" {
        Invoke-PendingSecretImport -VersionedSecretId $versionedSecretId -UnversionedSecretId $unversionedSecretId
    }
    "Microsoft.KeyVault.SecretRotationPending" {
        Invoke-PendingSecretRotation -VersionedSecretId $versionedSecretId -UnversionedSecretId $unversionedSecretId
    }
    default {
        throw "The Event Grid event '$eventType' is unsupported. Expected 'Microsoft.KeyVault.SecretImportPending' or 'Microsoft.KeyVault.SecretRotationPending'."
    }
}