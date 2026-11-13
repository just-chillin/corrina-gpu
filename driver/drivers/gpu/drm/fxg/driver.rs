// SPDX-License-Identifier: GPL-2.0

use kernel::{
    device::{
        Bound,
        Core,
        DeviceContext, //
    },
    dma::{
        Device as _,
        DmaMask, //
    },
    drm::{
        self,
        gem,
        ioctl, //
    },
    io::Io,
    irq::{
        self,
        IrqRequest,
        IrqReturn,
        ThreadedIrqReturn, //
    },
    new_condvar,
    new_mutex,
    pci,
    prelude::*,
    sync::{
        aref::ARef,
        Arc,
        CondVar,
        Mutex, //
    },
    time::{
        msecs_to_jiffies,
        Jiffies, //
    },
};

use crate::{
    file::File,
    gem::FxgBo,
    regs, //
};

pub(crate) struct FxgDriver;

/// Convenience alias for the DRM device type of this driver.
pub(crate) type FxgDevice<Ctx = drm::Normal> = drm::Device<FxgDriver, Ctx>;

pub(crate) type Bar0<'bound> = pci::Bar<'bound, { regs::BAR_SIZE }>;

/// How long a job may run. Generous, because the "hardware" may be an RTL simulation.
const JOB_TIMEOUT_MS: u32 = 120_000;

/// How a wait for the hardware ended.
pub(crate) enum JobEnd {
    Done,
    Timeout,
    Signal,
}

/// The hardware, shared between ioctl context and the interrupt handler.
#[pin_data]
pub(crate) struct Hw<'bound> {
    pub(crate) bar: Bar0<'bound>,
    /// Held for the whole of a job: the hardware runs one at a time. Because the device only
    /// ever touches buffer objects while a job runs, holding this lock is also what makes CPU
    /// access to their memory exclusive.
    #[pin]
    pub(crate) job: Mutex<()>,
    /// Set by the interrupt thread when the hardware reports completion.
    #[pin]
    done: Mutex<bool>,
    #[pin]
    done_cv: CondVar,
}

impl Hw<'_> {
    pub(crate) fn write64(&self, value: u64, offset: usize) -> Result {
        self.bar.try_write32(value as u32, offset)?;
        self.bar.try_write32((value >> 32) as u32, offset + 4)
    }

    /// Aborts whatever the hardware is doing and re-arms its interrupt.
    pub(crate) fn reset(&self) {
        self.bar.write32(regs::CTRL_RESET, regs::CTRL);
        self.bar.write32(1, regs::IRQ_ENABLE);
    }

    /// Starts the programmed job and sleeps until its interrupt arrives.
    ///
    /// The caller must hold [`Hw::job`].
    pub(crate) fn run(&self) -> JobEnd {
        let mut done = self.done.lock();
        *done = false;
        self.bar.write32(regs::CTRL_START, regs::CTRL);

        let mut left: Jiffies = msecs_to_jiffies(JOB_TIMEOUT_MS);
        while !*done {
            use kernel::sync::CondVarTimeoutResult::*;

            match self.done_cv.wait_interruptible_timeout(&mut done, left) {
                Woken { jiffies } => left = jiffies,
                Timeout => return JobEnd::Timeout,
                Signal { .. } => return JobEnd::Signal,
            }
        }
        JobEnd::Done
    }
}

/// Interrupt handler. The hard half acknowledges the device; the threaded half may take the
/// mutex that the waiter sleeps on, so a completion can never be missed.
struct IrqHandler<'bound> {
    hw: Arc<Hw<'bound>>,
}

impl irq::ThreadedHandler for IrqHandler<'_> {
    fn handle(&self) -> ThreadedIrqReturn {
        if self.hw.bar.read32(regs::IRQ_STATUS) & 1 == 0 {
            return ThreadedIrqReturn::None;
        }
        self.hw.bar.write32(1, regs::IRQ_STATUS);
        ThreadedIrqReturn::WakeThread
    }

    fn handle_threaded(&self) -> IrqReturn {
        *self.hw.done.lock() = true;
        self.hw.done_cv.notify_all();
        IrqReturn::Handled
    }
}

/// Per-device driver data. Fields drop in declaration order on unbind: userspace is cut off
/// first, then the interrupt, then its vector, then the hardware state.
pub(crate) struct Fxg<'bound> {
    _reg: drm::Registration<'bound, FxgDriver>,
    _irq: Pin<KBox<irq::ThreadedRegistration<'bound, IrqHandler<'bound>>>>,
    _vectors: Pin<KBox<pci::IrqVectorRegistration<'bound>>>,
    hw: Arc<Hw<'bound>>,
    #[expect(unused)]
    drm: ARef<FxgDevice>,
}

