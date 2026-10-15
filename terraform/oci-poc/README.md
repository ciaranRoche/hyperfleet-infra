# HyperFleet OCI POC environment

Terraform for the OCI on OKE proof of concept under the `hyperfleet-poc`
compartment: a service side with an Enhanced OKE management cluster and two
customer sides, joined by a DRG so that each customer reaches the service VCN
and the customers cannot reach each other. Separate from `terraform/oci/`, the
CI compartment stack, and from the GKE stacks.

Two stacks, applied in order:

| Stack | Holds | Why separate |
| --- | --- | --- |
| `compartments/` | The three compartments | OCI deletes a compartment asynchronously and slowly (30 minutes or more after it is empty) and the name stays taken until then. Keeping them out of the rebuild cycle makes destroy and re-apply of everything else a matter of minutes. Compartments cost nothing |
| `.` (this directory) | Everything else, looked up by compartment name | Rebuilt as often as needed |

## What this creates

| Resource | Where | Purpose |
| --- | --- | --- |
| Compartments `service-provider`, `customer-a`, `customer-b` (stack `compartments/`) | siblings under `hyperfleet-poc` | The customer boundary. Siblings, never nested, because OCI policies inherit downwards. OCI reserves the plain name `service` |
| VCN `hyperfleet-poc-service` 10.60.0.0/16 | `service` | Subnets: `oke-endpoint` 10.60.0.0/28 (public), `lb-private` 10.60.1.0/24, `lb-public` 10.60.2.0/24 (public, empty), `oke-nodes` 10.60.8.0/21, `oke-pods` 10.60.128.0/17 |
| VCN `hyperfleet-poc-customer-a` 10.70.0.0/16, `-customer-b` 10.71.0.0/16 | each customer compartment | Subnets: `workers` 10.7x.8.0/21, `lb-private` 10.7x.1.0/24, `lb-public` 10.7x.2.0/24 (public) |
| Internet, NAT and service gateways, route tables | each VCN | Public subnets route to the internet gateway; private subnets to NAT, Oracle services to the service gateway, peer VCNs to the DRG |
| DRG `hyperfleet-poc-drg` with three VCN attachments | `service` | Route table `service` imports every attached VCN. Tables `customer-a` and `customer-b` carry one static route to 10.60.0.0/16 and no import distribution, which is what keeps the customers apart |
| NSGs `oke-endpoint`, `oke-nodes`, `oke-pods`, `<customer>-workers` | each VCN | The only ingress rules that exist. Every VCN's default security list is reduced to egress only |
| OKE cluster `hyperfleet-poc-oke` | `service` | `ENHANCED_CLUSTER`, VCN-native CNI, public API endpoint locked to `allowed_cidrs` on 6443, OIDC discovery on, LoadBalancer services default to `lb-private` |
| Node pool, 3 x `VM.Standard.E5.Flex` 4 OCPU / 32 GB | `service` | One node per fault domain, newest Oracle Linux OKE image for the version |
| Policy `hyperfleet-oke-lb-nsg-policy` | `service` | Lets the cloud controller manager own LoadBalancer frontend NSGs (architecture ADR 0024) |

Nothing here touches DNS. Later work adds record sets to the existing zone
through a data source; the zone itself is never managed by any stack.

## Running it

```bash
cd terraform/oci-poc/compartments
cp poc.tfbackend.example poc.tfbackend
cp poc.tfvars.example poc.tfvars     # fill in owner
terraform init -backend-config=poc.tfbackend
terraform apply -var-file=poc.tfvars

cd ..
cp poc.tfbackend.example poc.tfbackend
cp poc.tfvars.example poc.tfvars     # fill in owner and allowed_cidrs
terraform init -backend-config=poc.tfbackend
terraform plan -var-file=poc.tfvars
terraform apply -var-file=poc.tfvars
```

If your shell exports `TF_VAR_oci_auth=APIKey` from older notes, the value
this stack accepts is `ApiKey`.

`poc.tfvars` and `poc.tfbackend` are gitignored in both directories. State lives in the shared
GCS bucket under `terraform/state/oci-poc`, so `gcloud auth
application-default login` (or equivalent) must work first.

Expect roughly 15 minutes: the OKE control plane takes most of it, the node
pool another few minutes after that.

## Connecting

```bash
export OCI_CLI_PROFILE=APIKEY OCI_CLI_AUTH=api_key
eval "$(terraform output -raw connect_command)"
kubectl get nodes -L oci.oraclecloud.com/fault-domain
```

The kubeconfig's exec plugin runs `oci ce cluster generate-token` and inherits
`OCI_CLI_PROFILE` and `OCI_CLI_AUTH` from your shell; without them it falls
back to the `DEFAULT` profile and fails.

## LoadBalancer services

Every `Service` of type `LoadBalancer` on this cluster must carry

```yaml
metadata:
  annotations:
    oci.oraclecloud.com/security-rule-management-mode: "NSG"
```

so the cloud controller manager creates and owns the frontend NSG instead of
editing security lists (architecture ADR 0024). Add
`service.beta.kubernetes.io/oci-load-balancer-internal: "true"` for a private
load balancer in `lb-private`, which is the subnet customer VCNs reach over
the DRG.

## Destroying

The cloud controller manager creates load balancers and NSGs that Terraform
does not know about, and `terraform destroy` fails while they hold a subnet.
Delete every LoadBalancer service first, then sweep, then destroy:

```bash
kubectl delete svc --all-namespaces --field-selector spec.type=LoadBalancer   # or per service
OCI_COMPARTMENT_ID=<hyperfleet-poc OCID> scripts/oci-poc-sweep.sh list
OCI_COMPARTMENT_ID=<hyperfleet-poc OCID> DRY_RUN=false scripts/oci-poc-sweep.sh sweep
terraform destroy -var-file=poc.tfvars
OCI_COMPARTMENT_ID=<hyperfleet-poc OCID> scripts/oci-poc-sweep.sh list
```

The sweep removes what Terraform does not own in `hyperfleet-poc` and its
children: load balancers, network load balancers, NSGs without the
`hyperfleet-managed-by` tag, unattached volumes and console history captures.
It never deletes custom images or anything tagged `hyperfleet-keep=true`.

Two things the first destroy taught, both handled by the sweep: OKE leaves
the node pool's boot volumes behind unattached when the pool is deleted, and
a console history capture left in a compartment stops that compartment from
being deleted. Run the sweep after the destroy as well as before it.

The `compartments/` stack is not part of the rebuild cycle. Destroy it only
when the POC is over, and expect each compartment to take 30 minutes or more
to disappear once it is empty.

## Cost

While it runs: Enhanced cluster 0.10 USD per hour, three E5.Flex nodes at
4 OCPU / 32 GB roughly 0.18 USD per hour each, gateways free, boot volumes a
few USD per month. About 16 USD per day. A private flexible load balancer
adds a few cents per hour while a test service exists.
