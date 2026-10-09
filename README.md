# Non-Network Pods Test Bed

Build a complete kind node from the custom Kubernetes branch, then layer the
custom containerd branch onto it. kind packages and preloads the API server,
controller manager, scheduler, and proxy images; copying their binaries onto
the node alone would not replace the running components.

## Prerequisites

- Docker (tested with Docker Desktop, ARM64, 8 GB memory).
- Go and kind (tested with kind v0.33.0).
- kubectl.
- On macOS, GNU tar: `brew install gnu-tar`.

## Build and launch

The Makefile automates the workflow: `make up` builds both images and creates
the cluster; `make test` runs the smoke test; `make delete` removes the cluster.
Use `make help` to list targets. For the already-running cluster, use `make test`
or `make status` without rebuilding. `make node-image BUILD_FLAGS=--no-cache`
refreshes the containerd branch. Overrides include `ARCH`, `KUBERNETES_DIR`,
`CLUSTER_NAME`, `KUBERNETES_IMAGE`, and `NODE_IMAGE`.

From this directory, using the sibling Kubernetes checkout:

```sh
# Only clone if the sibling checkout does not already exist.
git clone --single-branch --branch mzappa/nonnetworkpodsmain \
  https://github.com/MikeZappa87/kubernetes.git ../kubernetes

KUBE_GIT_VERSION_FILE="$PWD/kubernetes-version.env" \
  "$(go env GOPATH)/bin/kind" build node-image ../kubernetes \
  --type source --arch arm64 --image nonnetwork-kubernetes:dev

docker build -f Containerfile -t nonnetwork-pods-node:dev .

"$(go env GOPATH)/bin/kind" create cluster --name nonnetwork-pods \
  --config kind.yaml --wait 180s
```

Use `--arch amd64` instead on an AMD64 host. The Containerfile builds for the
Docker build's native target architecture. Keep the two builds' architectures
the same.

The Kubernetes checkout used for the initial test was commit
`50b500bcc862923961072fc8597251f8cc534abd`; containerd was
`ead11bd1cfd1f75afd88d3ee0e23bcb29a4fb52d`.
The Kubernetes branch's Git tags identify an older version, so
`kubernetes-version.env` explicitly supplies 1.38 development metadata to both
kind and the containerized build. Update its commit and version when changing
the Kubernetes revision. It assumes no tracked source changes; set its tree
state to `dirty` if building modified source.

Docker may cache the branch clone in the containerd stage. To fetch new branch
commits, rebuild with `docker build --no-cache -f Containerfile -t
nonnetwork-pods-node:dev .`.

## Smoke test

```sh
kubectl --context kind-nonnetwork-pods wait --for=condition=Ready nodes \
  --all --timeout=120s
kubectl --context kind-nonnetwork-pods apply -f ./examples/nonnetwork-pod.yaml
kubectl --context kind-nonnetwork-pods wait --for=condition=Ready \
  pod/nonnetwork --timeout=120s
kubectl --context kind-nonnetwork-pods get pod nonnetwork -o wide
kubectl --context kind-nonnetwork-pods exec nonnetwork -- sh -c \
  'ip -o addr; ip route; test "$(ls /sys/class/net)" = lo; test -z "$(ip route)"'
```

Expected: the Pod is Running/Ready, has no Pod IP, only the loopback interface,
and no routes. The default CNI remains enabled so normal cluster workloads
continue to work.

## Cleanup

```sh
"$(go env GOPATH)/bin/kind" delete cluster --name nonnetwork-pods
```