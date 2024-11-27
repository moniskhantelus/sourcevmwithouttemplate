
output "attachments" {
  description = "Disk attachments to the resource policy."
  value       = google_compute_disk_resource_policy_attachment.attachment[*]
}
