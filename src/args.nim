
# Copyright (C) 2023 flxj(https://github.com/flxj)
#
# All Rights Reserved.
#
# Use of this source code is governed by an Apache-style
# license that can be found in the LICENSE file.

#include global
import global

import std/parseopt
import std/tables
import std/strutils
import std/strformat
import std/times 
import std/posix
import std/sequtils
import std/sugar
import std/paths

type 
    Options* = ref object 
        optPidFile* : string
        optLogLevel*: string 
        optLogPath*:string 
        optContainerPidFile*: string
        optContainerLogDriver*: string # passthrough | json | k8s
        optContainerLogFile*: string
        optContainerExitFile*:string 
        optSysLog*:bool 
        optContainerName*:string
        optContainerID*:string 
        optContainerUUID*:string 
        optBundle*:string
        optSyncMode*:bool
        optSocketDir*:string 
        optStdin*:bool 
        optTerminal*:bool 
        optSystemdCgroups*:bool 
        optFullAttach*:bool 
        runtimePath*: string 
        runtimeExec*: bool 
        runtimeExecAttach*:bool 
        runtimeExecProcessSpec*:string 
        runtimeRestore*:bool 
        runtimeArgs*: seq[string] 
        runtimeOpts*:seq[string] 
        timeout*:Duration
        version*:bool 
        help*:bool

type optConfigurator = proc (ops:Options):string

type    
    optionInfo = object
        name:string
        alias:seq[string]
        helpMsg:string
        configurator: proc (p:string):optConfigurator

proc withPidFile(pidfile:string):optConfigurator =
    proc (ops:Options):string =
        ops.optPidFile = pidfile
        
proc withLogLevel(loglevel:string):optConfigurator =
    proc (ops:Options):string =
        case toLower(loglevel)
        of "debug":
            ops.optLogLevel = "debug"
        of "warn":
            ops.optLogLevel = "warn"
        of "error":
            ops.optLogLevel = "error"
        else:
            ops.optLogLevel = "info"

proc withLogPath(path:string):optConfigurator =
    proc (ops:Options):string =
        ops.optLogPath = path

proc withContainerPidFile(pidfile:string):optConfigurator =
    proc (ops:Options):string =
        ops.optContainerPidFile = pidfile

proc withContainerLogDriver(driver:string):optConfigurator =
    proc (ops:Options):string =
        ops.optContainerLogDriver = driver

proc withContainerLogFile(logfile:string):optConfigurator =
    proc (ops:Options):string =
        ops.optContainerLogFile = logfile

proc withContainerExitFile(exitfile:string):optConfigurator =
    proc (ops:Options):string =
        ops.optContainerExitFile = exitfile

proc withSysLog(syslog:string):optConfigurator =
    proc (ops:Options):string =
        ops.optSysLog = true 

proc withContainerName(name:string):optConfigurator =
    proc (ops:Options):string =
        ops.optContainerName = name

proc withContainerID(id:string):optConfigurator =
    proc (ops:Options):string =
        ops.optContainerID = id

proc withContainerUUID(uuid:string):optConfigurator =
    proc (ops:Options):string =
        ops.optContainerUUID = uuid

proc withBundle(bundle:string):optConfigurator =
    proc (ops:Options):string =
        ops.optBundle = bundle

proc withSync(sync:string):optConfigurator =
    proc (ops:Options):string =
        ops.optSyncMode = true 

proc withRuntimePath(path:string):optConfigurator =
    proc (ops:Options):string =
        ops.runtimePath = path

proc withRuntimeExec(exec:string):optConfigurator =
    proc (ops:Options):string =
        ops.runtimeExec = true
proc withRuntimeExecAttach(attach:string):optConfigurator =
    proc (ops:Options):string =
        ops.runtimeExecAttach = true 

proc withRuntimeExecProcessSpec(spec:string):optConfigurator =
    proc (ops:Options):string =
        ops.runtimeExecProcessSpec = spec 

proc withRuntimeRestore(restore:string):optConfigurator =
    proc (ops:Options):string =
        ops.runtimeRestore = true

proc withRuntimeArgs(args:string):optConfigurator =
    proc (ops:Options):string =
        let sp = args.split(",")
        ops.runtimeArgs = sp.filter(x => x.len > 1).map(x => fmt"--{x}") & sp.filter(x => x.len == 1).map(x => fmt"-{x}")

