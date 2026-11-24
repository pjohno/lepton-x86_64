// SPDX-License-Identifier: MIT
// Host check for direct output (patch 0030), without Android: can this GPU's
// VA-API driver convert a P010 (or NV12) surface into an imported linear
// dma-buf laid out like an Android YV12 gralloc buffer, exactly?
//
// Build (needs libva-devel and mesa-libgbm-devel, or their headers):
//   cc -O2 -o /tmp/va-vpp-import-probe tests/runtime/va-vpp-import-probe.c -lva -lva-drm -lgbm
// Run:
//   /tmp/va-vpp-import-probe MODE [ALIGN] [ITERATIONS] [WIDTH] [HEIGHT]
//   MODE: yv12 (Android YV12 described as YV12), i420 (the same memory described
//         as I420, U plane first: what the service does), nv12
//   ALIGN: Y row pitch alignment in bytes (default 64; Mesa needs 256-aligned
//          chroma pitches, e.g. 1024 for 4K)
//   Environment: SRC8=1 for an NV12 source; PRETOUCH=1 writes the buffer on
//   the CPU first; NORENDER=1 allocates it without GBM_BO_USE_RENDERING.
// Prints the time per conversion (submit + wait) and, per plane, samples more
// than one code from nearest rounding of the source, then PASS or FAIL.
// Results (2026-11-24): Intel iHD 26.1.5 exact in all modes; Mesa 26.2.7
// radeonsi exact for nv12 and i420, chroma swapped for yv12.
#define _GNU_SOURCE
#include <fcntl.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>
#include <va/va.h>
#include <va/va_drm.h>
#include <va/va_drmcommon.h>
#include <va/va_vpp.h>
#include <gbm.h>
#include <drm/drm_fourcc.h>

