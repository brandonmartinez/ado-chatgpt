#!/usr/bin/env bash

# Function to stylize echo as INFO or ERROR
function logmsg() {
    local message=$1
    local style=$2

    if [[ $style == "HEADER" ]]; then
        echo ''
        echo -e "\033[0;33m$message\033[0m" | fold -w 100 -s # Yellow text with word wrapping
        echo -e "**************************************************" # 50 blue asterisks
        echo ''
    elif [[ $style == "INFO" ]]; then
        echo -e "\033[0;37m$message\033[0m" | fold -w 100 -s # Light gray text with word wrapping
    elif [[ $style == "ERROR" ]]; then
        echo -e "\033[0;31m$message\033[0m" | fold -w 100 -s # Red text with word wrapping
    else
        echo $message | fold -w 50 # Word wrapping for other styles
    fi
}

# Checking for pre-reqs
##################################################

logmsg "Checking for pre-requisites" "HEADER"

if ! command -v az &> /dev/null; then
    logmsg "Azure CLI is not installed" "ERROR"
    exit 1
fi

if ! az extension show --name azure-devops &> /dev/null; then
    logmsg "Azure DevOps extension is not installed" "ERROR"
    exit 1
fi

logmsg "All pre-requisites are installed"

# Prepare env configuration
##################################################

logmsg "Preparing environment configuration" "HEADER"

if [ ! -f .env ]; then
    cp .envsample .env
    logmsg "Update .env with parameter values and run again" "ERROR"
    exit 1
fi

# import env variables, export them to be available in subshells
set -a
source .env
export AZURE_RESOURCEGROUP="rg-$AZURE_WORKLOAD"
set +a

# setting up temporary directories
# Create a variable of the current working directory based on the current file
WORKING_DIR=$(dirname "$(realpath "$0")")
TEMP_DIR="$WORKING_DIR/.temp"
TEMP_WORKITEM_DIR="$TEMP_DIR/workitems"

mkdir -p "$TEMP_WORKITEM_DIR"

logmsg "Environment configuration completed"

# Login to Azure
##################################################
logmsg "Preparing Azure configuration" "HEADER"

if ! az account show &> /dev/null; then
    az login
fi

logmsg "Setting Azure subscription to $AZURE_SUBSCRIPTIONID" "INFO"
az account set --subscription "$AZURE_SUBSCRIPTIONID"

logmsg "Setting default location to $AZURE_LOCATION and resource group to $AZURE_RESOURCEGROUP" "INFO"
az configure --defaults location="$AZURE_LOCATION" group="$AZURE_RESOURCEGROUP"

# Store auth token from az cli to AZURE_AUTHTOKEN
AZURE_AUTHTOKEN=$(az account get-access-token --query 'accessToken' -o tsv)

logmsg "Azure configuration completed"

# Execute IaC deployment
##################################################
if [[ "$SKIP_INFRASTRUCTURE" == "1" ]]; then
    logmsg "Skipping infrastructure deployment" "INFO"
else
    logmsg "Starting Azure infrastructure deployment" "HEADER"

    logmsg "Token substitution of environment variables to Bicep parameters" "INFO"
    envsubst < src/main.parameters.template.json > src/main.parameters.json

    logmsg "Creating resource group $AZURE_RESOURCEGROUP if it does not exist" "INFO"
    az group create --name "$AZURE_RESOURCEGROUP" --location "$AZURE_LOCATION"

    logmsg "Initiating the Bicep deployment of infrastructure" "INFO"
    AZ_DEPLOYMENT_TIMESTAMP=$(date +"%Y-%m-%d-%H-%M-%S")

    deployment_name="ADO-AI-Deployment-$AZ_DEPLOYMENT_TIMESTAMP"
    output=$(az deployment group create \
        -n "$deployment_name" \
        --template-file src/main.bicep \
        --parameters src/main.parameters.json \
        -g "$AZURE_RESOURCEGROUP" \
        --query 'properties.outputs')

    AZURE_STORAGEACCOUNT_NAME=$(echo "$output" | jq -r '.storageAccountName.value')
    AZURE_STORAGEACCOUNT_CONNECTIONSTRING=$(echo "$output" | jq -r '.storageAccountConnectionString.value')
    AZURE_SEARCHSERVICE_NAME=$(echo "$output" | jq -r '.searchServiceName.value')
    AZURE_SEARCHSERVICE_URL=$(echo "$output" | jq -r '.searchServiceUrl.value')
    AZURE_SEARCHSERVICE_ADMINKEY=$(echo "$output" | jq -r '.searchServiceAdminKey.value')
    AZURE_OPENAI_NAME=$(echo "$output" | jq -r '.openAiName.value')
    AZURE_OPENAI_URL=$(echo "$output" | jq -r '.openAiUrl.value')
    AZURE_OPENAI_KEY=$(echo "$output" | jq -r '.openAiKey.value')

    logmsg "Azure infrastructure deployment completed"