proc withRuntimeOpts(opts:string):optConfigurator =
    proc (ops:Options):string =
        let sp = opts.split(",")
        ops.runtimeOpts = opts.split(",").map(x => fmt"--{x}") & sp.filter(x => x.len == 1).map(x => fmt"-{x}")

proc withSocketDir(socket:string):optConfigurator =
    proc (ops:Options):string =
        ops.optSocketDir = socket

proc withStdin(stdin:string):optConfigurator =
    proc (ops:Options):string =
        ops.optStdin = true

proc withTerminal(ter:string):optConfigurator =
    proc (ops:Options):string =
        ops.optTerminal = true  

proc withSystemdCgroups(sc:string):optConfigurator =
    proc (ops:Options):string =
        ops.optSystemdCgroups = true

proc withTimeout(timeout:string):optConfigurator =
    proc (ops:Options):string =
        var s : int
        try:
            s = parseInt(timeout)
        except ValueError as e:
            return e.msg
        ops.timeout = initDuration(milliseconds=s)

proc withVersiuon(version:string):optConfigurator =
    proc (ops:Options):string =
        ops.version = true 

proc withFullAttach(ft:string):optConfigurator =
    proc (ops:Options):string =
        ops.optFullAttach = true 

proc withHelp(ft:string):optConfigurator =
    proc (ops:Options):string =
        ops.help = true 

var optConfs = {
    "pid-file":optionInfo(configurator:withPidFile,helpMsg:"Record ctrshim daemon pid"),
    "log-path":optionInfo(configurator:withLogPath,helpMsg:"Log file of ctrshim"),
    "log-level":optionInfo(configurator:withLogLevel,helpMsg:"Log level of ctrshim"),
    "container-pidfile":optionInfo(configurator:withContainerPidFile,helpMsg:"Pid file of container"),
    "container-logdriver":optionInfo(configurator:withContainerLogDriver,helpMsg:"Conatiner log driver, passthrough | json | k8s"),
    "container-logfile":optionInfo(configurator:withContainerLogFile,helpMsg:"File path to record container stdout & stderr"),
    "container-exitfile":optionInfo(configurator:withContainerExitFile,helpMsg:"File path to record container exit status"),
    "sys-log":optionInfo(configurator:withSysLog,helpMsg:"Log to syslog (use with cgroupfs cgroup manager)"),
    "container-name":optionInfo(configurator:withContainerName,helpMsg:"Name of container"),
    "container-id":optionInfo(configurator:withContainerID,helpMsg:"ID of container"),
    "conatiner-uuid":optionInfo(configurator:withContainerUUID,helpMsg:"UUID of container"),
    "bundle":optionInfo(configurator:withBundle,helpMsg:"OCI Bundle path of the container"),
    "sync":optionInfo(configurator:withSync,helpMsg:"Keep the main ctrshim process as its child by only forking once"),
    "runtime-path":optionInfo(configurator:withRuntimePath,helpMsg:"OCI runtime tool path,for example,/usr/bin/runc"),
    "exec":optionInfo(configurator:withRuntimeExec,helpMsg:"Exec command in a running container"),
    "exec-attach":optionInfo(alias: @["a"],configurator:withRuntimeExecAttach,helpMsg:"Exec command and attach to it's stdio stream"),
    "a":optionInfo(configurator:withRuntimeExecAttach,helpMsg:"exec-attach"),
    "exec-process-spec":optionInfo(configurator:withRuntimeExecProcessSpec,helpMsg:"OCI process.json path"),
    "restore":optionInfo(configurator:withRuntimeRestore,helpMsg:"Restore a container from a previous checkpoint (not support now!)"),
    "runtime-args":optionInfo(configurator:withRuntimeArgs,helpMsg:"Additional arg to pass to the runtime. The format like '--runtime-args:foo=a,bar=b,abc,b'"),
    "runtime-opts":optionInfo(configurator:withRuntimeOpts,helpMsg:"Additional opts to pass to the restore or exec command. The format like '--runtime-opts:foo=a,bar=b,abc,b'"),
    "socket-dir":optionInfo(configurator:withSocketDir,helpMsg:"Location of container attach sockets"),
    "stdin":optionInfo(alias: @["i"],configurator:withStdin,helpMsg:"Open up a pipe to pass stdin to the container"),
    "i":optionInfo(configurator:withStdin,helpMsg:"stdin"),
    "terminal":optionInfo(alias: @["t"],configurator:withTerminal,helpMsg:"Allocate a pseudo-TTY. The default is false"),
    "t":optionInfo(configurator:withTerminal,helpMsg:"terminal"),
    "systemd-cgroups":optionInfo(configurator:withSystemdCgroups,helpMsg:"Enable systemd cgroup manager, rather then use the cgroupfs directly"),
    "timeout":optionInfo(configurator:withTimeout,helpMsg:"Kill container after specified timeout in seconds."),
    "version":optionInfo(alias: @["v"], configurator:withVersiuon,helpMsg:"Print version and exit"),
    "v":optionInfo(configurator:withVersiuon,helpMsg:"Print version and exit"),
    "full-attach":optionInfo(configurator:withFullAttach,helpMsg:"Don't truncate the path to the attach socket. This option causes conmon to ignore --socket-dir-path"),
    "help":optionInfo(alias: @["h"],configurator:withHelp,helpMsg:"Print help info and exit"),
    "h":optionInfo(configurator:withHelp,helpMsg:"help"),
    }.toTable

