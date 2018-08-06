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
	   -p 8002:8002 -p 30080:30080 \
	   -v $(GCP_CREDENTIALS):/tmp/gcp.json \
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

.PHONY: preconfigure-bucket
preconfigure-bucket: ##
	@docker exec gke-bastion-pachy \
	   sh -c 'gsutil ls gs://pachyderm-poc > /dev/null 2>&1 || gsutil mb gs://$(BUCKET_NAME)'

.PHONY: install-cli
install-cli: ## Install pachctl.
	@docker exec gke-bastion-pachy \
	   sh -c "curl -Lo pachctl_$(VERSION_PACHYDERM)_linux_amd64.tar.gz \
	   https://github.com/pachyderm/pachyderm/releases/download/v$(VERSION_PACHYDERM)/pachctl_$(VERSION_PACHYDERM)_linux_amd64.tar.gz \
	   && tar -xvf pachctl_$(VERSION_PACHYDERM)_linux_amd64.tar.gz \
	   && chmod +x pachctl_$(VERSION_PACHYDERM)_linux_amd64/pachctl && mv pachctl_$(VERSION_PACHYDERM)_linux_amd64/pachctl /usr/local/bin/"

.PHONY: deploy-pachyderm
deploy-pachyderm: preconfigure-bucket install-cli ## Deploy pachyderm on cluster using its cli.
	@docker exec gke-bastion-pachy \
	   sh -c "pachctl deploy google $(BUCKET_NAME) $(STORAGE_SIZE) --dynamic-etcd-nodes=1"

.PHONY: pachyderm-ui ## TODO: command client require an argument to set the bind host
pachyderm-ui: ## Launch pachyderm dashboard through the proxy.
	@docker exec gke-bastion-pachy \
	   sh -c "pachctl port-forward &"
	$(OPEN) http://127.0.0.1:30080

.PHONY: gke-delete-cluster
gke-delete-cluster: ## Delete a kubernetes cluster on GKE.
	@docker exec gke-bastion-pachy \
	   sh -c "gcloud config set project $(GCP_PROJECT_ID) \
	          && gcloud container --project $(GCP_PROJECT_ID) clusters delete $(GKE_CLUSTER_NAME) \
	          --zone $(GCP_ZONE) --quiet"

.PHONY: pachyderm-set-lbs
pachyderm-set-lbs: ## Configure pachyderm load balancer for dashboard and pachyderm service.
	@docker exec gke-bastion-pachy \
	   sh -c "kubectl patch svc/pachd --patch '{ \"spec\" : { \"type\": \"LoadBalancer\"}}' && \
	          kubectl patch svc/dash --patch '{ \"spec\" : { \"type\": \"LoadBalancer\"}}'

.PHONY: pachyderm-get-lbs
pachyderm-get-lbs: ## Get pachyderm load balancer ips.
	@docker exec gke-bastion-pachy \
	   sh -c 'for svc in dash pachd; \
	          do echo "$$svc --> $$(kubectl get svc $$svc -o jsonpath="'"{.status.loadBalancer.ingress[0].ip}"'")"; done'