fi

# Capturing ADO work items to export to storage
##################################################
if [[ "$SKIP_ADO_DOWNLOAD" == "1" ]]; then
    logmsg "Skipping ADO work item export" "INFO"
else
    logmsg "Export ADO work items to temporary working directory" "HEADER"

    logmsg "Setting Azure DevOps az configuration" "INFO"
    IFS=',' read -ra ADO_QUERIES <<< "$ADO_QUERIES"

    az devops configure --defaults organization=https://dev.azure.com/$ADO_ORG/ project=$ADO_PROJECT

    for ADO_QUERYID in "${ADO_QUERIES[@]}"; do
        logmsg "Exporting ADO work items from query $ADO_QUERYID" "INFO"
        ADO_WORKITEM_IDS=$(az boards query --id $ADO_QUERYID --query '[].id' -o tsv)

        batch_size=10
        count=0

        for ADO_WORKITEM_ID in $ADO_WORKITEM_IDS; do
            ADO_WORKITEM_FILENAME="$TEMP_WORKITEM_DIR/$ADO_WORKITEM_ID.json"
            az boards work-item show --id $ADO_WORKITEM_ID -o json --query $ADO_RECORDFORMAT > $ADO_WORKITEM_FILENAME &
            count=$((count + 1))
            if [ $((count % batch_size)) -eq 0 ]; then
                wait
            fi
        done

        wait
    done

    logmsg "Finished ADO work item export"
fi

# Uploading exported ADO work items
##################################################
if [[ "$SKIP_ADO_UPLOAD" == "1" ]]; then
    logmsg "Skipping ADO work item upload to Azure Storage" "INFO"
else
    logmsg "Import ADO work items to storage account $AZURE_STORAGEACCOUNT_NAME" "HEADER"

    az storage blob upload-batch --account-name "$AZURE_STORAGEACCOUNT_NAME" -d 'ado' -s "$TEMP_WORKITEM_DIR/" --overwrite

    logmsg "Finished ADO work item import"
fi

# Deploying Open AI model
##################################################
if [[ "$SKIP_OPENAI_MODELSETUP" == "1" ]]; then
    logmsg "Skipping Azure Open AI model deployment" "INFO"
else
    logmsg "Deploying Open AI models" "HEADER"

    logmsg "Deploying Open AI model $AZURE_OPENAI_MODELNAME($AZURE_OPENAI_MODELVERSION)" "INFO"

    curl -X PUT https://management.azure.com/subscriptions/$AZURE_SUBSCRIPTIONID/resourceGroups/$AZURE_RESOURCEGROUP/providers/Microsoft.CognitiveServices/accounts/$AZURE_OPENAI_NAME/deployments/$AZURE_OPENAI_MODELNAME-$AZURE_OPENAI_MODELVERSION?api-version=2023-05-01 \
        -H "Content-Type: application/json" \
        -H "Authorization: Bearer $AZURE_AUTHTOKEN" \
        --data-binary @- << EOF
{
    "sku": {
        "name": "Standard",
        "capacity": 120
    },
    "properties": {
        "model": {
            "format": "OpenAI",
            "name": "$AZURE_OPENAI_MODELNAME",
            "version": "$AZURE_OPENAI_MODELVERSION"
        },
        "versionUpgradeOption": "OnceCurrentVersionExpired"
    }
}
EOF

    logmsg "Deploying Open AI model $AZURE_OPENAI_EMBEDDINGMODELNAME($AZURE_OPENAI_EMBEDDINGMODELVERSION)" "INFO"

    curl -X PUT https://management.azure.com/subscriptions/$AZURE_SUBSCRIPTIONID/resourceGroups/$AZURE_RESOURCEGROUP/providers/Microsoft.CognitiveServices/accounts/$AZURE_OPENAI_NAME/deployments/$AZURE_OPENAI_EMBEDDINGMODELNAME-$AZURE_OPENAI_EMBEDDINGMODELVERSION?api-version=2023-05-01 \
        -H "Content-Type: application/json" \
        -H "Authorization: Bearer $AZURE_AUTHTOKEN" \
        --data-binary @- << EOF
{
    "sku": {
        "name": "Standard",
        "capacity": 120
    },
    "properties": {
        "model": {
            "format": "OpenAI",
            "name": "$AZURE_OPENAI_EMBEDDINGMODELNAME",
            "version": "$AZURE_OPENAI_EMBEDDINGMODELVERSION"
        },
        "versionUpgradeOption": "OnceCurrentVersionExpired"
    }
}
EOF
fi

