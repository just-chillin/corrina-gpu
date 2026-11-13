// Verilator wrapper for fxg_gpu: clocking, register access, and a pluggable
// backend that answers the core's DMA requests.
#pragma once
#include <cstdint>
#include "Vfxg_gpu.h"
#include "verilated.h"

struct FxgMemory {
    virtual uint32_t read32(uint64_t addr) = 0;
    virtual void write32(uint64_t addr, uint32_t val) = 0;
    virtual ~FxgMemory() {}
};

class FxgSim {
public:
    explicit FxgSim(FxgMemory *mem) : mem_(mem) {
        top_.clk = 0; top_.rst = 1; top_.s_valid = 0; top_.m_ready = 0;
        for (int i = 0; i < 4; i++) tick();
        top_.rst = 0;
        tick();
    }
    void tick() {
        // The DMA request is combinational on registered state, so it is
        // stable here; answer it and let the next edge consume the answer.
        if (top_.m_valid) {
            if (top_.m_we) mem_->write32(top_.m_addr, top_.m_wdata);
            else top_.m_rdata = mem_->read32(top_.m_addr);
            top_.m_ready = 1;
        } else {
            top_.m_ready = 0;
        }
        top_.clk = 0; top_.eval();
        top_.clk = 1; top_.eval();
        cycles_++;
    }
    void write(uint32_t off, uint32_t val) {
        top_.s_valid = 1; top_.s_we = 1; top_.s_addr = off; top_.s_wdata = val;
        tick();
        top_.s_valid = 0; top_.s_we = 0;
        top_.eval();
    }
    uint32_t read(uint32_t off) {
        top_.s_valid = 1; top_.s_we = 0; top_.s_addr = off;
        top_.eval();
        uint32_t v = top_.s_rdata;
        top_.s_valid = 0;
        return v;
    }
    void write64(uint32_t off, uint64_t v) { write(off, (uint32_t)v); write(off + 4, v >> 32); }
    bool irq() { return top_.irq; }
    bool busy() { return read(0x08) & 1; }
    uint64_t cycles() const { return cycles_; }
private:
    Vfxg_gpu top_;
    FxgMemory *mem_;
    uint64_t cycles_ = 0;
};
