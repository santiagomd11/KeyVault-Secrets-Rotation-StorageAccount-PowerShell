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

function EvaluateCredentialId($credentialId){
   
    #if empty, default to key1
    if(-Not($credentialId)){
        $credentialId = "key1"
    }
    
    $validCredentialIdsRegEx = 'key[1-2]'
    
    If($credentialId -NotMatch $validCredentialIdsRegEx){
        throw "Invalid credential id: $credentialId. Credential id must follow this pattern:$validCredentialIdsRegEx"
    }
    If($credentialId -eq 'key1'){
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

    $secret = (Invoke-WebRequest -Uri "https://$keyVaultName.vault.azure.net/secrets/${secretName}?api-version=7.6-preview.1" -Headers $headers -Method GET).Content | ConvertFrom-Json
   
    Write-Host "Secret Retrieved"
    
    If($secret.Version -ne $secretVersion){
        #if current version is different than one retrived in event
        Write-Host "Secret version is already imported"
        return 
    }

    #Retrieve Secret Info
    $validityPeriodDays = $secret.rotationPolicy.validityPeriod
    $credentialId =  $secret.providerConfig.ActiveCredentialId
    $providerAddress = $secret.providerConfig.providerAddress
    
    Write-Host "Secret Info Retrieved"
    Write-Host "Validity Period: $validityPeriodDays"
    Write-Host "Credential Id: $credentialId"
    Write-Host "Provider Address: $providerAddress"

    $credentialId = EvaluateCredentialId $credentialId

    #Get credential in provider
    $newCredentialValue = (RegenerateCredential $credentialId $providerAddress)
    Write-Host "Credential retrieved. Credential Id: $credentialId Resource Id: $providerAddress"

    #Add new credential to Key Vault
    $setSecretBody = @{
        value = $newCredentialValue
        providerConfig = @{
            activeCredentialId = $credentialId
        }
    } | ConvertTo-Json -Depth 10

    Invoke-WebRequest -Uri "https://$keyVaultName.vault.azure.net/secrets/${secretName}/pending?api-version=7.6-preview.1" -Headers $headers -Body $setSecretBody -Method PUT

    Write-Host "New credential added to Key Vault. Secret Name: $secretName"
}
$ErrorActionPreference = "Stop"
# Make sure to pass hashtables to Out-String so they're logged correctly
$eventGridEvent | ConvertTo-Json | Write-Host

If($eventGridEvent.eventType -eq "Microsoft.KeyVault.SecretImportPending")
{
    $secretName = $eventGridEvent.subject
    $secretVersion = $eventGridEvent.data.Version
    $keyVaultName = $eventGridEvent.data.VaultName

    Write-Host "Key Vault Name: $keyVAultName"
    Write-Host "Secret Name: $secretName"
    Write-Host "Secret Version: $secretVersion"

    #Rotate secret
    Write-Host "Import started."
    ImportSecret $keyVAultName $secretName $secretVersion
    Write-Host "Secret Imported Successfully"
}
else {
    throw "Invalid event grid event. Microsoft.KeyVault.SecretImportPending is required to initiate import."
}