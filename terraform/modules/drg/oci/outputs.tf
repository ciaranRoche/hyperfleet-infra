output "drg_id" {
  description = "OCID of the DRG."
  value       = oci_core_drg.this.id
}

output "route_table_ids" {
  description = "DRG route table OCIDs keyed by the route table key."
  value       = { for k, t in oci_core_drg_route_table.this : k => t.id }
}
