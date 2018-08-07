#!/usr/bin/env bash

set -e


[ -z "$GITHUB_TOKEN" ] && echo "Env variable GITHUB_TOKEN not defined" && exit 1

curl -L -H "Authorization: token ${GITHUB_TOKEN}" -o ks.tar.gz $(curl -H "Authorization: token ${GITHUB_TOKEN}" -s https://api.github.com/repos/ksonnet/ksonnet/releases/latest | jq -r ".assets[] | select(.name | test(\"linux_amd64\")) | .browser_download_url")
tar -zxvf ks.tar.gz --strip-components=1 && mv ./ks /usr/local/bin/

kubectl create namespace kubeflow

# Initialize a ksonnet app. Set the namespace for default environment.
ks init kubeflow
cd kubeflow
ks env set default --namespace kubeflow

# Install Kubeflow components
ks registry add kubeflow github.com/kubeflow/kubeflow/tree/v${VERSION_KUBEFLOW}/kubeflow

ks pkg install kubeflow/argo
ks pkg install kubeflow/core
ks pkg install kubeflow/examples
ks pkg install kubeflow/katib
ks pkg install kubeflow/seldon
ks pkg install kubeflow/tf-serving

# Create templates for core components
ks generate kubeflow-core kubeflow-core

# Enable collection of anonymous usage metrics
# Skip this step if you don't want to enable collection.
ks param set kubeflow-core reportUsage false
# Uncomment this line if report usage is activated
# ks param set kubeflow-core usageId $(uuidgen)

# Deploy Kubeflow
ks apply default -c kubeflow-core

# Adding Gcloud credentials as secret
kubectl create secret generic gcloud-creds --from-file=gcp.json=/tmp/gcp.json -n kubeflow
