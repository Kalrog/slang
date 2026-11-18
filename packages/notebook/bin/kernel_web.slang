// The main file of a notebook's kernel in a browser's worker: `slang run
// kernel_web.slang <notebook>`, started by web/worker.js.
require("notebook/kernel_web").main(args())
