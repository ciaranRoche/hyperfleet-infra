# Upstream HyperShift on the OCI POC OKE cluster

Reference manifests for a `platform: None` hosted cluster on the OKE
management cluster built by `terraform/oci-poc/`, published privately so that
workers in a customer VCN reach it over the DRG. Driven by
`scripts/oci-poc-hypershift.sh`.

## Version set

| Component | Version |
| --- | --- |
| OpenShift release | `quay.io/openshift-release-dev/ocp-release:4.22.18-x86_64` (`sha256:` digest recorded per run; Kubernetes 1.35.8) |
| Control plane operator | from the 4.22.18 payload (`openshift/hypershift` `754de9e`, `release-4.22`) |
| HyperShift operator | `quay.io/hypershift/hypershift-operator@sha256:9a2e262ed79d57237b20a7e52813db385ea4527df1f33396da7c98d3772a0cfc` |
| HyperShift CLI | built from `openshift/hypershift` `253c3f5c790d08668d4aa365688e88a0ab950af8`, the commit that image was built from |
| Management cluster | OKE Enhanced, Kubernetes v1.37.0, VCN-native CNI, cri-o |
| Monitoring CRDs | prometheus-operator `v0.88.0` |
| Route CRD | `openshift/api` `e07c1fd9d99c` |

Upstream publishes the operator image only as `latest`, so it is pinned by
digest, and the CLI is built from the same commit. A CLI and image from
different commits produce misleading failures.

## Files

| File | What it is |
| --- | --- |
| `hostedcluster-demo1.yaml` | `hypershift create cluster none --render` output, edited: all four services as hostname Routes, PodSecurity override, `SingleReplica`, etcd on `oci-bv` |
| `nodepool-demo1.yaml` | The None NodePool. Only produces the token and user-data secrets |
| `router-internal-lb.yaml` | Merge patch that makes the per-cluster router Service an internal OCI load balancer |

The operator install is not committed (93 CRDs, 5.5 MB). `oci-poc-hypershift.sh
install` renders it from the pinned CLI and image.

## What a non-OpenShift management cluster needs

| Need | Symptom without it | Fix |
| --- | --- | --- |
| `podmonitors.monitoring.coreos.com` CRD | Operator leader exits after two minutes: `failed to wait for hostedcluster caches to sync kind source: *v1.PodMonitor` | prometheus-operator CRD |
| `servicemonitors` and `prometheusrules` CRDs | Install apply fails on the operator's ServiceMonitor and PrometheusRule, rendered even with `--platform-monitoring None` | prometheus-operator CRDs |
| `routes.route.openshift.io` CRD | HostedCluster `ValidConfiguration=False`: `cluster does not support Routes, but service "APIServer" is exposed via a Route` | openshift/api Route CRD, then restart the operator: capabilities are read only at startup |
| PodSecurity override | Control plane namespace is labelled `restricted`, no SCC fills in the security context, every pod is refused | HostedCluster annotation `hypershift.openshift.io/pod-security-admission-label-override: privileged` |
| Internal load balancer annotations on the router Service | The OCI cloud controller tries a public load balancer in a private subnet and fails with `400 InvalidParameter` | `router-internal-lb.yaml`; the control-plane-operator leaves these annotations alone |

Not needed: service-ca (the operator generates its own serving certificate),
SCCs, a router on the management cluster (the per-cluster router serves the
Routes).

## Publishing shape

Every service is a Route with a hostname, so the per-cluster HAProxy router
serves all four on 443 behind one internal load balancer:

| Service | Hostname | Port |
| --- | --- | --- |
| APIServer | `api.demo1.hcp.oci.hypershell.app` | 443 |
| OAuthServer | `oauth.demo1.hcp.oci.hypershell.app` | 443 |
| Konnectivity | `konnectivity.demo1.hcp.oci.hypershell.app` | 443 |
| Ignition | `ignition.demo1.hcp.oci.hypershell.app` | 443 |

The four A records point at the router's private IP in the service VCN's
`lb-private` subnet. They resolve publicly but are reachable only from the
service and customer VCNs. From a workstation, reach the hosted API with
`kubectl -n clusters-demo1 port-forward svc/kube-apiserver 16443:6443` and a
kubeconfig whose server is `https://127.0.0.1:16443` with
`tls-server-name: api.demo1.hcp.oci.hypershell.app`.

## Availability on a single availability domain

`HighlyAvailable` does not schedule in `us-sanjose-1`: HyperShift sets a
required pod anti-affinity on `topology.kubernetes.io/zone` for HA control
plane workloads on None, and every OKE node reports the one availability
domain as its zone. OKE's managed control plane resets that label within about
a second if it is changed. These manifests use `SingleReplica`.

## Order of operations

```bash
export KUBECONFIG=<OKE kubeconfig> OCI_CLI_PROFILE=APIKEY OCI_CLI_AUTH=api_key
scripts/oci-poc-hypershift.sh build
scripts/oci-poc-hypershift.sh shims
scripts/oci-poc-hypershift.sh install
PULL_SECRET_FILE=<pull secret> scripts/oci-poc-hypershift.sh cluster-up
DNS_COMPARTMENT_ID=<zone compartment> scripts/oci-poc-hypershift.sh dns
scripts/oci-poc-hypershift.sh status
```

Tear down with `DNS_COMPARTMENT_ID=<zone compartment>
scripts/oci-poc-hypershift.sh cluster-down`. Deleting the HostedCluster
removes the router load balancer, its NSG and the etcd volumes. It does not
wait for, or touch, any worker instances: on None those are never known to
HyperShift.
