// SPDX-License-Identifier: GPL-2.0

//! FXG-1 register map (BAR0). Mirrors `include/fxg_regs.h` and `rtl/fxg_gpu.v`.

pub(crate) const BAR_SIZE: usize = 0x80;

pub(crate) const ID: usize = 0x00;
pub(crate) const ID_VALUE: u32 = 0x4658_4731; // "FXG1"
pub(crate) const CTRL: usize = 0x04;
pub(crate) const CTRL_START: u32 = 0x1;
/// Aborts the running job. Also clears `IRQ_ENABLE`.
pub(crate) const CTRL_RESET: u32 = 0x2;
pub(crate) const STATUS: usize = 0x08;
pub(crate) const IRQ_STATUS: usize = 0x0c;
pub(crate) const IRQ_ENABLE: usize = 0x10;
pub(crate) const RT_ADDR: usize = 0x14;
pub(crate) const Z_ADDR: usize = 0x1c;
pub(crate) const RT_DIM: usize = 0x24;
pub(crate) const VTX_ADDR: usize = 0x28;
pub(crate) const VTX_COUNT: usize = 0x30;
pub(crate) const VTX_STRIDE: usize = 0x34;
pub(crate) const VS_ADDR: usize = 0x38;
pub(crate) const VS_LEN: usize = 0x40;
pub(crate) const FS_ADDR: usize = 0x44;
pub(crate) const FS_LEN: usize = 0x4c;
pub(crate) const TEX_ADDR: usize = 0x50;
pub(crate) const TEX_DIM: usize = 0x58;
pub(crate) const UNI_ADDR: usize = 0x5c;
pub(crate) const UNI_COUNT: usize = 0x64;
pub(crate) const FLAGS: usize = 0x68;
pub(crate) const CLEAR_COLOR: usize = 0x6c;
pub(crate) const CLEAR_DEPTH: usize = 0x70;
pub(crate) const PERF_CYCLES: usize = 0x74;
pub(crate) const PERF_PIXELS: usize = 0x78;

pub(crate) const MAX_DIM: u32 = 2048;
pub(crate) const MAX_PROG_WORDS: u32 = 256;
pub(crate) const MAX_UNIFORMS: u32 = 32;
pub(crate) const MAX_STRIDE: u32 = 8;
pub(crate) const MAX_TEX_LOG2: u32 = 11;
pub(crate) const DEPTH_MAX: u32 = 0x00ff_ffff;
