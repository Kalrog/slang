// Package boot embeds the precompiled slang-side standard library and
// compiler (the "seed"). The files are generated from slang/ by `make seed`.
package boot

import "embed"

// The seed lives in boot/slang at the repository root; `make go-build`
// copies it here (Go's embed cannot leave the module).
//
//go:embed slang/*.slb
var FS embed.FS
