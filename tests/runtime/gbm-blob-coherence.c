// SPDX-License-Identifier: MIT
/* Patch 0016 diagnostic. Cross-process visibility of CPU writes to a linear R8 gbm buffer, the way
 * Codec2 shares BLOB blocks: the writer maps and writes but keeps the mapping;
 * a second process imports the dma-buf, maps it and reads. Repeated with new
 * data while both mappings stay open, and again after the writer unmaps.
 * DIRECT=1 maps the dma-buf itself (as patch 0016 does) instead of gbm_bo_map;
 * HOLD=1 keeps one reader mapping open. Exit status 0 when no read was stale. */
#include <fcntl.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include <sys/wait.h>
#include <sys/socket.h>
#include <unistd.h>
#include <stdlib.h>
#include <sys/mman.h>
#include <sys/ioctl.h>
#include <linux/dma-buf.h>

struct gbm_device; struct gbm_bo;
struct gbm_import_fd_modifier_data { uint32_t width, height, format, num_fds; int fds[4], strides[4], offsets[4]; uint64_t modifier; };
struct gbm_device *gbm_create_device(int fd);
struct gbm_bo *gbm_bo_create_with_modifiers2(struct gbm_device *, uint32_t, uint32_t, uint32_t, const uint64_t *, unsigned, uint32_t);
struct gbm_bo *gbm_bo_import(struct gbm_device *, uint32_t, void *, uint32_t);
int gbm_bo_get_fd(struct gbm_bo *);
uint32_t gbm_bo_get_stride(struct gbm_bo *);
void *gbm_bo_map(struct gbm_bo *, uint32_t, uint32_t, uint32_t, uint32_t, uint32_t, uint32_t *, void **);
void gbm_bo_unmap(struct gbm_bo *, void *);
#define R8 0x20203852u
#define W 4096
#define H 8

static void send_fd(int s, int fd)
{
	char b = 0; struct iovec io = { &b, 1 }; char c[CMSG_SPACE(sizeof(int))];
	struct msghdr m = { 0 }; m.msg_iov = &io; m.msg_iovlen = 1; m.msg_control = c; m.msg_controllen = sizeof c;
	struct cmsghdr *h = CMSG_FIRSTHDR(&m); h->cmsg_level = SOL_SOCKET; h->cmsg_type = SCM_RIGHTS;
	h->cmsg_len = CMSG_LEN(sizeof(int)); memcpy(CMSG_DATA(h), &fd, sizeof(int));
	sendmsg(s, &m, 0);
}
static int recv_fd(int s)
{
	char b; struct iovec io = { &b, 1 }; char c[CMSG_SPACE(sizeof(int))]; int fd = -1;
	struct msghdr m = { 0 }; m.msg_iov = &io; m.msg_iovlen = 1; m.msg_control = c; m.msg_controllen = sizeof c;
	if (recvmsg(s, &m, 0) <= 0) return -1;
	memcpy(&fd, CMSG_DATA(CMSG_FIRSTHDR(&m)), sizeof(int));
	return fd;
}
static struct gbm_bo *import(struct gbm_device *g, int fd)
{
	struct gbm_import_fd_modifier_data d = { W, H, R8, 1, { fd }, { W }, { 0 }, 0 };
	return gbm_bo_import(g, 0x5504, &d, 0);
}

int main(int argc, char **argv)
{
	const char *node = argc > 1 ? argv[1] : "/dev/dri/renderD128";
	setvbuf(stdout, NULL, _IONBF, 0);
	alarm(30);
	int sv[2]; socketpair(AF_UNIX, SOCK_STREAM, 0, sv);
	if (fork() == 0) { /* reader process: own device, maps per read like Codec2 */
		alarm(30);
		int fd = recv_fd(sv[1]);
		struct gbm_device *g2 = gbm_create_device(open(node, O_RDWR | O_CLOEXEC));
		struct gbm_bo *bo = import(g2, fd);
		uint32_t st; void *md; char cmd;
		int hold = getenv("HOLD") != NULL, n = 0;
		unsigned char *held = NULL; void *hmd = NULL;
		fprintf(stderr, "reader: import %s\n", bo ? "ok" : "FAILED");
		while (read(sv[1], &cmd, 1) == 1) {
			unsigned char *p;
			md = NULL;
			if (getenv("DIRECT")) { p = mmap(NULL, W * H, PROT_READ, MAP_SHARED, fd, 0); if (p == MAP_FAILED) p = NULL; unsigned char o[2] = { p ? p[0] : 0xee, p ? p[W * H - 1] : 0xee }; if (p) munmap(p, W * H); write(sv[1], o, 2); continue; }
			if (hold) { if (!held) held = gbm_bo_map(bo, 0, 0, W, H, 1, &st, &hmd); p = held; }
			else p = gbm_bo_map(bo, 0, 0, W, H, 1, &st, &md);
			if (!p && n++ < 2) fprintf(stderr, "reader: map failed\n");
			unsigned char *raw = mmap(NULL, W * H, PROT_READ, MAP_SHARED, fd, 0);
			unsigned char out[2] = { p ? p[0] : 0xee, raw != MAP_FAILED ? raw[0] : 0xee };
			if (raw != MAP_FAILED) munmap(raw, W * H);
			if (p && !hold) gbm_bo_unmap(bo, md);
			write(sv[1], out, 2);
		}
		_exit(0);
	}
	struct gbm_device *g = gbm_create_device(open(node, O_RDWR | O_CLOEXEC));
	uint64_t lin = 0;
	struct gbm_bo *alloc = gbm_bo_create_with_modifiers2(g, W, H, R8, &lin, 1, 0);
	int fd = gbm_bo_get_fd(alloc);
	send_fd(sv[0], fd);
	struct gbm_bo *wbo = import(g, fd);
	uint32_t st; void *md;
	unsigned char *p;
	int direct = getenv("DIRECT") != NULL;
	if (direct) {
		p = mmap(NULL, W * H, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
		if (p == MAP_FAILED) p = NULL;
		struct dma_buf_sync s = { DMA_BUF_SYNC_START | DMA_BUF_SYNC_RW };
		printf("direct mmap %s, sync start %d\n", p ? "ok" : "FAILED", ioctl(fd, DMA_BUF_IOCTL_SYNC, &s));
		st = W;
	} else p = gbm_bo_map(wbo, 0, 0, W, H, 3, &st, &md);
	printf("writer map %s, stride %u\n", p ? "ok" : "FAILED", st);
	int stale = 0; unsigned char got[2]; char c = 'r';
	for (int i = 1; i <= 20; i++) {
		memset(p, i, W * H);
		write(sv[0], &c, 1); read(sv[0], got, 2);
		if (got[0] != i || got[1] != i) stale++;
		if (i <= 3 || got[0] != i) printf("  write %2d while mapped -> reader: gbm map sees %u, raw dma-buf sees %u\n", i, got[0], got[1]);
	}
	if (direct) { struct dma_buf_sync e = { DMA_BUF_SYNC_END | DMA_BUF_SYNC_RW }; ioctl(fd, DMA_BUF_IOCTL_SYNC, &e); munmap(p, W * H); }
	else gbm_bo_unmap(wbo, md);
	write(sv[0], &c, 1); read(sv[0], got, 2);
	printf("  after writer unmap -> reader: gbm map sees %u, raw dma-buf sees %u\n", got[0], got[1]);
	printf("RESULT stale_reads_while_mapped=%d/20\n", stale);
	shutdown(sv[0], SHUT_WR); wait(NULL);
	return stale ? 1 : 0;
}