const INFO: drm::DriverInfo = drm::DriverInfo {
    major: 1,
    minor: 0,
    patchlevel: 0,
    name: c"fxg",
    desc: c"FXG-1 GPU",
};

kernel::pci_device_table!(
    PCI_TABLE,
    <FxgDriver as pci::Driver>::IdInfo,
    [(pci::DeviceId::from_id(pci::Vendor::REDHAT, 0x4658), ())]
);

impl pci::Driver for FxgDriver {
    type IdInfo = ();
    type Data<'bound> = Fxg<'bound>;

    const ID_TABLE: pci::IdTable<Self::IdInfo> = &PCI_TABLE;

    fn probe<'bound>(
        pdev: &'bound pci::Device<Core<'_>>,
        _info: Option<&'bound Self::IdInfo>,
    ) -> impl PinInit<Self::Data<'bound>, Error> + 'bound {
        pdev.enable_device_mem()?;
        pdev.set_master();

        // SAFETY: Nothing allocates or maps DMA memory for this device before probe returns.
        unsafe { pdev.dma_set_mask_and_coherent(DmaMask::new::<64>())? };

        let bar: Bar0<'bound> = pdev.iomap_region_sized::<{ regs::BAR_SIZE }>(0, c"fxg")?;
        if bar.read32(regs::ID) != regs::ID_VALUE {
            dev_err!(pdev, "unexpected ID register\n");
            return Err(ENODEV);
        }

        let hw = Arc::pin_init(
            try_pin_init!(Hw {
                bar,
                job <- new_mutex!(()),
                done <- new_mutex!(false),
                done_cv <- new_condvar!(),
            }),
            GFP_KERNEL,
        )?;
        hw.bar.write32(regs::CTRL_RESET, regs::CTRL);

        let bound: &'bound pci::Device<Bound> = pdev;
        let vectors = KBox::pin(bound.alloc_irq_vectors(1, 1, pci::IrqTypes::all())?, GFP_KERNEL)?;
        // SAFETY: The vector allocation is heap-pinned and stored in `Fxg` after the interrupt
        // registration that borrows it, so it is dropped later and this reference stays valid
        // for as long as that registration exists.
        let vectors_ref: &'bound pci::IrqVectorRegistration<'bound> =
            unsafe { &*core::ptr::from_ref(&*vectors) };
        let request: IrqRequest<'bound> = vectors_ref.index(0)?.into();

        // SAFETY: The registration is stored in `Fxg` and dropped on unbind; never forgotten.
        let irq = KBox::pin_init(
            unsafe {
                irq::ThreadedRegistration::new(
                    request,
                    irq::Flags::SHARED,
                    c"fxg",
                    Ok(IrqHandler { hw: hw.clone() }),
                )
            },
            GFP_KERNEL,
        )?;
        hw.bar.write32(1, regs::IRQ_ENABLE);

        let drm = drm::UnregisteredDevice::<Self>::new(bound, Ok(()))?;
        // SAFETY: `reg` is stored in `Fxg` and dropped when the driver is unbound; it is never
        // forgotten.
        let reg = unsafe { drm::Registration::new(bound.as_ref(), drm, hw.clone(), 0)? };

        dev_info!(pdev, "FXG-1 GPU ready\n");

        Ok(Fxg {
            drm: reg.device().into(),
            _reg: reg,
            _irq: irq,
            _vectors: vectors,
            hw,
        })
    }

    fn unbind<'bound>(_pdev: &'bound pci::Device<Core<'_>>, this: Pin<&Self::Data<'bound>>) {
        // Let a job in flight finish, then silence the hardware.
        let _job = this.hw.job.lock();
        this.hw.bar.write32(regs::CTRL_RESET, regs::CTRL);
    }
}

#[vtable]
impl drm::Driver for FxgDriver {
    type Data = ();
    type RegistrationData<'a> = Arc<Hw<'a>>;
    type File = File;
    type Object = gem::Object<FxgBo>;
    type ParentDevice<Ctx: DeviceContext> = pci::Device<Ctx>;

    const INFO: drm::DriverInfo = INFO;
    const FEAT_RENDER: bool = true;

    kernel::declare_drm_ioctls! {
        (FXG_BO_CREATE, drm_fxg_bo_create, ioctl::RENDER_ALLOW, File::bo_create),
        (FXG_BO_WRITE, drm_fxg_bo_rw, ioctl::RENDER_ALLOW, File::bo_write),
        (FXG_BO_READ, drm_fxg_bo_rw, ioctl::RENDER_ALLOW, File::bo_read),
        (FXG_SUBMIT, drm_fxg_submit, ioctl::RENDER_ALLOW, File::submit),
    }
}
