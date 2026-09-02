# AWX memory footprint: unbounded task pods on a 7.75 GiB node

Investigated 2026-08-29 against the live `south` cluster. All figures below were measured, not
estimated. The diagnosis is below; the fix it argues for is what `awx.yml` now carries.

## How this surfaced

A routine `estate-status` sweep reported `k8s-south-node-1` at **29.3% memory free** while AWX had
been idle for days. The obvious explanations were both wrong:

- **Not job activity.** The last substantive job was `General: Machines: Check kernel health` on
  2026-08-23. Everything since is AWX's own internal cleanup tasks. Three real jobs in the
  preceding week.
- **Not a leak.** `node_memory_AnonPages_bytes` over 7 days went **5.05 → 4.91 GiB**. Flat, in fact
  slightly declining.

The memory is claimed when the pods *start* and never released, because both of AWX's worker pools
are **preforked**. An idle AWX and a busy AWX cost the same.

## What is actually resident

`awx-task` runs **6 replicas** (`task_replicas: 6` in `awx.yml`), scheduled 3 per node. node-1 also
carries `awx-web` and the operator, which is the entire difference between the two nodes.

45 `awx-manage` processes on node-1:

| subcommand | count | Rss | per task pod |
| :-- | --: | --: | :-- |
| `run_dispatcher` | 15 | 2.42 GiB | 1 parent + **4 workers** |
| `run_callback_receiver` | 15 | 2.20 GiB | 1 parent + **4 workers** |
| `run_rsyslog_configurer` | 4 | 0.64 GiB | 1 |
| `run_wsrelay` | 3 | 0.44 GiB | 1 |
| `run_cache_clear` / `run_ws_heartbeat` | 2 | 0.30 GiB | (web pod) |

Each `awx-task` pod sits at **~1.2–1.3 GiB** measured at the pod cgroup, idle.

### RSS overstates it; use Pss

RSS double-counts copy-on-write pages shared between a forked parent and its children. The honest
figure is `Pss`, from `/proc/<pid>/smaps_rollup`:

| node-1 | Rss | **Pss** |
| :-- | --: | --: |
| `run_dispatcher` (15) | 2.42 GiB | **1.65 GiB** |
| `run_callback_receiver` (15) | 2.20 GiB | **0.81 GiB** |
| all `awx-manage` (45) | 6.00 GiB | **3.64 GiB** |

The callback receiver is the striking one — only 37% of its RSS is real memory.

## Neither pool can simply be turned down

### The dispatcher's floor is hardcoded

`AutoscalePool` *does* reap idle workers, but only down to `min_workers`, and the dispatcher sets
that literally:

```python
# awx/main/management/commands/run_dispatcher.py:70
consumer = AWXConsumerPG('dispatcher', TaskWorker(), queues, AutoscalePool(min_workers=4), ...)
```

Not a setting, not exposed in the CR, no env var. Live status confirms the pool has already scaled
itself to the floor:

```
awx-task-55b7985cbc-btkbd[pid:38] workers total=4 min=4 max=88
.  worker[pid:119524] sent=47806 finished=47806 qsize=0 rss=171.773MB [IDLE]
```

### There is no worker-recycling setting, and it would not help

`AutoscalePool.cleanup()` terminates a worker in exactly three cases: it already crashed; it is
idle **and** the pool is above `min_workers`; or `SIGUSR1` to a worker whose `task_manager` has held
the advisory lock past timeout. `messages_finished` is incremented at `pool.py:139` and rendered in
the status template at `:262` — it is never compared against a threshold. Nothing in
`awx/main/dispatch/` matches `max_requests`, `max_tasks`, `lifetime`, or `recycle`.

There is no `maxtasksperchild` equivalent, and the measurements say one would not be worth much:

```
  PID       PPID           Rss      Pss   Private  ROLE
  101922    101464       157.0    103.0      89.0  PARENT
  2940178   2344017      157.0    110.0     100.0  PARENT
  2292084   2975990      171.0    122.0     112.0  worker
  978387    101922       159.0    102.0      87.0  worker
```

A worker's private set is **87–112 MB** against a parent at **89–100 MB**, after ~48,000 tasks each.
That is not accumulated heap — it is the cost of Django plus AWX imports per forked child, with
Python's refcounting unsharing the COW pages almost immediately. Recycling would reclaim perhaps
10–25 MB per worker, at the cost of a fork storm.

### `JOB_EVENT_WORKERS` is tunable, but the operator only ever raises it

