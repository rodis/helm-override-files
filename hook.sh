#!/bin/bash

cat <&0 > all.yaml
kubectl kustomize vector/overlay && rm all.yaml