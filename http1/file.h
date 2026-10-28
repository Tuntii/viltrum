// file.h: open a file with its size and mtime, read it at an offset, close it. The
// part of Ctx.file that differs per platform (where struct stat keeps mtime, no
// pread on Windows).
#ifndef VILTRUM_FILE_H
#define VILTRUM_FILE_H

#include <stdint.h>
#include <fcntl.h>
#include <sys/types.h>
#include <sys/stat.h>
#ifdef _WIN32
#include <io.h>
#include <stdio.h>
#else
#include <unistd.h>
#endif

typedef struct {
	int64_t size;
	int64_t mtime;    // seconds since the epoch
	int64_t mtime_ns; // and the nanoseconds within it, where the platform keeps them
	int kind;         // 1: regular file, 2: directory, 0: anything else
} viltrum_file_info;

static void viltrum_file_close(int fd) {
#ifdef _WIN32
	_close(fd);
#else
	close(fd);
#endif
}

// viltrum_file_open opens path read-only and describes it in info; -1 when it cannot
// be opened, and for a directory, which it reports as kind 2 without keeping it open
// (Windows cannot open one at all). O_NONBLOCK: opening a FIFO someone left in a
// served directory must not block the worker.
static int viltrum_file_open(const char *path, viltrum_file_info *info) {
	info->kind = 0;
#ifdef _WIN32
	int fd = _open(path, _O_RDONLY | _O_BINARY | _O_NOINHERIT);
	if (fd < 0) {
		struct _stat64 ds;
		if (_stat64(path, &ds) == 0 && (ds.st_mode & _S_IFMT) == _S_IFDIR) {
			info->kind = 2;
		}
		return -1;
	}
	struct _stat64 st;
	if (_fstat64(fd, &st) != 0) {
		_close(fd);
		return -1;
	}
	info->mtime = (int64_t)st.st_mtime;
	info->mtime_ns = 0;
#else
	int fd = open(path, O_RDONLY | O_CLOEXEC | O_NONBLOCK);
	if (fd < 0) {
		return -1;
	}
	struct stat st;
	if (fstat(fd, &st) != 0) {
		close(fd);
		return -1;
	}
#if defined(__APPLE__)
	info->mtime = (int64_t)st.st_mtimespec.tv_sec;
	info->mtime_ns = (int64_t)st.st_mtimespec.tv_nsec;
#else
	info->mtime = (int64_t)st.st_mtim.tv_sec;
	info->mtime_ns = (int64_t)st.st_mtim.tv_nsec;
#endif
#endif
	if (info->mtime < 0) {
		// before 1970: the IMF-fixdate formatter indexes its tables with the day count
		info->mtime = 0;
		info->mtime_ns = 0;
	}
	info->size = (int64_t)st.st_size;
	info->kind = (st.st_mode & S_IFMT) == S_IFREG ? 1 : (st.st_mode & S_IFMT) == S_IFDIR ? 2 : 0;
	if (info->kind == 2) {
		viltrum_file_close(fd);
		return -1;
	}
	return fd;
}

// viltrum_file_pread reads up to n bytes at off: the count, 0 at the end, -1 on error.
static int64_t viltrum_file_pread(int fd, void *buf, size_t n, int64_t off) {
#ifdef _WIN32
	if (_lseeki64(fd, off, SEEK_SET) < 0) {
		return -1;
	}
	return (int64_t)_read(fd, buf, (unsigned int)n);
#else
	return (int64_t)pread(fd, buf, n, (off_t)off);
#endif
}

#endif
