# Copyright (C) 2023 flxj(https://github.com/flxj)
#
# All Rights Reserved.
#
# Use of this source code is governed by an Apache-style
# license that can be found in the LICENSE file.

import std/strformat
import std/sequtils
import std/osproc
import std/strtabs

type 
    containerInfo = ref object 
        id:string
        cuuid:string
        name:string
        bundle:string
        pidPath:string
        logPath:string
        exitPath:string
        logDriver:string
        noCgroup:bool
        runtimePath:string
        terminal:bool
        stdin:bool

    #
    shimInfo = ref object 
        path:string
        pidPath:string
        logPath:string
        logLevel:string

import std/envvars
import std/os
import std/posix
import std/parseutils

proc closeSocket(fd:cint) = discard

proc createSocketPair():(cint,cint) = (0,0)

proc readContainerPidFrom(name:string,fd:cint):Pid = Pid(0)
proc readSimPidFrom(path:string):Pid = Pid(0)
proc sendCgroupSignalTo(cmd:Process,fd:cint) = discard

proc removeContainer(ctr:containerInfo,shim:shimInfo) = discard


proc createContainer(ctr:containerInfo,shim:shimInfo) = 
    echo fmt"[debug] start to create a container {ctr.name}"

    var args = @[
        "--conatiner-id", ctr.id,
        "--conatiner-uuid", ctr.cuuid,
        "--runtime-path", ctr.runtimePath,
        "--bundle", ctr.bundle,
        "--conatiner-pidfile", ctr.pidPath,
        "--container-logdriver",ctr.logDriver,
        "--container-logfile",ctr.logPath,
        "--container-exitfile",ctr.exitPath,
        "--conatiner-name", ctr.name,
        "--full-attach",
    ]
    if ctr.terminal:
        args.add("-t")
    if ctr.stdin:
        args.add("-i")
    #
    var runcArgs:string = ""
    if  ctr.logPath.len != 0:
        runcArgs = fmt"log-format=json,log=${ctr.logPath}"
    if ctr.noCgroup:
        runcArgs &= ",cgroup-manager=disable"
    if runcArgs.len != 0:
        args.add(fmt"--runtime-args:${runcArgs}")
    #
    args = concat(args,@["--pid-file",shim.pidPath,"--log-level",shim.logLevel,"--log-path",shim.logPath])
    #
    # ENV
    var envs = newStringTable(modeStyleInsensitive)
    let p = getEnv("PATH")
    if p != "":
        envs["PATH"] = p
    #
    var preserveFDs:int = 0
    let val = getEnv("LISTEN_FDS")
    if val != "":
        discard parseInt(val,preserveFDs)
    #
    #
    let (syncPipe,syncPipeShim) = createSocketPair()
    defer:closeSocket(syncPipe)

    let (startPipeShim,startPipe) = createSocketPair()
    defer:closeSocket(startPipe)

    envs["SHIM_SYNCPIPE"] = fmt"{syncPipeShim}"
    envs["SHIM_STARTPIPE"] = fmt"{startPipeShim}"

    # 
    let pros = startProcess(command=shim.path,args=args,env=envs)
    closeSocket(syncPipeShim)
    closeSocket(startPipeShim)

    sendCgroupSignalTo(pros,startPipe)
    
    let code = waitForExit(pros,10000000)
    if code < 0:
        raiseOSError(OSErrorCode(1),fmt"start shim process failed:{code}")

    try:
        let pid = readContainerPidFrom(ctr.name,syncPipe)
        echo fmt"Container {ctr.name} PID is:{pid}"
    except OSError,IOError:
        let msg = getCurrentExceptionMsg()
        try:
            removeContainer(ctr,shim)
        except IOError,OSError:
            echo fmt"remove container {ctr.name} failed:{getCurrentExceptionMsg()}"
        raiseOSError(OSErrorCode(1),fmt"get container pid failed:{msg}")
    #
    try:
        let shimPid = readSimPidFrom(shim.pidPath)
        if shimPid > Pid(0):
            echo fmt"Shim PID is:{shimPid}"
    except IOError,OSError:
        echo getCurrentExceptionMsg()
    

proc testCreateContainer(name:string,bundle:string) =
    let ctr = new(containerInfo)
    let shim = new(shimInfo)
    # TODO init paramenters
    createContainer(ctr,shim)


proc runTest() =
    let name = ""
    let path = ""
    testCreateContainer(name,path)