# Design notes

Why k8s-rollout-lab is built the way it is. The README says what it does; this says what was decided, what was left
out, and what the tests can and cannot prove.

## The problem in one paragraph

`kubectl apply` works until the day a release is slow to start, never becomes ready, or a node is drained in the middle of
a rollout. What a user sees then is a number of failed requests. Most Kubernetes examples stop at "the pods are Running";
this one measures the thing that matters (requests that failed) while the bad things happen, and it has a control that
shows the measurement can see failures at all.

## Decisions

### Count requests from inside the cluster

The load generator is a pod that sends about twenty requests a second to the Service and logs one line per request.
A test slices the log with a marker taken before each action ("failed since line N"), so a failure is attributed to the
step that caused it. A new connection is used for every request, because each one should be balanced across the pods
like a new client would be; a kept-alive connection would stay on one pod and hide a bad one.

The generator uses the Service's ClusterIP, not its DNS name. A node drain may move a DNS pod, and that is not the
application's failure. The cost is that DNS is not under test.

The generator runs on the control-plane node, so that draining a worker never moves the thing doing the measuring.

### A rolling update that cannot lose capacity

`maxUnavailable: 0` and `maxSurge: 1`: a new pod is started first, and an old one is removed only when the new one
is ready. The cost is one extra pod during a rollout. Without a readiness probe this setting means nothing, because
"ready" would be "the container started", which is what the control experiment uses to drop requests.

### The application drains itself

On SIGTERM the service turns `/readyz` to 503 and keeps answering for `DRAIN_SECONDS` (5) before it exits. A pod that is
being deleted is removed from the Service's endpoints, but that change takes a moment to reach every node, and
requests already on their way must not meet a closed port. The common alternative is a `preStop` sleep, which is the
right answer when the application cannot be changed. I chose to put it in the application because the code is small and
it can be unit-tested without a cluster. `terminationGracePeriodSeconds` (30) is longer than the drain, or the kubelet
would kill the pod in the middle of it.

### A release that never becomes ready is stopped, not rolled back for you

`progressDeadlineSeconds: 45` makes Kubernetes report a stuck rollout as failed (`ProgressDeadlineExceeded`) instead of
"progressing" for ever. With `maxUnavailable: 0` the old pods keep serving while the new one never becomes ready, so the
test sees no failed requests. Kubernetes does not undo the rollout by itself: the test runs `kubectl rollout undo`, as a
pipeline would. Progressive delivery tools (Argo Rollouts, Flagger) do the rollback automatically; they are left out on
purpose, because the point here is what plain Kubernetes already gives you.

### A PodDisruptionBudget only where there are replicas

The `prod` overlay has three replicas and `minAvailable: 2`: a drain moves one pod at a time. The `dev` overlay has one
replica and no budget, because a budget that asks for one pod to stay up on a one-pod Deployment would make every node
drain wait for ever. The test drains the node with the most pods and counts failed requests.

### Topology spread that never blocks scheduling

`topologySpreadConstraints` with `whenUnsatisfiable: ScheduleAnyway`: spread the pods over nodes when there is room, but
never refuse to schedule for it. A hard constraint would leave pods Pending during a drain on a small cluster.

### A NetworkPolicy that names its clients

Ingress to the app is allowed only from pods in the same namespace that carry the label `rollout-lab/access: client`.
Three probes in the test: a labelled pod gets through; an unlabelled pod in the same namespace and a labelled pod in
another namespace are blocked. The policy needs a network plugin that enforces it; kind's default plugin did in the
version pinned here, and the test would fail loudly if a future one did not (the "blocked" cases would get a 200).

### Three images from one build

The same code is built three times with different build arguments: `1.0.0` and `1.1.0` (two good releases) and
`1.2.0-bad` (starts, is alive, never ready). That makes "a new release" and "a broken release" without any change to
the code under test.

### A control experiment

`tests/control.sh` deploys the same service without a readiness probe and with a release that takes three seconds to
start listening, rolls it out under load, and **requires** failed requests. If it saw none, "no request failed" in the
main test could mean that the load generator or the counting is blind. The main test also checks that the load saw both
versions during the rollout, so a rollout that finished before the load started would not pass.

### Pinned, and checked where it can be

kind v0.33.0 (downloaded with its checksum checked), the node image by digest, kubeconform by checksum, actionlint by
checksum, Kubernetes 1.34 schemas for validation. A moving `latest` would make a green build mean less each month.

## How it was checked

* Unit tests for the service and the load generator: readiness, the slow start, never-ready, the drain on SIGTERM and
  its timing, and the load generator's counting. Five mutations of the service (readiness ignoring the drain, no drain
  wait, `FAIL_READY` ignored, no start delay, liveness failing while draining) were each caught by a test; a sixth, HTTP/1.1 keep-alive, was not, so the claim that depended on it was removed.
* Every overlay rendered with kustomize and validated with kubeconform against the 1.34 schemas.
* The cluster tests on kind, in CI, on every push, and the control.
* `shellcheck` on the test scripts and `actionlint` on the workflows.

## What this cannot show

kind is one machine with containers as nodes. There is no cloud load balancer, no ingress, no real node failure, and
no network between nodes that can be slow. Twenty requests a second of tiny responses is not traffic. A request counts as
failed if it does not return 200 within two seconds, which is a stricter rule than many users apply and a looser one than
some. The HorizontalPodAutoscaler is left out because it needs metrics-server and a test of its own; it is on the
roadmap. None of this has run in a production cluster.

## What would be changed next

See [ROADMAP.md](../ROADMAP.md): the Pod Security `restricted` label comes first, because the pods already comply and
it is a cheap way to keep them compliant.

## Questions this design usually draws

**Why Kustomize and not Helm?** Nothing here needs templating: two overlays that change a replica count and add a budget.
Plain YAML that kubeconform can validate is easier to review.

**Why Python for a Kubernetes demo?** The service is not the point, and the standard library keeps the image small and
free of dependencies. What is measured does not depend on the language.

**Why not just a `preStop` sleep?** It works, and is the answer for software you cannot change. Draining in the
application is testable without a cluster, and the shutdown behaviour is visible in the code.

**What does `maxSurge: 1` cost?** One extra pod during a rollout. On a cluster with no spare room the surge pod stays
Pending and the rollout stalls; the progress deadline then reports it.

**How do I know the test is not vacuous?** The control experiment drops requests when the safeguards are removed, and the
main test checks that both versions answered during the rollout.

**Could the bad release be rolled back automatically?** Yes, with Argo Rollouts or Flagger, or a pipeline step that runs
`kubectl rollout status` and then `kubectl rollout undo`, which is what the test does by hand.

## Three-minute demo

You need Docker, [kind](https://kind.sigs.k8s.io/) and kubectl.

```sh
make e2e        # builds the three images, creates a three-node kind cluster, runs tests/e2e.sh
make control    # the same service without its safeguards, which must drop requests
make down
```

What to say: the first run rolls out a new version, ships a release that never becomes ready, drains a node and checks a
NetworkPolicy, all while twenty requests a second hit the service, and counts the failures: none. The second run takes
away the readiness probe and rolls out a slow-starting release, and the same counting shows a few dozen failures. The
second run is why the first one means something.
