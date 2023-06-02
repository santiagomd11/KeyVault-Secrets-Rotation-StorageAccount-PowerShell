param($eventGridEvent, $TriggerMetadata)

function GetCredential($credentialId, $providerAddress){
    if(-Not($providerAddress)){
       throw "Provider Address is missing"
    }

    Write-Host "Retrieving credential. Id: $credentialId Resource Id: $providerAddress"
    
    $storageAccountName = ($providerAddress -split '/')[8]
    $resourceGroupName = ($providerAddress -split '/')[4]
    
    #Retrieve credential
    $newCredentialValue = (Get-AzStorageAccountKey -ResourceGroupName $resourceGroupName -AccountName $storageAccountName|where KeyName -eq $credentialId).value 
    return $newCredentialValue
}

function RegenerateCredential($credentialId, $providerAddress){
    if(-Not($providerAddress)){
       throw "Provider Address is missing"
    }

    Write-Host "Regenerating credential. Id: $credentialId Resource Id: $providerAddress"
    
    $storageAccountName = ($providerAddress -split '/')[8]
    $resourceGroupName = ($providerAddress -split '/')[4]
    
    #Regenerate key 
    $operationResult = New-AzStorageAccountKey -ResourceGroupName $resourceGroupName -Name $storageAccountName -KeyName $credentialId
    $newCredentialValue = (Get-AzStorageAccountKey -ResourceGroupName $resourceGroupName -AccountName $storageAccountName|where KeyName -eq $credentialId).value 
    return $newCredentialValue
}

function EvaluateCredentialId($credentialId){
   
    #if empty, default to key1
    if(-Not($credentialId)){
        $credentialId = "key1"
    }
    
    $validCredentialIdsRegEx = 'key[1-2]'
    
    If($credentialId -NotMatch $validCredentialIdsRegEx){
        throw "Invalid credential id: $credentialId. Credential id must follow this pattern:$validCredentialIdsRegEx"
    }

    return $credentialId
 }

 function GetAlternateCredentialId($currentCredentialId){
   
   $currentCredentialId = EvaluateCredentialId $currentCredentialId

    If($currentCredentialId -eq 'key1'){
        return "key2"
    }
    Else{
        return "key1"
    }
}

function ImportSecret($keyVaultName,$secretName,$secretVersion){
    #Retrieve Secret
    $token = (Get-AzAccessToken -ResourceUrl "https://vault.azure.net").Token
    $headers = @{
        "Authorization" = "Bearer $token"
        "Content-Type" = "application/json"
    }

    $currentSecret = (Invoke-WebRequest -Uri "https://$keyVaultName.vault.azure.net/secrets/${secretName}?api-version=7.6-preview.1" -Headers $headers -Method GET).Content | ConvertFrom-Json
    $currentSecretVersion = $currentSecret.id.Split("/")[-1]

    Write-Host "Secret Retrieved"
    
    If($currentSecretVersion -ne $secretVersion){
        #if current version is different than one retrived in event
        Write-Host "The secret version is already imported"
        return 
    }

    #Retrieve Secret Info
    $validityPeriodDays = $currentSecret.rotationPolicy.validityPeriod
    $credentialId =  $currentSecret.providerConfig.ActiveCredentialId
    $providerAddress = $currentSecret.providerConfig.providerAddress
    
    Write-Host "Secret Info Retrieved"
    Write-Host "Validity Period: $validityPeriodDays"
    Write-Host "Credential Id: $credentialId"
    Write-Host "Provider Address: $providerAddress"

    $credentialId = EvaluateCredentialId $credentialId

    #Get credential in provider
    $newCredentialValue = (GetCredential $credentialId $providerAddress)
    Write-Host "Credential retrieved. Credential Id: $credentialId Resource Id: $providerAddress"

    #Add new credential to Key Vault
    $setSecretBody = @{
        id = $currentSecret.id
        value = $newCredentialValue
        providerConfig = @{
            activeCredentialId = $credentialId
        }
    } | ConvertTo-Json -Depth 10

    Invoke-WebRequest -Uri "https://$keyVaultName.vault.azure.net/secrets/${secretName}/pending?api-version=7.6-preview.1" -Headers $headers -Body $setSecretBody -Method PUT

    Write-Host "New credential added to Key Vault. Secret Name: $secretName"
}

