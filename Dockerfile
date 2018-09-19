FROM python:2.7-slim-jessie

ARG TAXI_VERSION="0.9.0"

RUN apt update && apt install --yes git cmake

RUN git clone -b v${TAXI_VERSION} https://github.com/tensorflow/model-analysis.git

WORKDIR model-analysis/examples/chicago_taxi

RUN pip install -r requirements.txt

COPY ./preprocess.sh .
COPY ./train.sh .