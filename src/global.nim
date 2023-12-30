
# Copyright (C) 2023 flxj(https://github.com/flxj)
#
# All Rights Reserved.
#
# Use of this source code is governed by an Apache-style
# license that can be found in the LICENSE file.

import std/logging
import std/posix
import std/strformat

var
    ctrshimInfo*:string = &"ctrshim is a container shim program, work with container manager system and oci runtime tool, to run and monitor container\n"
    ctrshimUsage*:string = &"Usage:  ctrshim [OPTIONS]\n"
    ctrshimCmd*:string = &"Options:\n"

const
    version* {.strdefine: "VERSION".}:string = "0.1.0"
    commit* {.strdefine: "COMMIT".}:string = ""
    buildDate* {.strdefine: "BUILDDATE".}:string = ""

# remote socket: user attach socket connection to container or exec session
type
    remoteSocket* = ref object
        fd*:SocketHandle # attach socket
        readers*:seq[SocketHandle] # user connection
var 
    remoteSock*:remoteSocket

var
    containerStatus*:cint = -1
    containerPid*:Pid
    createPid*:Pid 
    runtimeState*:cint

    consoleSocketFd*:SocketHandle
    containerLogFile*:File

const 
    logDriverPass*:string = "passthrough"
    logDriverJson*:string = "json"
    logDriverK8s*:string = "k8s"

proc getContainerLog*():File = containerLogFile

# for terminal size contorl
var 
    terminalControlR*:FileHandle
    terminalControlW*:FileHandle
    winSizeR*:FileHandle
    winSizeW*:FileHandle

# shim logger
var 
    logger*:FileLogger

proc initLogger*(level:Level, path:string) =
    logger = newFileLogger(filename=path,levelThreshold=level,fmtStr="$datetime [$levelname] ")

proc closeLogger*() = logger.file.close()