# Setting up Azure Search Index
##################################################
if [[ "$SKIP_SEARCH_INDEXSETUP" == "1" ]]; then
    logmsg "Skipping search indexes setup" "INFO"
else
    logmsg "Creating search indexes" "HEADER"

    logmsg "Creating ado-index search index" "INFO"
    curl -X PUT "https://$AZURE_SEARCHSERVICE_NAME.search.windows.net/indexes/ado-index?api-version=2023-10-01-Preview" \
        -H "api-key: $AZURE_SEARCHSERVICE_ADMINKEY" \
        -H "Content-Type: application/json" \
        --data-binary @- << EOF
{
    "name": "ado-index",
    "fields": [
        {
            "name": "Id",
            "type": "Edm.String",
            "key": true,
            "filterable": true
        },
        {
            "name": "AreaPath",
            "type": "Edm.String",
            "filterable": true
        },
        {
            "name": "AssignedTo",
            "type": "Edm.String",
            "filterable": true
        },
        {
            "name": "Categories",
            "type": "Edm.String"
        },
        {
            "name": "ChangedDate",
            "type": "Edm.DateTimeOffset"
        },
        {
            "name": "ClosedDate",
            "type": "Edm.DateTimeOffset"
        },
        {
            "name": "CreatedDate",
            "type": "Edm.DateTimeOffset"
        },
        {
            "name": "StateChangeDate",
            "type": "Edm.DateTimeOffset"
        },
        {
            "name": "Description",
            "type": "Edm.String",
            "analyzer": "en.lucene"
        },
        {
            "name": "State",
            "type": "Edm.String",
            "filterable": true
        },
        {
            "name": "Tags",
            "type": "Edm.String",
            "filterable": true
        },
        {
            "name": "Title",
            "type": "Edm.String",
            "filterable": true
        }
    ],
    "corsOptions": {
        "allowedOrigins": [
            "*"
        ],
        "maxAgeInSeconds": 300
    }
}
EOF

    logmsg "Creating ado-vector-index search index" "INFO"
    curl -X PUT "https://$AZURE_SEARCHSERVICE_NAME.search.windows.net/indexes/ado-vector-index?api-version=2023-10-01-Preview" \
        -H "api-key: $AZURE_SEARCHSERVICE_ADMINKEY" \
        -H "Content-Type: application/json" \
        --data-binary @- << EOF
{
  "name": "ado-vector-index",
  "defaultScoringProfile": null,
  "fields": [
    {
      "name": "chunk_id",
      "type": "Edm.String",
      "searchable": true,
      "filterable": true,
      "retrievable": true,
      "sortable": true,
      "facetable": true,
      "key": true,
      "indexAnalyzer": null,
      "searchAnalyzer": null,
      "analyzer": "keyword",
      "normalizer": null,
      "dimensions": null,
      "vectorSearchProfile": null,
      "synonymMaps": []
    },
    {
      "name": "parent_id",
      "type": "Edm.String",
      "searchable": true,
      "filterable": true,
      "retrievable": true,
      "sortable": true,
      "facetable": true,
      "key": false,
      "indexAnalyzer": null,
      "searchAnalyzer": null,
      "analyzer": null,
      "normalizer": null,
      "dimensions": null,
      "vectorSearchProfile": null,
      "synonymMaps": []
    },
    {
      "name": "chunk",
      "type": "Edm.String",
      "searchable": true,
      "filterable": false,
      "retrievable": true,
      "sortable": false,
      "facetable": false,
      "key": false,
      "indexAnalyzer": null,
      "searchAnalyzer": null,
      "analyzer": null,
      "normalizer": null,
      "dimensions": null,
      "vectorSearchProfile": null,
      "synonymMaps": []
    },
    {
      "name": "title",
      "type": "Edm.String",
      "searchable": true,
      "filterable": true,
      "retrievable": true,
      "sortable": false,
      "facetable": false,
      "key": false,
      "indexAnalyzer": null,
      "searchAnalyzer": null,
      "analyzer": null,
      "normalizer": null,
      "dimensions": null,
      "vectorSearchProfile": null,
      "synonymMaps": []
    },
    {
      "name": "vector",
      "type": "Collection(Edm.Single)",
      "searchable": true,
      "filterable": false,
      "retrievable": true,
      "sortable": false,
      "facetable": false,
      "key": false,
      "indexAnalyzer": null,
      "searchAnalyzer": null,
      "analyzer": null,
      "normalizer": null,
      "dimensions": 1536,
      "vectorSearchProfile": "ado-vector-profile",
      "synonymMaps": []
    }
  ],
  "scoringProfiles": [],
  "corsOptions": null,
  "suggesters": [],
  "analyzers": [],
  "normalizers": [],
  "tokenizers": [],
  "tokenFilters": [],
  "charFilters": [],
  "encryptionKey": null,
  "similarity": {
    "@odata.type": "#Microsoft.Azure.Search.BM25Similarity",
    "k1": null,
    "b": null
  },
  "semantic": {
    "defaultConfiguration": "ado-vector-semantic-configuration",
    "configurations": [
      {
        "name": "ado-vector-semantic-configuration",
        "prioritizedFields": {
          "titleField": {
            "fieldName": "title"
          },
          "prioritizedContentFields": [
            {
              "fieldName": "chunk"
            }
          ],
          "prioritizedKeywordsFields": []
        }
      }
    ]
  },
  "vectorSearch": {
    "algorithms": [
      {
        "name": "ado-vector-algorithm",
        "kind": "hnsw",
        "hnswParameters": {
          "metric": "cosine",
          "m": 4,
          "efConstruction": 400,
          "efSearch": 500
        },
        "exhaustiveKnnParameters": null
      }
    ],
    "profiles": [
      {
        "name": "ado-vector-profile",
        "algorithm": "ado-vector-algorithm",
        "vectorizer": "ado-vector-vectorizer"
      }
    ],
    "vectorizers": [
      {
        "name": "ado-vector-vectorizer",
        "kind": "azureOpenAI",
        "azureOpenAIParameters": {
          "resourceUri": "$AZURE_OPENAI_URL",
          "deploymentId": "$AZURE_OPENAI_EMBEDDINGMODELNAME-$AZURE_OPENAI_EMBEDDINGMODELVERSION",
          "apiKey": "$AZURE_OPENAI_KEY",
          "authIdentity": null
        },
        "customWebApiParameters": null
      }
    ]
  }
}
EOF

    logmsg "Finished creating search index"
