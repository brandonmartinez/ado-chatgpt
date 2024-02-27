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
SRC_DIR="$WORKING_DIR/src"
TEMPLATE_DIR="$WORKING_DIR/templates"
TEMP_DIR="$WORKING_DIR/.temp"
TEMP_BICEP_DIR="$TEMP_DIR/bicep"
TEMP_REST_DIR="$TEMP_DIR/rest"
TEMP_WORKITEM_DIR="$TEMP_DIR/workitems"

mkdir -p "$TEMP_BICEP_DIR" "$TEMP_REST_DIR" "$TEMP_WORKITEM_DIR"

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
    envsubst < "$TEMPLATE_DIR/main.parameters.json" > "$TEMP_BICEP_DIR/main.parameters.json"

    logmsg "Creating resource group $AZURE_RESOURCEGROUP if it does not exist" "INFO"
    az group create --name "$AZURE_RESOURCEGROUP" --location "$AZURE_LOCATION"

    logmsg "Initiating the Bicep deployment of infrastructure" "INFO"
    AZ_DEPLOYMENT_TIMESTAMP=$(date +"%Y-%m-%d-%H-%M-%S")

    AZ_DEPLOYMENT_NAME="ADO-AI-$AZ_DEPLOYMENT_TIMESTAMP"
    output=$(az deployment group create \
        -n "$AZ_DEPLOYMENT_NAME" \
        --template-file "$SRC_DIR/main.bicep" \
        --parameters "$TEMP_BICEP_DIR/main.parameters.json" \
        -g "$AZURE_RESOURCEGROUP" \
        --query 'properties.outputs')

    export AZURE_STORAGEACCOUNT_NAME=$(echo "$output" | jq -r '.storageAccountName.value')
    export AZURE_SEARCHSERVICE_NAME=$(echo "$output" | jq -r '.searchServiceName.value')
    export AZURE_SEARCHSERVICE_URL=$(echo "$output" | jq -r '.searchServiceUrl.value')
    export AZURE_OPENAI_NAME=$(echo "$output" | jq -r '.openAiName.value')
    export AZURE_OPENAI_URL=$(echo "$output" | jq -r '.openAiUrl.value')

    logmsg "Getting Admin keys for Azure Search and OpenAI" "INFO"
    export AZURE_SEARCHSERVICE_ADMINKEY=$(az search admin-key show --service-name "$AZURE_SEARCHSERVICE_NAME" --query "primaryKey" --output tsv)
    export AZURE_OPENAI_KEY=$(az cognitiveservices account keys list --name "$AZURE_OPENAI_NAME" --query "key1" --output tsv)

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

    envsubst < "$TEMPLATE_DIR/openai-model.json" > "$TEMP_REST_DIR/openai-model.json"
    curl -X PUT https://management.azure.com/subscriptions/$AZURE_SUBSCRIPTIONID/resourceGroups/$AZURE_RESOURCEGROUP/providers/Microsoft.CognitiveServices/accounts/$AZURE_OPENAI_NAME/deployments/$AZURE_OPENAI_MODELNAME-$AZURE_OPENAI_MODELVERSION?api-version=2023-05-01 \
        -H "Content-Type: application/json" \
        -H "Authorization: Bearer $AZURE_AUTHTOKEN" \
        --data-binary "@$TEMP_REST_DIR/openai-model.json"

    logmsg "Deploying Open AI model $AZURE_OPENAI_EMBEDDINGMODELNAME($AZURE_OPENAI_EMBEDDINGMODELVERSION)" "INFO"

    envsubst < "$TEMPLATE_DIR/openai-embeddingmodel.json" > "$TEMP_REST_DIR/openai-embeddingmodel.json"
    curl -X PUT https://management.azure.com/subscriptions/$AZURE_SUBSCRIPTIONID/resourceGroups/$AZURE_RESOURCEGROUP/providers/Microsoft.CognitiveServices/accounts/$AZURE_OPENAI_NAME/deployments/$AZURE_OPENAI_EMBEDDINGMODELNAME-$AZURE_OPENAI_EMBEDDINGMODELVERSION?api-version=2023-05-01 \
        -H "Content-Type: application/json" \
        -H "Authorization: Bearer $AZURE_AUTHTOKEN" \
        --data-binary "@$TEMP_REST_DIR/openai-embeddingmodel.json"
fi

# Setting up Azure Search Index
##################################################
if [[ "$SKIP_SEARCH_INDEXSETUP" == "1" ]]; then
    logmsg "Skipping search indexes setup" "INFO"
