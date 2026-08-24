# HyperFleet OCI Infrastructure

Terraform for the team's OCI environment in the `rhelcert` tenancy: VCN, OKE cluster, and container registry repositories, with an optional DNS zone. Mirrors the GKE setup one directory up, reusing the same module layout (`../modules/network/oci-vcn`, `../modules/cluster/oke`) and the same GCS state backend.

## What it creates

| Resource | Name | Notes |
|----------|------|-------|
| VCN | `hyperfleet-poc-vcn` | 10.20.0.0/16 (avoids the demo VCNs and GCP dev ranges) |
| Subnets | `-public`, `-private` | Public: LBs + OKE API endpoint. Private: worker nodes |
| Gateways | igw, nat, sgw | Internet (public), NAT + service gateway (private) |
| OKE cluster | `hyperfleet-poc-oke` | Basic cluster, flannel CNI, public API endpoint, latest k8s unless pinned |
| Node pool | `hyperfleet-poc-oke-pool` | 3x VM.Standard.E4.Flex (2 OCPU / 16 GB), private subnet |
| Registry repos | `hyperfleet-poc/*` | Private OCIR repositories |
| DNS zone | optional | Only with a delegatable domain; skipped by default |

All resources land in the `hyperfleet-poc` compartment and carry `owner` / `managed-by` / `project` freeform tags.

## Prerequisites

- Terraform >= 1.5
- OCI CLI authenticated: `oci session authenticate --region us-sanjose-1` (profile `DEFAULT`). Sessions last ~1h; `oci session refresh` extends without the browser
- Membership of `Grp-HyperFleet` (grants `manage all-resources` in the `HyperFleet` compartment)
- For remote state: access to the team's GCS state bucket (same one the GKE stacks use)

## Usage

```bash
cd terraform/oci

# remote state (copy ../envs/oke/poc.tfbackend.example first)
terraform init -backend-config=../envs/oke/poc-<your-name>.tfbackend

terraform plan -var-file=../envs/oke/poc.tfvars
terraform apply -var-file=../envs/oke/poc.tfvars

# kubeconfig for the new cluster
terraform output -raw kubeconfig_command | bash
kubectl get nodes
```

**kubeconfig gotcha:** the generated kubeconfig authenticates via an `oci ce cluster generate-token` exec plugin, and that call does NOT inherit the `--auth security_token` flag, so kubectl fails with "config file invalid: user missing" unless the CLI can find credentials. Fix either way:

- `export OCI_CLI_AUTH=security_token` in your shell profile (recommended, also saves typing it on every `oci` call), or
- add `--auth security_token` to the exec `args` of the cluster's user entry in `~/.kube/config`

Teardown:

```bash
terraform destroy -var-file=../envs/oke/poc.tfvars
```

After destroy, check the compartment for stragglers, OKE-created load balancers and block volumes are not always owned by Terraform state:

```bash
oci search resource structured-search \
  --query-text "query all resources where compartmentId = '<compartment-ocid>'" \
  --auth security_token
```

## Conventions

- **Every resource goes through `var.compartment_id`**, one variable, so the whole stack provably targets one compartment
- **Tag or name resources with your kerberos** (`owner` variable) so ownership is traceable
- The security lists are POC-loose (VCN-open, 443/6443 from anywhere). Tighten before anything production-shaped
- Flannel CNI keeps subnet requirements simple; revisit VCN-native pod networking when workloads need it
