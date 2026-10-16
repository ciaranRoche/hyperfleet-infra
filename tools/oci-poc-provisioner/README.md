# OCI provisioner stand-in

**This tool stands in for the service the cloud provider would run to give a
`platform: None` hosted cluster its workers.** HyperShift on None creates no
machines: a NodePool only produces an ignition stub with a bearer token. Some
service has to launch instances with that stub in the customer's compartment,
keep their number and configuration right, and remove them. In the OCI
offering that service is the provider's. This is a proof-of-concept version of
it, written to find out what such a service needs from HyperFleet and
HyperShift. It is not production code.

## What it does

One reconcile pass every 30 seconds (`--once` for a single pass):

| Step | Source of truth | Action |
| --- | --- | --- |
| Read intent | `GET /clusters`, `GET /nodepools` | node pool `spec`: count, shape, ocpus, memory_gb, boot_volume_gb, image_id, compartment_id, subnet_id, nsg_ids, fault_domains, labels, taints |
| Find the user-data | `np-hypershift` status data | `user_data_secret_namespace`, `user_data_secret_name`, `config_version` |
| Launch | `oci compute instance launch` | one instance per pass until the count of instances at the current config version is reached; spread over `fault_domains`; tagged `hyperfleet-cluster`, `hyperfleet-nodepool-id`, `hyperfleet-config-version` |
| Admit nodes | guest CSRs | approve client CSRs whose subject is a node it launched, and serving CSRs from those nodes; nothing else |
| Label and taint | node pool spec | `kubectl label` and `taint` on its nodes (None never applies NodePool labels or taints) |
| Replace on config change | instance tag vs current config version | surge one new instance, retire a stale one only when every current instance is Ready: cordon, drain, delete Node, terminate |
| Scale down | count | cordon, drain, delete Node, terminate the newest |
| Bootstrap the guest | cluster spec `compartment_id`, `vcn_id`, `lb_subnet_id` | once a node is Ready: OCI provider package (`scripts/oci-poc-guest-oci.sh install` and `configure`, everything tagged `hyperfleet-cluster`), `*.apps` DNS record to the ingress load balancer |
| Clean up on cluster delete | cluster `deleted_time` | delete the guest's LoadBalancer Services and PVCs while the guest still answers |
| Reap | tags | terminate instances whose node pool is gone; delete load balancers, NSGs and volumes tagged with a cluster that is gone |
| Report | `PUT .../nodepools/{id}/statuses` as adapter `oci-provisioner` | instances, Ready nodes, config version |

## Running it

```bash
export MGMT_KUBECONFIG=<OKE kubeconfig> OCI_CLI_PROFILE=APIKEY OCI_CLI_AUTH=api_key
export HYPERFLEET_API=http://127.0.0.1:18000/api/hyperfleet/v1   # gateway port-forward
export DNS_COMPARTMENT_ID=<zone compartment> REAP_COMPARTMENTS=<customer compartments, comma separated>
tools/oci-poc-provisioner/provisioner.py
```

Python 3 standard library; needs `oci`, `kubectl` and `openssl` on the path.

## Seams: every shortcut it takes

Each row is something a real provider service could not do this way, and
therefore something HyperFleet, HyperShift or the provider has to design.

| Shortcut | Why it is needed | What a real service needs instead |
| --- | --- | --- |
| Reads the user-data secret from the management cluster with management cluster credentials | HyperFleet reports where the stub is, not the stub | a scoped, audited way to fetch one NodePool's stub (an API returning it to an authorised caller, or a token exchange), never management cluster access |
| Uses the hosted cluster's admin kubeconfig through a management cluster port-forward | CSR approval, drain, node deletion, labels and taints all need the guest API | a narrow guest identity (CSR approver and node lifecycle only), reachable from the provider's network |
| Approves CSRs itself | the machine-approver on None matches CSRs to Machines, which None never creates | a CSR approver that trusts the provider's launch records, in the control plane or the guest |
| Applies node labels and taints | None ignores NodePool `nodeLabels` and `taints` | HyperShift applying them on None, or the provider doing it as part of the contract |
| Drains through the guest API | scale down and replace need cordon and drain | the same narrow guest identity, plus PodDisruptionBudget handling rules |
| Installs the OCI provider package and configures the guest | a None guest has no CCM, CSI, ingress load balancer or registry storage | an owned, versioned provider package delivered by HyperShift or an operator, not by the instance launcher |
| Writes `*.apps` DNS | nothing else knows the ingress load balancer's IP | a DNS owner for guest ingress (external-dns in the guest, or the provider) |
| Cleans up guest load balancers and volumes before the control plane goes, and reaps by tag afterwards | the guest CCM and CSI create resources in the customer compartment and disappear with the cluster | a delete ordering in HyperFleet (provider finalizes before the hosted cluster is removed), and tags on every created resource |
| Polls every 30 seconds | HyperFleet has no event the provider can subscribe to | a subscription (broker topic or webhook) for node pool changes |
| Learns a NodePool config change only when the adapter next reports | a change made in HyperShift directly does not bump the HyperFleet generation, so the adapter does not run again until the sentinel's 30-minute staleness rule | config changes only through HyperFleet, or the adapter reporting on HyperShift changes |
| One OCI API key for every customer compartment | it runs in our tenancy | cross-tenancy launch permissions granted by each customer |
