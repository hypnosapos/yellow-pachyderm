#!/usr/bin/env bash

set -e

gsutil ls gs://pachyderm-poc > /dev/null 2>&1 || gsutil mb gs://${BUCKET_NAME}

kubectl create secret generic \
	pachyderm-storage-secret \
	--from-file=google-cred=/tmp/gcp.json \
	--from-literal=google-bucket=${BUCKET_NAME}

ks init pachyderm
cd pachyderm

ks env set default --namespace default

# Install Kubeflow components
ks registry add kubeflow github.com/kubeflow/kubeflow/tree/v${VERSION_KUBEFLOW}/kubeflow

ks pkg install kubeflow/pachyderm

ks generate pachyderm pachyderm

ks param set pachyderm backend gcp
ks apply default -c pachyderm
