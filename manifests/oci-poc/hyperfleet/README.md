# HyperFleet on the OCI POC management cluster

HyperFleet deployed on the OKE cluster from `terraform/oci-poc` with
`HELMFILE_ENV=oci`, driving HyperShift on the same cluster through two
adapters with the direct Kubernetes transport:

| Adapter | Resource | Creates | Reports |
| --- | --- | --- | --- |
| `hc-hypershift` | clusters | HostedCluster (platform None) in `clusters` | API URL, ignition endpoint, console URL, kubeconfig secret name, version |
| `np-hypershift` | nodepools | NodePool with the OCI kubelet identity and device-path MachineConfigs | user-data secret namespace and name, config version |

Neither reports a credential; a launcher reads the user-data secret it is
pointed at.

## Order of operations

```bash
export KUBECONFIG=<OKE kubeconfig> OCI_CLI_PROFILE=APIKEY OCI_CLI_AUTH=api_key
# HyperShift and its prerequisites: scripts/oci-poc-hypershift.sh build|shims|install
DNS_COMPARTMENT_ID=<zone compartment> PULL_SECRET_FILE=<pull secret> scripts/oci-poc-platform.sh install
HELMFILE_ENV=oci make install-hyperfleet
kubectl -n hyperfleet port-forward svc/hyperfleet-gateway 18000:8000
curl -X POST localhost:18000/api/hyperfleet/v1/clusters -H 'Content-Type: application/json' -d @cluster.json
```

`scripts/oci-poc-platform.sh` installs what makes clusters need no hand
steps: `router-admission-policy.yaml` (every hosted cluster's router Service
becomes an internal OCI load balancer with its four hostnames), external-dns
(publishes them), the platform pull secret and the NodePool MachineConfig
ConfigMaps.

## Example payloads

Cluster:

```json
{"kind": "Cluster", "name": "demo2", "spec": {
  "version": "4.22.18", "availability": "SingleReplica", "region": "us-sanjose-1",
  "compartment_id": "<customer compartment>", "vcn_id": "<customer VCN>",
  "base_domain": "hcp.oci.hypershell.app"}}
```

Node pool:

```json
{"kind": "NodePool", "name": "workers", "spec": {
  "count": 2, "shape": "VM.Standard.E5.Flex", "ocpus": 4, "memory_gb": 16,
  "boot_volume_gb": 120, "image_id": "<RHCOS image>", "compartment_id": "<customer compartment>",
  "subnet_id": "<workers subnet>", "nsg_ids": ["<workers NSG>"],
  "fault_domains": ["FAULT-DOMAIN-1", "FAULT-DOMAIN-2", "FAULT-DOMAIN-3"],
  "labels": {"workload-tier": "general"},
  "taints": [{"key": "dedicated", "value": "poc", "effect": "PreferNoSchedule"}]}}
```

The launch fields (shape, subnet, NSGs, image, count, fault domains, boot
volume) are for whoever launches instances; on platform None HyperShift
creates none, and `labels` and `taints` are recorded on the NodePool but never
applied to nodes.

## Image versions

`env.oci`: API `0.4.1` and sentinel `0.3.1` releases; the adapter's `main`
build pinned by commit tag, because its latest release predates the v2 task
configuration format; applier `0.1.0-rc1`. `AUTH_MODE=NONE` (sentinel 0.3.1
cannot render an auth scheme).
