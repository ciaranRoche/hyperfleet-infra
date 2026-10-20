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
| Label and taint | node pool spec | `kubectl label` and `taint` on its nodes (None never applies NodePool labels or taints); the keys it applied are kept in the `hyperfleet.io/oci-provisioner-managed` node annotation, so a label or taint removed from the spec is removed from the nodes |
| Repair | instance state and its Node | an instance that is STOPPED or STOPPING, whose Node has been NotReady for 5 minutes, or that has run 15 minutes without registering a Node, is replaced like a stale one: surge one, then remove it without a drain |
| Replace on config change | instance tag vs current config version | surge one new instance, retire a stale one only when every current instance is Ready: cordon, drain, delete Node, terminate |
| Scale down | count | cordon, drain, delete Node, terminate the newest |
| Pause a blocked drain | `kubectl drain --timeout=60s` | if a drain cannot finish (a PodDisruptionBudget allows no disruption, say), leave the node cordoned and the instance running, report `DrainBlocked` naming the budget, retry every pass; uncordon it if the spec stops wanting it gone |
| Bootstrap the guest | cluster spec `compartment_id`, `vcn_id`, `lb_subnet_id` | once a node is Ready: OCI provider package (`scripts/oci-poc-guest-oci.sh install` and `configure`, everything tagged `hyperfleet-cluster`), `*.apps` DNS record to the ingress load balancer |
| Mark retained volumes | guest PersistentVolumes | tag the OCI volume behind every reclaim-policy Retain block volume PV `hyperfleet-retain=true` while the guest is alive; the reaper and the cluster's `Finalized` check leave those volumes alone |
| Clean up on cluster delete | cluster `deleted_time` | delete the guest's LoadBalancer Services and PVCs with reclaim policy Delete, and keep the nodes (and with them the guest CCM and CSI) until they are gone or 10 minutes pass; remove the `*.apps` record |
| Reap | tags | terminate instances whose node pool is gone; delete load balancers and volumes tagged with a cluster that is gone or has no instances left; delete CCM NSGs whose load balancer is gone |
| Report | `PUT .../statuses` as adapter `oci-provisioner`, on node pools and clusters | node pool: instances, Ready nodes, config version, `Applied` and `Available` False with reason `DrainBlocked` while a drain is paused, `Finalized` once its instances are gone; cluster: `Available` once the guest is bootstrapped, `Finalized` once no instances or tagged load balancers and volumes remain |

The `oci` Helmfile environment lists `oci-provisioner` under `externalAdapters`,
so the API requires its status on clusters and node pools: a node pool is
reconciled only with Ready nodes, and neither is hard-deleted before the
stand-in reports `Finalized`.

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
| Cleans up guest load balancers and volumes before the control plane goes, and reaps by tag afterwards | the guest CCM and CSI create resources in the customer compartment and run on the workers, so they go with the last node; every required adapter gets the delete at once, `hc-hypershift` deletes the HostedCluster straight away, and the guest API was gone within a minute of the `DELETE`, so in practice the reaper does all of it | a delete ordering in HyperFleet (guest cloud resources, then workers, then the control plane), and the cluster tag on every created resource from the moment it is created; a resource created before the tag is configured cannot be traced back |
| Tags load balancers and volumes through the CCM `tags.loadBalancer` and `tags.blockVolume` sections | `tags.common` is only merged when OKE's resource tracking feature is on, which it is not outside OKE | the provider package setting per-kind tags |
| Finds CCM NSGs by name | the CCM tags its per-load-balancer NSGs with `CreatedBy` and `ServiceUid` only | the cluster tag on NSGs too |
| Is a required adapter only through an `externalAdapters` list in the Helmfile environment | the API derives required adapters from the adapters Helmfile deploys | a supported way to register an external reporter as required, per kind |
| Reports `Available` on a cluster once the guest is bootstrapped | it has no cheap signal for "every operator is healthy" | a status that says what it means: bootstrapped (about 12 minutes from `POST`) is not complete (about 17 minutes) |
| Approves a stopped period's CSR backlog in one go | a kubelet with no approved client CSR raises a new one about every 15 minutes | an approver that only accepts the newest CSR per node |
| Polls every 30 seconds | HyperFleet has no event the provider can subscribe to | a subscription (broker topic or webhook) for node pool changes |
| Learns a NodePool config change only when the adapter next reports | a change made in HyperShift directly does not bump the HyperFleet generation, so the adapter does not run again until the sentinel's 30-minute staleness rule | config changes only through HyperFleet, or the adapter reporting on HyperShift changes |
| Keeps a paused drain only in memory, one cluster at a time in a single loop | it is a stand-in; a restart re-detects the block on its next pass, and one slow guest delays the others (two cold runs finished together) | durable per node pool state and per-cluster workers |
| Decides which volumes are Retain from the guest | the reclaim policy lives on the guest's PV; once the cluster is deleted the guest is gone within about a minute | the provider package tagging Retain volumes at provisioning time, and an API object for volumes that outlive their cluster (today nothing lists or reclaims them) |
| Repairs from instance and Node state with fixed grace periods | None has no MachineHealthCheck | health rules the customer can tune, and the API reporting a repair in progress |
| One OCI API key for every customer compartment | it runs in our tenancy | cross-tenancy launch permissions granted by each customer |
