# Yellow Pachyderm

![We love open source](https://badges.frapsoft.com/os/v1/open-source.svg?v=103 "We love open source")

This project is a proof of concept about well known **Chicago taxis** dataset.

The goal is to reproduce this [example of tensorflow](https://github.com/tensorflow/model-analysis/tree/master/examples/chicago_taxi) by using [pachyderm](https://github.com/pachyderm/pachyderm)

![Taxi chicago over pachyderm](taxi_chicago.png)

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

## Use cases

### 1 - File aggregation

**DoD**: When we put a data.csv file to pachyderm repo a new trained model is got out and ready on tfserving.

This command put a new file (new commit on pachyderm) with last 50 lines of original data.csv file:
```bash
make aggregate-data
```

These are job statuses after a couple of minutes:

```bash
$ docker exec -it gke-bastion bash -c "wait pachctl list-job"
ID                               OUTPUT COMMIT                               STARTED        DURATION       RESTART PROGRESS  DL       UL       STATE            
021a2af8e0f04ca2ab33fb2fbf1090eb train/937281c0a74c4759b44cefc4a6f3a638      11 minutes ago 2 minutes      0       1 + 0 / 1 1.129MiB 9.404MiB success 
fe4d2ad502124b67898394b37cbb658d preprocess/a5f617fccc494a8682fc88660df46511 11 minutes ago 54 seconds     0       1 + 0 / 1 1.837MiB 1.129MiB success 
ee72437134804c90abb87344bbc6d415 train/7f0fe2d56c0d4387b5b5151fee7b1a46      17 minutes ago 2 minutes      0       1 + 0 / 1 1.119MiB 9.391MiB success 
15fd208fec02475a8f9c99c7393cae49 preprocess/1706bff2563c47f49b95dae0d543ff0e 17 minutes ago 56 seconds     0       1 + 0 / 1 1.836MiB 1.119MiB success 
```

Models are available at GCS:
```bash
gsutil ls gs://taxi_chicago/output/train/local_chicago_taxi_output/serving_model_dir/export/chicago-taxi/
gs://taxi_chicago/output/train/local_chicago_taxi_output/serving_model_dir/export/chicago-taxi/1537356456/
gs://taxi_chicago/output/train/local_chicago_taxi_output/serving_model_dir/export/chicago-taxi/1537356951/

```

Note how models 1537356456 and 1537356951 (last one is the model for complete dataset, created after the aggregation) are served via TFServing and clients reach them.

TFServing logs:

```bash
2018-09-19 11:28:52.591230: I tensorflow_serving/core/loader_harness.cc:74] Loading servable version {name: chicago_taxi version: 1537356456}
2018-09-19 11:28:52.757413: I external/org_tensorflow/tensorflow/contrib/session_bundle/bundle_shim.cc:360] Attempting to load native SavedModelBundle in bundle-shim from: gs://taxi_chicago/output/train/local_chicago_taxi_output/serving_model_dir/export/chicago-taxi/1537356456
2018-09-19 11:28:52.757478: I external/org_tensorflow/tensorflow/cc/saved_model/reader.cc:31] Reading SavedModel from: gs://taxi_chicago/output/train/local_chicago_taxi_output/serving_model_dir/export/chicago-taxi/1537356456
```
```bash
2018-09-19 11:36:12.062605: I tensorflow_serving/core/loader_harness.cc:74] Loading servable version {name: chicago_taxi version: 1537356951}
2018-09-19 11:36:12.771773: I external/org_tensorflow/tensorflow/contrib/session_bundle/bundle_shim.cc:360] Attempting to load native SavedModelBundle in bundle-shim from: gs://taxi_chicago/output/train/local_chicago_taxi_output/serving_model_dir/export/chicago-taxi/1537356951
2018-09-19 11:36:12.771873: I external/org_tensorflow/tensorflow/cc/saved_model/reader.cc:31] Reading SavedModel from: gs://taxi_chicago/output/train/local_chicago_taxi_output/serving_model_dir/export/chicago-taxi/1537356951
```

TFServing client logs:

```bash
$ make tfserving-client
...
model_spec {
  name: "chicago_taxi"
  version {
    value: 1537356456
  }
  signature_name: "predict"
}
```
```bash
$ make tfserving-client
...
model_spec {
  name: "chicago_taxi"
  version {
    value: 1537356951
  }
  signature_name: "predict"
}
```

## VCK

[VCK](https://github.com/IntelAI/vck) aims indirectly attach pachyderm repos to kubernetes volumes.
 
```bash
make vck-install
```

This example shows you how to create a pod with pachyderm taxi repo as local volume:
```bash
make vck-taxi-vol vck-taxi
```
 