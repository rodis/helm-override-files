# AWX memory footprint: unbounded task pods on a 7.75 GiB node

Investigated 2026-08-29 against the live `south` cluster. All figures below were measured, not
estimated. **Nothing has been changed yet** — this document is the diagnosis and the proposed fix.

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

To lower it you need `extra_settings`.

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

## Proposed change

In `awx/awx.yml`:

```yaml
spec:
  task_replicas: 4                    # was 6 — 2 per node

  task_resource_requirements:
    requests:
      cpu: 250m
      memory: 1Gi
    limits:
      cpu: 2                          # keep ≤ 4, or the operator raises JOB_EVENT_WORKERS
      memory: 2Gi                     # ⇒ SYSTEM_TASK_ABS_MEM='2Gi' ⇒ max_workers 27, capacity ~20

  ee_resource_requirements:
    requests: {cpu: 100m, memory: 128Mi}
    limits:   {memory: 1Gi}           # job execution lives here — be generous

  redis_resource_requirements:
    requests: {cpu: 50m, memory: 64Mi}
    limits:   {memory: 256Mi}

  rsyslog_resource_requirements:
    requests: {cpu: 100m, memory: 128Mi}
    limits:   {memory: 256Mi}

  extra_settings:
    - setting: JOB_EVENT_WORKERS
      value: 2                        # default 4; three jobs a week does not need 24 workers
```

### Expected effect

| change | measured / derived effect |
| :-- | :-- |
| `task_replicas: 6 → 4` | **−0.8 to −1.0 GiB per node**, plus ~10 postgres connections |
| memory limits | scheduler view corrected; `max=88 → 27`; `capacity 474 → ~80` |
| `JOB_EVENT_WORKERS: 4 → 2` | **−~240 MB** on node-1 at current replica count |

node-1 should land near **4.2–4.4 GiB used**, i.e. roughly **42–45% MemAvailable**, up from 29.3%.

Replica reduction is the dominant lever: removing a pod drops its parents, its four sidecars
(`redis`, `awx-ee`, `awx-rsyslog`, plus receptor) and its wsrelay postgres connections together,
none of which the per-worker view captures. `JOB_EVENT_WORKERS` is worth setting but is a rounding
error next to it.

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

AWX is deployed from `awx/playbooks/install.yml` via its Spacelift stack. Autodeploy is **off** on
every stack in the account, so the sequence is:

```
git push                                        # triggers a tracked run that plans and waits
spacectl stack confirm --id <stack> --run <id>  # confirm BY COMMIT, not "the first UNCONFIRMED run"
```

Do not follow a `sync-commit` or a push with `spacectl stack deploy` — the push already scheduled
the run, and a second call produces a duplicate queued behind it. Check that the run used *your*
commit and that the task count changed; a green Spacelift run is not by itself evidence that your
change ran.

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
