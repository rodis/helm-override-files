#!/bin/bash

cat <&0 > vector/all.yml
kubectl kustomize vector && rm vector/all.yaml