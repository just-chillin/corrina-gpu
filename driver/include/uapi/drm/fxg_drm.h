/* SPDX-License-Identifier: (GPL-2.0 WITH Linux-syscall-note) OR MIT */
/* Userspace API of the fxg DRM render driver (FXG-1 GPU). */
#ifndef __FXG_DRM_H__
#define __FXG_DRM_H__

#include "drm.h"

#if defined(__cplusplus)
extern "C" {
#endif

/* drm_fxg_submit.flags */
#define DRM_FXG_CLEAR_COLOR	0x01
#define DRM_FXG_CLEAR_DEPTH	0x02
#define DRM_FXG_DEPTH_TEST	0x04
#define DRM_FXG_DEPTH_WRITE	0x08
#define DRM_FXG_CULL_BACK	0x10

/* drm_fxg_submit.status */
#define DRM_FXG_STATUS_FAULT	0x2	/* illegal opcode or runaway shader */

/**
 * struct drm_fxg_bo_create - allocate a buffer object
 * @size: in, bytes; rounded up to a page
 * @handle: out, GEM handle
 *
 * Buffer objects are DMA-contiguous and zero-filled.
 */
struct drm_fxg_bo_create {
	__u32 size;
	__u32 handle;
};

/**
 * struct drm_fxg_bo_rw - copy data into or out of a buffer object
 * @handle: GEM handle
 * @offset: byte offset inside the object
 * @data_ptr: userspace buffer
 * @size: bytes to copy
 * @pad: must be zero
 *
 * Used by both BO_WRITE and BO_READ. There is no mmap: the Rust GEM
 * abstraction does not offer one for DMA-contiguous objects yet.
 */
struct drm_fxg_bo_rw {
	__u32 handle;
	__u32 offset;
	__u64 data_ptr;
	__u32 size;
	__u32 pad;
};

/**
 * struct drm_fxg_submit - run one job: optional clears, then a triangle list
 *
 * Blocks until the GPU raises its completion interrupt. A signal aborts the
 * job on the hardware and returns EINTR.
 */
struct drm_fxg_submit {
	__u32 rt_handle;	/* colour target, ARGB8888, width * height words */
	__u32 z_handle;		/* depth target, 24 bits in 32; 0 without depth flags */
	__u32 vtx_handle;	/* vtx_count * vtx_stride words */
	__u32 vs_handle;	/* vertex program */
	__u32 fs_handle;	/* fragment program */
	__u32 tex_handle;	/* ARGB8888, power-of-two sides; 0 for none */
	__u32 uni_handle;	/* uniforms; 0 if uni_count == 0 */
	__u32 width;
	__u32 height;
	__u32 vtx_count;
	__u32 vtx_stride;	/* words per vertex, 1..8 */
	__u32 vs_len;		/* words, 1..256 */
	__u32 fs_len;		/* words, 1..256 */
	__u32 uni_count;	/* words, 0..32 */
	__u32 tex_log2_w;
	__u32 tex_log2_h;
	__u32 flags;		/* DRM_FXG_* */
	__u32 clear_color;
	__u32 clear_depth;
	__u32 status;		/* out */
	__u32 perf_cycles;	/* out: clock cycles the job took */
	__u32 perf_pixels;	/* out: fragments written */
};

#define DRM_FXG_BO_CREATE	0x00
#define DRM_FXG_BO_WRITE	0x01
#define DRM_FXG_BO_READ		0x02
#define DRM_FXG_SUBMIT		0x03

enum {
	DRM_IOCTL_FXG_BO_CREATE	= DRM_IOWR(DRM_COMMAND_BASE + DRM_FXG_BO_CREATE,
					   struct drm_fxg_bo_create),
	DRM_IOCTL_FXG_BO_WRITE	= DRM_IOWR(DRM_COMMAND_BASE + DRM_FXG_BO_WRITE,
					   struct drm_fxg_bo_rw),
	DRM_IOCTL_FXG_BO_READ	= DRM_IOWR(DRM_COMMAND_BASE + DRM_FXG_BO_READ,
					   struct drm_fxg_bo_rw),
	DRM_IOCTL_FXG_SUBMIT	= DRM_IOWR(DRM_COMMAND_BASE + DRM_FXG_SUBMIT,
					   struct drm_fxg_submit),
};

#if defined(__cplusplus)
}
#endif

#endif /* __FXG_DRM_H__ */
