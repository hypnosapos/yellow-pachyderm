# Yellow Pachyderm

![We love open source](https://badges.frapsoft.com/os/v1/open-source.svg?v=103 "We love open source")

This project is a proof of concept about well known **Chicago taxis** dataset.

The goal is to reproduce the [example of tensorflow](https://github.com/tensorflow/model-analysis/tree/master/examples/chicago_taxi) by using [pachyderm](https://github.com/pachyderm/pachyderm)

## Requirements

- Make (gcc)
- Docker (17+)
- Kubernetes 1.8+ (we'll use a cluster on GKE, created through [k8s-gke](https://github.com/hypnosapos/k8s-gke))

## Creating a kubernetes cluster

```bash
git clone https://github.com/hypnosapos/k8s-gke
vi k8s-gke/k8s-gke.sh ### Adjust your own values: GKE_CLUSTER_NAME=pachy
source k8s-gke/k8s-gke.sh 
make -C k8s-gke gke-bastion gke-create-cluster gke-ui-login-skip gke-proxy gke-ui
```

## Deploy pachyderm on kubernetes

```bash
export STORAGE_SIZE=10
export BUCKET_NAME=pachyderm-poc
make preconfigure-bucket pachy-install-cli pachy-deploy
```

## Build and push docker container \[optional\]

```bash
make docker-publish
```

Pre-built images are [available here](https://hub.docker.com/r/hypnosapos/taxi_chicago/tags/).

## Launch pipelines

```bash
make pachy-proxy pachy-pipelines
```

Follow job statuses by:
```bash
docker exec -it gke-bastion bash -c "watch pachctl list-jobs"
```

## Deploy tf-serving and check CD of models

If statuses of jobs are 'success' then model resources should be at GCS, in the egress URL specified in file `train.json`
 (by default: gs://taxi_chicago/output/)

Now, let's deploy tfserving to serve models:
```bash
make gcp-secret tfserving-deploy
```

To get predictions:
```bash
make tfserving-client
```