else
    logmsg "Creating search indexes" "HEADER"

    logmsg "Creating ado-index search index" "INFO"

    envsubst < "$TEMPLATE_DIR/search-ado-index.json" > "$TEMP_REST_DIR/search-ado-index.json"
    curl -X PUT "https://$AZURE_SEARCHSERVICE_NAME.search.windows.net/indexes/ado-index?api-version=2023-10-01-Preview" \
        -H "api-key: $AZURE_SEARCHSERVICE_ADMINKEY" \
        -H "Content-Type: application/json" \
        --data-binary "@$TEMP_REST_DIR/search-ado-index.json"

    logmsg "Creating ado-vector-index search index" "INFO"

    envsubst < "$TEMPLATE_DIR/search-ado-vector-index.json" > "$TEMP_REST_DIR/search-ado-vector-index.json"
    curl -X PUT "https://$AZURE_SEARCHSERVICE_NAME.search.windows.net/indexes/ado-vector-index?api-version=2023-10-01-Preview" \
        -H "api-key: $AZURE_SEARCHSERVICE_ADMINKEY" \
        -H "Content-Type: application/json" \
        --data-binary "@$TEMP_REST_DIR/search-ado-vector-index.json"

    logmsg "Finished creating search index"
fi

# Setting up Azure Search Data Source for Storage
##################################################
if [[ "$SKIP_SEARCH_DATASOURCESETUP" == "1" ]]; then
    logmsg "Skipping search data source setup" "INFO"
else
    logmsg "Creating search data source for storage account" "HEADER"

    envsubst < "$TEMPLATE_DIR/search-datasource.json" > "$TEMP_REST_DIR/search-datasource.json"
    curl -X POST "https://$AZURE_SEARCHSERVICE_NAME.search.windows.net/datasources?api-version=2023-10-01-Preview" \
        -H "api-key: $AZURE_SEARCHSERVICE_ADMINKEY" \
        -H "Content-Type: application/json" \
        --data-binary "@$TEMP_REST_DIR/search-datasource.json"

    logmsg "Finished creating search data source"
fi

# Setting up Azure Search Skillsets
##################################################
if [[ "$SKIP_SEARCH_SKILLSETSETUP" == "1" ]]; then
    logmsg "Skipping search skillset setup" "INFO"
else
    logmsg "Creating search skillset" "HEADER"

    envsubst < "$TEMPLATE_DIR/search-ado-vector-skillset.json" > "$TEMP_REST_DIR/search-ado-vector-skillset.json"
    curl -X PUT "https://$AZURE_SEARCHSERVICE_NAME.search.windows.net/skillsets/ado-vector-skillset?api-version=2023-10-01-Preview" \
        -H "api-key: $AZURE_SEARCHSERVICE_ADMINKEY" \
        -H "Content-Type: application/json" \
        --data-binary "@$TEMP_REST_DIR/search-ado-vector-skillset.json"

    logmsg "Finished creating search data source"
fi

# Setting up Azure Search Indexer against Storage
##################################################
if [[ "$SKIP_SEARCH_INDEXERSETUP" == "1" ]]; then
    logmsg "Skipping search indexers setup" "INFO"
else
    logmsg "Creating search indexers against storage account" "HEADER"

    logmsg "Creating ado-indexer search indexer against storage account" "INFO"

    envsubst < "$TEMPLATE_DIR/search-ado-indexer.json" > "$TEMP_REST_DIR/search-ado-indexer.json"
    curl -X POST "https://$AZURE_SEARCHSERVICE_NAME.search.windows.net/indexers?api-version=2023-10-01-Preview" \
        -H "api-key: $AZURE_SEARCHSERVICE_ADMINKEY" \
        -H "Content-Type: application/json" \
        --data-binary "@$TEMP_REST_DIR/search-ado-indexer.json"

    logmsg "Creating ado-vector-indexer search indexer against storage account" "INFO"

    envsubst < "$TEMPLATE_DIR/search-ado-vector-indexer.json" > "$TEMP_REST_DIR/search-ado-vector-indexer.json"
    curl -X POST "https://$AZURE_SEARCHSERVICE_NAME.search.windows.net/indexers?api-version=2023-10-01-Preview" \
        -H "api-key: $AZURE_SEARCHSERVICE_ADMINKEY" \
        -H "Content-Type: application/json" \
        --data-binary "@$TEMP_REST_DIR/search-ado-vector-indexer.json"

    logmsg "Finished creating search indexer"
fi