fi

# Setting up Azure Search Data Source for Storage
##################################################
if [[ "$SKIP_SEARCH_DATASOURCESETUP" == "1" ]]; then
    logmsg "Skipping search data source setup" "INFO"
else
    logmsg "Creating search data source for storage account" "HEADER"

    curl -X POST "https://$AZURE_SEARCHSERVICE_NAME.search.windows.net/datasources?api-version=2023-10-01-Preview" \
        -H "api-key: $AZURE_SEARCHSERVICE_ADMINKEY" \
        -H "Content-Type: application/json" \
        --data-binary @- << EOF
{
    "name" : "$AZURE_STORAGEACCOUNT_NAME-datasource",
    "description" : "ADO data from the storage account",
    "type" : "azureblob",
    "credentials" : { "connectionString" : "$AZURE_STORAGEACCOUNT_CONNECTIONSTRING" },
    "container": {
        "name": "ado"
    }
}
EOF

    logmsg "Finished creating search data source"
fi

# Setting up Azure Search Skillsets
##################################################
if [[ "$SKIP_SEARCH_SKILLSETSETUP" == "1" ]]; then
    logmsg "Skipping search skillset setup" "INFO"
else
    logmsg "Creating search skillset" "HEADER"

    curl -X PUT "https://$AZURE_SEARCHSERVICE_NAME.search.windows.net/skillsets/ado-vector-skillset?api-version=2023-10-01-Preview" \
        -H "api-key: $AZURE_SEARCHSERVICE_ADMINKEY" \
        -H "Content-Type: application/json" \
        --data-binary @- << EOF
{
  "name": "ado-vector-skillset",
  "description": "Skillset to chunk documents and generate embeddings",
  "skills": [
    {
      "@odata.type": "#Microsoft.Skills.Text.AzureOpenAIEmbeddingSkill",
      "name": "#1",
      "description": null,
      "context": "/document/pages/*",
      "resourceUri": "$AZURE_OPENAI_URL",
      "apiKey": "$AZURE_OPENAI_KEY",
      "deploymentId": "$AZURE_OPENAI_EMBEDDINGMODELNAME-$AZURE_OPENAI_EMBEDDINGMODELVERSION",
      "inputs": [
        {
          "name": "text",
          "source": "/document/pages/*"
        }
      ],
      "outputs": [
        {
          "name": "embedding",
          "targetName": "vector"
        }
      ],
      "authIdentity": null
    },
    {
      "@odata.type": "#Microsoft.Skills.Text.SplitSkill",
      "name": "#2",
      "description": "Split skill to chunk documents",
      "context": "/document",
      "defaultLanguageCode": "en",
      "textSplitMode": "pages",
      "maximumPageLength": 2000,
      "pageOverlapLength": 500,
      "maximumPagesToTake": 0,
      "inputs": [
        {
          "name": "text",
          "source": "/document/content"
        }
      ],
      "outputs": [
        {
          "name": "textItems",
          "targetName": "pages"
        }
      ]
    }
  ],
  "cognitiveServices": null,
  "knowledgeStore": null,
  "indexProjections": {
    "selectors": [
      {
        "targetIndexName": "ado-vector-index",
        "parentKeyFieldName": "parent_id",
        "sourceContext": "/document/pages/*",
        "mappings": [
          {
            "name": "chunk",
            "source": "/document/pages/*",
            "sourceContext": null,
            "inputs": []
          },
          {
            "name": "vector",
            "source": "/document/pages/*/vector",
            "sourceContext": null,
            "inputs": []
          },
          {
            "name": "title",
            "source": "/document/metadata_storage_name",
            "sourceContext": null,
            "inputs": []
          }
        ]
      }
    ],
    "parameters": {
      "projectionMode": "skipIndexingParentDocuments"
    }
  },
  "encryptionKey": null
}
EOF

    logmsg "Finished creating search data source"
