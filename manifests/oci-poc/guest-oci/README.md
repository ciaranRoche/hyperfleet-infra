# OCI integration for a platform None hosted cluster

What a `platform: None` hosted cluster's guest needs so that LoadBalancer
Services, block volumes, the default ingress and the image registry land in
the customer's OCI compartment. This is the provider package Oracle's
standalone OpenShift stack (`oracle-quickstart/oci-openshift`) carries, adapted
to a hosted cluster whose guest has worker nodes only.

Driven by `scripts/oci-poc-guest-oci.sh` (`install`, then `configure`).

## Pieces

| Piece | Where | Why |
| --- | --- | --- |
| `nodepool-config-kubelet-identity.yaml` | NodePool `spec.config` | Sets `KUBELET_PROVIDERID=oci://<instance OCID>` and the zone, region and instance-type node labels from instance metadata. On None the kubelet runs with `--cloud-provider=` and nothing else sets them; without the zone label the block volume CSI driver reports an empty availability domain |
| `nodepool-config-device-path.yaml` | NodePool `spec.config` | Oracle's udev rules for `/dev/oracleoci/oraclevd*`, which the CSI driver waits for on both iSCSI and paravirtualized attachments |
| Oracle CCM and block volume CSI, `oracle/oci-cloud-controller-manager` v1.35.1 | guest, namespaces `oci-cloud-controller-manager` and `oci-csi` | Upstream release manifests, moved out of `kube-system` and re-targeted from `node-role.kubernetes.io/control-plane` to `node-role.kubernetes.io/worker` (a hosted guest has no control-plane nodes). Instance principal auth, `securityListManagementMode: None`, load balancers opt into a CCM-owned NSG per Service |
| `guest-network-masquerade.yaml` | guest `network.operator/cluster` | Moves OVN-Kubernetes's internal masquerade subnet off `169.254.0.0/17`, which covers OCI's iSCSI targets. HostedCluster does not expose this field |
| HostedCluster `operatorConfiguration.ingressOperator` | management cluster | Default IngressController created as `LoadBalancerService` (the HCCO only applies this at creation; converting an existing HostNetwork controller does not work) |
| `router-default-internal-lb.yaml` | guest Service `openshift-ingress/router-default` | Makes the ingress load balancer internal in the customer's private subnet. Keep the IngressController scope `External`: on None the ingress operator has no notion of an internal OCI load balancer |
| `registry-pvc.yaml` | guest | ReadWriteOnce block volume for the image registry (one replica, Recreate); the operator's own claim is ReadWriteMany |

## IAM

No dynamic group. In each customer compartment, one policy lets instance
principals whose own compartment is that compartment act only there
(`terraform/oci-poc/iam.tf`):

```
allow any-user to manage load-balancers in compartment id <c> where ALL {request.principal.type = 'instance', request.principal.compartment.id = '<c>'}
allow any-user to manage network-security-groups in compartment id <c> where ALL {...}
allow any-user to manage virtual-network-family in compartment id <c> where ALL {...}
allow any-user to manage volume-family in compartment id <c> where ALL {...}
allow any-user to manage instance-family in compartment id <c> where ALL {...}
```

`use virtual-network-family` was not enough: the CCM's `CreateNetworkSecurityGroup`
returned `NotAuthorizedOrNotFound` until `manage` was granted.

## Order of operations

```bash
# management cluster: NodePool configs are applied by oci-poc-hypershift.sh cluster-up
export GUEST_KUBECONFIG=<hosted cluster admin kubeconfig>
export COMPARTMENT_ID=<customer compartment> VCN_ID=<customer VCN> LB_SUBNET_ID=<customer lb-private subnet>
scripts/oci-poc-guest-oci.sh install
scripts/oci-poc-guest-oci.sh configure
# DNS: *.apps.<cluster>.<base domain> -> the router-default load balancer IP
```

Workers launched before the NodePool carried the two configs do not change
on None; replace them (`scripts/oci-poc-worker.sh launch`, `approve`, then
drain and `terminate` the old ones).
