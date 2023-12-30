
# Copyright (C) 2023 flxj(https://github.com/flxj)
#
# All Rights Reserved.
#
# Use of this source code is governed by an Apache-style
# license that can be found in the LICENSE file.

#include args 
#include global 
import args
import global 

import std/[os,osproc,logging,strformat,strscans,posix,strutils]

#
var PR_SET_CHILD_SUBREAPER {.importc:"PR_SET_CHILD_SUBREAPER",header:"<sys/prctl.h>"}:cint
var PR_SET_PDEATHSIG* {.importc:"PR_SET_PDEATHSIG",header:"<sys/prctl.h>"}:cint
var SOCK_SEQPACKET {.importc: "SOCK_SEQPACKET", header: "<sys/socket.h>".}: cint
var SOCK_CLOEXEC {.importc: "SOCK_CLOEXEC", header: "<sys/socket.h>".}: cint
var SOCK_NONBLOCK {.importc: "SOCK_NONBLOCK", header: "<sys/socket.h>".}: cint


proc accept4*(a1:SocketHandle,a2:ptr SockAddr, a3:ptr SockLen, flags:cint):cint {.importc,header:"<sys/types.h>".}
proc pipe2*(pipefd:array[0..1,cint],flags:cint):cint {.importc,header:"<unistd.h>".}
proc prctl*(option:cint,arg2:culong, arg3:culong,arg4:culong,arg5:culong):cint {.importc,header:"<sys/prctl.h>".}

#
proc setSubreaper*() = 
    let a:culong = 1
    let b:culong = 0
    if prctl(PR_SET_CHILD_SUBREAPER,a,b,b,b)!=0:
        quit("Set subreaper failed",QuitFailure)
#
proc reapChildren*() =
    var n:cint
    while waitpid(-1, n, WNOHANG)>0:
        discard
#
proc createPipe*():(cint,cint)=
    var fds:array[0..1,cint]
    if pipe2(fds,O_CLOEXEC)<0:
        logger.log(lvlError,"Create pipe failed")
        quit("Create pipe filed",QuitFailure)
    (fds[0],fds[1])

#
proc getPipeFromEnv*(env:string):cint =
    let val = parseInt(getEnv(env))
    assert val > 0 
    let fd = cint(val)
    if fcntl(fd,F_SETFD, FD_CLOEXEC) == -1:
        logger.log(lvlError,fmt"Get pipe from env {env} failed")
        -1
    else:
        fd
#
proc runOCIRuntimeCmd*(ops:Options,consoleSocket:string) =
    var cmd:seq[string] = @[ops.runtimePath]
    if ops.runtimeExec:
        cmd.add(@["exec","--pid-file",ops.optContainerPidFile,"--process",ops.runtimeExecProcessSpec,"-d"])
        if ops.optTerminal:
            cmd.add("--tty")
    else:
        cmd.add(if ops.runtimeRestore: "restore" else:"create")
        cmd.add(@["--bundle",ops.optBundle,"--pid-file",ops.optContainerPidFile])
    
    for op in ops.runtimeOpts:
        cmd.add(op)
    for arg in ops.runtimeArgs:
        cmd.add(arg)
    
    if consoleSocket != "":
        cmd.add("--console-socket")
        cmd.add(consoleSocket)
    
    cmd.add(ops.optContainerName)

    discard execCmdEx(command=join(cmd," "))

#
proc getContainerPid*(path:string):Pid = 
    var f:File
    try:
        let f = open(path,fmReadWriteExisting,16)
        let cont = readAll(f)
        Pid(int32(parseInt(cont)))
    finally:
        if f != nil :
            close(f)   
#
proc getExitStatus*(status:cint):int =
    if WIFEXITED(status):
        int(WEXITSTATUS(status))
    elif WIFSIGNALED(status):
        int(128 + WTERMSIG(status));
    else:
        0
