😁 `ctrshim` is a container runtime shim program that works in conjunction with the OCI runtime tool to create and monitor containers.

### Compile

Requires nimlang 2.0

```shell
make build
```

### Usage


`ctrshim --version` command

```shell
Version: GitCommit:a7c1f1d BuildData:2023-12-27T14:56:32Z
```


`ctrshim --help` command
```shell
ctrshim is a container shim program, work with container manager system and oci runtime tool, to run and monitor container

Usage:  ctrshim [OPTIONS]

Options:

--runtime-path           OCI runtime tool path,for example,/usr/bin/runc
--version,-v             Print version and exit
--runtime-args           Additional arg to pass to the runtime. The format like '--runtime-args:foo=a,bar=b,abc,b'
--container-logdriver    Conatiner log driver, passthrough | json | k8s
--bundle                 OCI Bundle path of the container
--exec-process-spec      OCI process.json path
--timeout                Kill container after specified timeout in seconds.
--terminal,-t            Allocate a pseudo-TTY. The default is false
--pid-file               Record ctrshim daemon pid
--socket-dir             Location of container attach sockets
--container-logfile      File path to record container stdout & stderr
--container-pidfile      Pid file of container
--full-attach            Don't truncate the path to the attach socket. This option causes conmon to ignore --socket-dir-path
--sys-log                Log to syslog (use with cgroupfs cgroup manager)
--help,-h                Print help info and exit
--runtime-opts           Additional opts to pass to the restore or exec command. The format like '--runtime-opts:foo=a,bar=b,abc,b'
--log-path               Log file of ctrshim
--container-exitfile     File path to record container exit status
--container-id           ID of container
--exec                   Exec command in a running container
--systemd-cgroups        Enable systemd cgroup manager, rather then use the cgroupfs directly
--stdin,-i               Open up a pipe to pass stdin to the container
--conatiner-uuid         UUID of container
--sync                   Keep the main ctrshim process as its child by only forking once
--log-level              Log level of ctrshim
--container-name         Name of container
--restore                Restore a container from a previous checkpoint (not support now!)
--exec-attach,-a         Exec command and attach to it's stdio stream
```