`WorkerPool.__init__` takes `min_workers or settings.JOB_EVENT_WORKERS`, currently **4**. The
operator's `config.yaml.j2` sets it *upward* only, and only from a CPU limit:

```jinja
{%- if callback_receiver_cpu |int > 4 %}
    JOB_EVENT_WORKERS = {{ callback_receiver_cpu }}
{%- endif -%}
```

To lower it you need `extra_settings`. **This was considered and deliberately not taken.**

The callback receiver is **not sharded per job**. `AWXConsumerRedis.run` only sleeps, and every
`CallbackBrokerWorker` independently `BLPOP`s the single shared `CALLBACK_QUEUE` list — they are
competing consumers on one FIFO, not owners of a partition. So halving the workers halves the
drain rate for *one large job* exactly as much as for many, and the backlog accumulates in a redis
the operator configures with **no `maxmemory`**.

Against a claimed ~240 MB at the old replica count — nearer **160 MB** at four replicas, and a
rounding error against the replica reduction below — that is a poor trade for the estate's heaviest
job. Revisit it once `callback_receiver_events_queue_size_redis` has actually been observed during
a kubespray run.

The same reasoning is why redis gets **512Mi** here rather than the 256Mi a first pass suggested:
limits are not reservations — the scheduler counts requests — so headroom on the container holding
the event backlog is free insurance.

## The actual defect: no memory limits, so AWX sizes itself from the host

This is the part worth fixing.

```
SYSTEM_TASK_ABS_MEM    <unset>
IS_K8S                 True
```

With no memory limit on the container, `psutil.virtual_memory().total` reads the **host's**
7.75 GiB rather than the pod's share. `AutoscalePool.__init__` then computes:

```
total_memory_gb = (7.75 GiB >> 30) + 1        = 8
get_mem_effective_capacity(8 GiB)              # IS_K8S ⇒ memory_penalty_bytes = 0
  8192 MB ÷ 100 MB-per-fork                    = 81
  + 7 ("magic prime number of extra workers")  = 88
```

Hence `max=88` per pod, and:

```
[controlplane capacity=474 policy=100%]
	awx-task-...  capacity=79  × 6
```

**AWX's own model believes node-1 can carry ~237 concurrent forks**, on a box with 2.3 GiB
available and no swap. The pool sits at 4 because nothing queues work — not because anything bounds
it.

The same gap misleads the scheduler. On node-1:

| | |
| :-- | :-- |
| memory **requests** (what the scheduler sees) | 1682Mi — **22%** |
| memory **actually used** | 5.2 GiB — **67%** |
| `Committed_AS` | 10.09 GiB against 7.75 GiB total — **130% overcommit** |
| swap | none |

**40 of 48 containers cluster-wide declare no memory limit** — 27 of them in `awx`.

## One change fixes three things

The operator emits `SYSTEM_TASK_ABS_MEM` **only** when a memory limit is present:

```jinja
{% if "limits" in task_resource_requirements and "memory" in task_resource_requirements["limits"] %}
    SYSTEM_TASK_ABS_MEM = '{{ task_resource_requirements["limits"]["memory"] }}'
{% endif %}
```

The operator default (`roles/installer/defaults/main.yml:315`) carries `requests` only, so the guard
never fires. Verified on the live `awx-awx-configmap`: the `settings` key contains `IS_K8S = True`
and nothing else from that block.

So setting `task_resource_requirements.limits.memory` simultaneously:

1. gives the scheduler an honest number,
2. imposes a real cgroup bound instead of letting the pod grow into the node, and
3. corrects AWX's `max_workers` and advertised capacity.

## The change

As applied in `awx/awx.yml` (comments there carry the reasoning; this is the shape):

```yaml
spec:
  task_replicas: 4                    # was 6 — 2 per node

  task_resource_requirements:
    requests:
      cpu: 250m
      memory: 1Gi
    limits:
      cpu: "2"                        # quoted: the CRD types cpu as a string, and the operator's
                                      # cpu_string_to_decimal filter raises on a non-str.
                                      # Keep ≤ 4, or the operator raises JOB_EVENT_WORKERS.
      memory: 2Gi                     # ⇒ SYSTEM_TASK_ABS_MEM='2Gi' ⇒ max_workers 27, capacity ~20

  ee_resource_requirements:
    requests: {cpu: 100m, memory: 128Mi}
    limits:   {memory: 1Gi}           # job execution lives here — be generous

  redis_resource_requirements:
    requests: {cpu: 50m, memory: 64Mi}
    limits:   {memory: 512Mi}         # the event backlog lives here and redis.conf sets no
                                      # maxmemory, so this cgroup limit is the only bound.
                                      # Sized for kubespray, not for the idle footprint.

  rsyslog_resource_requirements:
    requests: {cpu: 100m, memory: 128Mi}
    limits:   {memory: 256Mi}
```

