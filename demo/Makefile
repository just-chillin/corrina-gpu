# Static so it can be dropped into an initramfs.
CFLAGS := -O2 -Wall -static -I../include -I../driver/include/uapi/drm -I/usr/include/drm

fxg_demo: fxg_demo.c fxg_shaders.h
	$(CC) $(CFLAGS) -o $@ fxg_demo.c -lm
fxg_shaders.h: ../shaders/cube.vs.s ../shaders/cube.fs.s ../tools/fxgasm.py
	python3 ../tools/fxgasm.py fxg_cube_vs=../shaders/cube.vs.s fxg_cube_fs=../shaders/cube.fs.s -o $@
clean:
	rm -f fxg_demo fxg_shaders.h
