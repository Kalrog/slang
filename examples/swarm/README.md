# swarm

A million particles simulated on the GPU, with sound that follows them,
written with the `gpu` and `window` packages.

```
make swarm          # or: cd examples/swarm && ../../bin/slang run main.slang
```

| control | |
|---|---|
| left mouse button | pull the swarm toward the cursor |
| right mouse button | push it away |
| space, middle button | a shock wave (with a whoosh) |
| wheel | the strength of the flow field |
| 1, 2, 3 | colors: ember, aurora, silver |
| F | fullscreen |
| R | scatter the swarm again |
| Escape | quit |

A gamepad works too. The left stick moves the cursor, the right trigger
pulls, the left trigger pushes, and the south button sends a shock wave,
which rumbles.

## How it works

The particles never leave the GPU. They live in a storage buffer of
`SWARM_COUNT` particles (1,048,576 by default), each with a position and
a velocity. Each frame:

1. **Simulate.** A compute shader (`step` in `sim/shaders.slang`) moves
   every particle through a field of drifting sine waves, toward or away
   from the cursor, and adds the shock wave. It also adds the kinetic
   energy of one particle in 64 into an atomic counter.
2. **Draw.** A render pass draws a soft dot for every particle: one draw
   call of a million instances of a 4-vertex strip. The vertex shader
   reads the particle from the same storage buffer the compute shader
   wrote. The dots add up in a 16-bit float (HDR) texture, so dense
   regions get brighter without clipping.
3. **Tone-map.** A full-screen triangle maps the HDR texture onto the
   window with an exposure curve and a vignette.

Every eighth frame, the program reads the energy counter back. Its square
root, the swarm's typical speed, steers the sound. The sound is computed
in slang in its own isolate by `window/audio` (`sim/sound.slang`): wind
made of filtered noise that grows louder and brighter as the swarm
speeds up and is panned toward the cursor, over a drone that rises a fifth
while the swarm is pulled and sinks while it is pushed. The shock wave's
whoosh is a sound computed once at startup and played as a voice.

## Why not raylib

raylib draws through OpenGL 3.3 on macOS, which has neither compute
shaders nor storage buffers. A million particles would have to be moved
in slang and uploaded every frame, about 16 MB per frame. Here the CPU
writes 48 bytes of uniforms per frame and reads 4 bytes back every eighth
frame. raylib also has no float render targets for HDR blending and no
gamepad rumble.

`SWARM_FRAMES=n` quits after n frames and prints the frame rate, the
measured energy and the sound's load.
