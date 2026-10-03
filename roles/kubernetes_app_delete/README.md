# kubernetes_app_delete

Removes one application this repo installs, by undoing exactly what its install playbook did.

Registered in AWX as a single job template, `General: Kubernetes: App: Delete`, through the thin
wrapper at `playbooks/delete_app.yml`.

## Why this is a role and not seven playbooks

There were seven hand-written `<app>/playbooks/delete.yml` files. By 2026-10-03 they had drifted
into four defects, all found by reading them side by side:

| file | defect |
| :-- | :-- |
| `n8n/playbooks/delete.yml` | task named **"Delete Redpanda from Helm and kustomize"** |
| `traefik/playbooks/delete.yml` | task named "Delete application" |
| `kafka/playbooks/delete.yml` | removed neither the namespace nor the SASL secret its install creates |
| `redpanda/playbooks/delete.yml` | needs `context`, which nothing had supplied since the workflow job templates were deleted on 2026-08-22 |

They were seven copies of one four-line task, and they collapse to **two** shapes — `<app>/` and
`<app>/kustomize/overlays/<context>/`. A map plus one set of tasks cannot drift against itself.

The per-application facts now live in `defaults/main.yml`, which is the part worth reviewing when
an application's layout changes.

## Why `app` is a constrained choice, not free text

`[25] General: Kubernetes: Cluster: Run Tags` is on this estate's never-invoke list because *"it
takes arbitrary tags, so its blast radius isn't knowable in advance."* A delete verb whose target
is free text has that same shape, and worse: the never-invoke list and any future grant match **by
template id**, so one generic template with a free-text target cannot express "may delete vector,
never argocd."

Two things keep it off that list:

- the role refuses any `app` not in its map, so the blast radius is one of a known, readable set
- the AWX template asks for `app` through a **survey multiple-choice**, so an operator picks from
  a list rather than typing, and the choice is recorded against the job

## The guards, and the failure each one is remembering

| guard | remembering |
| :-- | :-- |
| no default for `app`; unknown values refused | `_Dummy_default` — a verb that binds a target when the caller forgets an argument, and reports success |
| `dry_run` defaults true | rule 5: a verb is a read until explicitly armed |
| `authorizing_objective` + `'kubernetes.app.delete' in granted_actions`, **the action written literally** | `openstack_dead_ports`, whose check read `required_actions` from play vars — extra_vars outrank play vars, so `required_actions=[]` satisfied it while granting nothing |
| platform apps must be named a second time via `confirm_platform` | `[20] Cluster: Reset`, made usable by a human and impossible to trigger by accident with a mandatory survey |
| overlay apps must be given `context` | redpanda's delete, orphaned when the workflows that bound it per node were deleted |
| a missing kustomization stops the run | rendering nothing deletes nothing and reports success — a failure that does not resemble one |
| every k8s call is `delegate_to: localhost` | `connection: local` at play level does not survive being included |

## Order of removal, and why the namespace is last

1. the rendered kustomize output — this is the only step that reaches **cluster-scoped** objects
2. manifests the install applied with `src:` outside the kustomization (`extra` in the map)
3. the namespace

The namespace is the backstop, and it earns its place: when this was verified against production
on 2026-10-03, `secret/redpanda-tls` and the `Certificate`/`CertificateRequest` behind it were in
neither the render nor the extras — cert-manager created them from the Ingress. Only step 3
catches that class of object. Equally, only step 1 catches CRDs and ClusterRoles, which is why
both exist.

## Not handled here

`doppler` and `awx`. Neither installs from a directory in this repo — doppler downloads a release
manifest into a tempdir, awx clones the operator — so neither fits a path-based delete. AWX
additionally runs in `south`, which rule 7 puts off-limits.

`traefik`'s install also applies three CRD/RBAC manifests from raw.githubusercontent.com. This
role does **not** remove them: deleting `ingressroutes.traefik.io` would take every IngressRoute
in the cluster with it, including ones no longer belonging to this chart. Remove them by hand if
that is genuinely what you want.

## Usage

    # a read; needs no authority
    ansible-playbook playbooks/delete_app.yml -e app=redpanda -e context=production -e dry_run=true

    # armed
    ansible-playbook playbooks/delete_app.yml \
      -e app=redpanda -e context=production -e dry_run=false \
      -e authorizing_objective=<objective> \
      -e '{"granted_actions":["kubernetes.app.delete"]}'

**The credential binds the cluster, not the inventory.** The play runs on localhost against
whatever kubeconfig the job's Kubernetes credential supplies. The AWX template must therefore
carry no default credential and ask for one on launch.
