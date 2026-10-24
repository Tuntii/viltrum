// wait_linux.h: epoll_wait with a nanosecond timeout. epoll_wait takes whole
// milliseconds, so the loop rounded the wait for the next deferred response up to
// the next millisecond: a response due in 0.2 ms went out 1 ms later. epoll_pwait2
// (Linux 5.11) takes a timespec; where it is missing, or a seccomp profile refuses
// it, the wait falls back to epoll_wait for good.
#ifndef VILTRUM_WAIT_LINUX_H
#define VILTRUM_WAIT_LINUX_H

#include <errno.h>
#include <stdint.h>
#include <sys/epoll.h>
#include <sys/syscall.h>
#include <time.h>
#include <unistd.h>

#ifndef SYS_epoll_pwait2
#define SYS_epoll_pwait2 441 // the same number on every architecture
#endif

// Shared by the workers without a lock: each of them can only clear it, and a
// worker that still sees it set costs one more failed call.
static volatile int viltrum_pwait2_ok = 1;

// viltrum_epoll_wait waits for events at most timeout_ns.
static int viltrum_epoll_wait(int epfd, struct epoll_event *events, int max, int64_t timeout_ns) {
	if (viltrum_pwait2_ok) {
		struct timespec ts;
		ts.tv_sec = timeout_ns / 1000000000;
		ts.tv_nsec = timeout_ns % 1000000000;
		long n = syscall(SYS_epoll_pwait2, epfd, events, max, &ts, NULL, 0);
		if (n >= 0 || (errno != ENOSYS && errno != EPERM)) {
			return (int)n;
		}
		viltrum_pwait2_ok = 0;
	}
	return epoll_wait(epfd, events, max, (int)((timeout_ns + 999999) / 1000000));
}

#endif
