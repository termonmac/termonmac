#include <unistd.h>
#include <sys/ioctl.h>
#include <sys/socket.h>
#include <string.h>
#include <TargetConditionals.h>

// ---------- fd passing via SCM_RIGHTS ----------

int c_sendfd(int socket, int fd_to_send) {
    char dummy = 0;
    struct iovec iov = { .iov_base = &dummy, .iov_len = 1 };

    // Allocate control message buffer for one fd
    char cmsgbuf[CMSG_SPACE(sizeof(int))];
    memset(cmsgbuf, 0, sizeof(cmsgbuf));

    struct msghdr msg = {
        .msg_iov = &iov,
        .msg_iovlen = 1,
        .msg_control = cmsgbuf,
        .msg_controllen = sizeof(cmsgbuf),
    };

    struct cmsghdr *cmsg = CMSG_FIRSTHDR(&msg);
    cmsg->cmsg_level = SOL_SOCKET;
    cmsg->cmsg_type  = SCM_RIGHTS;
    cmsg->cmsg_len   = CMSG_LEN(sizeof(int));
    memcpy(CMSG_DATA(cmsg), &fd_to_send, sizeof(int));

    return sendmsg(socket, &msg, 0) >= 0 ? 0 : -1;
}

int c_recvfd(int socket) {
    char dummy;
    struct iovec iov = { .iov_base = &dummy, .iov_len = 1 };

    char cmsgbuf[CMSG_SPACE(sizeof(int))];
    memset(cmsgbuf, 0, sizeof(cmsgbuf));

    struct msghdr msg = {
        .msg_iov = &iov,
        .msg_iovlen = 1,
        .msg_control = cmsgbuf,
        .msg_controllen = sizeof(cmsgbuf),
    };

    if (recvmsg(socket, &msg, 0) < 0)
        return -1;

    struct cmsghdr *cmsg = CMSG_FIRSTHDR(&msg);
    if (cmsg == NULL ||
        cmsg->cmsg_level != SOL_SOCKET ||
        cmsg->cmsg_type  != SCM_RIGHTS ||
        cmsg->cmsg_len   != CMSG_LEN(sizeof(int)))
        return -1;

    int fd;
    memcpy(&fd, CMSG_DATA(cmsg), sizeof(int));
    return fd;
}

#if TARGET_OS_OSX
#include <util.h>

// Swift marks fork() as unavailable, so we wrap it in C.

int c_forkpty(int *masterfd, struct winsize *ws) {
    int master, slave;
    if (openpty(&master, &slave, NULL, NULL, ws) < 0)
        return -1;

    pid_t pid = fork();
    if (pid < 0) {
        close(master);
        close(slave);
        return -1;
    }

    if (pid == 0) {
        // Child
        close(master);
        setsid();
        ioctl(slave, TIOCSCTTY, 0);
        dup2(slave, STDIN_FILENO);
        dup2(slave, STDOUT_FILENO);
        dup2(slave, STDERR_FILENO);
        if (slave > STDERR_FILENO) close(slave);
        return 0; // caller checks: 0 = child
    }

    // Parent
    close(slave);
    *masterfd = master;
    return pid;
}

#else

// Stub for non-macOS platforms
int c_forkpty(int *masterfd, struct winsize *ws) {
    (void)masterfd;
    (void)ws;
    return -1;
}

#endif
