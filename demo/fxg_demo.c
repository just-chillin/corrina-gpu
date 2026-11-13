// Renders the demo cube through the fxg DRM driver and writes a PPM.
//   fxg_demo [out.ppm] [angle]
#include <fcntl.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <unistd.h>

#include "fxg_drm.h"
#include "fxg_scene.h"
#include "fxg_shaders.h"

#define W 320
#define H 240

static int open_fxg(void)
{
	for (int i = 128; i < 136; i++) {
		char path[64], name[32] = "";
		struct drm_version v = { .name = name, .name_len = sizeof(name) - 1 };
		snprintf(path, sizeof(path), "/dev/dri/renderD%d", i);
		int fd = open(path, O_RDWR);
		if (fd < 0)
			continue;
		if (!ioctl(fd, DRM_IOCTL_VERSION, &v) && !strcmp(name, "fxg")) {
			printf("fxg_demo: using %s (driver %s %d.%d)\n", path, name,
			       v.version_major, v.version_minor);
			return fd;
		}
		close(fd);
	}
	return -1;
}

static uint32_t bo_create(int fd, size_t size)
{
	struct drm_fxg_bo_create c = { .size = size };

	if (ioctl(fd, DRM_IOCTL_FXG_BO_CREATE, &c)) { perror("BO_CREATE"); exit(1); }
	return c.handle;
}

static void bo_rw(int fd, unsigned long req, uint32_t handle, const void *data, size_t size)
{
	struct drm_fxg_bo_rw rw = { .handle = handle, .data_ptr = (uintptr_t)data, .size = size };

	if (ioctl(fd, req, &rw)) { perror(req == DRM_IOCTL_FXG_BO_WRITE ? "BO_WRITE" : "BO_READ"); exit(1); }
}

/* Create a buffer object holding a copy of @data. */
static uint32_t bo_from(int fd, const void *data, size_t size)
{
	uint32_t handle = bo_create(fd, size);

	bo_rw(fd, DRM_IOCTL_FXG_BO_WRITE, handle, data, size);
	return handle;
}

int main(int argc, char **argv)
{
	const char *out = argc > 1 ? argv[1] : "frame.ppm";
	float angle = argc > 2 ? atof(argv[2]) : 0.9f;
	int fd = open_fxg();

	if (fd < 0) { fprintf(stderr, "fxg_demo: no fxg render node\n"); return 1; }

	static uint32_t vtx[FXG_SCENE_VERTS * FXG_SCENE_STRIDE], uni[32], tex[64 * 64], frame[W * H];

	fxg_scene_build(angle, (float)W / H, vtx, uni, tex);

	uint32_t rt = bo_create(fd, sizeof(frame));
	struct drm_fxg_submit s = {
		.rt_handle = rt,
		.z_handle = bo_create(fd, sizeof(frame)),
		.vtx_handle = bo_from(fd, vtx, sizeof(vtx)),
		.vs_handle = bo_from(fd, fxg_cube_vs, sizeof(fxg_cube_vs)),
		.fs_handle = bo_from(fd, fxg_cube_fs, sizeof(fxg_cube_fs)),
		.tex_handle = bo_from(fd, tex, sizeof(tex)),
		.uni_handle = bo_from(fd, uni, sizeof(uni)),
		.width = W, .height = H,
		.vtx_count = FXG_SCENE_VERTS, .vtx_stride = FXG_SCENE_STRIDE,
		.vs_len = sizeof(fxg_cube_vs) / 4, .fs_len = sizeof(fxg_cube_fs) / 4,
		.uni_count = 32, .tex_log2_w = FXG_SCENE_TEX_LOG2, .tex_log2_h = FXG_SCENE_TEX_LOG2,
		.flags = DRM_FXG_CLEAR_COLOR | DRM_FXG_CLEAR_DEPTH | DRM_FXG_DEPTH_TEST |
			 DRM_FXG_DEPTH_WRITE | DRM_FXG_CULL_BACK,
		.clear_color = 0xff101828, .clear_depth = 0x00ffffff,
	};
	if (ioctl(fd, DRM_IOCTL_FXG_SUBMIT, &s)) { perror("SUBMIT"); return 1; }
	bo_rw(fd, DRM_IOCTL_FXG_BO_READ, rt, frame, sizeof(frame));

	uint32_t hash = 2166136261u;   /* FNV-1a, same as the RTL testbench prints */
	const uint8_t *px = (const uint8_t *)frame;
	for (int i = 0; i < W * H * 4; i++)
		hash = (hash ^ px[i]) * 16777619u;
	printf("fxg_demo: status=%u cycles=%u pixels=%u\nframe hash %08x\n",
	       s.status, s.perf_cycles, s.perf_pixels, hash);

	/* The GPU trusts its registers, so the driver must refuse a job whose
	 * target is larger than the buffer behind it. */
	struct drm_fxg_submit bad = s;
	bad.width = bad.height = 2048;
	int r = ioctl(fd, DRM_IOCTL_FXG_SUBMIT, &bad);
	printf("fxg_demo: oversized job %s\n", r < 0 ? "rejected" : "ACCEPTED (driver bug)");
	if (r == 0)
		return 1;

	FILE *f = fopen(out, "wb");
	if (!f) { perror(out); return 1; }
	fprintf(f, "P6\n%d %d\n255\n", W, H);
	for (int i = 0; i < W * H; i++) {
		fputc(frame[i] >> 16, f); fputc(frame[i] >> 8, f); fputc(frame[i], f);
	}
	fclose(f);
	return s.status & DRM_FXG_STATUS_FAULT ? 1 : 0;
}
