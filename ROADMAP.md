# Roadmap

Small steps, in order. A step is done when CI is green (including the cluster tests), the README says what changed and
the CHANGELOG has a line for it. A step that adds a safeguard also gets a check in `tests/` that fails when the
safeguard is removed. Each step is meant to be a few hours of work.

- [ ] Label the namespaces `pod-security.kubernetes.io/enforce: restricted`, and test that the pods are admitted
      (they already comply) and that a pod without a security context is refused
- [ ] An in-flight request test: `/slow?ms=` on the service, and a request that is still running when its pod gets
      SIGTERM must finish with 200
- [ ] `startupProbe` and a slow-starting variant, with a test that a slow start is not killed by the liveness probe
- [ ] A control for the drain: the same drain with no PodDisruptionBudget, showing how many requests it costs (or that
      the extra replicas hide it)
- [ ] An egress policy that allows DNS and nothing else, and a test that the pod cannot reach the internet
- [ ] HorizontalPodAutoscaler in the prod overlay, with metrics-server in the kind cluster, and a test that load adds
      replicas and that a rollout during scale-up still drops nothing
- [ ] Push the image to GHCR from the release workflow, tagged with the version, and let the prod overlay reference it
- [ ] A canary variant of the rollout (two Deployments behind one Service) and a test of the traffic split
