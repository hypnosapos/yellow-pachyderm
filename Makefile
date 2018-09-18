.DEFAULT_GOAL := help

# Shell to use with Make
SHELL ?= /bin/bash

CONTAINER_NAME      ?= gke-bastion

IMAGE_VERSIONS      ?= 0.1 latest

STORAGE_SIZE        ?= 10
BUCKET_NAME         ?= pachyderm-poc

VERSION_PACHYDERM   ?= 1.7.7

.PHONY: help
help: ## Show this help
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | sort | awk 'BEGIN {FS = ":.*?## "}; {printf "\033[36m%-30s\033[0m %s\n", $$1, $$2}'

.PHONY: preconfigure-bucket
preconfigure-bucket: ## Preconfigure GCS bucket
	@docker exec $(CONTAINER_NAME) \
	   sh -c 'gsutil ls gs://$(BUCKET_NAME) > /dev/null 2>&1 || gsutil mb gs://$(BUCKET_NAME)'

.PHONY: pachy-install-cli
pachy-install-cli: ## Install pachctl client.
	@docker exec $(CONTAINER_NAME) \
	   sh -c "curl -Lo pachctl_$(VERSION_PACHYDERM)_linux_amd64.tar.gz \
	             https://github.com/pachyderm/pachyderm/releases/download/v$(VERSION_PACHYDERM)/pachctl_$(VERSION_PACHYDERM)_linux_amd64.tar.gz \
	            && tar -xvf pachctl_$(VERSION_PACHYDERM)_linux_amd64.tar.gz \
	            && chmod +x pachctl_$(VERSION_PACHYDERM)_linux_amd64/pachctl \
	            && mv pachctl_$(VERSION_PACHYDERM)_linux_amd64/pachctl /usr/local/bin/"

.PHONY: pachy-deploy
pachy-deploy: ## Deploy pachyderm with GCS storage.
	@docker exec $(CONTAINER_NAME) \
	   sh -c 'pachctl deploy google $(BUCKET_NAME) $(STORAGE_SIZE) --dynamic-etcd-nodes=1'

.PHONY: pachy-deploy-dash
pachy-deploy-dash: ## Just install pachyderm dashboard.
	@docker exec $(CONTAINER_NAME) \
	   sh -c 'pachctl deploy google $(BUCKET_NAME) $(STORAGE_SIZE) --dynamic-etcd-nodes=1 --dashboard-only'

.PHONY: pachy-set-lb
pachy-set-lb: ## Configure pachyderm load balancer to pget a public access.
	@docker exec $(CONTAINER_NAME) \
	   sh -c "kubectl patch svc/pachd --patch '{ \"spec\" : { \"type\": \"LoadBalancer\"}}'"
	## type: export ADDRESS=$(make pachy-get-lb):650, to get access to pachd externally
.PHONY: pachy-get-lb
pachy-get-lb: ## Get pachyderm public load balancer ip.
	@docker exec $(CONTAINER_NAME) \
	   sh -c "kubectl get svc pachd -o jsonpath='{.status.loadBalancer.ingress[0].ip}'"

.PHONY: pachy-proxy
pachy-proxy: ## Launch pachyderm proxy
	@docker exec -it -d $(CONTAINER_NAME) \
	  sh -c 'pachctl port-forward'

.PHONY: docker-publish
docker-publish: ## Build and publish docker image to be used in pachyderm pipelines
	@$(foreach image_version,\
	    $(IMAGE_VERSIONS),\
	    docker build -f Dockerfile -t hypnosapos/taxi_chicago:$(image_version) . && \
	    docker push hypnosapos/taxi_chicago:$(image_version);)


.PHONY: pachy-pipelines
pachy-pipelines: ## Launch chicago taxis pipelines on pachyderm
	@docker cp preprocess.json $(CONTAINER_NAME):/root/
	@docker cp train.json $(CONTAINER_NAME):/root/
	@docker exec $(CONTAINER_NAME) \
	   sh -c "pachctl create-repo taxi \
	          && pachctl put-file -r taxi master -f gs://taxi_chicago/train \
	          && pachctl put-file -r taxi master -f gs://taxi_chicago/eval \
	          && pachctl create-pipeline -f /root/preprocess.json \
	          && pachctl create-pipeline -f /root/train.json"

.PHONY: pachy-delete-all
pachy-delete-all: ## Remove all resources of pachyderm
	@docker exec -it $(CONTAINER_NAME) \
	   sh -c "pachctl delete-all"

.PHONY: gcp-secret
gcp-secret: ## Create a secret with GCP credentials
	@docker exec $(CONTAINER_NAME) \
	   sh -c "kubectl create secret generic gcloud-creds --from-file=gcp.json=/tmp/gcp.json"

.PHONY: tfserving-deploy
tfserving-deploy: ## Deploy TFServing
	@docker cp k8s-serving.yaml $(CONTAINER_NAME):/root/
	@docker exec -it $(CONTAINER_NAME) \
	   sh -c "kubectl create -f /root/k8s-serving.yaml \
	          && sleep 10 && kubectl logs -f deployment/tfserving-deployment"

.PHONY: tfserving-client
tfserving-client: ## Prediction api request to exposed models on TFServing
	@docker cp k8s-serving-client.yaml $(CONTAINER_NAME):/root/
	@docker exec -it $(CONTAINER_NAME) \
	   sh -c "kubectl create -f /root/k8s-serving-client.yaml \
	          && sleep 10 && kubectl logs -f job/tfserving-client"