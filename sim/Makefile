# make tb      -> obj/fxg_tb      standalone RTL testbench (writes a PPM)
# make bridge  -> obj/fxg_bridge  co-simulation endpoint for the QEMU device
RTL   := ../rtl/fxg_gpu.v ../rtl/fxg_shader.v ../rtl/fxg_div.v
VFLAGS := -Wall -Wno-UNUSEDSIGNAL -Wno-DECLFILENAME -Wno-PINCONNECTEMPTY \
          -Wno-WIDTHEXPAND -Wno-BLKSEQ --top-module fxg_gpu -O3 \
          -CFLAGS "-O2 -I../../include -I../../qemu -I.."
SHADERS := fxg_cube_vs=../shaders/cube.vs.s fxg_cube_fs=../shaders/cube.fs.s

all: tb bridge

fxg_shaders.h: ../shaders/cube.vs.s ../shaders/cube.fs.s ../tools/fxgasm.py
	python3 ../tools/fxgasm.py $(SHADERS) -o $@

tb: fxg_shaders.h
	verilator --cc --exe --build $(VFLAGS) --Mdir obj_tb -o fxg_tb $(RTL) tb_main.cpp
bridge:
	verilator --cc --exe --build $(VFLAGS) --Mdir obj_bridge -o fxg_bridge $(RTL) bridge_main.cpp
clean:
	rm -rf obj_tb obj_bridge fxg_shaders.h
.PHONY: all tb bridge clean