#
proc sigHandler*(sig:cint)=
    if containerPid > 0:
        if kill(containerPid,sig) == 0:
            return
    elif createPid > 0:
        if kill(createPid,sig) == 0:
            return
        if errno == ESRCH:
            if containerPid > 0 and kill(containerPid,sig) == 0:
                return
    raise newException(OSError,fmt"kill container:{containerPid} or runtime:{createPid} with signal {sig} failed")
    
#
proc writeSyncPipe*(fd:cint,res:int,msg:string) =
    var jsonStr:string
    if fd>0:
        var pf:File
        try:
            if not open(pf,fd,fmReadWrite):
                raise newException(IOError,fmt"open sync pipe {fd} failed")
            if len(msg)>0:
                jsonStr = &"""{{"data":{res}, "message":"{msg}"}}\n"""
            else:
                jsonStr = &"""{{"data":{res}}}\n"""
            write(pf,jsonStr)
        except IOError,OSError:
            let msg = getCurrentExceptionMsg()
            quit(msg,QuitFailure)
        finally:
            close(pf)
#
proc writeLogAsK8sFormat*(writer:File,cont:string)=
    try:
        write(writer,cont)
    except IOError as e:
        logger.log(lvlError,e.msg)
#
#
proc writeRemoteSocket*(cont:string) =
    for i,r in remoteSock.readers:
        if send(r,addr cont,cont.len,0) < 0:
            logger.log(lvlError,fmt"Send content to remote socket {cint(r)} failed {errno}")

# read content from container stdout & stderr, and send them to attach sockets, write them to container log file.
let logBufSize = 2048
var logBuf:array[0..2048,char]
proc serveContainerStdio*(fd:cint):bool =
    try:
        let n = read(fd,addr logBuf,logBufSize)
        if n > 0:
            var str:string = join(logBuf[0..n],"")
            writeLogAsK8sFormat(getContainerLog(),str)
            writeRemoteSocket(str)
        return true
    except EOFError:
        return true 
    except IOError,OSError:
        let msg = getCurrentExceptionMsg()
        logger.log(lvlError,fmt"write container log file faile:{msg}")
    false
#
proc serveContainerStdio*(reader:File):bool = 
    try:
        let content = readLine(reader)                
        writeLogAsK8sFormat(getContainerLog(),content)
        writeRemoteSocket(content)
        return true
    except EOFError:
        return true 
    except IOError,OSError:
        let msg = getCurrentExceptionMsg()
        logger.log(lvlError,fmt"write container log file faile:{msg}")
    false
#
let stdinBufSize = 2048
var stdinBuf:array[0..2048,char]
proc serveContainerStdin*(conn:SocketHandle,to:cint):bool =
    try:
        let n = recv(conn,addr stdinBuf,stdinBufSize,0)
        if n > 0:
            if write(to,addr stdinBuf,n) < 0:
                raiseOSError(OSErrorCode(1),"send content to container stdin failed")
    except EOFError:
        return true 
    except IOError,OSError:
        let msg = getCurrentExceptionMsg()
        logger.log(lvlError,fmt"serve attach io faile:{msg}")
    false

#
proc createConsoleSocket*(ops:Options):(SocketHandle,string)=
    let sockPath = fmt"/tmp/{ops.optContainerID}-terminal.sock"
    var sp:array[0..107,char]
    for i,c in sockPath.pairs:
        sp[i] = c
    
    if unlink(cstring(sockPath))<0:
        raiseOSError(OSErrorCode(1),fmt"Unlink {sockPath} failed")

    let sockFd = socket(AF_UNIX, SOCK_STREAM or SOCK_CLOEXEC, cint(0))
    if cint(sockFd)<0:
        raise newException(OSError,"Create socket failed")
    if fchmod(cint(sockFd),0700)<0:
        raise newException(OSError,"Change socket permissions failed")
    
    var sockAddr:Sockaddr_un
    sockAddr.sun_family = uint16(AF_UNIX)
    sockAddr.sun_path = sp
    if bindSocket(sockFd, cast[ptr SockAddr](sockAddr.addr), SockLen(sizeof(sockAddr)))<0:
        raise newException(OSError,"Bind socket addr failed")
    if listen(sockFd,128)<0:
        raise newException(OSError,"Listen on socket failed")
    (sockFd,sockPath)
