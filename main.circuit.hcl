# Facts give each host's distribution, which picks MySQL's repository and
# where its configuration lives, and its architecture, since MySQL builds
# its Debian and Ubuntu packages for amd64 only.
data "conn3x_host" "facts" {
  for_each = var.hosts

  ssh {
    host             = try(each.value.address, each.value)
    host_key         = try(each.value.host_key, null)
    user             = try(each.value.user, var.ssh_user)
    port             = try(each.value.port, var.ssh_port)
    private_key_file = try(each.value.private_key_file, var.ssh_private_key_file)
    jump_hosts       = try(each.value.jump_hosts, null)
    known_hosts_file = var.ssh_known_hosts_file
  }

  lifecycle {
    postcondition {
      condition     = try(each.value.os, self.os_id) == self.os_id
      error_message = "Host ${each.key} is ${self.os_id}, not the ${try(each.value.os, "")} its os says."
    }
    postcondition {
      condition     = self.os_family != "debian" || (self.arch == "x86_64" && contains(keys(local.codename), self.os_version))
      error_message = "Host ${each.key} is ${self.os_id} ${self.os_version} on ${self.arch}. MySQL's apt repository builds for amd64 on Ubuntu 24.04 and 26.04 and Debian 12 and 13."
    }
    postcondition {
      condition     = self.os_family == "debian" || (self.os_id != "fedora" && startswith(self.os_version, "10"))
      error_message = "Host ${each.key} is ${self.os_id} ${self.os_version}. This circuit supports Enterprise Linux 10 from MySQL's yum repository; MySQL doesn't build for Fedora 45."
    }
  }
}

locals {
  # A host object's os stands in for the facts of a host created in the
  # same plan, which can't be read until it exists.
  os     = { for name, h in var.hosts : name => try(h.os, data.conn3x_host.facts[name].os_id) }
  family = { for name, o in local.os : name => contains(["debian", "ubuntu"], o) ? "debian" : "redhat" }

  apt_hosts    = { for name, h in var.hosts : name => h if local.family[name] == "debian" }
  redhat_hosts = { for name, h in var.hosts : name => h if local.family[name] == "redhat" }

  codename = { "24.04" = "noble", "26.04" = "resolute", "12" = "bookworm", "13" = "trixie" }

  # Both families read every file in their drop-in directory in name order,
  # and the last value read wins. zz- sorts after the packages' own files.
  # The systemd unit is mysql on Debian and Ubuntu, and mysqld on Red Hat.
  layout = {
    debian = {
      config  = "/etc/mysql/mysql.conf.d/zz-conn3x.cnf"
      service = "mysql"
    }
    redhat = {
      config  = "/etc/my.cnf.d/zz-conn3x.cnf"
      service = "mysqld"
    }
  }
  hosts = { for name, f in local.family : name => local.layout[f] }

  port    = try(var.settings.port, "3306")
  datadir = try(var.settings.datadir, "/var/lib/mysql")

  conf = join("", concat(
    ["# Managed by Conn3x.\n[mysqld]\n"],
    [for k, val in merge(var.settings, { bind-address = var.bind_address }) : "${k} = ${val}\n"],
  ))

  password_dir = "/etc/conn3x/mysql"

  # Each user exists once per entry in user_hosts.
  accounts = { for u in var.users : u => [for h in var.user_hosts : "'${u}'@'${h}'"] }

  # In a database-level grant, _ and % are wildcards, so app_db would also
  # match appXdb. Escaping them grants on that one database.
  grants = {
    for g in var.grants : "${g.user}:${g.database}" => merge(g, {
      db  = replace(replace(g.database, "_", "\\_"), "%", "\\%")
      all = contains(g.privileges, "ALL PRIVILEGES")
    })
  }
}

# MySQL's apt repository, with one component per release series. The
# package installs, initialises and starts the server, and with no root
# password to ask for, it lets root in over the local socket only.
circuit "mysql_apt" {
  hosts = local.apt_hosts

  ssh {
    user             = var.ssh_user
    port             = var.ssh_port
    private_key_file = var.ssh_private_key_file
    known_hosts_file = var.ssh_known_hosts_file
    become           = var.ssh_become
  }

  step "repo" {
    repository {
      name       = "mysql"
      url        = "https://repo.mysql.com/apt/${local.os[each.key]}"
      key        = file("${path.module}/files/mysql.asc")
      suites     = [local.codename[data.conn3x_host.facts[each.key].os_version]]
      components = ["mysql-${var.mysql_version}-lts"]
    }
  }

  step "server" {
    package {
      name = "mysql-community-server"
    }
  }
}

