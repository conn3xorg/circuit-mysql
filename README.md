# circuit-mysql

[![Conn3x grade](https://conn3x.org/circuits/mysql/grade.svg)](https://conn3x.org/circuits/mysql/grade)

A Conn3x circuit that installs MySQL Community Server from Oracle's own repositories, and creates the databases, users and grants your apps log in with. It does what `mysql_secure_installation` would, without anyone typing answers into it, and keeps doing it: if an anonymous user or a `test` database turns up later, the next plan shows it.

Its inputs match [circuit-mariadb](https://github.com/conn3xorg/circuit-mariadb)'s, apart from `mysql_version`, so you can switch a module between the two by changing its source and that one line. The data doesn't move with it; that's a dump and a restore.

Passwords never land in state. You pass them in at run time through an ephemeral variable, and the plan shows only that a password changed.

## Usage

```hcl
variable "app_db_password" {
  type      = string
  ephemeral = true
  sensitive = true
}

module "mysql" {
  source = "github.com/conn3xorg/circuit-mysql?ref=v0.1.0"

  hosts                = { db = "192.168.1.30" }
  ssh_private_key_file = "~/.ssh/id_ed25519"

  bind_address = "0.0.0.0"
  settings     = { innodb_buffer_pool_size = "1G", max_connections = "200" }

  users          = ["app"]
  user_passwords = { app = var.app_db_password }
  user_hosts     = ["localhost", "192.168.1.%"]
  databases      = ["app"]
  grants         = [{ user = "app", database = "app" }]
}
```

Then run `conn3x init` and `conn3x apply` with the password in the environment:

```sh
export TF_VAR_app_db_password='...'
conn3x apply
```

A second `conn3x plan` says `No changes.` Every plan needs the password too, since Conn3x checks the file on the host against it.

For hosts created in the same plan, pass host objects with the host key you generated, so Conn3x checks it without a known_hosts entry. Give each one's distribution in `os` too: the circuit picks the repository and file paths by distribution, and Conn3x can't ask a host that doesn't exist yet. If `os` turns out not to match the host, Conn3x stops before configuring it. Set `os` as well when you put `depends_on` on this module: `depends_on` holds back reading the hosts until the apply, so without `os` the plan fails with `Invalid for_each argument`.

```hcl
hosts = {
  for name, d in digitalocean_droplet.db : name => {
    address  = d.ipv4_address
    host_key = tls_private_key.host[name].public_key_openssh
    os       = "ubuntu"
  }
}
```

To try it on a throwaway container first, see [examples/local](examples/local).

## What it does

On each host, in order:

1. Adds MySQL's repository, [repo.mysql.com](https://repo.mysql.com), for the series in `mysql_version`: its apt repository on Ubuntu and Debian, its yum repository on Rocky Linux and the rest of Enterprise Linux 10. Both are checked against MySQL's signing key, which ships with the circuit in [files/mysql.asc](files/mysql.asc).
2. On Enterprise Linux, when `settings` sets a `port` other than 3306, installs `policycoreutils-python-utils` and labels the port `mysqld_port_t` with `semanage`, so SELinux lets MySQL bind it. Hosts with SELinux off skip the label.
3. Installs `mysql-community-server`. On Enterprise Linux it also adds `!includedir /etc/my.cnf.d` to `/etc/my.cnf`, which MySQL's package leaves out.
4. Writes a drop-in, `zz-conn3x.cnf`, with a `[mysqld]` section holding `bind_address` and `settings`. Its name sorts after the packages' own files, so your values win. The new file is tested before it replaces the old one: `mysqld --validate-config` reads it with every other option file, the way a server start would. A misspelt setting fails the apply with MySQL's own `unknown variable` message, and the old file stays, so the running server, a restart and a reboot all keep what they had. Fix the input and apply again.
5. On Enterprise Linux's first apply, creates the data directory with `mysqld --initialize-insecure`. Left to the server's first start, it would get a random root password written to `/var/log/mysqld.log`; this way root has none until the next steps give it socket login. Since the drop-in is already there, settings that only count when the data directory is created, such as `lower_case_table_names`, take effect. Debian's and Ubuntu's package creates it on install.
6. Checks every option file again with `mysqld --validate-config` before anything restarts, whenever the drop-in or the `/etc/my.cnf` include line changed. A change to the include line alone doesn't rewrite the drop-in, so step 4's test doesn't run for it.
7. Restarts MySQL when the drop-in changed, then keeps it running and enabled at boot. `bind-address`, `port` and most settings do nothing until a restart.
8. Has `root@localhost` log in with `auth_socket`: only the system's root user, over the local socket, with no password to steal. That's how the circuit connects, and it's how circuit-mariadb leaves MariaDB's root.
9. Removes anonymous users, any `root` account that isn't on `localhost`, `127.0.0.1` or `::1`, the `test` database and the grants that let anyone use it. MySQL no longer creates any of these, so this only acts on ones someone added later.
10. For each of `users`, writes its password to `/etc/conn3x/mysql/NAME` (root only, mode 0600) and creates one account per entry in `user_hosts`, locked, so none is ever open without a password. It then sets the password and unlocks the accounts, again whenever that file changed or an account was added.
11. Creates each of `databases`.
12. Grants each of `grants` on every one of the user's accounts. If someone revokes a privilege by hand, the next plan shows it and the apply grants it again.

A password reaches the `mysql` client on standard input, so it never shows up in `ps`, and the server stores only its hash. It does pass through the server's statement handling, so don't turn on the general query log while you change one.

A `_` in a database name is a wildcard in MySQL grants, so a grant on `my_db` would also cover `myXdb`. The circuit escapes it, and a grant covers only the database it names.

If someone edits `zz-conn3x.cnf` by hand, the next plan shows the difference and the apply puts yours back, restarting as above.

### Which MySQL you get

`mysql_version` picks one of MySQL's long-term support series: 9.7, the default and the newest, or 8.4. Within a series you get whatever MySQL publishes, with its bug and security fixes and no new features. The circuit installs the server when it's missing; later point releases come in with your usual `apt upgrade` or `dnf upgrade`.

| | Ubuntu 24.04 | Debian 13 | Rocky Linux 10 |
| --- | --- | --- | --- |
| Repository | `repo.mysql.com/apt/ubuntu` noble | `repo.mysql.com/apt/debian` trixie | `repo.mysql.com/yum/mysql-9.7-community/el/10` |
| Drop-in | `/etc/mysql/mysql.conf.d/zz-conn3x.cnf` | `/etc/mysql/mysql.conf.d/zz-conn3x.cnf` | `/etc/my.cnf.d/zz-conn3x.cnf` |
| systemd unit | `mysql` | `mysql` | `mysqld` |

The `config_files` output gives the drop-in's path per host.

Where the distribution has its own MySQL, it doesn't get in the way. Ubuntu's `mysql-server` is a different package from `mysql-community-server`. Enterprise Linux 10 packages MySQL as `mysql8.4-server`, and has no modules, so there's no `mysql` module to disable; MySQL's guide asks for that on EL8 only.

The signing key in `files/mysql.asc` (fingerprint `BCA4 3417 C3B4 85DD 128E C6D4 B7B3 B788 A8D3 785C`) expires on 23 October 2027. MySQL has extended this key before, in 2025; once it does again, the circuit needs a release with the new copy, or installs start failing the signature check.

### Where it doesn't run

The circuit checks each host before it touches it, and stops with a message on these:

- **Fedora.** MySQL builds for Fedora 42 to 44, not Fedora 45, the current release. Fedora's own `community-mysql-server` is an option, but it isn't MySQL's build, and Fedora moves past each release in about a year. Use circuit-mariadb there, or Rocky Linux.
- **arm64 on Ubuntu and Debian.** MySQL's apt repository has amd64 packages only. Its yum repository builds for both, so Enterprise Linux on arm64 works.
- **Enterprise Linux 8 and 9.** MySQL builds for both, but they haven't been tested, and EL8's own `mysql` module would have to be disabled first.

Ubuntu 26.04 and Debian 12 are in MySQL's apt repository and the circuit accepts them, but neither has been tested.

### What it doesn't cover

- **Upgrades between series.** Changing `mysql_version` switches the repository, but the installed server stays where it is. Upgrade it with `apt` or `dnf` when you're ready; MySQL upgrades the data directory on the next start.
- **Removal.** Taking a user, host, database or grant out of the inputs leaves it in MySQL. Drop or revoke it in `mysql` first.
- **Global privileges.** Grants are per database. `PROCESS`, `RELOAD`, `REPLICATION CLIENT` and the like are yours to grant.
- **Password policy.** MySQL's `validate_password` component isn't installed, on any distribution, so MySQL takes any non-empty password. Install it yourself if you want one enforced.
- **A different data directory.** `settings` can set `datadir`, but it has to exist, belong to `mysql` and, under SELinux, carry the `mysqld_db_t` label first.
- **An existing server.** The circuit connects as root over the socket without a password. On a server where root already has one, the `auth_socket` step fails; switch root to `auth_socket` by hand first.
- **TLS certificates, replication, backups and Group Replication.** None of these are set up.
- **Firewall.** The circuit doesn't open port 3306. The [firewall circuit](https://github.com/conn3xorg/circuit-firewall) can.

## Inputs

| Name | Type | Default | Description |
| --- | --- | --- | --- |
| `hosts` | any | Required | Hosts to configure, by name. Each value is an address, such as `"203.0.113.10"`, or a host object such as `{ address = "203.0.113.10", host_key = "ssh-ed25519 AAAA..." }`. A host object can also set `user`, `port`, `private_key_file`, `jump_hosts` and `os`, the distribution's ID, such as `ubuntu` or `rocky`, which a host created in the same plan needs. The two forms can be mixed. |
| `ssh_user` | string | `"root"` | User to log in as. |
| `ssh_port` | number | `22` | SSH port. |
| `ssh_private_key_file` | string | `null` | Path to a private key. When null, Conn3x uses the SSH agent. |
| `ssh_known_hosts_file` | string | `null` | known_hosts file to check host keys against. When null, `~/.ssh/known_hosts`. Not used for a host object with `host_key`. |
| `ssh_become` | bool | `false` | Run commands as root through sudo. Set it when `ssh_user` isn't root. |
| `mysql_version` | string | `"9.7"` | Long-term support series to install: `"9.7"` or `"8.4"`. |
| `bind_address` | string | `"127.0.0.1"` | Addresses to listen on, comma-separated, such as `"0.0.0.0"` or `"127.0.0.1,10.0.0.5"`. Changing it restarts MySQL. |
| `settings` | map(string) | `{}` | Server settings, such as `{ max_connections = "200" }`. Changing them restarts MySQL. Set `bind_address` with its own input. |
| `users` | list(string) | `[]` | Users to create. Names use lowercase letters, digits and `_`, up to 32 characters. |
| `user_passwords` | map(string), ephemeral | `{}` | Password for each of `users`, by name. Every user needs one. |
| `user_hosts` | list(string) | `["localhost", "127.0.0.1", "::1"]` | Where each of `users` may connect from, such as `"192.168.1.%"` or `"10.0.0.0/255.255.255.0"`. Every user gets one account per entry, with the same password and grants. |
| `databases` | list(string) | `[]` | Databases to create, such as `["app"]`. |
| `grants` | list(object) | `[]` | Privileges on a database, each `{ user, database, privileges }`. `user` must be one of `users`. `privileges` defaults to `["ALL PRIVILEGES"]`, or lists database-level ones in capitals, such as `["SELECT", "INSERT", "UPDATE", "DELETE"]`. One grant per user and database. |

## Outputs

| Name | Description |
| --- | --- |
| `config_files` | The drop-in holding `bind_address` and `settings` on each host, such as `{ db = "/etc/mysql/mysql.conf.d/zz-conn3x.cnf" }`. |

## Requirements

Requires Conn3x v0.7.0 or later and systemd on each host, with access to `repo.mysql.com` and the distribution's package mirrors.

## Tested on

Rocky Linux 10, Ubuntu 24.04 and Debian 13, with MySQL 9.7. CI applies [examples/local](examples/local) to each on amd64, checks that the second plan has no changes, then logs in over TCP as the example's user with its password, creates a table in its own database and reads the row back, checks it's refused the other database, restarts MySQL and reads the row again. The same ran by hand in an arm64 Rocky Linux 10 container, along with MySQL 8.4; a misspelt setting, which failed the apply and left the server running; a password containing a quote and a backslash; a move to port 3307; and an anonymous user, a `test` database and a revoked privilege added by hand, each of which the next plan caught and the apply removed or put back.

All of that ran in containers, where SELinux is off. On Ubuntu 24.04, Debian 13 and Rocky Linux 10 droplets, with SELinux enforcing on Rocky, the example's users and grants were applied with MySQL on port 3307 on Rocky. The circuit labelled 3307 `mysqld_port_t`, MySQL ran confined as `mysqld_t`, the user checks passed, data survived a restart, the second plan had no changes, and the audit log had no denials. All three came back after a reboot with MySQL running, the row still there and the second plan clean.

## License

MPL-2.0. See [LICENSE](LICENSE). MySQL Community Server itself is GPL-2.0.