#
proc getSocketParentDir*(ops:Options):string=
    if ops.optFullAttach:
        ops.optBundle
    else:
        let path:cstring = cstring(fmt"{ ops.optSocketDir}/{ops.optContainerUUID}")
        if unlink(path)==(-1) and errno != ENOENT:
            raise newException(OSError,fmt"Remove existing symlink {path} for socket directory failed")
        if symlink(cstring(ops.optBundle),path) == -1:
            raise newException(OSError,fmt"Craete symlink {path} for socket directory failed")
        $path
#
proc bindUnixSocket*(name:string,sockType:cint,perm:Mode,ops:Options):(SocketHandle,string)=
    var sockFd:SocketHandle
    var sockAddr:Sockaddr_un
    sockAddr.sun_family = uint16(AF_UNIX)

    let parentDir = getSocketParentDir(ops)
    let parentDirFd = open(cstring(parentDir),O_PATH)
    if parentDirFd<0:
        raise newException(OSError,fmt"Open socket path parent dir {parentDir} failed")
    let sockProcEntry = fmt"/proc/self/fd/{parentDirFd}/{name}"

    var sp:array[0..107,char]
    for i,c in sockProcEntry.pairs:
        sp[i] = c
    sockAddr.sun_path = sp

    let sockFullPath = fmt"{parentDir}/{name}"
    sockFd = socket(AF_UNIX,sockType,0)
    if int(sockFd) < 0:
        raise newException(OSError,fmt"Create socket {sockFullPath} failed")
    if fchmod(cint(sockFd),perm) < 0:
        raise newException(OSError,fmt"Change socket {sockFullPath} permissions failed")
    if unlink(cstring(sockFullPath)) == -1 and errno != ENOENT:
        raise newException(OSError,fmt"Remove existing socket {sockFullPath} failed")
    if bindSocket(sockFd, cast[ptr SockAddr](sockAddr.addr), SockLen(sizeof(sockAddr)))<0:
        raise newException(OSError,fmt"Bind socket addr {sockFullPath} failed")
    if chmod(cstring(sockFullPath),perm)<0:
         raise newException(OSError,fmt"Change socket {sockFullPath} permissions failed")
    (sockFd,sockFullPath)

#
proc createAttachSocket*(ops:Options):(SocketHandle,string)=
    let (fd,symlinkDir) = bindUnixSocket("attach",SOCK_SEQPACKET or SOCK_NONBLOCK or SOCK_CLOEXEC,0700,ops)
    if listen(fd,10) == -1:
        raise newException(OSError,fmt"Listen on attach socket: {symlinkDir}/attach failed")
    (fd,symlinkDir)

# 
proc consoleSocketHandler*(sockFd:SocketHandle):FileHandle =
    var buf1:array[64,char]
    var buf:array[64,char]
    var vec:IOVec
    vec.iov_base = addr buf1
    vec.iov_len = uint(sizeof(buf1))

    var msg:Tmsghdr
    msg.msg_iov = addr vec
    msg.msg_iovlen = 1
    msg.msg_control = addr buf
    msg.msg_controllen = uint(sizeof(buf))

    let conn:SocketHandle = accept(sockFd, nil, nil)
    if recvmsg(conn,addr msg,0)<0:
        raise newException(OSError,"Recvmsg from console socket failed")
    
    let cmsg = CMSG_FIRSTHDR(addr msg)
    if cmsg == nil:
        raise newException(OSError, fmt"cmsg is nil, errno:{errno}")
    
    let consoleSockFd = cast[ptr FileHandle](CMSG_DATA(cmsg))[]
    logger.log(lvlDebug,fmt"recved console socket master fd:{cint(consoleSockFd)}")
    
    discard close(conn)
    consoleSockFd

#
proc attachHandler*(sockFd:SocketHandle):SocketHandle = 
    let sFd = accept(sockFd,nil,nil)
    if sFd == SocketHandle(-1):
        if errno != EWOULDBLOCK:
            logger.log(lvlError,"Failed to accept client connection on attach socket") 
    sFd