`JOB_EVENT_WORKERS` is deliberately **not** set — see above.

Setting `limits.cpu` also emits `SYSTEM_TASK_ABS_CPU = '2'`, giving a CPU-derived capacity of
`2 × SYSTEM_TASK_FORKS_CPU` = **8**. It does not bind today:
`capacity_adjustment` defaults to `1.0`, which takes the higher of the two derivations, so capacity
stays at the memory-derived ~20. It would start binding if anyone lowered `capacity_adjustment`.

### Expected effect

| change | measured / derived effect |
| :-- | :-- |
| `task_replicas: 6 → 4` | **−0.8 to −1.0 GiB per node**, plus ~10 postgres connections |
| memory limits | scheduler view corrected; `max=88 → 27`; `capacity 474 → ~80` |

node-1 should land near **4.4–4.6 GiB used**, i.e. roughly **40–43% MemAvailable**, up from 29.3%.

Replica reduction is the dominant lever: removing a pod drops its parents, its four sidecars
(`redis`, `awx-ee`, `awx-rsyslog`, plus receptor) and its wsrelay postgres connections together,
none of which the per-worker view captures. Everything else here is a rounding error next to it —
which is the argument for shipping the limits alone and measuring before reaching for
`JOB_EVENT_WORKERS`.

## Risks and cautions

- **A memory limit means the kernel will OOM-kill the container.** Today it is unbounded and grows
  into the node instead. 2Gi against a measured ~1.25 GiB pod is deliberate headroom; do not tighten
  it without re-measuring.
- **Keep the CPU limit at 4 or below.** Above that the operator template *raises*
  `JOB_EVENT_WORKERS` to match, which is the opposite of the intent here.
- **`awx-ee` is where jobs actually execute.** Its limit should stay generous; a tight one turns a
  large job into an OOMKill.
- **Capacity drops from 474 to roughly 80.** That is the honest number and far more than this estate
  uses (three jobs in the week measured), but it is a real reduction in concurrent-fork headroom.
- **Reducing `task_replicas` reduces job concurrency.** The cluster exists to run AWX and nothing
  competes for the memory, so this is a deliberate trade of unused capacity for headroom.

## Deployment path

This is `south`, the management plane. Under `infra-objectives` rule 7 it needs the repo owner's
per-occasion approval before anything is applied.

AWX is deployed from `awx/playbooks/install.yml` by stack `ansible-south-install-awx`
(*Ansible: south: Install AWX*), in space `kubernetes-apps-01KEAAEQMRS0SW7ED1WVDBAQ8S`, tracking
`main`. Autodeploy is **off** on every stack in the account.

**The trap here is `projectRoot`, and it is specific to this change.** The stack's `projectRoot` is
`awx/playbooks` and its `additionalProjectGlobs` is empty, but this change touches `awx/awx.yml` —
*outside* the tracked path. So a push to `main` creates **no run at all** and does **not** advance
the tracked commit. `spacectl stack deploy` would then run the *previous* tracked commit and report
FINISHED, which is the green-run-on-stale-code failure `infra-objectives` keeps warning about.

The file is still present in the workspace — Spacelift checks the whole repository out to
`/mnt/workspace/source` and only sets the working directory to `projectRoot`, which is why
`install.yml`'s `{{ playbook_dir }}/../awx.yml` has always resolved. `projectRoot` governs
*triggering*, not *contents*.

So the sequence is:

```
git push                                             # nothing under awx/playbooks: NO run created
spacectl stack sync-commit --id ansible-south-install-awx   # advances tracked commit, TRIGGERS a run
spacectl stack confirm --id ... --run <id>           # confirm BY COMMIT, not "first UNCONFIRMED"
```

Do not follow `sync-commit` (or a push that *did* trigger) with `spacectl stack deploy` — the run is
already scheduled, and a second call produces a duplicate queued behind it. Check that the run used
*your* commit and that the task count changed; a green Spacelift run is not by itself evidence that
your change ran.

