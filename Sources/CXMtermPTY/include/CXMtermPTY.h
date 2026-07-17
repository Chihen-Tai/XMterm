#ifndef CXMTERMPTY_H
#define CXMTERMPTY_H

#include <stdint.h>
#include <sys/types.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct XMtermPTYSpawnResult {
    int32_t master_fd;
    pid_t child_pid;
    int32_t startup_errno;
} XMtermPTYSpawnResult;

/* Allocates a PTY and execs argv/envp without invoking a shell. */
int32_t xmterm_pty_spawn(
    const char *executable_path,
    char *const argv[],
    char *const envp[],
    const char *working_directory_path,
    uint16_t columns,
    uint16_t rows,
    XMtermPTYSpawnResult *result
);

/* Applies the PTY kernel window size through TIOCSWINSZ. */
int32_t xmterm_pty_set_window_size(
    int32_t master_fd,
    uint16_t columns,
    uint16_t rows
);

/* Returns the process group currently in the foreground of the PTY. */
pid_t xmterm_pty_foreground_process_group(int32_t master_fd);

/* Atomically signals the process group currently in the foreground of the PTY. */
int32_t xmterm_pty_signal_foreground_process_group(
    int32_t master_fd,
    int32_t signal_number
);

/* Signals every process in the supplied process group. */
int32_t xmterm_pty_signal_process_group(pid_t process_group_id, int32_t signal_number);

#ifdef __cplusplus
}
#endif

#endif
