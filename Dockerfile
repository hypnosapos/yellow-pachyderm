FROM python:2.7-slim-jessie

RUN apt update && apt install --yes git cmake

RUN git clone -b v0.9.2 https://github.com/tensorflow/model-analysis.git

WORKDIR model-analysis/examples/chicago_taxi

RUN pip install -r requirements.txt

COPY ./preprocess.sh .
COPY ./train.sh .