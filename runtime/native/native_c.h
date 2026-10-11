/* Build-time translation only; never read by the deployed executable. */
#include <sqlite3.h>
#include <sys/types.h>
#include <sys/stat.h>
#include <sys/socket.h>
#include <sys/file.h>
#include <fcntl.h>
#include <unistd.h>
#include <stdlib.h>
#include <stdio.h>
#include <poll.h>
#include <signal.h>
#include <stdint.h>

/* Keep libc's target-specific stat layout on the C side. */
struct protean_native_stat {
    uint64_t st_dev;
    uint64_t st_ino;
    uint64_t st_uid;
    uint64_t st_nlink;
    uint32_t st_mode;
    int64_t st_size;
};
int protean_native_fstat(int fd, struct protean_native_stat *out);
typedef void (*protean_native_signal_handler)(int);
int protean_native_signals_begin(protean_native_signal_handler handler);
void protean_native_signals_end(void);
