# KeyVault-Secrets-Rotation-StorageAccount-PowerShell

Function imports and rotate individual key (alternating between two keys) in Storage Account and stores them in Key Vault.

## Features

This project framework provides the following features:

* Azure function (AKVStorageAccountConnector) to manage Storage Account key. It is triggered by Event Grid 

* ARM template for function deployment 

## Functions

* AKVStorageAccountConnector - event triggered function, performs storage account key import and rotation

### Installation

ARM templates available:

* [Secrets rotation Azure Function and configuration deployment template](https://github.com/jlichwa/KeyVault-Secrets-Rotation-StorageAccount-PowerShell/blob/main/ARM-Templates/Readme.md) - it creates and deploys function app and function code, creates necessary permissions,  Key Vault event subscription for ImportPending and RotationPending events for individual secret (secret name can be provided as parameter).
