/* LD_PRELOAD compatibility shim for running stock Alpine/Linux chromium on
 * HarmonyOS PC. Three platform gaps, all intercepted here:
 *
 * 1) seccomp SIGSYS: the app sandbox KILLs the process (SIGSYS) on syscalls
 *    outside its allowlist where Linux would return -ENOSYS. Chromium probes
 *    landlock_* (444/445/446) at startup via musl's syscall(3); we answer
 *    -ENOSYS so it treats the feature as absent.
 *
 * 2) /proc/<pid>/status "Groups:" line: the HarmonyOS kernel emits it with NO
 *    trailing space after the last gid, but crashpad's process_info_linux.cc
 *    parser requires every gid to be followed by a space (as mainline Linux
 *    emits). The parse failure leaves the supplementary-group set empty, which
 *    later trips a null-deref during browser startup. We intercept reads of any
 *    /proc/.../status and hand back a fixed-up copy ending with that space.
 *
 * 3) chromium/base CHECKs that file descriptors it wraps are read-only
 *    (fcntl(F_GETFL) & (O_ACCMODE|O_PATH) == 0). Our fixed-up status fd must
 *    therefore be O_RDONLY. memfd is O_RDWR and /proc/self/fd re-open is EACCES
 *    on this device, so we stage the patched bytes through a real temp file in
 *    TMPDIR, re-open it O_RDONLY, and unlink it immediately.
 */
#define _GNU_SOURCE
#include <stdarg.h>
#include <string.h>
#include <stdlib.h>
#include <stdio.h>
#include <unistd.h>
#include <fcntl.h>
#include <errno.h>
#include <dlfcn.h>

/* ---- 1. syscall() denylist ---- */
static int deny(long n) {
  switch (n) {
    case 444: /* landlock_create_ruleset */
    case 445: /* landlock_add_rule */
    case 446: /* landlock_restrict_self */
      return 1;
    default:
      return 0;
  }
}

long syscall(long n, ...) {
  static long (*real)(long, ...);
  if (deny(n)) { errno = ENOSYS; return -1; }
  if (!real) real = (long (*)(long, ...))dlsym(RTLD_NEXT, "syscall");
  va_list ap; va_start(ap, n);
  long a = va_arg(ap, long), b = va_arg(ap, long), c = va_arg(ap, long);
  long d = va_arg(ap, long), e = va_arg(ap, long), f = va_arg(ap, long);
  va_end(ap);
  return real(n, a, b, c, d, e, f);
}

/* ---- 2+3. /proc/.../status Groups fixup, handed back as an O_RDONLY fd ---- */
static int is_status_path(const char *p) {
  if (!p) return 0;
  size_t n = strlen(p);
  return n >= 13 && strncmp(p, "/proc/", 6) == 0 &&
         strcmp(p + n - 7, "/status") == 0;
}

static int real_open_ro(const char *path) {
  static int (*ro)(const char *, int, ...);
  if (!ro) ro = (int (*)(const char *, int, ...))dlsym(RTLD_NEXT, "open");
  return ro(path, O_RDONLY);
}

/* Returns an O_RDONLY fd to a patched copy of the status file, or -1 to fall
 * back to the original fd. Buffers live on the heap: this can run on crashpad
 * threads with tiny stacks, so a multi-KB stack frame would overflow. */
static int patched_status_fd(int realfd) {
  enum { CAP = 65536 };
  char *buf = (char *)malloc(CAP);
  if (!buf) return -1;
  ssize_t total = 0, r;
  while (total < (ssize_t)CAP && (r = read(realfd, buf + total, CAP - total)) > 0)
    total += r;
  if (r < 0 || total <= 0 || total >= (ssize_t)CAP) { free(buf); return -1; }

  char *out = (char *)malloc((size_t)total + 8);
  if (!out) { free(buf); return -1; }
  size_t oi = 0, i = 0;
  int patched = 0;
  while (i < (size_t)total) {
    size_t ls = i;
    while (i < (size_t)total && buf[i] != '\n') i++;
    size_t len = i - ls;
    memcpy(out + oi, buf + ls, len); oi += len;
    if (!patched && len >= 7 && strncmp(buf + ls, "Groups:", 7) == 0 &&
        buf[ls + len - 1] != ' ') {
      out[oi++] = ' ';
      patched = 1;
    }
    if (i < (size_t)total) { out[oi++] = '\n'; i++; }
  }
  free(buf);
  if (!patched) { free(out); return -1; }

  const char *tmpdir = getenv("TMPDIR");
  if (!tmpdir || !*tmpdir) tmpdir = "/tmp";
  char tmpl[4096];
  int nn = snprintf(tmpl, sizeof(tmpl), "%s/.pwstat-XXXXXX", tmpdir);
  if (nn <= 0 || (size_t)nn >= sizeof(tmpl)) { free(out); return -1; }
  int wfd = mkstemp(tmpl);
  if (wfd < 0) { free(out); return -1; }
  size_t w = 0;
  while (w < oi) {
    ssize_t k = write(wfd, out + w, oi - w);
    if (k <= 0) { close(wfd); unlink(tmpl); free(out); return -1; }
    w += (size_t)k;
  }
  close(wfd);
  free(out);
  int rofd = real_open_ro(tmpl);
  unlink(tmpl);
  return rofd;  /* -1 tolerated: caller falls back */
}

int open(const char *path, int flags, ...) {
  static int (*real)(const char *, int, ...);
  if (!real) real = (int (*)(const char *, int, ...))dlsym(RTLD_NEXT, "open");
  mode_t mode = 0;
  if (flags & O_CREAT) { va_list ap; va_start(ap, flags); mode = va_arg(ap, mode_t); va_end(ap); }
  int fd = real(path, flags, mode);
  if (fd < 0 || (flags & O_ACCMODE) != O_RDONLY || !is_status_path(path)) return fd;
  int pf = patched_status_fd(fd);
  if (pf < 0) { lseek(fd, 0, SEEK_SET); return fd; }
  close(fd);
  return pf;
}

int openat(int dirfd, const char *path, int flags, ...) {
  static int (*real)(int, const char *, int, ...);
  if (!real) real = (int (*)(int, const char *, int, ...))dlsym(RTLD_NEXT, "openat");
  mode_t mode = 0;
  if (flags & O_CREAT) { va_list ap; va_start(ap, flags); mode = va_arg(ap, mode_t); va_end(ap); }
  int fd = real(dirfd, path, flags, mode);
  if (fd < 0 || (flags & O_ACCMODE) != O_RDONLY || !is_status_path(path)) return fd;
  int pf = patched_status_fd(fd);
  if (pf < 0) { lseek(fd, 0, SEEK_SET); return fd; }
  close(fd);
  return pf;
}
