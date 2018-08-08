.DEFAULT_GOAL := help

# Shell to use with Make
SHELL ?= /bin/bash
ROOT_PATH := $(PWD)/$({0%/*})

CONTAINER_NAME      ?= gke-bastion

IMAGE_VERSION       ?= 0.11

GCLOUD_IMAGE_TAG    ?= 206.0.0-alpine
GCP_CREDENTIALS     ?= $$HOME/Git/keypairs/gce/gcp.json
GCP_ZONE            ?= europe-west1-b
GCP_PROJECT_ID      ?= bbva-ialabs-poc

GKE_CLUSTER_VERSION ?= 1.10.5-gke.3
GKE_CLUSTER_NAME    ?= kspachy
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
	@docker run -it -d --name $(CONTAINER_NAME) \
	   -p 8080:8080 -p 8000:8000 \
	   -v $(GCP_CREDENTIALS):/tmp/gcp.json \
	   -v $(shell pwd):/tmp \
	   google/cloud-sdk:$(GCLOUD_IMAGE_TAG) \
	   sh
	@docker exec $(CONTAINER_NAME) \
	   sh -c "gcloud components install kubectl beta --quiet \
	          && gcloud auth activate-service-account --key-file=/tmp/gcp.json"
	@docker exec $(CONTAINER_NAME) \
	   sh -c "gcloud config set project $(GCP_PROJECT_ID)"

.PHONY: gke-create-cluster
gke-create-cluster: ## Create a kubernetes cluster on GKE.
	@docker exec $(CONTAINER_NAME) \
	   sh -c "gcloud container --project $(GCP_PROJECT_ID) clusters create $(GKE_CLUSTER_NAME) --zone "$(GCP_ZONE)" \
	          --username "admin" --cluster-version "$(GKE_CLUSTER_VERSION)" --machine-type $(GKE_MACHINE_TYPE) \
	          --image-type "COS" --disk-type "pd-standard" --disk-size "100" \
	          --scopes "compute-rw","storage-rw","logging-write","monitoring","service-control","service-management","trace" \
	          --num-nodes $(GKE_NUM_NODES) --enable-cloud-logging --enable-cloud-monitoring --network "default" \
	          --subnetwork "default" --addons HorizontalPodAutoscaling,HttpLoadBalancing,KubernetesDashboard"
	@docker exec $(CONTAINER_NAME) \
	   sh -c "gcloud container clusters get-credentials $(GKE_CLUSTER_NAME) --zone "$(GCP_ZONE)" --project $(GCP_PROJECT_ID) \
	          && kubectl config set-credentials gke_$(GCP_PROJECT_ID)_$(GCP_ZONE)_$(GKE_CLUSTER_NAME) --username=admin \
	          --password=$$(gcloud container clusters describe $(GKE_CLUSTER_NAME) --zone $(GCP_ZONE) | grep password | awk '{print $$2}')"
	@docker exec $(CONTAINER_NAME) \
	   sh -c "kubectl apply -f https://raw.githubusercontent.com/GoogleCloudPlatform/container-engine-accelerators/stable/nvidia-driver-installer/cos/daemonset-preloaded.yaml"
	@docker exec $(CONTAINER_NAME) \
	   sh -c "apk --update add jq && \
	          rm -rf /var/lib/apt/lists/* && \
	          rm /var/cache/apk/*"

.PHONY: install-pachy-cli
install-pachy-cli: ## Install pachctl.
	@docker exec $(CONTAINER_NAME) \
	   sh -c "curl -Lo pachctl_$(VERSION_PACHYDERM)_linux_amd64.tar.gz \
	   https://github.com/pachyderm/pachyderm/releases/download/v$(VERSION_PACHYDERM)/pachctl_$(VERSION_PACHYDERM)_linux_amd64.tar.gz \
	   && tar -xvf pachctl_$(VERSION_PACHYDERM)_linux_amd64.tar.gz \
	   && chmod +x pachctl_$(VERSION_PACHYDERM)_linux_amd64/pachctl && mv pachctl_$(VERSION_PACHYDERM)_linux_amd64/pachctl /usr/local/bin/"

.PHONY: install-pachy-dash
install-pachy-dash: ## Install pachctl dash.
	@docker exec $(CONTAINER_NAME) \
	   sh -c 'pachctl deploy local --dashboard-only'

.PHONY: deploy-kubeflow
deploy-kubeflow: ## Deploy kubeflow on cluster using ksonnet.
	@docker exec $(CONTAINER_NAME) \
	   sh -c 'GITHUB_TOKEN=$(GITHUB_TOKEN) VERSION_KUBEFLOW=$(VERSION_KUBEFLOW) /tmp/kubeflow.sh'

.PHONY: portforward-kubeflow
portforward-kubeflow: ## Port forwarding kubeflow ports.
	@docker exec $(CONTAINER_NAME) \
	   sh -c 'kubectl -n kubeflow port-forward $$(kubectl -n kubeflow get pods --selector=service=ambassador | awk "'"{print $1}"'" | tail -1) 8080:80 2>&1 >/dev/null &'
	@docker exec $(CONTAINER_NAME) \
	   sh -c 'kubectl -n kubeflow port-forward $$(kubectl -n kubeflow get pods --selector=app=tf-hub | awk "'"{print $1}"'" | tail -1) 8000:8000 2>&1 >/dev/null &'

.PHONY: preconfigure-bucket
preconfigure-bucket: ##
	@docker exec $(CONTAINER_NAME) \
	   sh -c 'gsutil ls gs://pachyderm-poc > /dev/null 2>&1 || gsutil mb gs://$(BUCKET_NAME)'

.PHONY: deploy-pachyderm
deploy-pachyderm: preconfigure-bucket install-pachy-cli ## Deploy pachyderm on cluster using its cli.
	@docker exec $(CONTAINER_NAME) \
	   sh -c "pachctl deploy google $(BUCKET_NAME) $(STORAGE_SIZE) --dynamic-etcd-nodes=1"

.PHONY: gke-delete-cluster
gke-delete-cluster: ## Delete a kubernetes cluster on GKE.
	@docker exec $(CONTAINER_NAME) \
	   sh -c "gcloud config set project $(GCP_PROJECT_ID) \
	          && gcloud container --project $(GCP_PROJECT_ID) clusters delete $(GKE_CLUSTER_NAME) \
	          --zone $(GCP_ZONE) --quiet"

.PHONY: pachyderm-set-lb
pachyderm-set-lb: ## Configure pachyderm load balancer.
	@docker exec $(CONTAINER_NAME) \
	   sh -c "kubectl patch svc/pachd --patch '{ \"spec\" : { \"type\": \"LoadBalancer\"}}'"

.PHONY: pachyderm-get-lb
pachyderm-get-lb: ## Get pachyderm load balancer ip.
	@docker exec $(CONTAINER_NAME) \
	   sh -c "echo \"type: export ADDRESS=$$(kubectl get svc pachd -o jsonpath='{.status.loadBalancer.ingress[0].ip}'):650\""

.PHONY: kubeflow-ui
kubeflow-ui: ## Launch kubeflow dashboard
	$(OPEN) https://localhost:8080

.PHONY: pachyderm-ui
pachyderm-ui: ## Launch pachyderm dashboard
	pachctl port-forward &
	$(OPEN) https://localhost:30080

.PHONY: docker-publish
docker-publish: ## Build and publish docker image for preprocessing, train, etc
	docker build -f Dockerfile -t hypnosapos/taxi_chicago:$(IMAGE_VERSION) $(ROOT_PATH)
	docker push hypnosapos/taxi_chicago:$(IMAGE_VERSION)

.PHONY: basic-example
basic-example: ## Launch basic example on pachyderm
	pachctl create-repo taxi
	pachctl put-file -r taxi master -f gs://taxi_chicago/train
	pachctl put-file -r taxi master -f gs://taxi_chicago/eval
	pachctl create-pipeline -f preprocess.json
	pachctl create-pipeline -f train.json
	pachctl create-pipeline -f serving.json