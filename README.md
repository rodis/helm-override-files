# helm-override-files

Kustomize/Helm overrides for shared cluster infrastructure, deployed to the
prod cluster (mostly via the per-service `playbooks/`).

Services: `argocd`, `awx`, `cert-manager`, `doppler`, `kafka`, `n8n`,
`redpanda`, `traefik`.

`platform/` installs what every cluster gets after it is built -- `traefik`, `cert-manager`,
`doppler`, in that order. Infra and production both run Traefik; the bitnami
`nginx-ingress-controller` it replaced was removed on 2026-09-26 (see `traefik/INFRA-CUTOVER.md`).

**Each app directory is cluster-agnostic, and that is the contract.** The same `traefik/`,
`cert-manager/` and `doppler/` install infra, production and development: no hostnames, IPs,
tenants or inventory groups in them. Anything that differs per cluster (today only
`DOPPLER_TOKEN_SECRET`, and the kubeconfig) is supplied by the caller. The callers are thin
wrappers and should stay that way: a Spacelift stack on infra, an AWX template elsewhere, both
running `platform/playbooks/install.yml`. If a cluster seems to need its own values, pass them
in from the wrapper instead of forking the app directory.

> **Note:** `vector/` and `inference/` used to live here but were moved into the
> [`inference`](https://github.com/rodis/inference) repo (`deploy/`) and are now
> managed by Argo CD (apps `inference-vector` and `inference-runtime`). Don't
> re-add them here.
