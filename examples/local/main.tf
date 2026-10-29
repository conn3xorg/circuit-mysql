variable "port" {
  type    = number
  default = 2284
}

variable "app_password" {
  type      = string
  ephemeral = true
  sensitive = true
}

module "mysql" {
  source = "../.."

  hosts                = { box = "127.0.0.1" }
  ssh_port             = var.port
  ssh_private_key_file = "./id_ed25519"
  ssh_known_hosts_file = "./known_hosts"

  settings       = { max_connections = "50", innodb_buffer_pool_size = "64M" }
  users          = ["app"]
  user_passwords = { app = var.app_password }
  databases      = ["app", "other"]
  grants         = [{ user = "app", database = "app" }]
}
