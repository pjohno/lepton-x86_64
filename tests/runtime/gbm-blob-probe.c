// SPDX-License-Identifier: MIT
/* Patch 0014 diagnostic: minigbm gbm_mesa BLOB handling against the host Mesa driver.
 * Allocation: W-byte BLOB -> 4096 x ceil(W/4096) linear R8 (as gbm_mesa_bo_create).
 * Import+map A ("current"): W x 1, stride 4096 (gralloc without patch 0014).
 * Import+map B ("fixed"):   4096 x ceil(W/4096), stride 4096 (patch 0014).
 * Exit status 0 when the fixed geometry maps at every size. */
#include <fcntl.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

struct gbm_device; struct gbm_bo;
struct gbm_import_fd_modifier_data {
	uint32_t width, height, format, num_fds;
	int fds[4], strides[4], offsets[4];
	uint64_t modifier;
};
struct gbm_device *gbm_create_device(int fd);
struct gbm_bo *gbm_bo_create_with_modifiers2(struct gbm_device *, uint32_t, uint32_t, uint32_t,
					     const uint64_t *, unsigned, uint32_t);
struct gbm_bo *gbm_bo_import(struct gbm_device *, uint32_t, void *, uint32_t);
int gbm_bo_get_fd(struct gbm_bo *);
uint32_t gbm_bo_get_stride(struct gbm_bo *);
uint64_t gbm_bo_get_modifier(struct gbm_bo *);
void *gbm_bo_map(struct gbm_bo *, uint32_t, uint32_t, uint32_t, uint32_t, uint32_t, uint32_t *, void **);
void gbm_bo_unmap(struct gbm_bo *, void *);
void gbm_bo_destroy(struct gbm_bo *);

#define R8 0x20203852u
#define IMPORT_FD_MODIFIER 0x5504
#define RW 3

static int try_map(struct gbm_device *g, int fd, uint32_t w, uint32_t h, uint32_t stride,
		   uint64_t mod, size_t bytes, const char *tag)
{
	struct gbm_import_fd_modifier_data d = { w, h, R8, 1, { fd }, { (int)stride }, { 0 }, mod };
	struct gbm_bo *bo = gbm_bo_import(g, IMPORT_FD_MODIFIER, &d, 0);
	if (!bo) {
		printf("  %-8s import %ux%u stride %u: IMPORT FAILED\n", tag, w, h, stride);
		return 0;
	}
	uint32_t ms = 0; void *md = NULL;
	unsigned char *p = gbm_bo_map(bo, 0, 0, w, h, RW, &ms, &md);
	int ok = p != NULL;
	if (ok) {
		memset(p, 0x5a, bytes < (size_t)ms * h ? bytes : (size_t)ms * h);
		gbm_bo_unmap(bo, md);
	}
	printf("  %-8s import %ux%u stride %u: map %s (map_stride %u)\n", tag, w, h, stride,
	       ok ? "OK" : "FAILED", ms);
	gbm_bo_destroy(bo);
	return ok;
}

int main(int argc, char **argv)
{
	const char *node = argc > 1 ? argv[1] : "/dev/dri/renderD128";
	int dfd = open(node, O_RDWR | O_CLOEXEC);
	if (dfd < 0) { perror(node); return 2; }
	struct gbm_device *g = gbm_create_device(dfd);
	if (!g) { fprintf(stderr, "gbm_create_device failed\n"); return 2; }
	static const uint32_t sizes[] = { 4096, 8192, 16384, 32768, 65536, 1048576 };
	int cur_fail = 0, fix_fail = 0;
	for (unsigned i = 0; i < sizeof(sizes) / sizeof(*sizes); i++) {
		uint32_t W = sizes[i], aw = 4096, ah = (W + 4095) / 4096;
		uint64_t lin = 0;
		struct gbm_bo *bo = gbm_bo_create_with_modifiers2(g, aw, ah, R8, &lin, 1, 0);
		if (!bo) { printf("W=%u: alloc %ux%u FAILED\n", W, aw, ah); fix_fail++; continue; }
		int fd = gbm_bo_get_fd(bo);
		uint32_t st = gbm_bo_get_stride(bo);
		uint64_t mod = gbm_bo_get_modifier(bo);
		gbm_bo_destroy(bo);
		printf("BLOB W=%u -> alloc %ux%u stride %u mod 0x%llx\n", W, aw, ah, st,
		       (unsigned long long)mod);
		cur_fail += !try_map(g, fd, W, 1, st, mod, W, "current");
		fix_fail += !try_map(g, fd, aw, ah, st, mod, W, "fixed");
		close(fd);
	}
	printf("RESULT current_failures=%d fixed_failures=%d\n", cur_fail, fix_fail);
	return fix_fail ? 1 : 0;
}
