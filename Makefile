SHELL := /bin/bash
.DEFAULT_GOAL := help

ROOT := $(abspath $(dir $(lastword $(MAKEFILE_LIST))))
KUBERNETES_DIR ?= $(ROOT)/../kubernetes
KUBERNETES_REPO ?= https://github.com/MikeZappa87/kubernetes.git
KUBERNETES_BRANCH ?= mzappa/nonnetworkpodsmain
CONTAINERD_BRANCH ?= mzappa/nonnetworkpods
VERSION_FILE ?= $(ROOT)/kubernetes-version.env
ARCH ?= $(shell uname -m | sed 's/aarch64/arm64/;s/x86_64/amd64/')
KIND ?= $(shell command -v kind 2>/dev/null || printf '%s/bin/kind' "$$(go env GOPATH)")
DOCKER ?= docker
KUBECTL ?= kubectl
KUBERNETES_IMAGE ?= nonnetwork-kubernetes:dev
NODE_IMAGE ?= nonnetwork-pods-node:dev
CLUSTER_NAME ?= nonnetwork-pods
CONTEXT := kind-$(CLUSTER_NAME)
BUILD_FLAGS ?=
WAIT ?= 180s

.PHONY: help source kubernetes-image node-image build cluster up test status delete

help:
	@printf '%s\n' \
	  'make build             Build Kubernetes and final node images' \
	  'make kubernetes-image  Build Kubernetes with kind (clones if missing)' \
	  'make node-image        Layer containerd onto an existing Kubernetes image' \
	  'make cluster           Create a cluster using the existing node image' \
	  'make up                Build images and create the cluster' \
	  'make test              Run the non-network Pod smoke test' \
	  'make status            Show nodes and cluster workloads' \
	  'make delete            Delete the cluster (keep sources and images)' \
	  '' \
	  'Overrides: ARCH, KIND, KUBERNETES_DIR, VERSION_FILE, CLUSTER_NAME,' \
	  '           KUBERNETES_IMAGE, NODE_IMAGE, CONTAINERD_BRANCH, BUILD_FLAGS' \
	  'Refresh containerd: make node-image BUILD_FLAGS=--no-cache'

# Never reset, pull, or overwrite an existing source checkout.
source:
	@if [[ ! -e "$(KUBERNETES_DIR)" ]]; then \
	  git clone --single-branch --branch "$(KUBERNETES_BRANCH)" \
	    "$(KUBERNETES_REPO)" "$(KUBERNETES_DIR)"; \
	else \
	  git -C "$(KUBERNETES_DIR)" rev-parse --is-inside-work-tree >/dev/null; \
	fi

kubernetes-image: source
	KUBE_GIT_VERSION_FILE="$(abspath $(VERSION_FILE))" "$(KIND)" build node-image \
	  "$(KUBERNETES_DIR)" --type source --arch "$(ARCH)" --image "$(KUBERNETES_IMAGE)"

node-image:
	$(DOCKER) build $(BUILD_FLAGS) --platform "linux/$(ARCH)" \
	  --build-arg BASE_IMAGE="$(KUBERNETES_IMAGE)" \
	  --build-arg CONTAINERD_BRANCH="$(CONTAINERD_BRANCH)" \
	  -f "$(ROOT)/Containerfile" -t "$(NODE_IMAGE)" "$(ROOT)"

# Recursive invocation ensures the base image finishes before the overlay,
# even when make is invoked with -j.
build: kubernetes-image
	$(MAKE) node-image

cluster:
	"$(KIND)" create cluster --name "$(CLUSTER_NAME)" \
	  --config "$(ROOT)/kind.yaml" --image "$(NODE_IMAGE)" --wait "$(WAIT)"

up: build
	$(MAKE) cluster

test:
	$(KUBECTL) --context "$(CONTEXT)" wait --for=condition=Ready nodes --all --timeout="$(WAIT)"
	$(KUBECTL) --context "$(CONTEXT)" apply -f "$(ROOT)/nonnetwork-pod.yaml"
	$(KUBECTL) --context "$(CONTEXT)" wait --for=condition=Ready pod/nonnetwork --timeout="$(WAIT)"
	$(KUBECTL) --context "$(CONTEXT)" get pod nonnetwork -o wide
	@test -z "$$($(KUBECTL) --context "$(CONTEXT)" get pod nonnetwork -o jsonpath='{.status.podIPs[*].ip}')"
	$(KUBECTL) --context "$(CONTEXT)" exec nonnetwork -- sh -c \
	  'ip -o addr; ip route; test "$$(ls /sys/class/net)" = lo; test -z "$$(ip route)"'

status:
	$(KUBECTL) --context "$(CONTEXT)" get nodes -o wide
	$(KUBECTL) --context "$(CONTEXT)" get pods --all-namespaces -o wide

delete:
	"$(KIND)" delete cluster --name "$(CLUSTER_NAME)"