# MySQL's yum repository. Enterprise Linux 10 has no modules, so there is
# no mysql module to disable, which MySQL's guide asks for on EL8 only, and
# the distribution's own MySQL is packaged as mysql8.4-server, which this
# name doesn't match.
circuit "mysql_el" {
  hosts = local.redhat_hosts

  ssh {
    user             = var.ssh_user
    port             = var.ssh_port
    private_key_file = var.ssh_private_key_file
    known_hosts_file = var.ssh_known_hosts_file
    become           = var.ssh_become
  }

  step "repo" {
    repository {
      name = "mysql-community"
      url  = "https://repo.mysql.com/yum/mysql-${var.mysql_version}-community/el/$releasever/$basearch"
      key  = file("${path.module}/files/mysql.asc")
    }
  }

  step "server" {
    package {
      name = "mysql-community-server"
    }
  }

  # The package's /etc/my.cnf doesn't read /etc/my.cnf.d, where the
  # distribution's packages and this circuit put their drop-ins.
  step "include" {
    line {
      path   = "/etc/my.cnf"
      regexp = "^!includedir +/etc/my\\.cnf\\.d/?$"
      line   = "!includedir /etc/my.cnf.d"
    }
  }
}

# SELinux only lets MySQL bind ports labelled mysqld_port_t, which 3306
# already is. Another port gets the label here, on hosts where SELinux is on.
circuit "mysql_selinux" {
  hosts = local.redhat_hosts

  ssh {
    user             = var.ssh_user
    port             = var.ssh_port
    private_key_file = var.ssh_private_key_file
    known_hosts_file = var.ssh_known_hosts_file
    become           = var.ssh_become
  }

  step "semanage" {
    for_each = local.port == "3306" ? [] : ["policycoreutils-python-utils"]
    package {
      name = item.value
    }
  }

  step "port" {
    for_each = local.port == "3306" ? [] : [local.port]
    command {
      command = "semanage port -a -t mysqld_port_t -p tcp ${item.value} || semanage port -m -t mysqld_port_t -p tcp ${item.value}"
      unless  = "! selinuxenabled || semanage port -l | awk '$1 == \"mysqld_port_t\" && $2 == \"tcp\"' | grep -qw ${item.value}"
    }
  }
}

