// SPDX-License-Identifier: GPL-2.0

//! Ioctls.
//!
//! FXG-1 reads and writes wherever its registers point. Nothing but the checks in
//! [`File::submit`] stands between a job and arbitrary kernel memory, so every size a job
//! implies is compared against the buffer object that backs it before the hardware is touched.

use kernel::{
    drm::{
        self,
        gem::{
            self,
            BaseObject, //
        },
        Registered, //
    },
    io::Io,
    prelude::*,
    sync::{
        aref::ARef,
        Arc, //
    },
    uaccess::UserSlice,
    uapi, //
};

use crate::{
    driver::{
        FxgDevice,
        FxgDriver,
        Hw,
        JobEnd, //
    },
    gem::FxgBo,
    regs, //
};

type Bo = ARef<gem::Object<FxgBo>>;

pub(crate) struct File;

impl drm::file::DriverFile for File {
    type Driver = FxgDriver;

    fn open(_dev: &FxgDevice) -> Result<Pin<KBox<Self>>> {
        Ok(KBox::new(Self, GFP_KERNEL)?.into())
    }
}

/// Looks up `handle` and requires the object to hold at least `words` 32-bit words.
fn job_bo(file: &drm::File<File>, handle: u32, words: u64) -> Result<Bo> {
    let bo = FxgBo::lookup(file, handle)?;

    if words.checked_mul(4).ok_or(EINVAL)? > bo.size() as u64 {
        return Err(EINVAL);
    }
    Ok(bo)
}

/// Validates the byte range of a `drm_fxg_bo_rw` against its object.
fn rw_range(bo: &gem::Object<FxgBo>, req: &uapi::drm_fxg_bo_rw) -> Result<core::ops::Range<usize>> {
    if req.pad != 0 {
        return Err(EINVAL);
    }
    let start = req.offset as usize;
    let end = start.checked_add(req.size as usize).ok_or(EINVAL)?;
    if end > bo.mem.size() {
        return Err(EINVAL);
    }
    Ok(start..end)
}

impl File {
    /// IOCTL: bo_create: allocate a buffer object.
    pub(crate) fn bo_create(
        dev: &FxgDevice<Registered>,
        _hw: &Arc<Hw<'_>>,
        req: &mut uapi::drm_fxg_bo_create,
        file: &drm::File<File>,
    ) -> Result<u32> {
        let bo = FxgBo::new(dev, req.size as usize)?;

        req.handle = bo.create_handle(file)?;
        Ok(0)
    }

    /// IOCTL: bo_write: copy from userspace into a buffer object.
    pub(crate) fn bo_write(
        _dev: &FxgDevice<Registered>,
        hw: &Arc<Hw<'_>>,
        req: &mut uapi::drm_fxg_bo_rw,
        file: &drm::File<File>,
    ) -> Result<u32> {
        let bo = FxgBo::lookup(file, req.handle)?;
        let range = rw_range(&bo, req)?;
        let mut reader =
            UserSlice::new(UserPtr::from_addr(req.data_ptr as usize), range.len()).reader();

        let _job = hw.job.lock();
        // SAFETY: `job` is held, so no job is running: the device is not accessing the buffer,
        // and neither is any other bo_write/bo_read.
        let mem = unsafe { bo.mem.as_mut() };
        reader.read_slice(&mut mem[range])?;
        Ok(0)
    }

    /// IOCTL: bo_read: copy from a buffer object to userspace.
    pub(crate) fn bo_read(
        _dev: &FxgDevice<Registered>,
        hw: &Arc<Hw<'_>>,
        req: &mut uapi::drm_fxg_bo_rw,
        file: &drm::File<File>,
    ) -> Result<u32> {
        let bo = FxgBo::lookup(file, req.handle)?;
        let range = rw_range(&bo, req)?;
        let mut writer =
            UserSlice::new(UserPtr::from_addr(req.data_ptr as usize), range.len()).writer();

        let _job = hw.job.lock();
        // SAFETY: `job` is held, so no job is running: the device is not accessing the buffer,
        // and no bo_write is modifying it.
        let mem = unsafe { bo.mem.as_ref() };
        writer.write_slice(&mem[range])?;
        Ok(0)
    }

