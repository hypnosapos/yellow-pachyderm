# Yellow Pachyderm

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
make preconfigure-bucket install-pachy-cli deploy-pachy
```

## Connect to pachd externally

```bash
make pachyderm-set-lb
# wait for public ip
make pachyderm-get-lb
```

Check pachd is reachable:
```bash
export ADDRESS=<address>
pachctl version
```

## Example

```bash
make 
```