circuit "mysql" {
  hosts = var.hosts

  ssh {
    user             = var.ssh_user
    port             = var.ssh_port
    private_key_file = var.ssh_private_key_file
    known_hosts_file = var.ssh_known_hosts_file
    become           = var.ssh_become
  }

  step "config" {
    file {
      path    = local.hosts[each.key].config
      content = local.conf
      mode    = "0644"
    }
    depends_on = [conn3x_package.mysql_apt__server, conn3x_line.mysql_el__include, conn3x_command.mysql_selinux__port]
  }

  # On Red Hat the data directory is created on the server's first start,
  # with a random root password written to the log. Creating it here first,
  # after the drop-in, leaves root without a password until the auth_socket
  # step below, and lets settings that only count at creation, such as
  # lower_case_table_names, take effect. Debian's package already did it.
  step "initialize" {
    command {
      command = "cd / && mysqld --initialize-insecure --user=mysql"
      creates = "${local.datadir}/mysql"
    }
  }

  # Before anything restarts, checks the new file. mysqld reads every option
  # file as a server start would and stops at an option it doesn't know, so
  # a misspelt setting fails the apply and the running server keeps what it
  # had.
  step "check" {
    command {
      command = "cd / && out=$(mysqld --validate-config --user=mysql 2>&1) || { echo \"$out\" >&2; exit 1; }"
      triggers = {
        config  = conn3x_file.mysql__config[each.key].revision
        include = try(conn3x_line.mysql_el__include[each.key].revision, "")
      }
    }
  }

  # bind-address, port and most settings only take effect on a restart. It
  # runs here rather than in a handler so the steps below find the server
  # running with the new settings. On Red Hat's first apply it's what starts
  # the server.
  step "restart" {
    command {
      command = "systemctl restart ${local.hosts[each.key].service}"
      triggers = {
        config  = conn3x_file.mysql__config[each.key].revision
        include = try(conn3x_line.mysql_el__include[each.key].revision, "")
      }
    }
  }

  step "running" {
    service {
      name    = local.hosts[each.key].service
      state   = "started"
      enabled = true
    }
  }

  # root logs in over the local socket as the system's root, with no
  # password to set or steal, which is how this circuit itself connects.
  step "auth_socket" {
    command {
      command = <<-EOT
        set -e
        if ! mysql -NB -e "SELECT 1 FROM information_schema.PLUGINS WHERE PLUGIN_NAME = 'auth_socket'" | grep -qx 1; then
          mysql -e "INSTALL PLUGIN auth_socket SONAME 'auth_socket.so'"
        fi
        mysql -e "ALTER USER 'root'@'localhost' IDENTIFIED WITH auth_socket"
      EOT
      unless  = "mysql -NB -e \"SELECT plugin FROM mysql.user WHERE User = 'root' AND Host = 'localhost'\" | grep -qx auth_socket"
    }
  }

  # What mysql_secure_installation does, apart from the root password.
  # MySQL doesn't create these any more, so this only acts on ones someone
  # added later.
  step "secure" {
    command {
      command = <<-EOT
        set -e
        drops=$(mysql -NB -e "SELECT CONCAT('DROP USER ', QUOTE(User), '@', QUOTE(Host), ';') FROM mysql.user WHERE User = '' OR (User = 'root' AND Host NOT IN ('localhost', '127.0.0.1', '::1'))")
        printf '%s\n' "$drops" | mysql
        mysql <<'SQL'
        DROP DATABASE IF EXISTS test;
        DELETE FROM mysql.db WHERE Db IN ('test', 'test\_%');
        FLUSH PRIVILEGES;
        SQL
      EOT
      unless  = <<-EOT
        n=$(mysql -NB <<'SQL'
        SELECT (SELECT COUNT(*) FROM mysql.user WHERE User = '' OR (User = 'root' AND Host NOT IN ('localhost', '127.0.0.1', '::1')))
             + (SELECT COUNT(*) FROM information_schema.SCHEMATA WHERE SCHEMA_NAME = 'test')
             + (SELECT COUNT(*) FROM mysql.db WHERE Db IN ('test', 'test\_%'));
        SQL
        ) && [ "$n" = 0 ]
      EOT
    }
  }

  step "password_dir" {
    directory {
      path = local.password_dir
      mode = "0700"
    }
  }

  # Each password lands in a root-only file, never in state or the plan.
  step "password" {
    for_each = toset(var.users)
    file {
      path       = "${local.password_dir}/${item.key}"
      content_wo = var.user_passwords[item.key]
    }
  }

  # Creates the accounts locked, so none of them is ever open without a
  # password. set_password unlocks them.
  step "user" {
    for_each = toset(var.users)
    command {
      command = "mysql -e \"CREATE USER IF NOT EXISTS ${join(", ", local.accounts[item.key])} ACCOUNT LOCK\""
      unless  = "[ \"$(mysql -NB -e \"SELECT COUNT(*) FROM mysql.user WHERE User = '${item.key}' AND Host IN ('${join("', '", var.user_hosts)}')\")\" = ${length(var.user_hosts)} ]"
    }
  }

  # Sets the password when its file changed or an account was added. The
  # password reaches mysql on stdin as part of the SQL, so it never shows in
  # ps, and the server stores only its hash.
  step "set_password" {
    for_each = toset(var.users)
    command {
      command = <<-EOT
        set -e
        pw=$(sed -e 's/\\/\\\\/g' -e "s/'/''/g" ${local.password_dir}/${item.key} | tr -d '\n')
        printf '%s\n' "ALTER USER ${join(", ", [for a in local.accounts[item.key] : "${a} IDENTIFIED BY '$pw'"])} ACCOUNT UNLOCK;" | mysql
      EOT
      triggers = {
        password = conn3x_file.mysql__password["${each.key}/${item.key}"].revision
        user     = conn3x_command.mysql__user["${each.key}/${item.key}"].revision
      }
    }
  }

  step "database" {
    for_each = toset(var.databases)
    command {
      command = "mysql -e 'CREATE DATABASE IF NOT EXISTS `${item.key}`'"
      unless  = "mysql -NB -e \"SELECT 1 FROM information_schema.SCHEMATA WHERE SCHEMA_NAME = '${item.key}'\" | grep -qx 1"
    }
  }

  # GRANT only adds, so running it again is harmless. unless looks for every
  # privilege on every one of the user's accounts.
  step "grant" {
    for_each = local.grants
    command {
      command = <<-EOT
        mysql <<'SQL'
        GRANT ${join(", ", item.value.privileges)} ON `${item.value.db}`.* TO ${join(", ", local.accounts[item.value.user])};
        SQL
      EOT
      unless = item.value.all ? join(" && ", [
        for a in local.accounts[item.value.user] :
        "mysql -NBr -e \"SHOW GRANTS FOR ${a}\" | grep -qF 'GRANT ALL PRIVILEGES ON `${item.value.db}`.* TO'"
      ]) : <<-EOT
        n=$(mysql -NB <<'SQL'
        SELECT COUNT(*) FROM information_schema.SCHEMA_PRIVILEGES
         WHERE TABLE_SCHEMA = '${item.value.db}'
           AND GRANTEE IN (${join(", ", [for h in var.user_hosts : "'''${item.value.user}''@''${h}'''"])})
           AND PRIVILEGE_TYPE IN ('${join("', '", item.value.privileges)}');
        SQL
        ) && [ "$n" = ${length(var.user_hosts) * length(item.value.privileges)} ]
      EOT
    }
  }
}
