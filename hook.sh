#!/bin/bash

cat <&0 > all.yaml

#./kustomize build .
kubectl kustomize vector/overlay && rm all.yaml