#
#
proc closeAllAttachReaders*() =
    for i,r in remoteSock.readers:
        if close(r) < 0:
            logger.log(lvlError,fmt"close attach reader fd {cint(r)} failed")
    remoteSock.readers = @[]


#
proc createTerminalControlFifo*(bundle:string) :(FileHandle,FileHandle)=
    let path:cstring = cstring(joinPath(bundle,"ctl"))
    if mkfifo(path,0666) == -1:
        if errno==EEXIST:
            discard unlink(path)
            if mkfifo(path, 0666) == -1:
                raiseOSError(OSErrorCode(1),fmt"Failed mkfifo at {path}")
    var r = open(path,O_RDONLY or O_NONBLOCK or O_CLOEXEC)
    if r == -1:
        raiseOSError(OSErrorCode(1),"Failed open read endpoint of terminal control fifo")
    var w = open(path,O_WRONLY or O_CLOEXEC)
    if w == -1:
        raiseOSError(OSErrorCode(1),"Failed open write endpoint of terminal control fifo")
    (FileHandle(r),FileHandle(w))

#
proc createWinSizeFifo*(bundle:string):(FileHandle,FileHandle) =
    let path:cstring = cstring(joinPath(bundle,"winsize"))
    if mkfifo(path,0666) == -1:
        if errno==EEXIST:
            discard unlink(path)
            if mkfifo(path, 0666) == -1:
                raiseOSError(OSErrorCode(1),fmt"Failed mkfifo at {path}")
    var r = open(path,O_RDONLY or O_NONBLOCK or O_CLOEXEC)
    if r == -1:
        raiseOSError(OSErrorCode(1),"Failed open read endpoint of window resize control fifo")
    var w = open(path,O_WRONLY or O_CLOEXEC)
    if w == -1:
        raiseOSError(OSErrorCode(1),"Failed open write endpoint of window resize control fifo")
    (FileHandle(r),FileHandle(w))
#
import std/termios
proc resizeWin(fd:FileHandle,height:int,width:int) =
    let win = new(IOctl_WinSize)
    win.ws_row = cushort(height)
    win.ws_col = cushort(width)
    if ioctl(cint(fd),TIOCGWINSZ,addr win) == -1:
        raiseOSError(OSErrorCode(1),"Failed to set process pty terminal size")

#
proc readAndResizeWin*(fd:FileHandle,win:FileHandle) = 
    var buf:array[0..200,char]
    let num = read(fd,addr buf,199)
    if num<0:
        raiseOSError(OSErrorCode(1),fmt"Failed to read content from fd:{fd}")

    buf[num] = '\n'
    let lines = split(join(buf,""),"\n")
    for i in 0..<lines.len:
        if lines[i]=="":
            continue
        var 
            height:int 
            width:int
        if not scanf(lines[i], "$i $i", height, width):
            raiseOSError(OSErrorCode(1),"Failed to sscanf message")
        resizeWin(win,height,width)
#
const
    WIN_RESIZE_EVENT:int = 0

proc readTerminalControlFifo*(fd:FileHandle) =
    var buf:array[0..200,char]
    let num = read(fd,addr buf,199)
    if num<0:
        raiseOSError(OSErrorCode(1),fmt"Failed to read content from fd:{fd}")

    buf[num] = '\n'
    let lines = split(join(buf,""),"\n")
    for i in 0..<lines.len:
        # parse line
        if lines[i] == "":
            continue 
        var 
            msgType:int 
            height:int 
            width:int
        if scanf(lines[i], "$i $i $i", msgType,height, width):
            raiseOSError(OSErrorCode(1),"Failed to sscanf message")
        case msgType:
            of WIN_RESIZE_EVENT:
                var msg:string = &"{height} {width}\n"
                if write(winSizeW,addr msg,msg.len)<0:
                    raiseOSError(OSErrorCode(1),"Failed to write to window resize fifo: winSizeW")
            else:
                return
