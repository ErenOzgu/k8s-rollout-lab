CLUSTER ?= rollout-lab
KIND_IMAGE_TAGS = 1.0.0 1.1.0 1.2.0-bad

.PHONY: help test lint manifests images cluster e2e control down

help:
	@echo "make test       unit tests for the service and the load generator (Python only)"
	@echo "make lint       ruff, shellcheck"
	@echo "make manifests  render and validate every overlay (needs kustomize and kubeconform)"
	@echo "make e2e        build images, create a kind cluster, run tests/e2e.sh (needs docker, kind, kubectl)"
	@echo "make control    run tests/control.sh on the same cluster"
	@echo "make down       delete the kind cluster"

test:
	python3 -m unittest discover -s tests -p 'test_app.py' -v

lint:
	ruff check .
	ruff format --check .
	shellcheck -x tests/*.sh

manifests:
	@for dir in k8s/overlays/dev k8s/overlays/prod tests/control; do \
	  echo "== $$dir"; kustomize build $$dir | kubeconform -strict -summary -kubernetes-version 1.34.0 || exit 1; \
	done

# The same code built three times: two good releases, and one that never becomes ready.
images:
	docker build -t rollout-lab:1.0.0 --build-arg VERSION=1.0.0 .
	docker build -t rollout-lab:1.1.0 --build-arg VERSION=1.1.0 .
	docker build -t rollout-lab:1.2.0-bad --build-arg VERSION=1.2.0-bad --build-arg FAIL_READY=1 .

cluster: images
	kind get clusters | grep -qx $(CLUSTER) || kind create cluster --name $(CLUSTER) --config tests/kind.yaml --wait 180s
	for tag in $(KIND_IMAGE_TAGS); do kind load docker-image rollout-lab:$$tag --name $(CLUSTER); done

e2e: cluster
	tests/e2e.sh

control:
	tests/control.sh

down:
	kind delete cluster --name $(CLUSTER)
