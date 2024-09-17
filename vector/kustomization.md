kustomize edit remove configmap vector-sources --namespace vector
kustomize edit remove configmap vector-sinks --namespace vector
kustomize edit remove configmap vector-transforms --namespace vector

kustomize edit add configmap vector-sources --from-file='configs/sources/*.yml' --namespace vector
kustomize edit add configmap vector-sinks --from-file='configs/sinks/*.yml' --namespace vector
kustomize edit add configmap vector-transforms --from-file='configs/transforms/*.yml' --namespace vector