#define CK(x) do { VAStatus s_ = (x); if (s_ != VA_STATUS_SUCCESS) { \
    fprintf(stderr, "%s:%d %s -> %d (%s)\n", __FILE__, __LINE__, #x, s_, vaErrorStr(s_)); exit(1);} } while (0)
#define ALIGN(v, a) (((v) + (a) - 1) / (a) * (a))

static double now_ms(void) { struct timespec t; clock_gettime(CLOCK_MONOTONIC, &t); return t.tv_sec * 1e3 + t.tv_nsec / 1e6; }
static unsigned y10(int x, int y) { return 64 + (unsigned)((x * 7 + y * 3) % 877); }
static unsigned u10(int x, int y) { return 64 + (unsigned)((x * 5 + y * 11) % 897); }
static unsigned v10(int x, int y) { return 64 + (unsigned)((x * 13 + y * 2) % 897); }
static unsigned to8(unsigned v) { unsigned r = (v + 2) >> 2; return r > 255 ? 255 : r; }

int main(int argc, char **argv) {
    const char *mode = argc > 1 ? argv[1] : "yv12";
    int align = argc > 2 ? atoi(argv[2]) : 64;
    int iters = argc > 3 ? atoi(argv[3]) : 200;
    int W = argc > 4 ? atoi(argv[4]) : 3840, H = argc > 5 ? atoi(argv[5]) : 2160;
    int i420 = !strcmp(mode, "i420");
    int yv12 = !strcmp(mode, "yv12") || i420;  // i420: Android YV12 memory described as I420

    int fd = open("/dev/dri/renderD128", O_RDWR);
    VADisplay dpy = vaGetDisplayDRM(fd);
    int maj, min;
    CK(vaInitialize(dpy, &maj, &min));
    printf("driver: %s\n", vaQueryVendorString(dpy));

    // Destination: one linear BO, Android-style planes.
    int ystride = ALIGN(W, align);
    int cstride = yv12 ? ALIGN(ystride / 2, 16) : ystride;
    size_t ysize = (size_t)ystride * H;
    size_t csize = yv12 ? (size_t)cstride * (H / 2) : 0;
    size_t total = yv12 ? ysize + 2 * csize : ysize + (size_t)ystride * (H / 2);
    struct gbm_device *gbm = gbm_create_device(fd);
    struct gbm_bo *bo = gbm_bo_create(gbm, ystride, (uint32_t)((total + ystride - 1) / ystride),
                                      GBM_FORMAT_R8, getenv("NORENDER") ? GBM_BO_USE_LINEAR : GBM_BO_USE_LINEAR | GBM_BO_USE_RENDERING);
    if (!bo) { fprintf(stderr, "gbm_bo_create failed\n"); return 1; }
    if ((int)gbm_bo_get_stride(bo) != ystride) { fprintf(stderr, "gbm stride %u != %d\n", gbm_bo_get_stride(bo), ystride); return 1; }
    int dmafd = gbm_bo_get_fd(bo);
    if (getenv("PRETOUCH")) {  // CPU-write the buffer first, as a recycled or cleared buffer would be
        uint32_t ps; void *ph = NULL;
        uint8_t *pm = gbm_bo_map(bo, 0, 0, ystride, gbm_bo_get_height(bo), GBM_BO_TRANSFER_READ_WRITE, &ps, &ph);
        if (pm) { memset(pm, 0xAA, (size_t)ps * gbm_bo_get_height(bo)); volatile uint8_t sink = pm[12345]; (void)sink; gbm_bo_unmap(bo, ph); }
        printf("pretouched\n");
    }

    VADRMPRIMESurfaceDescriptor d;
    memset(&d, 0, sizeof d);
    d.fourcc = i420 ? VA_FOURCC_I420 : yv12 ? VA_FOURCC_YV12 : VA_FOURCC_NV12;
    d.width = W; d.height = H;
    d.num_objects = 1;
    d.objects[0].fd = dmafd;
    d.objects[0].size = (uint32_t)lseek(dmafd, 0, SEEK_END);
    d.objects[0].drm_format_modifier = DRM_FORMAT_MOD_LINEAR;
    d.num_layers = 1;
    d.layers[0].drm_format = i420 ? DRM_FORMAT_YUV420 : yv12 ? DRM_FORMAT_YVU420 : DRM_FORMAT_NV12;
    d.layers[0].num_planes = yv12 ? 3 : 2;
    d.layers[0].offset[0] = 0; d.layers[0].pitch[0] = ystride;
    d.layers[0].offset[1] = ysize; d.layers[0].pitch[1] = cstride;
    if (yv12) { d.layers[0].offset[2] = ysize + csize; d.layers[0].pitch[2] = cstride; }
    if (i420) { d.layers[0].offset[1] = ysize + csize; d.layers[0].offset[2] = ysize; }
    VASurfaceAttrib da[2] = {
        { .type = VASurfaceAttribMemoryType, .flags = VA_SURFACE_ATTRIB_SETTABLE,
          .value = { .type = VAGenericValueTypeInteger, .value.i = VA_SURFACE_ATTRIB_MEM_TYPE_DRM_PRIME_2 } },
        { .type = VASurfaceAttribExternalBufferDescriptor, .flags = VA_SURFACE_ATTRIB_SETTABLE,
          .value = { .type = VAGenericValueTypePointer, .value.p = &d } },
    };
    VASurfaceID dst;
    CK(vaCreateSurfaces(dpy, VA_RT_FORMAT_YUV420, W, H, &dst, 1, da, 2));
    printf("imported %s %dx%d ystride=%d cstride=%d size=%u\n", mode, W, H, ystride, cstride, d.objects[0].size);

    // Source: driver-allocated P010 with a known pattern.
    int src8 = getenv("SRC8") != NULL;
    VASurfaceAttrib sa = { .type = VASurfaceAttribPixelFormat, .flags = VA_SURFACE_ATTRIB_SETTABLE,
        .value = { .type = VAGenericValueTypeInteger, .value.i = src8 ? VA_FOURCC_NV12 : VA_FOURCC_P010 } };
    VASurfaceID src;
    CK(vaCreateSurfaces(dpy, src8 ? VA_RT_FORMAT_YUV420 : VA_RT_FORMAT_YUV420_10, W, H, &src, 1, &sa, 1));
    VAImage im; void *p;
    CK(vaDeriveImage(dpy, src, &im));
    CK(vaMapBuffer(dpy, im.buf, &p));
    for (int y = 0; y < H; y++) {
        uint16_t *r = (uint16_t *)((char *)p + im.offsets[0] + (size_t)y * im.pitches[0]);
        if (src8) { uint8_t *b = (uint8_t *)r; for (int x = 0; x < W; x++) b[x] = (uint8_t)to8(y10(x, y)); }
        else for (int x = 0; x < W; x++) r[x] = (uint16_t)(y10(x, y) << 6);
    }
    for (int y = 0; y < H / 2; y++) {
        uint16_t *r = (uint16_t *)((char *)p + im.offsets[1] + (size_t)y * im.pitches[1]);
        if (src8) { uint8_t *b = (uint8_t *)r; for (int x = 0; x < W / 2; x++) { b[2 * x] = (uint8_t)to8(u10(x, y)); b[2 * x + 1] = (uint8_t)to8(v10(x, y)); } }
        else for (int x = 0; x < W / 2; x++) { r[2 * x] = (uint16_t)(u10(x, y) << 6); r[2 * x + 1] = (uint16_t)(v10(x, y) << 6); }
    }
    CK(vaUnmapBuffer(dpy, im.buf));
    CK(vaDestroyImage(dpy, im.image_id));

    VAConfigID cfg; VAContextID ctx;
    CK(vaCreateConfig(dpy, VAProfileNone, VAEntrypointVideoProc, NULL, 0, &cfg));
    CK(vaCreateContext(dpy, cfg, W, H, VA_PROGRESSIVE, &dst, 1, &ctx));
    VAProcPipelineParameterBuffer pp;
    memset(&pp, 0, sizeof pp);
    pp.surface = src;
    pp.surface_color_standard = VAProcColorStandardBT709;
    pp.output_color_standard = VAProcColorStandardBT709;
    pp.input_color_properties.color_range = VA_SOURCE_RANGE_REDUCED;
    pp.output_color_properties.color_range = VA_SOURCE_RANGE_REDUCED;
    VARectangle rr = { 0, 0, (uint16_t)W, (uint16_t)H };
    pp.surface_region = &rr; pp.output_region = &rr;

    double t_submit = 0, t_sync = 0, worst = 0;
    for (int i = 0; i < iters; i++) {
        VABufferID pb;
        double t0 = now_ms();
        CK(vaCreateBuffer(dpy, ctx, VAProcPipelineParameterBufferType, sizeof pp, 1, &pp, &pb));
        CK(vaBeginPicture(dpy, ctx, dst));
        CK(vaRenderPicture(dpy, ctx, &pb, 1));
        CK(vaEndPicture(dpy, ctx));
        double t1 = now_ms();
        CK(vaSyncSurface(dpy, dst));
        double t2 = now_ms();
        vaDestroyBuffer(dpy, pb);
        t_submit += t1 - t0; t_sync += t2 - t1;
        if (t2 - t0 > worst) worst = t2 - t0;
    }
    printf("vpp x%d: submit %.3f ms, sync %.3f ms, total %.3f ms, worst %.3f ms\n",
           iters, t_submit / iters, t_sync / iters, (t_submit + t_sync) / iters, worst);

    // Verify through a CPU mapping of the BO itself.
    uint32_t mstride; void *mh = NULL;
    uint8_t *m = gbm_bo_map(bo, 0, 0, ystride, gbm_bo_get_height(bo), GBM_BO_TRANSFER_READ, &mstride, &mh);
    if (!m) { fprintf(stderr, "gbm_bo_map failed\n"); return 1; }
    long bad[3] = {0}, n[3] = {0}, inexact = 0; int peak[3] = {0};
    for (int y = 0; y < H; y++) for (int x = 0; x < W; x++) {
        int e = abs((int)m[(size_t)y * mstride + x] - (int)to8(y10(x, y)));
        if (e) inexact++;
        n[0]++; if (e > 1) bad[0]++; if (e > peak[0]) peak[0] = e;
    }
    for (int y = 0; y < H / 2; y++) for (int x = 0; x < W / 2; x++) {
        int gu, gv;
        if (yv12) { // Y, V, U
            gv = m[ysize + (size_t)y * cstride + x];
            gu = m[ysize + csize + (size_t)y * cstride + x];
        } else {
            gu = m[ysize + (size_t)y * ystride + 2 * x];
            gv = m[ysize + (size_t)y * ystride + 2 * x + 1];
        }
        int eu = abs(gu - (int)to8(u10(x, y))), ev = abs(gv - (int)to8(v10(x, y)));
        n[1]++; n[2]++; if (eu > 1) bad[1]++; if (ev > 1) bad[2]++;
        if (eu > peak[1]) peak[1] = eu; if (ev > peak[2]) peak[2] = ev;
    }
    printf("verify Y bad=%ld/%ld peak=%d | U bad=%ld/%ld peak=%d | V bad=%ld/%ld peak=%d\n",
           bad[0], n[0], peak[0], bad[1], n[1], peak[1], bad[2], n[2], peak[2]);
    printf("Y inexact=%ld\n", inexact);
    printf("sample Y[0..3]=%u %u %u %u expect %u %u %u %u\n", m[0], m[1], m[2], m[3],
           to8(y10(0,0)), to8(y10(1,0)), to8(y10(2,0)), to8(y10(3,0)));
    gbm_bo_unmap(bo, mh);
    int ok = !bad[0] && !bad[1] && !bad[2];
    printf("%s\n", ok ? "PASS" : "FAIL");
    return ok ? 0 : 2;
}
