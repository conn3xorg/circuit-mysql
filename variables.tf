variable "hosts" {
  type        = any
  description = "Hosts to configure: a map of names to addresses, or to host objects with an address and optional host_key, user, port, private_key_file, jump_hosts or os."

  validation {
    condition     = alltrue([for h in var.hosts : contains(["debian", "ubuntu", "rocky", "almalinux", "rhel"], try(h.os, "debian"))])
    error_message = "A host object's os must be one of debian, ubuntu, rocky, almalinux or rhel. CentOS Linux reached end of life on 30 June 2024: use Rocky Linux."
  }
}

variable "ssh_user" {
  type        = string
  default     = "root"
  description = "User to log in as."
}

variable "ssh_port" {
  type        = number
  default     = 22
  description = "SSH port."
}

variable "ssh_private_key_file" {
  type        = string
  default     = null
  description = "Path to a private key. When null, Conn3x uses the SSH agent."
}

variable "ssh_known_hosts_file" {
  type        = string
  default     = null
  description = "known_hosts file to check host keys against. When null, ~/.ssh/known_hosts."
}

variable "ssh_become" {
  type        = bool
  default     = false
  description = "Run commands as root through sudo."
}

variable "mysql_version" {
  type        = string
  default     = "9.7"
  description = "MySQL long-term support series to install from MySQL's repository: \"9.7\" or \"8.4\". Changing it on a host that already runs MySQL switches the repository but doesn't upgrade the server."

  validation {
    condition     = contains(["8.4", "9.7"], var.mysql_version)
    error_message = "mysql_version must be a long-term support series MySQL still builds: \"8.4\" or \"9.7\"."
  }
}

variable "bind_address" {
  type        = string
  default     = "127.0.0.1"
  description = "Addresses MySQL listens on, comma-separated, such as \"127.0.0.1\", \"0.0.0.0\" or \"127.0.0.1,10.0.0.5\". Changing it restarts MySQL."

  validation {
    condition     = can(regex("^[A-Za-z0-9.:_-]+( *, *[A-Za-z0-9.:_-]+)*$", var.bind_address))
    error_message = "bind_address must be a comma-separated list of host names or IP addresses."
  }
}

variable "settings" {
  type        = map(string)
  default     = {}
  description = "Server settings for the [mysqld] section, such as { max_connections = \"200\", innodb_buffer_pool_size = \"1G\" }. They go to a zz-conn3x.cnf drop-in, and changing them restarts MySQL."

  validation {
    condition     = alltrue([for k, v in var.settings : can(regex("^[a-z][a-z0-9_-]*$", k)) && !strcontains(v, "\n")])
    error_message = "Setting names use lowercase letters, digits, _ and -, and values can't contain line breaks."
  }

  validation {
    condition     = !contains(keys(var.settings), "bind-address") && !contains(keys(var.settings), "bind_address")
    error_message = "Set bind_address with its own input, not in settings."
  }

  validation {
    condition     = can(regex("^[0-9]+$", lookup(var.settings, "port", "3306")))
    error_message = "port must be a number."
  }
}

variable "users" {
  type        = list(string)
  default     = []
  description = "Accounts to create, one per entry in user_hosts. Each needs a password in user_passwords."

  validation {
    condition     = alltrue([for u in var.users : can(regex("^[a-z_][a-z0-9_]{0,31}$", u)) && !contains(["root", "mysql"], u)])
    error_message = "User names use lowercase letters, digits and _, start with a letter or _, are at most 32 characters, and can't be root or mysql."
  }
}

variable "user_passwords" {
  type        = map(string)
  default     = {}
  ephemeral   = true
  sensitive   = true
  nullable    = false
  description = "Password for each of users, by name. Pass it at run time with -var or TF_VAR_user_passwords; it never reaches state or the plan."

  validation {
    condition     = alltrue([for u in var.users : length(lookup(var.user_passwords, u, "")) > 0])
    error_message = "Each of users needs a non-empty password in user_passwords."
  }
}

variable "user_hosts" {
  type        = list(string)
  default     = ["localhost", "127.0.0.1", "::1"]
  description = "Hosts each of users may connect from, such as \"localhost\", \"10.0.0.%\" or \"10.0.0.0/255.255.255.0\". Every user gets one account per entry, with the same password and grants."

  validation {
    condition     = length(var.user_hosts) > 0 && alltrue([for h in var.user_hosts : can(regex("^[A-Za-z0-9.:%_/-]+$", h))])
    error_message = "user_hosts needs at least one entry, and each is a host name, an IP address, a pattern with % or _, or an address/netmask."
  }
}

variable "databases" {
  type        = list(string)
  default     = []
  description = "Databases to create, such as [\"app\"]."

  validation {
    condition     = alltrue([for d in var.databases : can(regex("^[a-z_][a-z0-9_]{0,63}$", d)) && !contains(["mysql", "sys", "information_schema", "performance_schema", "test"], d)])
    error_message = "Database names use lowercase letters, digits and _, start with a letter or _, are at most 64 characters, and can't be a system database or test."
  }
}

variable "grants" {
  type = list(object({
    user       = string
    database   = string
    privileges = optional(list(string), ["ALL PRIVILEGES"])
  }))
  default     = []
  description = "Privileges each of users gets on a database, such as { user = \"app\", database = \"app\" } for all of them, or privileges = [\"SELECT\"]. They apply to every one of the user's accounts."

  validation {
    condition     = alltrue([for g in var.grants : contains(var.users, g.user)])
    error_message = "Each grant's user must be one of users."
  }

  validation {
    condition     = alltrue([for g in var.grants : can(regex("^[a-z_][a-z0-9_]{0,63}$", g.database))])
    error_message = "Each grant's database uses lowercase letters, digits and _, and is at most 64 characters."
  }

  validation {
    condition     = length(distinct([for g in var.grants : "${g.user}:${g.database}"])) == length(var.grants)
    error_message = "Give each user and database pair one grant, listing all its privileges."
  }

  validation {
    condition = alltrue(flatten([for g in var.grants : [for p in g.privileges : contains([
      "ALL PRIVILEGES", "SELECT", "INSERT", "UPDATE", "DELETE", "CREATE", "DROP", "INDEX", "ALTER", "REFERENCES",
      "CREATE TEMPORARY TABLES", "LOCK TABLES", "EXECUTE", "CREATE VIEW", "SHOW VIEW", "CREATE ROUTINE",
      "ALTER ROUTINE", "EVENT", "TRIGGER",
    ], p)]]))
    error_message = "Each privilege is a database-level one in capitals, such as SELECT, INSERT, CREATE TEMPORARY TABLES or ALL PRIVILEGES."
  }

  validation {
    condition     = alltrue([for g in var.grants : length(g.privileges) > 0 && length(distinct(g.privileges)) == length(g.privileges) && (!contains(g.privileges, "ALL PRIVILEGES") || length(g.privileges) == 1)])
    error_message = "Each grant lists at least one privilege, none twice, and ALL PRIVILEGES stands alone."
  }
}
