.DEFAULT_GOAL := help

# Shell to use with Make
SHELL ?= /bin/bash
ROOT_PATH := $(PWD)/$({0%/*})

GCLOUD_IMAGE_TAG    ?= 206.0.0-alpine
GCP_CREDENTIALS     ?= $$HOME/Git/keypairs/gce/gcp.json
GCP_ZONE            ?= europe-west1-b
GCP_PROJECT_ID      ?= bbva-ialabs-poc

GKE_CLUSTER_VERSION ?= 1.10.4-gke.2
GKE_CLUSTER_NAME    ?= pachyderm
GKE_NUM_NODES       ?= 4
GKE_MACHINE_TYPE    ?= n1-standard-8

STORAGE_SIZE        ?= 10
BUCKET_NAME         ?= pachyderm-poc

VERSION_PACHYDERM   ?= 1.7.4
VERSION_KUBEFLOW    ?= 0.2.2

UNAME := $(shell uname -s)
ifeq ($(UNAME),Linux)
OPEN := xdg-open
else
OPEN := open
endif

.PHONY: help
help: ## Show this help
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | sort | awk 'BEGIN {FS = ":.*?## "}; {printf "\033[36m%-30s\033[0m %s\n", $$1, $$2}'

.PHONY: pachyderm-client
pachyderm-client: ## Install pachyderm client
	curl -o /tmp/pachctl.tar.gz -L https://github.com/pachyderm/pachyderm/releases/download/v1.7.3/pachctl_$(VERSION_PACHYDERM)_linux_amd64.tar.gz \
	  && tar -xvf /tmp/pachctl.tar.gz -C /tmp \
	  && sudo cp /tmp/pachctl_$(VERSION_PACHYDERM)_linux_amd64/pachctl /usr/local/bin

.PHONY: gke-bastion
gke-bastion: ## Run a gke-bastion container.
	@docker run -it -d --name gke-bastion-pachy \
	   -p 8080:8080 -p 8000:8000\
	   -v $(GCP_CREDENTIALS):/tmp/gcp.json \
	   -v $(shell pwd):/tmp/
	   google/cloud-sdk:$(GCLOUD_IMAGE_TAG) \
	   sh
	@docker exec gke-bastion-pachy \
	   sh -c "gcloud components install kubectl beta --quiet \
	          && gcloud auth activate-service-account --key-file=/tmp/gcp.json"
	@docker exec gke-bastion-pachy \
	   sh -c "gcloud config set project $(GCP_PROJECT_ID)"

.PHONY: gke-create-cluster
gke-create-cluster: ## Create a kubernetes cluster on GKE.
	@docker exec gke-bastion-pachy \
	   sh -c "gcloud container --project $(GCP_PROJECT_ID) clusters create $(GKE_CLUSTER_NAME) --zone "$(GCP_ZONE)" \
	          --username "admin" --cluster-version "$(GKE_CLUSTER_VERSION)" --machine-type $(GKE_MACHINE_TYPE) \
	          --image-type "COS" --disk-type "pd-standard" --disk-size "100" \
	          --scopes "compute-rw","storage-rw","logging-write","monitoring","service-control","service-management","trace" \
	          --num-nodes $(GKE_NUM_NODES) --enable-cloud-logging --enable-cloud-monitoring --network "default" \
	          --subnetwork "default" --addons HorizontalPodAutoscaling,HttpLoadBalancing,KubernetesDashboard"
	@docker exec gke-bastion-pachy \
	   sh -c "gcloud container clusters get-credentials $(GKE_CLUSTER_NAME) --zone "$(GCP_ZONE)" --project $(GCP_PROJECT_ID) \
	          && kubectl config set-credentials gke_$(GCP_PROJECT_ID)_$(GCP_ZONE)_$(GKE_CLUSTER_NAME) --username=admin \
	          --password=$$(gcloud container clusters describe $(GKE_CLUSTER_NAME) --zone $(GCP_ZONE) | grep password | awk '{print $$2}')"
	@docker exec gke-bastion-pachy \
	   sh -c "kubectl apply -f https://raw.githubusercontent.com/GoogleCloudPlatform/container-engine-accelerators/stable/nvidia-driver-installer/cos/daemonset-preloaded.yaml"
	@docker exec gke-bastion-pachy \
	   sh -c "apk --update add jq && \
	          rm -rf /var/lib/apt/lists/* && \
	          rm /var/cache/apk/*"

.PHONY: install-pachy-cli
install-pachy-cli: ## Install pachctl.
	@docker exec gke-bastion-pachy \
	   sh -c "curl -Lo pachctl_$(VERSION_PACHYDERM)_linux_amd64.tar.gz \
	   https://github.com/pachyderm/pachyderm/releases/download/v$(VERSION_PACHYDERM)/pachctl_$(VERSION_PACHYDERM)_linux_amd64.tar.gz \
	   && tar -xvf pachctl_$(VERSION_PACHYDERM)_linux_amd64.tar.gz \
	   && chmod +x pachctl_$(VERSION_PACHYDERM)_linux_amd64/pachctl && mv pachctl_$(VERSION_PACHYDERM)_linux_amd64/pachctl /usr/local/bin/"

.PHONY: install-pachy-dash
install-pachy-dash: ## Install pachctl dash.
	@docker exec gke-bastion-pachy \
	   sh -c 'pachctl deploy local --dashboard-only'

.PHONY: deploy-kubeflow
deploy-kubeflow: ## Deploy kubeflow on cluster using ksonnet.
	@docker exec gke-bastion-pachy \
	   sh -c 'GITHUB_TOKEN=$(GITHUB_TOKEN) VERSION_KUBEFLOW=$(VERSION_KUBEFLOW) /tmp/kubeflow.sh'

.PHONY: portforward-kubeflow
portforward-kubeflow: ## Port forwarding kubeflow ports.
	@docker exec gke-bastion-pachy \
	   sh -c 'kubectl -n kubeflow port-forward $$(kubectl -n kubeflow get pods --selector=service=ambassador | awk "'"{print $1}"'" | tail -1) 8080:80 2>&1 >/dev/null &  &&\
	          kubectl -n kubeflow port-forward $$(kubectl -n kubeflow get pods --selector=app=tf-hub | awk "'"{print $1}"'" | tail -1) 8000:8000 2>&1 >/dev/null &'

.PHONY: deploy-pachyderm
deploy-pachyderm: ## Deploy pachyderm on cluster using ksonnet.
	@docker exec gke-bastion-pachy \
	   sh -c 'BUCKET_NAME=$(BUCKET_NAME) VERSION_KUBEFLOW=$(VERSION_KUBEFLOW) /tmp/pachyderm.sh'

.PHONY: gke-delete-cluster
gke-delete-cluster: ## Delete a kubernetes cluster on GKE.
	@docker exec gke-bastion-pachy \
	   sh -c "gcloud config set project $(GCP_PROJECT_ID) \
	          && gcloud container --project $(GCP_PROJECT_ID) clusters delete $(GKE_CLUSTER_NAME) \
	          --zone $(GCP_ZONE) --quiet"

.PHONY: pachyderm-set-lb
pachyderm-set-lb: ## Configure pachyderm load balancer.
	@docker exec gke-bastion-pachy \
	   sh -c "kubectl patch svc/pachd --patch '{ \"spec\" : { \"type\": \"LoadBalancer\"}}'"

.PHONY: pachyderm-get-lb
pachyderm-get-lb: ## Get pachyderm load balancer ip.
	@docker exec gke-bastion-pachy \
	   sh -c "echo \"type: export ADDRESS=$$(kubectl get svc pachd -o jsonpath='{.status.loadBalancer.ingress[0].ip}'):650\""

.PHONY: kubeflow-ui
kubeflow-ui: ## Launch kubeflow dashboard
	$(OPEN) https://localhost:8080

.PHONY: pachyderm-ui
pachyderm-ui: ## Launch pachyderm dashboard
	pachctl port-forward &
	$(OPEN) https://localhost:30080

