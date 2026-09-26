# Moving infra from nginx to Traefik

**Status: DONE, 2026-09-26.** Infra (`south`, the management plane) runs Traefik. Every step
was approved by the owner for that occasion, per rule 7 of `infra-objectives/CLAUDE.md`. The
plan below is kept as written. What actually happened is in *Outcome* at the end.

## Why

Infra is the one cluster still on nginx, and the nginx it runs is a dead end: the bitnami chart
`nginx-ingress-controller-12.0.7` on `bitnamilegacy/*` images, which bitnami froze when it stopped
publishing free images. Production already runs Traefik with cert-manager. Once infra matches it,
"install the platform" means the same thing on every cluster, and it can run as one step after every
cluster build (see *After the cutover* below).

## What infra runs today (read 2026-09-26)

| | infra (`south`) | production (east/north) |
| :-- | :-- | :-- |
| ingress | bitnami nginx 12.0.7 / controller 1.13.1, one replica on node-2 | Traefik chart 39.0.2 / v3.6.8, DaemonSet on the 3 control-plane nodes |
| how :80/:443 arrive | ClusterIP Service with `externalIPs: [208.113.131.96]` (master-1). kube-proxy DNATs; nothing listens on the host | `hostPort` 80/443 on each control-plane node (CNI `portmap`) |
| IngressClass | `nginx`, controller `k8s.io/ingress-nginx`, owned by the nginx Helm release | `nginx`, same controller string, applied by `traefik/` |
| Ingresses | one: `awx/awx-ingress`, `infra.rods.me` | six, all class `nginx` |
| cert-manager | v1.19.2 | v1.19.3 |
| Doppler operator | 1.7.1 | 1.7.1 |

`infra.rods.me` resolves to `208.113.131.96`, which is master-1. Master-1 already carries the
`nginx-controller` security group (80/443 open), is tainted `control-plane:NoSchedule` (which
`traefik/values.yml` tolerates), and its `/etc/cni/net.d/10-flannel.conflist` includes `portmap`.
So Traefik's production values fit infra as they are. The DaemonSet lands on the one node DNS
already points at, and **no DNS, security group or Terraform change is needed.**

### Why nothing that uses the ingress has to change

`traefik/values.yml` turns on Traefik's `kubernetesIngressNginx` provider, which serves Ingresses
of class `nginx`. Production has relied on this for 215 days:

- AWX's Ingress (`ingress_class_name: nginx` in `awx/awx.yml`) is served unchanged. **AWX is not
  touched.**
- The ClusterIssuers solve HTTP-01 with `class: nginx`, and that works through Traefik:
  `inference/argo-workflows-tls` was issued on 2026-09-03 on production, by this path.

## What this branch changes

| file | change | why |
| :-- | :-- | :-- |
| `traefik/helmChart.yml` | pin `version: 39.0.2` | was unpinned; now matches production |
| `traefik/playbooks/install.yml` | CRD/RBAC URLs from tag `v3.6.8`, not branch `v3.6` | a branch moves; and should match the image |
| `cert-manager/helmChart.yml` | pin `version: v1.19.3` | was unpinned; production's version |
| `cert-manager/values.yml` | `startupapicheck.enabled: false` | the fix for `Job.batch "cert-manager-startupapicheck" is invalid`, the reason `Ansible: south: Install the cert manager` fails at plan. See the comment in the file |
| `cert-manager/le-staging-cluster-issuer.yml` | new `letsencrypt-staging` | lets step 5 test ACME through Traefik without spending production rate limit |
| `doppler/playbooks/install.yml` | pin `v1.7.1`; refuse an empty token; `no_log` on the secret | `latest` drifted per build; an unset env var wrote an empty token and reported success; the module result was putting the token in Spacelift's run history |
| `nginx-ingress-controller/helmChart.yml` | pin `version: 12.0.7` | so the rollback restores what was removed |
| `nginx-ingress-controller/playbooks/delete.yml` | new | removes the controller and **keeps IngressClass `nginx`** |
| `platform/playbooks/install.yml` | new | Traefik → cert-manager → Doppler, one verb for every cluster |

Rendered and checked locally: the chart versions resolve, cert-manager renders no startupapicheck
Job, Traefik renders a DaemonSet with hostPort 80/443 and the nginx provider, and the nginx delete
covers 15 objects with `IngressClass/nginx` excluded. `--syntax-check` passes on the new playbooks,
and the Doppler guard fails as intended with the variable unset.

## The cutover

**Run it through Spacelift, not AWX.** This is the same bootstrap-ordering argument that keeps
south's install stacks in Spacelift: AWX sits behind the ingress being replaced. If the cutover
breaks routing, `infra.rods.me` goes down and AWX goes with it, but Spacelift is unaffected, and so is
the rollback. SSH reads keep working throughout.

