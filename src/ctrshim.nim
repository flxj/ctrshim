
# Copyright (C) 2023 flxj(https://github.com/flxj)
#
# All Rights Reserved.
#
# Use of this source code is governed by an Apache-style
# license that can be found in the LICENSE file.

#include global
#include util

import global
import util 
import args

import std/[strformat,selectors,posix,logging,tables,os,strutils]

proc main(arg:string) =
    let ops = parseArgs(arg)
    defer:closeLogger()
    
    let bufSize = 8192
    var buf:array[0..8192,char]
    
    # get start_pipe
    # peocess reading the pipe well be block until get some content from pipe
    # when shim be blocked, the parent process(manager) can setting cgroups for shim, the send a nonce value to shim by the start pipe
    # the shim process get the 'signal' and then continue to run.
    let startPipe = getPipeFromEnv("SHIM_STARTPIPE")
    if startPipe<0:
        quit("Get start pipe from env failed",QuitFailure)
    logger.log(lvlDebug,"Wait continue signal from start pipe...")
    if read(startPipe,addr buf,bufSize)<0 :
        logger.log(lvlError,"Read start pipe failed")
        quit("Read start pipe failed",QuitFailure)
    # if we not set exec attach option, we not need the pipe anymore，
    # otherwise, we will reuse the pipe later.
    if not ops.runtimeExecAttach:
        discard close(startPipe)
        logger.log(lvlDebug,"Closed start pipe")
    
    # get sync pipe
    # shim need the pipe to report some information about container to parent(manager),for example, 
    # container_create_err,container_pid,container_exitcode... 
    let syncPipe = getPipeFromEnv("SHIM_SYNCPIPE")
    if syncPipe<0:
        quit("Get sync pipe from env failed",QuitFailure)
    
    # we need shim be daemon process,so double-fork
    let pid = fork()
    if pid < 0:
        logger.log(lvlError,"Double fork failed")
        quit("Double fork failed",QuitFailure)
    elif pid>0:
        # main process record the daemon process pid to pidFile and exit
        var f :File 
        try:
            f = open(ops.optPidFile,fmReadWriteExisting)
            write(f,pid)
        except IOError as e:
            quit(e.msg,QuitFailure)
        finally:
            close(f)
        quit("",QuitSuccess)
    
    # shim well be subreaper, so when shim exit, 
    # it need wait all it's child processes completed to avoid zombie process.
    defer:reapChildren()

    logger.log(lvlDebug,"Redirect stdio")
    # redirect stdio of shim process.
    let dev_null_r = open("/dev/null", O_RDONLY or O_CLOEXEC)
    if dev_null_r<0:
        quit("Failed to open /dev/null",QuitFailure)
    let dev_null_w = open("/dev/null", O_WRONLY or O_CLOEXEC)
    if dev_null_w<0:
        quit("Failed to open /dev/null",QuitFailure)
    #
    if dup2(dev_null_r, STDIN_FILENO)<0:
        quit("Failed to redirect shim stdin to /dev/null",QuitFailure)
    if dup2(dev_null_w, STDOUT_FILENO)<0:
        quit("Failed to redirect shim stdout to /dev/null",QuitFailure)
    if dup2(dev_null_w, STDERR_FILENO)<0:
        quit("Failed to redirect shim stderr to /dev/null",QuitFailure)

    # set a new session id.
    discard setsid()

    # set shim be subreaper.
    setSubreaper()
    
    var 
        stdinPipe_w:cint
        stdinPipe :cint
        stdoutPipe_r:cint
        stdoutPipe:cint  
    var consoleSocketName:string
    if ops.optTerminal:
        #[
            if need terminal, we should create a unix domain socket
            then exec oci runtime command with '--console-socket' option by the socket address
            oci runtime will send back terminal master endpoint fd via the socket (sendmsg system call)
            we then register a callback in mainloop to accept connection of the socket and read fd from it(recvmsg system call).
        ]#
        try:
            (consoleSocketFd,consoleSocketName) = createConsoleSocket(ops)
            logger.log(lvlDebug,fmt"Create console socket at {consoleSocketName}")
        except OSError as e:
            let msg = fmt"Create console socket failed:{e.msg}"
            logger.log(lvlError,msg)
            quit(msg,QuitFailure)
    else:
        # if no terminal, we should create stdin/stdout pipe for container 
        if ops.optStdin:
            (stdinPipe,stdinPipe_w) = createPipe()
            logger.log(lvlDebug,"Create stdio pipes")
            # TODO: set stdinPipe_w noblock
            #if (g_unix_set_fd_nonblocking(mainfd_stdin, TRUE, NULL) == FALSE)
            #    nwarn("Failed to set mainfd_stdin to non blocking");
        (stdoutPipe_r,stdoutPipe) = createPipe()
        logger.log(lvlDebug,"Create stdout pipes")
    # 
    var (stderrPipe_r,stderrPipe) = createPipe()
    logger.log(lvlDebug,"Create stderr pipes")

    # attach socket
    var 
        attachPipe:cint
        attachSocketFd:SocketHandle
        attachSocketPath:string
    if ops.optBundle != "" and ops.optContainerLogDriver != logDriverPass:
        try:
            (attachSocketFd,attachSocketPath) = createAttachSocket(ops)
            remoteSock.fd = attachSocketFd
            logger.log(lvlDebug,fmt"Create attach socket at {attachSocketPath}")
            # 
            (terminalControlR,terminalControlR) = createTerminalControlFifo(ops.optBundle)
            (winSizeR,winSizeW) = createWinSizeFifo(ops.optBundle)
            logger.log(lvlDebug,"Create terminal control socket")
        except OSError as e:
            let msg = fmt"Create attach socket failed:{e.msg}"
            logger.log(lvlError,msg)
            quit(msg,QuitFailure)
        # if user need immediately attach to the io stream when exec command
        # after setup attach socket, shim need use the attach pipe to send a nonce value as signal to 
        # tell parent(manager) it's has prepared socket for attach.
        if ops.runtimeExecAttach :
            attachPipe = getPipeFromEnv("SHIM_ATTACHPIPE")
            if attachPipe < 0:
                quit("Faile to get attach pipe from SHIM_ATTACHPIPE",QuitFailure)
            logger.log(lvlDebug,"Sending attach signal to manager")
            var n = 0 
            if write(attachPipe,addr n,0)<0:
                let msg = "Write attach pipe failed"
                logger.log(lvlError,msg)
                quit(msg,QuitFailure)
            logger.log(lvlDebug,"Send attach signal success")

    createPid = fork()
    if createPid<0:
        logger.log(lvlError,"Fork to create failed")
        quit("Fork to create failed",QuitFailure)
    elif createPid == 0:
        # send kill signal to child,when parent dies.
        if prctl(PR_SET_PDEATHSIG, culong(SIGKILL),0,0,0) < 0:
            quit("Failed to set PDEATHSIG",QuitFailure)
        # redirect current process's stdio, such stdio will be container's stdio after runtime exited.
        if ops.optContainerLogDriver != logDriverPass:
            if stdinPipe < 0:
                stdinPipe = dev_null_r
            if dup2(stdinPipe, STDIN_FILENO) < 0:
                quit("Failed to redirect shim stdin",QuitFailure)
            #
            if stdoutPipe < 0:
                stdoutPipe = dev_null_w
            if dup2(stdoutPipe, STDOUT_FILENO) < 0:
                quit("Failed to redirect shim stdout",QuitFailure)
            #
            if stderrPipe < 0:
                stderrPipe = dev_null_w
            if dup2(stderrPipe, STDERR_FILENO) < 0:
                quit("Failed to redirect shim stderr",QuitFailure)
        # if shim send prepared_attach_socket signal to parent(manager)
        # then before exec oci runtime command, current process should block here to wait parent(manager) to handle properly attach operation,
        # when get signal from parent(manager),current process can continue to run.
        if ops.runtimeExecAttach:
            if startPipe>0:
                let rd = read(startPipe,addr buf,bufSize)
                if rd<0 :
                    quit("Read start pipe failed",QuitFailure)
                discard close(startPipe)
        #
        runOCIRuntimeCmd(ops,consoleSocketName)
        quit("",127)
    
    # close the pipes we not need in in shim main process:
    # the write endpoint of stderr and stdout pipes,
    # the read endpoint of stdin pipe.
    if stderrPipe>(-1):
        discard close(stderrPipe)
    if stdoutPipe>(-1):
        discard close(stdoutPipe)
    if stdinPipe>(-1):
        discard close(stdinPipe)

    #[
    if (sigprocmask(SIG_SETMASK, &oldmask, NULL) < 0)
        pexit("Failed to unblock signals");
    ]#

    var slt = newSelector[int]()
    defer:close(slt)

    registerHandle(slt,int(terminalControlR),{Read},-1)

    var atchConns = initTable[SocketHandle,bool]()
    registerHandle(slt,attachSocketFd,{Read},-1)

    let runtimeFd = registerSignal(slt,createPid,-1)
    # TODO: Add SIGCHLD signal
    #let chldFd = registerSignal(slt,SIGCHLD,-1)
    let sigs = {
        registerSignal(slt,SIGTERM,-2):SIGTERM,
        registerSignal(slt,SIGQUIT,-3):SIGQUIT,
        registerSignal(slt,SIGINT,-4):SIGINT,
    }.toTable
    
    var 
        ret:cint
        sigExit:bool
        sig:int
    if consoleSocketName != "":
        registerHandle(slt,consoleSocketFd,{Read},-1)
        if not ops.runtimeExec or containerStatus < 0:
            block mainloop:
                while true:
                    let keys = select(slt,-1)
                    for i,k in keys[0..^1]:
                        if k.errorCode != OSErrorCode(0):
                            continue
                        if (k.fd in sigs):
                            sigExit = true
                            sig = sigs[k.fd]
                            break mainloop
                        if k.fd == int(consoleSocketFd) and (Read in k.events):
                            try:
                                let consoleFd = consoleSocketHandler(consoleSocketFd)
                                if dup2(stdinPipe_w,consoleFd) < 0:
                                    raiseOSError(OSErrorCode(1),"Failed to dup console file descriptor for stdin")
                                if dup2(stdoutPipe_r,consoleFd) < 0:
                                    raiseOSError(OSErrorCode(1),"Failed to dup console file descriptor for stdout")
                            except OSError as e:
                                logger.log(lvlError,e.msg)
                                quit(e.msg,QuitFailure)
                            unregister(slt,consoleSocketFd)
                            registerHandle(slt,int(winSizeR),{Read},-1)
                        #
                        if k.fd == int(attachSocketFd) and (Read in k.events):
                            # accept a new socket connection and register it in mainloop，
                            # then we can read the user input and send it to container
                            let newConn = attachHandler(attachSocketFd)
                            if newConn!=SocketHandle(-1):
                                registerHandle(slt,newConn,{Read},-1)
                                # add the connection in readers list,then we can send the container's output to it
                                remoteSock.readers.add(newConn) 
                                atchConns[newConn] = true 
                        if (SocketHandle(k.fd) in atchConns) and (Read in k.events):
                            # read user input from the socket connection and write to container's stdin
                            let eof = serveContainerStdin(SocketHandle(k.fd), stdinPipe_w)
                            if eof :
                                discard close(SocketHandle(k.fd))
                                unregister(slt,k.fd)
                                atchConns.del(SocketHandle(k.fd))
                        if k.fd == runtimeFd:
                            # when child process exit, we should get it's status and break mainloop
                            discard waitpid(createPid,runtimeState,0)
                            createPid = -1
                            break mainloop
                        if k.fd == int(winSizeR) and (Read in k.events):
                            try:
                                 readAndResizeWin(winSizeR,stdoutPipe_r)
                            except OSError as e:
                                logger.log(lvlError,fmt"Failed to resize window size:{e.msg}")
                        if k.fd == int(terminalControlR) and (Read in k.events):
                            try:
                                readTerminalControlFifo(terminalControlR)
                            except OSError as e:
                                logger.log(lvlError,fmt"Failed to read terminal control fifo:{e.msg}")
            if sigExit:
                # TODO do some clean
                try:
                    sigHandler(cint(sig))
                except OSError as e:
                    quit(e.msg,QuitFailure)   
    else:
        # wait child exit and report container create status to parent(manager) by syncPipe
        ret = waitpid(createPid,runtimeState,0)
        while ret<0 and errno==EINTR:
            ret = waitpid(createPid,runtimeState,0)
        if ret<0:
            if createPid>0:
                let oldErrno = errno
                discard kill(createPid,SIGKILL)
                errno = oldErrno
            let cmd = if ops.runtimeExec:"exec" else:"create"
            let msg = fmt"Failed to wait runtime {cmd} command exit"
            logger.log(lvlError,msg)
            quit(msg,QuitFailure)
        
    # read from container stderr for any error and send it to parent(manager)
    # send -1 as pid to signal parent(manager) that create container has failed.
    if (not WIFEXITED(runtimeState)) or WEXITSTATUS(runtimeState)!=0:
        let rn = read(stderrPipe_r,addr buf,bufSize-1)
        if rn > 0:
            let content = join(buf[0..rn],"")
            logger.log(lvlError,fmt"runtime exec failed:{content}")
            if syncPipe>0:
                var p = -1 
                if ops.runtimeExec and containerStatus>0 :
                    p = -1*containerStatus
                writeSyncPipe(syncPipe,p,content)
        let s = getExitStatus(runtimeState)
        let msg = fmt"Failed to create container: exit status {s}"
        logger.log(lvlError,msg)
        quit(msg,QuitFailure)
    
    # get container pid form file,and send it to parent(manager) if need
    try:
        containerPid = getContainerPid(ops.optContainerLogFile)
        if (not ops.runtimeExec) and syncPipe>=0:
            writeSyncPipe(syncPipe,containerPid,"")
    except IOError,OSError:
        let msg = getCurrentExceptionMsg()
        logger.log(lvlError,msg)
        quit(fmt"Get container pid failed:{msg}",QuitFailure)
    
    # TODO: timeout

    let sigCtrFd = registerProcess(slt,containerPid,-5) 
    registerHandle(slt,stdoutPipe_r,{Read},-6)
    registerHandle(slt,stderrPipe_r,{Read},-7)

    if (not ops.runtimeExec) or (not ops.optTerminal) or (containerStatus < 0):
        var
            sigCtrExit:bool
            sigEOF:bool
        block mainLoop:
            while true:
                let keys = select(slt,-1)
                for i,k in keys[0..^1]:
                    if k.errorCode != OSErrorCode(0):
                        continue
                    if (k.fd in sigs):
                        sigExit = true
                        sig = sigs[k.fd]
                        break mainloop
                    # container process exit.
                    if k.fd == sigCtrFd and (Process in k.events):
                        sigCtrExit = true
                        break mainLoop
                    # container stderr.
                    if k.fd == stderrPipe_r and (Read in k.events):
                        let eof = serveContainerStdio(stderrPipe_r)
                        if eof:
                            discard close(stderrPipe_r)
                            stderrPipe_r = -1
                            if containerStatus>=0 and stdoutPipe_r<0:
                                sigEOF = true
                                break mainLoop
                    # process container output: 
                    # read them and write to log and send to remote sockets.
                    if k.fd == stdoutPipe_r and (Read in k.events):
                        let eof = serveContainerStdio(stdoutPipe_r)
                        if eof:
                            discard close(stdoutPipe_r)
                            stdoutPipe_r = -1
                            if containerStatus>=0 and stderrPipe_r<0:
                                sigEOF = true
                                break mainLoop
                    # process user new attach connection request.
                    if k.fd == int(attachSocketFd) and (Read in k.events):
                        # accept a new socket connection and register it in mainloop，then we can read the user input and send it to container
                        let newConn = attachHandler(attachSocketFd)
                        if int(newConn) != -1:
                            registerHandle(slt,newConn,{Read},-1) 
                            # add the connection in readers list,then we can send the container's output to it
                            remoteSock.readers.add(newConn) 
                            atchConns[newConn]=true 
                    # process user input from a attach conncetion.
                    if (SocketHandle(k.fd) in atchConns) and (Read in k.events):
                        # read user input from the socket connection and write to container's stdin
                        let eof = serveContainerStdin(SocketHandle(k.fd), stdinPipe_w)
                        if eof:
                            discard close(SocketHandle(k.fd))
                            unregister(slt,k.fd)
                            atchConns.del(SocketHandle(k.fd))
                    # process console resize event.
                    if k.fd == int(winSizeR) and (Read in k.events):
                        try:
                            readAndResizeWin(winSizeR,winSizeW)
                        except OSError as e:
                            logger.log(lvlError,fmt"Failed to resize window size:{e.msg}")
                    if k.fd == int(terminalControlR) and (Read in k.events):
                        try:
                            readTerminalControlFifo(terminalControlR)
                        except OSError as e:
                            logger.log(lvlError,fmt"Failed to read terminal control fifo:{e.msg}")
        #
        if sigCtrExit:
            discard waitpid(containerPid,containerStatus,0)
            containerPid = -1
            logger.log(lvlInfo,fmt"Container exit {containerStatus}")
        #
        if sigExit:
            logger.log(lvlInfo,fmt"Shim receved terminal signal,start to kill container")
            try:
                sigHandler(cint(sig))
            except OSError as e:
                logger.log(lvlError,e.msg)
                quit(e.msg,QuitFailure)  
        #
        if sigEOF:
            logger.log(lvlInfo,"Get EOF when serving container stdio")
        else:
            # read the remaining output of the container
            if stdoutPipe_r != -1:
                while not serveContainerStdio(stdoutPipe_r):
                    discard
            if stderrPipe_r != -1:
                while not serveContainerStdio(stdoutPipe_r):
                    discard
    
    # TODO if not timeout,we need not do this.
    var ctrExitStatus:int = -1
    if containerPid > 0:
        let group = getpgid(containerPid)
        if (group > 1):
            discard kill(-group, SIGKILL)
        else:
            discard kill(containerPid, SIGKILL)
    else:
        ctrExitStatus = getExitStatus(containerStatus)
    
    #
    try:
        closeAllAttachReaders()
    except OSError,IOError:
        let msg = getCurrentExceptionMsg()
        logger.log(lvlError,fmt"Close attach readers error:{msg}")
    
    # close attach socket
    if close(remoteSock.fd) < 0:
        logger.log(lvlError,fmt"Close attach spcket failed")

    #
    let exitState = fmt"{ctrExitStatus}"
    if ops.optContainerExitFile!="":
        var ef:File
        if open(ef,ops.optContainerExitFile,fmReadWrite):
            try:
                write(ef,exitState)
            except IOError,OSError:
                let msg = getCurrentExceptionMsg()
                quit(msg,QuitFailure)
            finally:
                close(ef)
        else:
            let msg = fmt"Failed to write {exitState} to container exit file: {ops.optContainerExitFile}"
            logger.log(lvlError,msg)
            quit(msg,QuitFailure)
    #
    if ops.runtimeExec and syncPipe > 0:
        writeSyncPipe(syncPipe,ctrExitStatus,"")
    if attachSocketPath != "" and unlink(cstring(attachSocketPath)) == -1 and errno != ENOENT:
        let msg = "Failed to remove symlink for attach socket directory"
        logger.log(lvlError,msg)
        quit(msg,QuitFailure)
    #
    quit(ctrExitStatus)
#
if isMainModule:
    let args = commandLineParams()
    main(join(args," "))
