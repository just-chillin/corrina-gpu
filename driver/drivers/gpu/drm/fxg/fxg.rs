// SPDX-License-Identifier: GPL-2.0

//! DRM render driver for the FXG-1 GPU.
//!
//! Render-only (no KMS), in the style of v3d or panfrost: it exposes
//! `/dev/dri/renderD*`, hands out GEM buffer objects and runs jobs on the
//! hardware. FXG-1 has no MMU, so buffer objects are DMA-contiguous and the
//! device is given their bus addresses directly.

mod driver;
mod file;
mod gem;
mod regs;

kernel::module_pci_driver! {
    type: driver::FxgDriver,
    name: "fxg",
    authors: ["corrina-gpu authors"],
    description: "FXG-1 GPU DRM render driver",
    license: "GPL v2",
}
