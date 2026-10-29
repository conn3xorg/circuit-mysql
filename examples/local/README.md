# Local example

Applies circuit-mysql to a throwaway Rocky Linux 10 container with systemd, creating databases called `app` and `other`, and a user `app` with every privilege on `app` and none on `other`. You need Conn3x and Podman.

```sh
./up.sh
export TF_VAR_app_password='pick-one'
conn3x init
conn3x apply
conn3x plan
```

The second plan says `No changes.` To log in over TCP as `app` and make a table:

```sh
podman exec -e MYSQL_PWD="$TF_VAR_app_password" circuit-mysql mysql -h 127.0.0.1 -u app app -e 'CREATE TABLE t (id INT)'
```

The same login on `other` gets `Access denied`.

`up.sh` listens on `127.0.0.1:2284`. Set `PORT` to use another port, and pass the same port to Conn3x with `-var port=PORT`. Set `CONTAINERFILE` to test another distro, such as one of the images in Conn3x's `test/images`, which CI uses. MySQL's packages for Ubuntu and Debian are amd64 only, so on an arm64 machine, such as a Mac with Apple silicon, stick to Rocky Linux.

`./down.sh` removes the container, its volumes, the key and the state.
