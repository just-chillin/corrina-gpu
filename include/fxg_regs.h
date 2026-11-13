/* SPDX-License-Identifier: GPL-2.0 OR MIT */
/* FXG-1 register map (BAR0). Shared by the RTL testbench, the bridge and the
 * kernel driver. Keep in sync with rtl/fxg_gpu.v. */
#ifndef FXG_REGS_H
#define FXG_REGS_H

#define FXG_PCI_VENDOR      0x1b36  /* Red Hat/QEMU; a real device needs its own */
#define FXG_PCI_DEVICE      0x4658
#define FXG_ID_VALUE        0x46584731  /* "FXG1" */

#define FXG_REG_ID          0x00
#define FXG_REG_CTRL        0x04
#define   FXG_CTRL_START      0x1
#define   FXG_CTRL_RESET      0x2   /* abort; also clears IRQ_ENABLE */
#define FXG_REG_STATUS      0x08
#define   FXG_STATUS_BUSY     0x1
#define   FXG_STATUS_FAULT    0x2   /* illegal opcode or runaway shader */
#define FXG_REG_IRQ_STATUS  0x0c    /* write 1 to clear */
#define FXG_REG_IRQ_ENABLE  0x10
#define FXG_REG_RT_ADDR     0x14    /* lo, hi */
#define FXG_REG_Z_ADDR      0x1c
#define FXG_REG_RT_DIM      0x24    /* width | height << 16 */
#define FXG_REG_VTX_ADDR    0x28
#define FXG_REG_VTX_COUNT   0x30
#define FXG_REG_VTX_STRIDE  0x34    /* 32-bit words per vertex, 1..8 */
#define FXG_REG_VS_ADDR     0x38
#define FXG_REG_VS_LEN      0x40    /* words, <= 256 */
#define FXG_REG_FS_ADDR     0x44
#define FXG_REG_FS_LEN      0x4c
#define FXG_REG_TEX_ADDR    0x50
#define FXG_REG_TEX_DIM     0x58    /* log2(width) | log2(height) << 8 */
#define FXG_REG_UNI_ADDR    0x5c
#define FXG_REG_UNI_COUNT   0x64    /* words, <= 32 */
#define FXG_REG_FLAGS       0x68
#define FXG_REG_CLEAR_COLOR 0x6c
#define FXG_REG_CLEAR_DEPTH 0x70
#define FXG_REG_PERF_CYCLES 0x74
#define FXG_REG_PERF_PIXELS 0x78

#define FXG_FLAG_CLEAR_COLOR 0x01
#define FXG_FLAG_CLEAR_DEPTH 0x02
#define FXG_FLAG_DEPTH_TEST  0x04
#define FXG_FLAG_DEPTH_WRITE 0x08
#define FXG_FLAG_CULL_BACK   0x10

#define FXG_MAX_DIM          2048
#define FXG_MAX_PROG_WORDS   256
#define FXG_MAX_UNIFORMS     32
#define FXG_MAX_STRIDE       8
#define FXG_DEPTH_MAX        0x00ffffff

#endif