#
proc initContainerLog(path:string):File =
    var containerLogF:File
    try:
        containerLogF = open(path,fmReadWrite)
    except IOError as e:
        quit(e.msg,QuitFailure)
    containerLogF

#
proc validOptions(ops:Options)=
    if ops.version:
        echo &"Version:{version} GitCommit:{commit} BuildData:{buildDate}\n"
        quit("",QuitSuccess)
    if ops.help:
        echo ctrshimInfo
        echo ctrshimUsage
        echo ctrshimCmd
        for k,v in optConfs.pairs:
            if k.len > 1:
                var p:string= fmt"--{k}"
                if v.alias.len > 0:
                    p = p & "," & join(v.alias.map(x => fmt"-{x}"),",")
                let name:string = p & " ".repeat(25-p.len)
                echo name,v.helpMsg
        quit("",QuitSuccess)
    #
    if ops.runtimeRestore:
        quit("Not support restore now",QuitFailure)

    assert ops.optPidFile!=""
    assert ops.optContainerExitFile!=""
    assert ops.optContainerLogFile!=""

    if (not ops.runtimeExec) and ops.runtimeExecAttach:
        quit("Attach can only be specified with exec",QuitFailure)  
    
    if ops.runtimeExec and ops.optContainerUUID=="":
        quit("Container UUID not provided",QuitFailure)
    
    if ops.runtimePath == "":
        quit("Runtime path not provided",QuitFailure)
    if access(cstring(ops.runtimePath),X_OK)<0:
        quit("Runtime path {ops.runtimePath} is not valid",QuitFailure)
    
    if ops.runtimeExec and ops.runtimeExecProcessSpec=="":
        quit("Exec process spec path not provided",QuitFailure)
    
    var wkDir:string = string(getCurrentDir())
    if ops.optContainerPidFile == "":
        ops.optContainerPidFile = fmt"{wkDir}/pidfile-{ops.optContainerId}"
    
    #
    if ops.optBundle == "" and (not ops.runtimeExec):
        ops.optBundle = wkDir
    #
    try:
        if ops.optContainerLogDriver != logDriverPass:
            containerLogFile = initContainerLog(ops.optContainerLogFile)
    except OSError,IOError:
        let msg = getCurrentExceptionMsg()
        quit(fmt"Init container log driver failed:{msg}",QuitFailure)

#
proc parseArgs*(arg:string):Options=
    let ops = new(Options)
    var p = initOptParser(arg)
    while true:
        p.next()
        case p.kind
        of cmdEnd: break
        of cmdArgument: discard
        of cmdShortOption, cmdLongOption:
            if p.key in optConfs:
                let oc = if p.val!="":optConfs[p.key].configurator(p.val) else:optConfs[p.key].configurator(p.key)
                let err = oc(ops)
                if err != "":
                   quit(err,QuitFailure)
            else:
                echo "[WARN] unknown option:",p.key 
    validOptions(ops)
    ops
