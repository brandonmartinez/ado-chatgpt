# ADO ChatGPT

A ChatGPT-like experience to query over work item data within an Azure DevOps
organization.

## Pre-requisites

To run this sample in its entirety, you need the following:

- a bash-like shell (e.g. Git Bash, WSL, etc.)
- an Azure DevOps organization and team project from which data will be exported
- An Azure DevOps Personal Access Token (PAT) with work-item read access
- an Azure subscription, with access to [Open AI](https://aka.ms/oai/access)
- az cli installed and logged in to your Azure subscription

## Configuration

Duplicate the `.envsample` file and rename it to `.env`. Fill in the values for
all of the required environment variables.

## Deploy the Sample

Execute the following commands to deploy the sample:

```bash

deploy.sh

```

## References and Additional Resources

- This sample is heavily based off this article:
  [Chat with your Azure DevOps data | Microsoft Tech Communities](https://techcommunity.microsoft.com/t5/fasttrack-for-azure/chat-with-your-azure-devops-data/ba-p/4017784)
- Which itself is based off this sample:
  [Preview - Sample Chat App with AOAI | GitHub](https://github.com/microsoft/sample-app-aoai-chatGPT)
