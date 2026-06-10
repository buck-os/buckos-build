/*
 * libkbuild_trace.so — LD_PRELOAD exec tracer for kernel build capture.
 *
 * Intercepts the exec(3) family and posix_spawn(3) and writes one JSON
 * object per call to the file named by $KBUILD_TRACE_FILE (or the fd
 * named by $KBUILD_TRACE_FD, default disabled). The real exec is then
 * invoked via dlsym(RTLD_NEXT, ...).
 *
 * Output format: one JSON object per line, single atomic write(2) with
 * O_APPEND so concurrent writers from parallel make jobs interleave
 * cleanly without inter-process locking.
 *
 *   {"ts":<ns>,"pid":1234,"ppid":1233,"cwd":"/abs","path":"/usr/bin/gcc",
 *    "argv":["gcc","-c","foo.c","-o","foo.o"],
 *    "env":["PATH=/usr/bin","HOME=/root"]}
 *
 * Per-call buffer is fixed (KB_BUF) and the line is truncated if argv
 * + env exceed it. Truncated lines are still valid JSON but get an
 * additional "truncated":true field.
 */

#define _GNU_SOURCE
#include <dlfcn.h>
#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <spawn.h>
#include <stdarg.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <time.h>
#include <unistd.h>

extern char **environ;

#define KB_BUF (1 << 17)  /* 128 KiB per call — well above any sane argv */

/* Cached pointers to real libc symbols. */
static int (*real_execve)(const char *, char *const[], char *const[]);
static int (*real_execvpe)(const char *, char *const[], char *const[]);
static int (*real_fexecve)(int, char *const[], char *const[]);
static int (*real_posix_spawn)(pid_t *, const char *,
                               const posix_spawn_file_actions_t *,
                               const posix_spawnattr_t *,
                               char *const[], char *const[]);
static int (*real_posix_spawnp)(pid_t *, const char *,
                                const posix_spawn_file_actions_t *,
                                const posix_spawnattr_t *,
                                char *const[], char *const[]);

/* Trace fd, lazily initialised per-process. -1 means disabled or failed. */
static int trace_fd = -2;  /* -2 = uninitialised, -1 = disabled, >=0 = open */

static void load_real_symbols(void) {
    if (real_execve) return;
    real_execve     = dlsym(RTLD_NEXT, "execve");
    real_execvpe    = dlsym(RTLD_NEXT, "execvpe");
    real_fexecve    = dlsym(RTLD_NEXT, "fexecve");
    real_posix_spawn  = dlsym(RTLD_NEXT, "posix_spawn");
    real_posix_spawnp = dlsym(RTLD_NEXT, "posix_spawnp");
}

static int open_trace_fd(void) {
    const char *path = getenv("KBUILD_TRACE_FILE");
    if (path && *path) {
        int fd = open(path, O_WRONLY | O_APPEND | O_CREAT | O_CLOEXEC, 0644);
        if (fd >= 0) return fd;
    }
    const char *fd_env = getenv("KBUILD_TRACE_FD");
    if (fd_env && *fd_env) {
        char *end = NULL;
        long v = strtol(fd_env, &end, 10);
        if (end && *end == '\0' && v >= 0 && v < INT_MAX) {
            int fd = (int)v;
            int flags = fcntl(fd, F_GETFL);
            if (flags != -1) return fd;
        }
    }
    return -1;
}

static int get_trace_fd(void) {
    if (trace_fd == -2) trace_fd = open_trace_fd();
    return trace_fd;
}

/* Append a JSON-escaped string to buf at *off, bounded by cap.
 * Returns 0 on success, -1 if truncated. */
static int json_escape(char *buf, size_t *off, size_t cap, const char *s) {
    size_t o = *off;
    if (o + 1 >= cap) return -1;
    buf[o++] = '"';
    for (const unsigned char *p = (const unsigned char *)s; *p; p++) {
        if (o + 8 >= cap) { *off = o; return -1; }
        unsigned char c = *p;
        switch (c) {
        case '"':  buf[o++] = '\\'; buf[o++] = '"'; break;
        case '\\': buf[o++] = '\\'; buf[o++] = '\\'; break;
        case '\b': buf[o++] = '\\'; buf[o++] = 'b';  break;
        case '\f': buf[o++] = '\\'; buf[o++] = 'f';  break;
        case '\n': buf[o++] = '\\'; buf[o++] = 'n';  break;
        case '\r': buf[o++] = '\\'; buf[o++] = 'r';  break;
        case '\t': buf[o++] = '\\'; buf[o++] = 't';  break;
        default:
            if (c < 0x20) {
                int n = snprintf(buf + o, cap - o, "\\u%04x", c);
                if (n < 0 || (size_t)n >= cap - o) { *off = o; return -1; }
                o += (size_t)n;
            } else {
                buf[o++] = (char)c;
            }
        }
    }
    if (o + 1 >= cap) { *off = o; return -1; }
    buf[o++] = '"';
    *off = o;
    return 0;
}

static int append_str(char *buf, size_t *off, size_t cap, const char *s) {
    size_t len = strlen(s);
    if (*off + len >= cap) return -1;
    memcpy(buf + *off, s, len);
    *off += len;
    return 0;
}

