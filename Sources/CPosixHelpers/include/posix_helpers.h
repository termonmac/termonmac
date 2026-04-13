#ifndef POSIX_HELPERS_H
#define POSIX_HELPERS_H

#include <sys/ttycom.h>

// Returns: 0 in child, pid in parent, -1 on error.
// On parent return, *masterfd is set to the PTY master fd.
int c_forkpty(int *masterfd, struct winsize *ws);

// Send a file descriptor over a Unix domain socket using SCM_RIGHTS.
// Returns 0 on success, -1 on error (check errno).
int c_sendfd(int socket, int fd_to_send);

// Receive a file descriptor from a Unix domain socket using SCM_RIGHTS.
// Returns the received fd on success, -1 on error (check errno).
int c_recvfd(int socket);

#endif
