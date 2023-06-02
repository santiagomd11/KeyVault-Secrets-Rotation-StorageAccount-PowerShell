# KeyVault-Secrets-Rotation-StorageAccount-PowerShell

Functions regenerate individual key (alternating between two keys) in Storage Account and add regenerated key to Key Vault as new version of the same secret.

## Features

This project framework provides the following features:

* Azure function (AKVStorageAccountConnector) to manage Storage Account key. It is triggered by Event Grid 

* ARM template for function deployment 

## Getting Started

* AKVStorageAccountConnector - event triggered function, performs storage account key import and rotation

### Installation

ARM templates available:

* [Secrets rotation Azure Function and configuration deployment template](https://github.com/Azure/KeyVault-Secrets-Rotation-StorageAccount-PowerShell/blob/main/ARM-Templates/Readme.md) - it creates and deploys function app and function code, creates necessary permissions,  Key Vault event subscription for Near Expiry Event for individual secret (secret name can be provided as parameter), and deploys secret with Storage Account key (optional)
