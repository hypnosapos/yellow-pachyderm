.DEFAULT_GOAL := help

# Shell to use with Make
SHELL ?= /bin/bash

CONTAINER_NAME      ?= gke-bastion

IMAGE_VERSION       ?= 0.1

STORAGE_SIZE        ?= 10
BUCKET_NAME         ?= pachyderm-poc

VERSION_PACHYDERM   ?= 1.7.7

UNAME := $(shell uname -s)
ifeq ($(UNAME),Linux)
OPEN := xdg-open
else
OPEN := open
endif

.PHONY: help
help: ## Show this help
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | sort | awk 'BEGIN {FS = ":.*?## "}; {printf "\033[36m%-30s\033[0m %s\n", $$1, $$2}'

.PHONY: preconfigure-bucket
preconfigure-bucket: ## Preconfigure GCS bucket
	@docker exec $(CONTAINER_NAME) \
	   sh -c 'gsutil ls gs://$(BUCKET_NAME) > /dev/null 2>&1 || gsutil mb gs://$(BUCKET_NAME)'

.PHONY: install-pachy-cli
install-pachy-cli: ## Install pachctl client.
	@docker exec $(CONTAINER_NAME) \
	   sh -c "curl -Lo pachctl_$(VERSION_PACHYDERM)_linux_amd64.tar.gz \
	   https://github.com/pachyderm/pachyderm/releases/download/v$(VERSION_PACHYDERM)/pachctl_$(VERSION_PACHYDERM)_linux_amd64.tar.gz \
	   && tar -xvf pachctl_$(VERSION_PACHYDERM)_linux_amd64.tar.gz \
	   && chmod +x pachctl_$(VERSION_PACHYDERM)_linux_amd64/pachctl \
	   && mv pachctl_$(VERSION_PACHYDERM)_linux_amd64/pachctl /usr/local/bin/"

.PHONY: deploy-pachy
deploy-pachy: ## Deploy pachyderm with GCS storage.
	@docker exec $(CONTAINER_NAME) \
	   sh -c 'pachctl deploy google $(BUCKET_NAME) $(STORAGE_SIZE) --dynamic-etcd-nodes=1 \
	          && pachctl port-forward &'

.PHONY: deploy-pachy-dash
install-pachy-dash: ## Just install pachyderm dashboard.
	@docker exec $(CONTAINER_NAME) \
	   sh -c 'pachctl deploy google $(BUCKET_NAME) $(STORAGE_SIZE) --dynamic-etcd-nodes=1 --dashboard-only'

.PHONY: pachyderm-set-lb
pachyderm-set-lb: ## Configure pachyderm load balancer to pget a public access.
	@docker exec $(CONTAINER_NAME) \
	   sh -c "kubectl patch svc/pachd --patch '{ \"spec\" : { \"type\": \"LoadBalancer\"}}'"

.PHONY: pachyderm-get-lb
pachyderm-get-lb: ## Get pachyderm public load balancer ip.
	@docker exec $(CONTAINER_NAME) \
	   sh -c "kubectl get svc pachd -o jsonpath='{.status.loadBalancer.ingress[0].ip}'"

.PHONY: pachyderm-ui
pachyderm-ui: ## Launch pachyderm dashboard
	##"export ADDRESS=<>:650"
	pachctl port-forward &
	$(OPEN) https://localhost:30080

.PHONY: docker-publish
docker-publish: ## Build and publish docker image for preprocessing, train, etc
	docker build -f Dockerfile -t hypnosapos/taxi_chicago:$(IMAGE_VERSION) .
	docker push hypnosapos/taxi_chicago:$(IMAGE_VERSION)

.PHONY: taxis-example
taxis-example: ## Launch chicago taxis trips example on pachyderm
	pachctl create-repo taxi \
	pachctl put-file -r taxi master -f gs://taxi_chicago/train
	pachctl put-file -r taxi master -f gs://taxi_chicago/eval
	pachctl create-pipeline -f preprocess.json
	pachctl create-pipeline -f train.json
	pachctl create-pipeline -f serving.json