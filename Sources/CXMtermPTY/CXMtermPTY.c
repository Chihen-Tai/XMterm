#include "CXMtermPTY.h"

#include <errno.h>
#include <fcntl.h>
#include <signal.h>
#include <stddef.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/wait.h>
#include <unistd.h>
#include <util.h>

static int xmterm_set_close_on_exec(int descriptor) {
    int flags = fcntl(descriptor, F_GETFD);
    if (flags == -1) {
        return -1;
    }
    return fcntl(descriptor, F_SETFD, flags | FD_CLOEXEC);
}

static int xmterm_set_nonblocking(int descriptor) {
    int flags = fcntl(descriptor, F_GETFL);
    if (flags == -1) {
        return -1;
    }
    return fcntl(descriptor, F_SETFL, flags | O_NONBLOCK);
}

static void xmterm_write_startup_errno_and_exit(int descriptor, int startup_errno) {
    const unsigned char *bytes = (const unsigned char *)&startup_errno;
    size_t written = 0;

    while (written < sizeof(startup_errno)) {
        ssize_t result = write(descriptor, bytes + written, sizeof(startup_errno) - written);
        if (result > 0) {
            written += (size_t)result;
            continue;
        }
        if (result == -1 && errno == EINTR) {
            continue;
        }
        break;
    }

    _exit(127);
}

static int xmterm_read_startup_errno(int descriptor, int *startup_errno) {
    unsigned char *bytes = (unsigned char *)startup_errno;
    size_t received = 0;
    *startup_errno = 0;

    while (received < sizeof(*startup_errno)) {
        ssize_t result = read(descriptor, bytes + received, sizeof(*startup_errno) - received);
        if (result > 0) {
            received += (size_t)result;
            continue;
        }
        if (result == 0) {
            if (received == 0) {
                return 0;
            }
            errno = EIO;
            return -1;
        }
        if (errno == EINTR) {
            continue;
        }
        return -1;
    }

    return 1;
}

static void xmterm_terminate_and_reap(pid_t child_pid, int master_fd) {
    if (master_fd >= 0) {
        close(master_fd);
    }
    if (child_pid > 0) {
        kill(-child_pid, SIGKILL);
        while (waitpid(child_pid, NULL, 0) == -1 && errno == EINTR) {
        }
    }
}

int32_t xmterm_pty_spawn(
    const char *executable_path,
    char *const argv[],
    char *const envp[],
    const char *working_directory_path,
    uint16_t columns,
    uint16_t rows,
    XMtermPTYSpawnResult *result
) {
    if (executable_path == NULL || argv == NULL || envp == NULL || result == NULL ||
        columns == 0 || rows == 0) {
        errno = EINVAL;
        return -1;
    }

    result->master_fd = -1;
    result->child_pid = -1;
    result->startup_errno = 0;

    int startup_pipe[2] = {-1, -1};
    if (pipe(startup_pipe) == -1) {
        return -1;
    }
    if (xmterm_set_close_on_exec(startup_pipe[0]) == -1 ||
        xmterm_set_close_on_exec(startup_pipe[1]) == -1) {
        int saved_errno = errno;
        close(startup_pipe[0]);
        close(startup_pipe[1]);
        errno = saved_errno;
        return -1;
    }

    struct winsize window_size;
    memset(&window_size, 0, sizeof(window_size));
    window_size.ws_col = columns;
    window_size.ws_row = rows;

    int master_fd = -1;
    pid_t child_pid = forkpty(&master_fd, NULL, NULL, &window_size);
    if (child_pid == -1) {
        int saved_errno = errno;
        close(startup_pipe[0]);
        close(startup_pipe[1]);
        errno = saved_errno;
        return -1;
    }

    if (child_pid == 0) {
        close(startup_pipe[0]);
        if (working_directory_path != NULL && chdir(working_directory_path) == -1) {
            xmterm_write_startup_errno_and_exit(startup_pipe[1], errno);
        }
        execve(executable_path, argv, envp);
        xmterm_write_startup_errno_and_exit(startup_pipe[1], errno);
    }

    close(startup_pipe[1]);

    int startup_errno = 0;
    int startup_result = xmterm_read_startup_errno(startup_pipe[0], &startup_errno);
    int startup_pipe_errno = errno;
    close(startup_pipe[0]);

    if (startup_result == -1) {
        xmterm_terminate_and_reap(child_pid, master_fd);
        errno = startup_pipe_errno;
        return -1;
    }
    if (startup_result == 1) {
        xmterm_terminate_and_reap(child_pid, master_fd);
        result->startup_errno = startup_errno;
        errno = startup_errno;
        return -1;
    }

    if (xmterm_set_close_on_exec(master_fd) == -1 || xmterm_set_nonblocking(master_fd) == -1) {
        int saved_errno = errno;
        xmterm_terminate_and_reap(child_pid, master_fd);
        errno = saved_errno;
        return -1;
    }

    result->master_fd = master_fd;
    result->child_pid = child_pid;
    return 0;
}

int32_t xmterm_pty_set_window_size(int32_t master_fd, uint16_t columns, uint16_t rows) {
    if (master_fd < 0 || columns == 0 || rows == 0) {
        errno = EINVAL;
        return -1;
    }

    struct winsize window_size;
    memset(&window_size, 0, sizeof(window_size));
    window_size.ws_col = columns;
    window_size.ws_row = rows;
    return ioctl(master_fd, TIOCSWINSZ, &window_size);
}

pid_t xmterm_pty_foreground_process_group(int32_t master_fd) {
    if (master_fd < 0) {
        errno = EINVAL;
        return -1;
    }
    return tcgetpgrp(master_fd);
}

int32_t xmterm_pty_signal_foreground_process_group(
    int32_t master_fd,
    int32_t signal_number
) {
    if (master_fd < 0 || signal_number <= 0) {
        errno = EINVAL;
        return -1;
    }
    return ioctl(master_fd, TIOCSIG, signal_number);
}

int32_t xmterm_pty_signal_process_group(pid_t process_group_id, int32_t signal_number) {
    if (process_group_id <= 0 || signal_number <= 0) {
        errno = EINVAL;
        return -1;
    }
    return kill(-process_group_id, signal_number);
}
