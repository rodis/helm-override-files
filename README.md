# helm-override-files
../../kustomize edit add configmap vector-sinks --from-file='configs/sinks/*.yml'
./kustomize edit add configmap some-name --from-file='configs/*.yml --namespace vector
./kustomize edit remove configmap some-name