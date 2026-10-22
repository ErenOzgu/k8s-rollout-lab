# Changelog

Format: [Keep a Changelog](https://keepachangelog.com/), versions follow [SemVer](https://semver.org/).

## Unreleased

### Added
- The `dev` and `prod` namespaces enforce the Pod Security `restricted` profile. The cluster test checks the label,
  that a pod built like the app's is admitted, and that a pod with no security context and a privileged pod are refused.

### Changed
- The probe pods of the NetworkPolicy test now carry a restricted security context, as the namespace requires.

## 0.1.0 - 2026-10-18

### Added
- A small service (`app/server.py`, standard library only) with `/healthz`, `/readyz` and `/`, which stops being ready
  on SIGTERM and keeps serving while it drains. `START_DELAY` and `FAIL_READY` make a slow release and a release that
  never becomes ready.
- A load generator (`app/loadgen.py`) that logs one line per request.
- Kustomize base, `dev` and `prod` overlays: rolling update with `maxUnavailable: 0`, probes, a progress deadline, a
  non-root read-only container, a PodDisruptionBudget and topology spread in prod, a NetworkPolicy.
- Cluster tests on kind (`tests/e2e.sh`): a rolling update, a bad release that is stopped and rolled back, a node drain
  and the NetworkPolicy, all under load, with failed requests counted. A control experiment (`tests/control.sh`) that
  must drop requests.
- Unit tests for the service and the load generator, manifest validation with kubeconform, shellcheck and actionlint.
- `docs/design-notes.md`, `ROADMAP.md`, and a release workflow that publishes the rendered manifests.
