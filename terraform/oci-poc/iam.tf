# The cloud controller manager creates and owns one frontend NSG per
# LoadBalancer service (architecture ADR 0024). Services must carry
# `oci.oraclecloud.com/security-rule-management-mode: "NSG"`.
module "oke_lb_nsg_policy" {
  source = "../modules/oke-lb-nsg-policy/oci"

  compartment_id = local.service_compartment_id
  freeform_tags  = local.tags
}

# Worker identity for each customer. A hosted cluster's guest runs Oracle's
# cloud controller manager and block volume CSI driver on its worker nodes,
# which authenticate as instance principals. Rather than a dynamic group per
# customer (tenancies cap how many exist, and this shared tenancy is at the
# cap), each customer's policy grants any instance principal whose own
# compartment is that customer's compartment, and only in that compartment.
resource "oci_identity_policy" "customer_workers" {
  for_each = local.customer_compartment_ids

  compartment_id = each.value
  name           = "${var.name_prefix}-${each.key}-workers"
  description    = "Lets ${each.key} workers run the guest cloud controller manager and block volume CSI driver in their own compartment."
  statements = [
    for s in var.customer_worker_policy_verbs :
    "allow any-user to ${s} in compartment id ${each.value} where ALL {request.principal.type = 'instance', request.principal.compartment.id = '${each.value}'}"
  ]
  freeform_tags = local.tags
}
