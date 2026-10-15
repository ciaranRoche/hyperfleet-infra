output "compartment_ids" {
  description = "OCIDs of the service and customer compartments, keyed by compartment name."
  value       = { for k, m in module.compartment : k => m.id }
}