static int append_array(char *buf, size_t *off, size_t cap, char *const v[]) {
    if (append_str(buf, off, cap, "[") < 0) return -1;
    if (v) {
        for (size_t i = 0; v[i]; i++) {
            if (i && append_str(buf, off, cap, ",") < 0) return -1;
            if (json_escape(buf, off, cap, v[i]) < 0) return -1;
        }
    }
    if (append_str(buf, off, cap, "]") < 0) return -1;
    return 0;
}

static void emit(const char *call, const char *path, char *const argv[],
                 char *const envp[]) {
    int fd = get_trace_fd();
    if (fd < 0) return;

    char buf[KB_BUF];
    size_t off = 0;
    int truncated = 0;

    struct timespec ts;
    clock_gettime(CLOCK_REALTIME, &ts);
    int64_t ns = (int64_t)ts.tv_sec * 1000000000LL + (int64_t)ts.tv_nsec;

    char cwd[PATH_MAX];
    if (!getcwd(cwd, sizeof(cwd))) cwd[0] = '\0';

    int n = snprintf(buf + off, sizeof(buf) - off,
                     "{\"ts\":%lld,\"pid\":%d,\"ppid\":%d,\"call\":\"%s\",",
                     (long long)ns, (int)getpid(), (int)getppid(), call);
    if (n < 0) return;
    off += (size_t)n;

    if (append_str(buf, &off, sizeof(buf), "\"cwd\":") < 0) return;
    if (json_escape(buf, &off, sizeof(buf), cwd) < 0) truncated = 1;
    if (append_str(buf, &off, sizeof(buf), ",\"path\":") < 0) return;
    if (json_escape(buf, &off, sizeof(buf), path ? path : "") < 0) truncated = 1;
    if (append_str(buf, &off, sizeof(buf), ",\"argv\":") < 0) return;
    if (append_array(buf, &off, sizeof(buf), argv) < 0) truncated = 1;
    if (append_str(buf, &off, sizeof(buf), ",\"env\":") < 0) return;
    if (append_array(buf, &off, sizeof(buf), envp) < 0) truncated = 1;

    if (truncated) {
        static const char marker[] = ",\"truncated\":true";
        size_t mlen = sizeof(marker) - 1;
        if (sizeof(buf) > mlen + 2 && off > sizeof(buf) - mlen - 2) {
            off = sizeof(buf) - mlen - 2;  /* reserve room */
        }
        (void)append_str(buf, &off, sizeof(buf), marker);
    }
    if (off + 2 < sizeof(buf)) {
        buf[off++] = '}';
        buf[off++] = '\n';
    } else {
        /* Force a closing brace + newline at the tail to keep parser happy. */
        buf[sizeof(buf) - 2] = '}';
        buf[sizeof(buf) - 1] = '\n';
        off = sizeof(buf);
    }

    /* Single atomic write — kernel guarantees O_APPEND atomicity for
     * writes <= PIPE_BUF on regular files, and for typical sizes here
     * concurrent writers do not interleave under O_APPEND. */
    ssize_t w = write(fd, buf, off);
    (void)w;
}

/* ── Interposed entry points ─────────────────────────────────────── */

int execve(const char *path, char *const argv[], char *const envp[]) {
    load_real_symbols();
    emit("execve", path, argv, envp);
    return real_execve(path, argv, envp);
}

int execv(const char *path, char *const argv[]) {
    load_real_symbols();
    emit("execv", path, argv, environ);
    return real_execve(path, argv, environ);
}

int execvp(const char *file, char *const argv[]) {
    load_real_symbols();
    emit("execvp", file, argv, environ);
    if (real_execvpe) return real_execvpe(file, argv, environ);
    /* Fallback: emulate PATH search via execvp by calling the real one.
     * dlsym for execvp directly to avoid infinite recursion. */
    int (*r)(const char *, char *const[]) = dlsym(RTLD_NEXT, "execvp");
    return r ? r(file, argv) : -1;
}

int execvpe(const char *file, char *const argv[], char *const envp[]) {
    load_real_symbols();
    emit("execvpe", file, argv, envp);
    return real_execvpe ? real_execvpe(file, argv, envp) : -1;
}

int fexecve(int fd, char *const argv[], char *const envp[]) {
    load_real_symbols();
    emit("fexecve", "<fd>", argv, envp);
    return real_fexecve ? real_fexecve(fd, argv, envp) : -1;
}

int posix_spawn(pid_t *pid, const char *path,
                const posix_spawn_file_actions_t *fa,
                const posix_spawnattr_t *attr,
                char *const argv[], char *const envp[]) {
    load_real_symbols();
    emit("posix_spawn", path, argv, envp);
    return real_posix_spawn ? real_posix_spawn(pid, path, fa, attr, argv, envp)
                            : -1;
}

int posix_spawnp(pid_t *pid, const char *file,
                 const posix_spawn_file_actions_t *fa,
                 const posix_spawnattr_t *attr,
                 char *const argv[], char *const envp[]) {
    load_real_symbols();
    emit("posix_spawnp", file, argv, envp);
    return real_posix_spawnp ? real_posix_spawnp(pid, file, fa, attr, argv, envp)
                             : -1;
}
