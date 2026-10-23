// Package boot embeds the precompiled slang-side standard library and
// compiler (the "seed"). The files are generated from slang/ by `make seed`.
package boot

import "embed"

//go:embed slang/*.slb
var FS embed.FS