**The durable fix is `additionalProjectGlobs: ["awx/*.yml"]` on the stack**, so that editing the CR
triggers the stack that applies it. That is a stack-definition change: the agent's Spacelift key
cannot do it, and `stackUpdate` over the API is a full replace rather than a patch, so it belongs in
the UI. Until it is set, every future `awx.yml` edit needs the `sync-commit` step above.

This stack **does** plan — `SPACELIFT_SKIP_PLANNING` is not in its environment, and `install.yml` is
`hosts: localhost`, so the plan is a real server-side dry run of the `kubernetes.core.k8s` tasks
rather than a no-op against an unparsed inventory.

## Outcome, measured 2026-09-02

Applied via run `01M1HXKWT2YXXE7RM9PYPXSXFE` on commit `2cb6911`, FINISHED with delta `0/5/0`. The
server-side dry run behind the confirm gate reported 17 resources, **16 unchanged** — operator CRDs,
RBAC and Deployment all untouched — with the single change being the `AWX/awx` CR.

AWX's own capacity model, which is the thing `SYSTEM_TASK_ABS_MEM` actually drives:

| | before | after |
| :-- | --: | --: |
| task pods | 6 | **4** |
| `mem_capacity` per pod | 79 | **20** |
| `cpu_capacity` per pod | — | **8** |
| `capacity` per pod | 79 | **20** |
| `controlplane` total | 474 | **80** |

`cpu_capacity: 8` confirms `SYSTEM_TASK_ABS_CPU = '2'` is emitted and that it does **not** bind:
`capacity` tracks the memory derivation, as `capacity_adjustment: 1.0` implies.

Host memory, `node_memory_MemAvailable_bytes`:

| host | before | after |
| :-- | --: | --: |
| `k8s-south-node-1` | 29.3% free | **55.3% free** |
| `k8s-south-node-2` | — | 68.7% free |

**That beats the 40–43% predicted above, and the gap is probably not durable.** The prediction
assumed the surviving pods keep their measured footprint; in fact every task pod was recreated by
the rollout, so its forked workers are freshly COW-shared rather than 48,000 tasks into unsharing
their pages. Expect node-1 to settle somewhat below 55% as the workers age. Re-measure in a week
before treating the headroom as won.

Not confirmed from metrics: the cgroup limits themselves.
`kube_pod_container_resource_limits` returns **no data** here — kube-state-metrics is deliberately
scoped to the kinds the dashboards plot, and that series is not among them. That is a gap in the
collector, not a statement about the cluster; the limits are evidenced instead by the capacity
figures above, which cannot change unless `SYSTEM_TASK_ABS_MEM` is set, which the operator cannot
emit unless the limit is present.

## How to verify afterwards

```bash
# pool ceiling should now read min=4 max=27
kubectl -n awx exec <awx-task-pod> -c awx-task -- awx-manage run_dispatcher --status

# capacity should be ~20 per instance
kubectl -n awx exec <awx-task-pod> -c awx-task -- awx-manage list_instances

# the setting should now be present in the configmap
kubectl -n awx get cm awx-awx-configmap -o jsonpath='{.data.settings}' | grep SYSTEM_TASK

# scheduler's view should now resemble reality
kubectl describe node k8s-south-node-1 | sed -n '/Allocated resources/,/^Events/p'
```

And on the node itself, `Pss` rather than `Rss`:

```bash
for p in $(pgrep -f "awx-manage"); do
  [ -r /proc/$p/smaps_rollup ] && sudo awk '/^Pss:/{s+=$2} END{print s}' /proc/$p/smaps_rollup
done | awk '{t+=$1} END {printf "awx-manage Pss total: %.2f GiB\n", t/1048576}'
```

## Appendix: source references

All paths inside the `awx-task` container, AWX **24.6.1**, operator **2.19.1**:

| what | where |
| :-- | :-- |
| dispatcher `min_workers=4` | `awx/main/management/commands/run_dispatcher.py:70` |
| `max_workers` derivation | `awx/main/dispatch/pool.py:317-336` |
| `get_mem_effective_capacity` | `awx/main/utils/common.py:824` |
| worker teardown conditions | `awx/main/dispatch/pool.py` — `AutoscalePool.cleanup()` |
| `JOB_EVENT_WORKERS = 4` default | `awx/settings/defaults.py:226` |
| `SYSTEM_TASK_ABS_MEM` emission | operator `roles/installer/templates/configmaps/config.yaml.j2:32-35` |
| `task_resource_requirements` default | operator `roles/installer/defaults/main.yml:315` |
