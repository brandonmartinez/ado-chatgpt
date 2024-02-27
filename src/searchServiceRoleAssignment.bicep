@description('The name of the Azure Search service.')
param searchServiceName string

@description('The principal ID type of the Container Registry.')
param principalId string

resource searchService 'Microsoft.Search/searchServices@2023-11-01' existing = {
  name: searchServiceName
}

@description('This is the built-in Contributor role. See https://docs.microsoft.com/azure/role-based-access-control/built-in-roles#contributor')
resource storageBlobDataReaderRoleDefinition 'Microsoft.Authorization/roleDefinitions@2018-01-01-preview' existing = {
  scope: subscription()
  name: 'ba92f5b4-2d11-453d-a403-e96b0029c9fe'
}

resource roleAssignment 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  scope: searchService
  name: guid(searchService.id, principalId, storageBlobDataReaderRoleDefinition.id)
  properties: {
    principalType: 'ServicePrincipal'
    principalId: principalId
    roleDefinitionId: storageBlobDataReaderRoleDefinition.id
  }
}