fi

# Setting up Azure Search Indexer against Storage
##################################################
if [[ "$SKIP_SEARCH_INDEXERSETUP" == "1" ]]; then
    logmsg "Skipping search indexers setup" "INFO"
else
    logmsg "Creating search indexers against storage account" "HEADER"

    logmsg "Creating ado-indexer search indexer against storage account" "INFO"
    curl -X POST "https://$AZURE_SEARCHSERVICE_NAME.search.windows.net/indexers?api-version=2023-10-01-Preview" \
        -H "api-key: $AZURE_SEARCHSERVICE_ADMINKEY" \
        -H "Content-Type: application/json" \
        --data-binary @- << EOF
{
  "name" : "ado-indexer",
  "dataSourceName" : "$AZURE_STORAGEACCOUNT_NAME-datasource",
  "targetIndexName" : "ado-index",
  "parameters": {
      "batchSize": null,
      "maxFailedItems": null,
      "maxFailedItemsPerBatch": null,
      "base64EncodeKeys": null,
      "configuration": {
          "indexedFileNameExtensions" : ".json",
          "dataToExtract": "contentAndMetadata",
          "parsingMode": "default"
      }
  },
  "schedule" : { },
  "fieldMappings" : [ ]
}
EOF

    logmsg "Creating ado-vector-indexer search indexer against storage account" "INFO"
    curl -X POST "https://$AZURE_SEARCHSERVICE_NAME.search.windows.net/indexers?api-version=2023-10-01-Preview" \
        -H "api-key: $AZURE_SEARCHSERVICE_ADMINKEY" \
        -H "Content-Type: application/json" \
        --data-binary @- << EOF
{
  "name": "ado-vector-indexer",
  "description": null,
  "dataSourceName" : "$AZURE_STORAGEACCOUNT_NAME-datasource",
  "skillsetName": "ado-vector-skillset",
  "targetIndexName": "ado-vector-index",
  "disabled": null,
  "schedule": {
    "interval": "P1D",
    "startTime": "2024-02-21T03:48:13Z"
  },
  "parameters": {
    "batchSize": null,
    "maxFailedItems": null,
    "maxFailedItemsPerBatch": null,
    "base64EncodeKeys": null,
    "configuration": {
      "dataToExtract": "contentAndMetadata",
      "parsingMode": "default"
    }
  },
  "fieldMappings": [
    {
      "sourceFieldName": "metadata_storage_name",
      "targetFieldName": "title",
      "mappingFunction": null
    }
  ],
  "outputFieldMappings": [],
  "encryptionKey": null
}
EOF

    logmsg "Finished creating search indexer"
fi
