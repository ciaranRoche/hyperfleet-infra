output "vcn_id" {
  description = "OCID of the VCN."
  value       = oci_core_vcn.this.id
}

output "cidr" {
  description = "CIDR block of the VCN."
  value       = var.cidr
}

output "subnet_ids" {
  description = "Subnet OCIDs keyed by the subnet key."
  value       = { for k, s in oci_core_subnet.this : k => s.id }
}

output "subnet_cidrs" {
  description = "Subnet CIDRs keyed by the subnet key."
  value       = { for k, s in var.subnets : k => s.cidr }
}

output "private_route_table_id" {
  description = "OCID of the private route table, null when there is no private subnet."
  value       = try(oci_core_route_table.private[0].id, null)
}

output "public_route_table_id" {
  description = "OCID of the public route table, null when there is no public subnet."
  value       = try(oci_core_route_table.public[0].id, null)
}

output "nat_gateway_ip" {
  description = "Public IP of the NAT gateway, null when there is no private subnet."
  value       = try(oci_core_nat_gateway.this[0].nat_ip, null)
}

output "drg_attachment_id" {
  description = "OCID of the DRG attachment, null when drg_id was not set."
  value       = try(oci_core_drg_attachment.this[0].id, null)
}
