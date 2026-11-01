# Isolates

`main.slang` renders the Mandelbrot set with a pool of isolates (slang/isolate):
once with one worker, once with one per CPU, and writes `mandelbrot.pgm`.

```
bin/slang run examples/isolates/main.slang [width] [height]
```

The pixels live in `buffer.shared("uint8_t", width * height)`, memory every
isolate writes into directly; the only things copied are the row numbers the
main program sends through a channel and the count each worker returns from
`join`. Workers take rows as they finish the previous one, so a slow row (the
inside of the set) does not hold the others up. The worker function crosses
to each isolate as bytecode, which is why it uses only its arguments and
requires `slang/isolate` itself.

On an M2 Pro (6 performance and 4 efficiency cores) 800x600 takes about
2.1 s with one isolate and 0.32 s with ten.
