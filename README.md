# helm-override-files

Kustomize/Helm overrides for shared cluster infrastructure, deployed to the
prod cluster (mostly via the per-service `playbooks/`).

Services: `argocd`, `awx`, `cert-manager`, `doppler`, `kafka`, `n8n`,
`nginx-ingress-controller`, `redpanda`, `traefik`.

> **Note:** `vector/` and `inference/` used to live here but were moved into the
> [`inference`](https://github.com/rodis/inference) repo (`deploy/`) and are now
> managed by Argo CD (apps `inference-vector` and `inference-runtime`). Don't
> re-add them here.