**Stacks the owner has to create** (the agent's Spacelift key cannot create stacks). Put them in
`kubernetes-apps-01KEAAEQMRS0SW7ED1WVDBAQ8S` with the same four contexts as the existing
cert-manager stack (`kubernetes-apps`, `tenant-iad2-south`, `ansible`, `clouds-yaml`):

- `Ansible: south: Install Traefik`, projectRoot `traefik/playbooks`, playbook `install.yml`
- nginx removal: re-enable `ansible-south-install-the-nginx-ingress-controller`, and run `delete.yml`
  on it as a task (or point a short-lived stack at `delete.yml`, if tasks prove awkward on this
  stack)

**Timing:** `awx-tls-secret` renews on **2026-11-11** and expires 2026-12-11. Finish by the end of
October so that the renewal is the second ACME proof, not the first.

| # | step | verify before moving on |
| :-- | :-- | :-- |
| 0 | preflight | `[68]` canary green; `check-awx-status.py` exits 0; no other south change in flight |
| 1 | **cert-manager** stack: v1.19.2 → v1.19.3, adds `letsencrypt-staging`, drops the startupapicheck Job from the render | plan is a server-side dry run, so read it: a patch bump and one new ClusterIssuer. Both issuers `Ready`; `awx-tls-secret` still `Ready`. The old Complete Job stays in the cluster, orphaned and harmless. Delete it by hand if wanted |
| 2 | **Traefik** stack, alongside nginx | DaemonSet 1/1 on master-1. Test Traefik directly, bypassing kube-proxy, from master-1: `curl -s --resolve infra.rods.me:8443:<traefik pod IP> https://infra.rods.me:8443/api/v2/ping/` returns AWX's ping, and `openssl s_client` shows the Let's Encrypt cert, not Traefik's default |
| 3 | **remove nginx** (`delete.yml`) | deleting the Service drops the externalIP DNAT, and the hostPort takes over. From outside: `curl https://infra.rods.me/api/v2/ping/`; any `run.sh` AWX call; `[68]` canary; `check-awx-status.py` |
| 4 | disable the nginx stack again | nothing should be able to re-create it by accident |
| 5 | **prove ACME** | a throwaway `Certificate` for `infra.rods.me` against `letsencrypt-staging`, into a secret other than `awx-tls-secret`, reaches `Ready`; then delete the Certificate and its secret |

Between steps 2 and 3 both controllers serve the same Ingress, with the same backend and the same
TLS secret. Whichever NAT rule wins for `208.113.131.96`, the kube-proxy externalIP or the portmap
hostPort, the response is the same. That overlap is what makes the cutover a swap rather than an
outage. It is also why step 2 tests Traefik on its pod IP: from outside, you cannot tell which
controller answered.

**Rollback** (at step 3 or later): re-enable the nginx stack and deploy `install.yml`. With the chart
pinned to 12.0.7 and the image already pinned, this restores the Service and its externalIP. Then
delete the Traefik DaemonSet (`traefik/playbooks/delete.yml`), so the two do not sit behind one
address indefinitely.

**Expected downtime:** none planned. At worst, the seconds between deleting the Service and the
first request reaching the hostPort.

## After the cutover: one post-install verb for every cluster

`platform/playbooks/install.yml` is the verb. How it gets launched:

- **Infra.** One `Ansible: south: Install platform` stack (projectRoot `platform/playbooks`,
  `additionalProjectGlobs: ["traefik/**", "cert-manager/**", "doppler/**"]`, because Spacelift only
  triggers on its own root). It replaces the separate cert-manager, Doppler and nginx stacks. Only
  after the cutover is proven: the first run on infra should be a no-op.
- **Production.** A plan here should also be close to a no-op: same Traefik, cert-manager and Doppler
  versions. Only the staging issuer is new. That makes it a cheap test that the platform playbook
  really describes production.
- **Development and any rebuilt cluster.** A new AWX template, `General: Kubernetes: Cluster:
  Install platform`: project `[21]`, EE `[6] kustomize`, no default inventory or credential. Then a
  step in `cluster-build` after `[66]`:

  ```yaml
  - step: install-platform
    verb:
      awx_job_template: <new>        # General: Kubernetes: Cluster: Install platform
      launch_with:
        inventory: "{{ target.inventory }}"
        credentials: [<kubernetes credential for target>, 8]   # 8 = Doppler
    expect: >-
      job successful AND graded on the installed thing: traefik DaemonSet ready on every
      control-plane node, both ClusterIssuers Ready, doppler operator Available
  ```

  West is the case this is for. Read on 2026-09-26, it has only `default`, `kube-*` namespaces and
  no IngressClass, so a freshly built cluster today comes up with no ingress at all.

### Open questions (decisions needed before phase 2)

1. **Cluster access: the AWX Kubernetes credentials. Decided by the owner, 2026-09-26.**
   `install-platform` authenticates the way the App templates already do: with the custom
   Kubernetes credential for the target (`[7] Kubernetes Development`, `[11] Kubernetes
   Production`), each holding a kubeconfig.

   **What this requires:** a kubeconfig belongs to one cluster, so a rebuild makes the stored one
   stale. The credential has to be refreshed after kubespray and before `install-platform`. Today
   `cluster-build` has no step that does this, and `[7]` was last modified 2026-02-19, before
   west's 2026-08 rebuilds. So either the refresh is done by hand outside the objective, or it is not
   done yet. Until a `refresh-kubernetes-credential` step exists, `install-platform` on a freshly
   rebuilt cluster needs `[7]` updated by hand first. If it is stale, the job fails loudly with a
   TLS or authentication error, not silently.

2. **Which Doppler token does each cluster get?** There is one AWX Doppler credential, `[8]`. If
   development and production should read different Doppler configs, that needs one credential
   per environment, bound per target like the OpenStack ones.
3. **Keep or retire `[23]`, `[27]`, `[28]`?** The per-app templates stay useful for running one
   component alone. The owner has kept never-run templates before; this draft does not touch them.

## Follow-ups noticed, not in this branch

- **cert-manager and the Doppler operator restart constantly on infra.** 322 restarts for the
  controller, 543 for cainjector, 1000 for Doppler, and 1066 for the awx-operator, all with `leader
  election lost`. That is etcd latency (see *The storage substrate* in `infra-objectives/CLAUDE.md`)
  outrunning the default lease timings. Longer `leaseDuration`/`renewDeadline` would probably stop
  it. It is unrelated to this change, but a controller that keeps dropping its lease is also the one
  that has to renew `awx-tls-secret`.
- **Ship Traefik's access logs.** Alloy's pod-log scope is `awx`, `kube-system`, `kube-flannel`. Add
  `traefik`.
- **Names that become historical:** the `nginx-controller` security group and the
  `nginx_ingress_controller` inventory group. Renaming the security group replaces it, and security
  groups are on `cluster-build`'s `never_destroy` list, so leave both names alone.
- **infra-objectives text to update once this lands:** the `infra-observability` policy says it
  "never touches … `ingress-nginx`" (it should say `traefik`); the *three stacks still fail at plan*
  table (cert-manager fixed, the nginx stack retired); and the Spacelift and bootstrap-ordering
  sections, which list "the ingress controller" among south's stacks.

## Outcome, 2026-09-26

| step | result |
| :-- | :-- |
| 0 preflight | canary job 3707 green (3 × `runner_on_ok`), `check-awx-status.py` 14/14 |
| 1 cert-manager | run `01M3FKRJ684HNEAB6PXPENVTQA` planned clean for the first time since August and applied v1.19.3; both issuers Ready, `awx-tls-secret` untouched. The apply landed a minute or two after confirm, so a check made immediately afterwards reads "nothing changed". Wait before grading |
| 2 Traefik | the first run, `01M3FNFPBR9VTN2ES6BSVVPRV6`, **failed at plan** with nothing applied: `namespaces "traefik" not found`, because in check mode the namespace and CRDs were only dry-run. Fixed in `ae21708` (a first-install plan skips the chart and says so). Run `01M3FP4MFYD9SH62S682F3WSAF` applied it. Tested on the pod IP: AWX ping 200, the Let's Encrypt cert, HTTP → 308 to HTTPS (the nginx provider's ssl-redirect, same as nginx) |
| 3 remove nginx | 15 objects and the namespace gone, `IngressClass/nginx` kept. Public ping 200 served by Traefik (seen in its access log), canary job 3711 green, `check-awx-status.py` 14/14. No downtime observed |
| 4 disable nginx stack | owner |
| 5 ACME | `letsencrypt-staging` Certificate for `infra.rods.me` Ready in 30s; Let's Encrypt's validators fetched the HTTP-01 path from three IPs, 200, not redirected. The solver Ingress has no `ingressClassName` (cert-manager's `class:` sets the annotation), and Traefik served it anyway. Probe deleted |

**Afterwards, 2026-09-26:** the orphaned `cert-manager-startupapicheck` Job was deleted, and the
`nginx-ingress-controller/` directory was removed from this repo. **The rollback described above no
longer exists as written.** Restoring nginx now means reverting that removal (the chart stays pinned
at 12.0.7 in the reverted files) and re-creating a stack for it.

Still open: the single infra platform stack and the AWX `Install platform` template (above), and
the follow-ups listed before this section.
