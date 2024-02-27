// Parameters
param location string = resourceGroup().location
param workload string

// Variables
var storageAccountName = 'sa${replace(workload, '-', '')}'
var searchServiceName = 'search-${workload}'
var openAiName = 'openai-${workload}'

resource storageAccount 'Microsoft.Storage/storageAccounts@2023-01-01' = {
  #disable-next-line BCP334
  name: storageAccountName
  location: location
  sku: {
    name: 'Standard_LRS'
  }
  kind: 'StorageV2'
  properties: {
    accessTier: 'Hot'
    allowBlobPublicAccess: true
    allowCrossTenantReplication: true
    minimumTlsVersion: 'TLS1_2'
    dnsEndpointType: 'Standard'
    defaultToOAuthAuthentication: false
    supportsHttpsTrafficOnly: true
  }
}

resource storageAccountContainer 'Microsoft.Storage/storageAccounts/blobServices/containers@2021-09-01' = {
  name: '${storageAccountName}/default/ado'
  properties: {
    publicAccess: 'None'
  }
}

resource searchService 'Microsoft.Search/searchServices@2023-11-01' = {
  name: searchServiceName
  location: location
  sku: {
    name: 'standard'
  }
  properties: {
    replicaCount: 1
    partitionCount: 1
    semanticSearch: 'standard'
  }
  identity: {
    type: 'SystemAssigned'
  }
}

module searchServiceRoleAssignment 'searchServiceRoleAssignment.bicep' = {
  name: '${deployment().name}-roles'
  params: {
    searchServiceName: searchServiceName
    principalId: searchService.identity.principalId
  }
}

resource openAi 'Microsoft.CognitiveServices/accounts@2023-05-01' = {
  name: openAiName
  location: location
  kind: 'OpenAI'
  sku: {
    name: 'S0'
  }
  properties: {
    customSubDomainName: toLower(openAiName)
  }
}

output storageAccountName string = storageAccount.name
output searchServiceName string = searchService.name
output searchServiceUrl string = 'https://${searchService.name}.search.windows.net'
output openAiName string = openAi.name
output openAiUrl string = openAi.properties.endpoint
