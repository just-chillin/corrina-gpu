// SPDX-License-Identifier: GPL-2.0

//! Buffer objects: a GEM object wrapping one DMA-contiguous allocation.

use kernel::{
    device::Bound,
    dma::Coherent,
    drm::{
        self,
        gem, //
    },
    page,
    pci,
    prelude::*,
    sizes::SZ_64M,
    sync::aref::ARef, //
};

use crate::{
    driver::{
        FxgDevice,
        FxgDriver, //
    },
    file::File,
};

/// Driver data of a buffer object.
#[pin_data]
pub(crate) struct FxgBo {
    /// The backing memory. The device reads and writes it by bus address while a job runs; the
    /// CPU touches it only with [`Hw::job`](crate::driver::Hw) held.
    pub(crate) mem: Coherent<[u8]>,
}

impl gem::DriverObject for FxgBo {
    type Driver = FxgDriver;
    type Args = Coherent<[u8]>;

    fn new(
        _dev: &drm::Device<FxgDriver>,
        _size: usize,
        mem: Self::Args,
    ) -> impl PinInit<Self, Error> {
        try_pin_init!(FxgBo { mem })
    }
}

impl FxgBo {
    /// Allocates a zero-filled buffer object of at least `size` bytes.
    pub(crate) fn new(
        dev: &FxgDevice<drm::Registered>,
        size: usize,
    ) -> Result<ARef<gem::Object<Self>>> {
        if size == 0 || size > SZ_64M {
            return Err(EINVAL);
        }
        let size = page::page_align(size).ok_or(EINVAL)?;

        let pdev: &pci::Device<Bound> = dev.as_ref();
        let mem = Coherent::<u8>::zeroed_slice(pdev.as_ref(), size, GFP_KERNEL)?;

        gem::Object::<Self>::new(dev, size, mem)
    }

    /// Looks up a handle of `file`.
    pub(crate) fn lookup(file: &drm::File<File>, handle: u32) -> Result<ARef<gem::Object<Self>>> {
        use gem::BaseObject;

        gem::Object::lookup_handle(file, handle)
    }
}
