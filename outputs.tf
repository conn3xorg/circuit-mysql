output "config_files" {
  description = "Drop-in file holding bind_address and settings on each host, by host name."
  value       = { for name, h in local.hosts : name => h.config }
}
