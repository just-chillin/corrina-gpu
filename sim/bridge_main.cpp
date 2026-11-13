// Co-simulation bridge: the Verilated GPU on one side, QEMU's "fxg" PCIe
// device on the other (see qemu/fxg.c and qemu/fxg_proto.h).
//
//   fxg_bridge /tmp/fxg.sock     # start this first, then QEMU
//
// DMA goes through a 4 KiB page cache: pages are fetched from guest memory
// on first touch and written back when the job finishes, before the reply
// that carries the interrupt. That keeps the socket traffic per job to a few
// hundred messages instead of one per pixel.
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <unordered_map>
#include <sys/socket.h>
#include <sys/un.h>
#include <unistd.h>
#include "fxg_sim.h"
#include "fxg_proto.h"

static int g_fd = -1;

static void xio(void *buf, size_t len, bool wr) {
    uint8_t *p = (uint8_t *)buf;
    while (len) {
        ssize_t n = wr ? write(g_fd, p, len) : read(g_fd, p, len);
        if (n <= 0) { fprintf(stderr, "fxg_bridge: QEMU went away\n"); exit(0); }
        p += n; len -= n;
    }
}

struct GuestMem : FxgMemory {
    struct Page { uint8_t d[4096]; bool dirty; };
    std::unordered_map<uint64_t, Page> pages;
    uint64_t fetched = 0, flushed = 0;

    Page &page(uint64_t pn) {
        auto it = pages.find(pn);
        if (it != pages.end()) return it->second;
        Page &pg = pages[pn];
        fxg_msg m = { FXG_DMA_READ, 4096, pn << 12, 0 };
        xio(&m, sizeof(m), true);
        xio(&m, sizeof(m), false);              // FXG_DMA_DATA
        xio(pg.d, 4096, false);
        pg.dirty = false;
        fetched++;
        return pg;
    }
    uint32_t read32(uint64_t a) override {
        uint32_t v;
        memcpy(&v, page(a >> 12).d + (a & 0xffc), 4);
        return v;
    }
    void write32(uint64_t a, uint32_t v) override {
        Page &pg = page(a >> 12);
        memcpy(pg.d + (a & 0xffc), &v, 4);
        pg.dirty = true;
    }
    void flush() {
        for (auto &kv : pages) {
            if (!kv.second.dirty) continue;
            fxg_msg m = { FXG_DMA_WRITE, 4096, kv.first << 12, 0 };
            xio(&m, sizeof(m), true);
            xio(kv.second.d, 4096, true);
            flushed++;
        }
        pages.clear();
    }
};

int main(int argc, char **argv) {
    Verilated::commandArgs(argc, argv);
    const char *path = argc > 1 ? argv[1] : "/tmp/fxg.sock";
    sockaddr_un sa = {};
    sa.sun_family = AF_UNIX;
    snprintf(sa.sun_path, sizeof(sa.sun_path), "%s", path);
    unlink(path);
    int ls = socket(AF_UNIX, SOCK_STREAM, 0);
    if (bind(ls, (sockaddr *)&sa, sizeof(sa)) < 0 || listen(ls, 1) < 0) { perror("bind"); return 1; }
    fprintf(stderr, "fxg_bridge: waiting for QEMU on %s\n", path);
    g_fd = accept(ls, nullptr, nullptr);
    if (g_fd < 0) { perror("accept"); return 1; }
    fprintf(stderr, "fxg_bridge: connected\n");

    GuestMem mem;
    FxgSim sim(&mem);
    bool was_busy = false;

    for (;;) {
        fxg_msg m;
        uint64_t val = 0;
        xio(&m, sizeof(m), false);
        switch (m.type) {
        case FXG_MMIO_READ:  val = sim.read(m.addr); break;
        case FXG_MMIO_WRITE: sim.write(m.addr, (uint32_t)m.data); break;
        case FXG_TICK:
            for (int i = 0; i < 4000 && sim.busy(); i++)
                for (int j = 0; j < 64; j++) sim.tick();
            break;
        }
        bool busy = sim.busy();
        if (!busy) {
            mem.flush();
            if (was_busy)
                fprintf(stderr, "fxg_bridge: job done at cycle %llu, %llu pages in, %llu pages out\n",
                        (unsigned long long)sim.cycles(), (unsigned long long)mem.fetched,
                        (unsigned long long)mem.flushed);
        }
        was_busy = busy;
        fxg_msg r = { FXG_REPLY, 0, (sim.irq() ? FXG_FLAG_IRQ : 0u) | (busy ? FXG_FLAG_BUSY : 0u), val };
        xio(&r, sizeof(r), true);
    }
}