    /// IOCTL: submit: run one job and wait for it.
    pub(crate) fn submit(
        _dev: &FxgDevice<Registered>,
        hw: &Arc<Hw<'_>>,
        req: &mut uapi::drm_fxg_submit,
        file: &drm::File<File>,
    ) -> Result<u32> {
        const DEPTH_FLAGS: u32 =
            uapi::DRM_FXG_CLEAR_DEPTH | uapi::DRM_FXG_DEPTH_TEST | uapi::DRM_FXG_DEPTH_WRITE;
        const ALL_FLAGS: u32 = DEPTH_FLAGS | uapi::DRM_FXG_CLEAR_COLOR | uapi::DRM_FXG_CULL_BACK;

        if req.width == 0
            || req.width > regs::MAX_DIM
            || req.height == 0
            || req.height > regs::MAX_DIM
            || req.vtx_stride == 0
            || req.vtx_stride > regs::MAX_STRIDE
            || req.vs_len == 0
            || req.vs_len > regs::MAX_PROG_WORDS
            || req.fs_len == 0
            || req.fs_len > regs::MAX_PROG_WORDS
            || req.uni_count > regs::MAX_UNIFORMS
            || req.tex_log2_w > regs::MAX_TEX_LOG2
            || req.tex_log2_h > regs::MAX_TEX_LOG2
            || req.flags & !ALL_FLAGS != 0
            || (req.flags & DEPTH_FLAGS != 0 && req.z_handle == 0)
            || (req.uni_count != 0 && req.uni_handle == 0)
        {
            return Err(EINVAL);
        }

        // The references taken here keep every buffer alive until the hardware is done with it.
        let pixels = u64::from(req.width) * u64::from(req.height);
        let rt = job_bo(file, req.rt_handle, pixels)?;
        let z = match req.z_handle {
            0 => None,
            h => Some(job_bo(file, h, pixels)?),
        };
        let vtx = job_bo(
            file,
            req.vtx_handle,
            u64::from(req.vtx_count) * u64::from(req.vtx_stride),
        )?;
        let vs = job_bo(file, req.vs_handle, req.vs_len.into())?;
        let fs = job_bo(file, req.fs_handle, req.fs_len.into())?;
        let tex = match req.tex_handle {
            0 => None,
            h => Some(job_bo(file, h, 1u64 << (req.tex_log2_w + req.tex_log2_h))?),
        };
        let uni = match req.uni_handle {
            0 => None,
            h => Some(job_bo(file, h, req.uni_count.into())?),
        };

        let addr = |bo: &Option<Bo>| bo.as_ref().map_or(0, |bo| bo.mem.dma_address());
        let bar = &hw.bar;

        let _job = hw.job.lock();

        hw.write64(rt.mem.dma_address(), regs::RT_ADDR)?;
        // Without depth flags the core never dereferences Z_ADDR.
        hw.write64(addr(&z), regs::Z_ADDR)?;
        bar.write32(req.width | req.height << 16, regs::RT_DIM);
        hw.write64(vtx.mem.dma_address(), regs::VTX_ADDR)?;
        bar.write32(req.vtx_count, regs::VTX_COUNT);
        bar.write32(req.vtx_stride, regs::VTX_STRIDE);
        hw.write64(vs.mem.dma_address(), regs::VS_ADDR)?;
        bar.write32(req.vs_len, regs::VS_LEN);
        hw.write64(fs.mem.dma_address(), regs::FS_ADDR)?;
        bar.write32(req.fs_len, regs::FS_LEN);
        match &tex {
            Some(tex) => {
                hw.write64(tex.mem.dma_address(), regs::TEX_ADDR)?;
                bar.write32(req.tex_log2_w | req.tex_log2_h << 8, regs::TEX_DIM);
            }
            None => {
                // A shader can execute TEX whether or not a texture is bound. Aim the sampler
                // at a 1x1 "texture" inside a buffer the job already owns, so that it cannot
                // read anything else.
                hw.write64(vs.mem.dma_address(), regs::TEX_ADDR)?;
                bar.write32(0, regs::TEX_DIM);
            }
        }
        hw.write64(addr(&uni), regs::UNI_ADDR)?;
        bar.write32(req.uni_count, regs::UNI_COUNT);
        bar.write32(req.flags, regs::FLAGS);
        bar.write32(req.clear_color, regs::CLEAR_COLOR);
        bar.write32(req.clear_depth & regs::DEPTH_MAX, regs::CLEAR_DEPTH);

        match hw.run() {
            JobEnd::Done => {
                req.status = bar.read32(regs::STATUS);
                req.perf_cycles = bar.read32(regs::PERF_CYCLES);
                req.perf_pixels = bar.read32(regs::PERF_PIXELS);
                Ok(0)
            }
            // In both cases the hardware must be stopped before the buffers are released.
            JobEnd::Timeout => {
                pr_err!("fxg: job timed out, resetting the GPU\n");
                hw.reset();
                Err(ETIMEDOUT)
            }
            JobEnd::Signal => {
                hw.reset();
                Err(EINTR)
            }
        }
    }
}
