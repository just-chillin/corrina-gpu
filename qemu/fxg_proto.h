/* Wire protocol between the QEMU PCIe device model and the Verilator bridge.
 * Everything is synchronous from QEMU's point of view: it sends one request
 * and services DMA messages until the matching FXG_REPLY arrives. */
#ifndef FXG_PROTO_H
#define FXG_PROTO_H
#include <stdint.h>

struct fxg_msg {
    uint32_t type;
    uint32_t len;   /* payload bytes following this header */
    uint64_t addr;  /* MMIO offset, DMA address, or reply flags */
    uint64_t data;  /* MMIO write value / read result */
};

enum {
    FXG_MMIO_READ  = 1, /* qemu -> sim */
    FXG_MMIO_WRITE = 2, /* qemu -> sim */
    FXG_TICK       = 3, /* qemu -> sim: run the clock for a while */
    FXG_REPLY      = 4, /* sim -> qemu: addr = flags, data = read value */
    FXG_DMA_READ   = 5, /* sim -> qemu: wants len bytes at addr */
    FXG_DMA_WRITE  = 6, /* sim -> qemu: len payload bytes for addr */
    FXG_DMA_DATA   = 7, /* qemu -> sim: answer to FXG_DMA_READ */
};

#define FXG_FLAG_IRQ  1u
#define FXG_FLAG_BUSY 2u
#endif
