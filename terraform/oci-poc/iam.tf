# The cloud controller manager creates and owns one frontend NSG per
# LoadBalancer service (architecture ADR 0024). Services must carry
# `oci.oraclecloud.com/security-rule-management-mode: "NSG"`.
module "oke_lb_nsg_policy" {
  source = "../modules/oke-lb-nsg-policy/oci"

  compartment_id = local.service_compartment_id
  freeform_tags  = local.tags
}
