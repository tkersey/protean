#include "native_c.h"

int protean_native_fstat(int fd, struct protean_native_stat *out) {
    struct stat value;
    if (fstat(fd, &value) != 0) return -1;
    out->st_dev = (uint64_t)value.st_dev;
    out->st_ino = (uint64_t)value.st_ino;
    out->st_uid = (uint64_t)value.st_uid;
    out->st_nlink = (uint64_t)value.st_nlink;
    out->st_mode = (uint32_t)value.st_mode;
    out->st_size = (int64_t)value.st_size;
    return 0;
}

/* Stdio and signal ownership are process-wide; no worker calls these helpers. */
static struct sigaction prior_pipe, prior_interrupt, prior_terminate;
static int signals_active;

int protean_native_signals_begin(protean_native_signal_handler handler) {
    if (signals_active) return -1;
    struct sigaction action = {0};
    sigemptyset(&action.sa_mask);
    action.sa_flags = SA_RESTART;
    action.sa_handler = SIG_IGN;
    if (sigaction(SIGPIPE, &action, &prior_pipe) != 0) return -1;
    action.sa_handler = handler;
    if (sigaction(SIGINT, &action, &prior_interrupt) != 0) {
        sigaction(SIGPIPE, &prior_pipe, 0);
        return -1;
    }
    if (sigaction(SIGTERM, &action, &prior_terminate) != 0) {
        sigaction(SIGINT, &prior_interrupt, 0);
        sigaction(SIGPIPE, &prior_pipe, 0);
        return -1;
    }
    signals_active = 1;
    return 0;
}

void protean_native_signals_end(void) {
    if (!signals_active) return;
    sigaction(SIGTERM, &prior_terminate, 0);
    sigaction(SIGINT, &prior_interrupt, 0);
    sigaction(SIGPIPE, &prior_pipe, 0);
    signals_active = 0;
}