function RoatateSecret($keyVaultName,$secretName,$secretVersion){
    #Retrieve Secret
    $token = (Get-AzAccessToken -ResourceUrl "https://vault.azure.net").Token
    $headers = @{
        "Authorization" = "Bearer $token"
        "Content-Type" = "application/json"
    }

    $currentSecret = (Invoke-WebRequest -Uri "https://$keyVaultName.vault.azure.net/secrets/${secretName}?api-version=7.6-preview.1" -Headers $headers -Method GET).Content | ConvertFrom-Json
    $currentSecretVersion = $currentSecret.id.Split("/")[-1]

    Write-Host "Secret Retrieved"
    
    If($currentSecretVersion -ne $secretVersion){
        #if current version is different than one retrived in event
        Write-Host "The secret version is already rotated"
        return 
    }

    #Retrieve Secret Info
    $validityPeriodDays = $currentSecret.rotationPolicy.validityPeriod
    $credentialId =  $currentSecret.providerConfig.ActiveCredentialId
    $providerAddress = $currentSecret.providerConfig.providerAddress
    
    Write-Host "Secret Info Retrieved"
    Write-Host "Validity Period: $validityPeriodDays"
    Write-Host "Credential Id: $credentialId"
    Write-Host "Provider Address: $providerAddress"

    #Get Credential Id to rotate - alternate credential
    $alternateCredentialId = GetAlternateCredentialId $credentialId
    Write-Host "Alternate credential id: $alternateCredentialId"

    #Regenerate alternate access credential in provider
    $newCredentialValue = (RegenerateCredential $alternateCredentialId $providerAddress)
    Write-Host "Credential regenerated. Credential Id: $alternateCredentialId Resource Id: $providerAddress"

    #Add new credential to Key Vault
    $setSecretBody = @{
        id = $currentSecret.id
        value = $newCredentialValue
        providerConfig = @{
            activeCredentialId = $alternateCredentialId
        }
    } | ConvertTo-Json -Depth 10

    Invoke-WebRequest -Uri "https://$keyVaultName.vault.azure.net/secrets/${secretName}/pending?api-version=7.6-preview.1" -Headers $headers -Body $setSecretBody -Method PUT

    Write-Host "New credential added to Key Vault. Secret Name: $secretName"
}

$ErrorActionPreference = "Stop"
# Make sure to pass hashtables to Out-String so they're logged correctly
$eventGridEvent | ConvertTo-Json | Write-Host

if(-not($eventGridEvent.eventType -eq "Microsoft.KeyVault.SecretImportPending" -or $eventGridEvent.eventType -eq "Microsoft.KeyVault.SecretRotationPending" ))
{
    throw "Invalid event grid event. Microsoft.KeyVault.SecretImportPending is required to initiate import."
}

$secretName = $eventGridEvent.subject
$secretVersion = $eventGridEvent.data.Version
$keyVaultName = $eventGridEvent.data.VaultName

Write-Host "Key Vault Name: $keyVAultName"
Write-Host "Secret Name: $secretName"
Write-Host "Secret Version: $secretVersion"


If($eventGridEvent.eventType -eq "Microsoft.KeyVault.SecretImportPending")
{
    #Import secret
    Write-Host "Import started."
    ImportSecret $keyVAultName $secretName $secretVersion
    Write-Host "Secret Imported Successfully"
}
elseif($eventGridEvent.eventType -eq "Microsoft.KeyVault.SecretRotationPending")
{
    #Rotate secret
    Write-Host "Rotation started."
    RoatateSecret $keyVAultName $secretName $secretVersion
    Write-Host "Secret Rotated Successfully"
}
