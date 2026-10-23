package stdlib

import (
	"os"
	"sort"
	"time"

	"slang/vm"
)

var processStart = time.Now()

// slang/os: files and process environment.
func osModule(v *vm.VM) *vm.Table {
	return makeModule(natives{
		{"exists", osExists},
		{"is_dir", osIsDir},
		{"read_file", osReadFile},
		{"write_file", osWriteFile},
		{"list_dir", osListDir},
		{"getenv", osGetenv},
		{"cwd", osCwd},
		{"exit", osExit},
		{"clock", osClock},
		{"mkdir_all", osMkdirAll},
		{"time_ms", osTimeMs},
	})
}

// mkdir_all(path): creates the directory and its parents.
func osMkdirAll(th *vm.Thread, args []vm.Value) (vm.Value, error) {
	path, err := vm.ArgString(args, 0, "path")
	if err != nil {
		return vm.Null, err
	}
	if merr := os.MkdirAll(path, 0o755); merr != nil {
		return vm.Null, vm.Errorf("cannot create %s: %v", path, merr)
	}
	return vm.Null, nil
}

// clock(): seconds since program start (monotonic, double).
func osClock(th *vm.Thread, args []vm.Value) (vm.Value, error) {
	return vm.Float(time.Since(processStart).Seconds()), nil
}

// time_ms(): milliseconds since the Unix epoch (int).
func osTimeMs(th *vm.Thread, args []vm.Value) (vm.Value, error) {
	return vm.Int(time.Now().UnixMilli()), nil
}

func osExists(th *vm.Thread, args []vm.Value) (vm.Value, error) {
	path, err := vm.ArgString(args, 0, "path")
	if err != nil {
		return vm.Null, err
	}
	_, serr := os.Stat(path)
	return vm.Bool(serr == nil), nil
}

func osIsDir(th *vm.Thread, args []vm.Value) (vm.Value, error) {
	path, err := vm.ArgString(args, 0, "path")
	if err != nil {
		return vm.Null, err
	}
	info, serr := os.Stat(path)
	return vm.Bool(serr == nil && info.IsDir()), nil
}

func osReadFile(th *vm.Thread, args []vm.Value) (vm.Value, error) {
	path, err := vm.ArgString(args, 0, "path")
	if err != nil {
		return vm.Null, err
	}
	data, rerr := os.ReadFile(path)
	if rerr != nil {
		return vm.Null, vm.Errorf("cannot read %s: %v", path, rerr)
	}
	return vm.String(string(data)), nil
}

func osWriteFile(th *vm.Thread, args []vm.Value) (vm.Value, error) {
	path, err := vm.ArgString(args, 0, "path")
	if err != nil {
		return vm.Null, err
	}
	content, err := vm.ArgString(args, 1, "content")
	if err != nil {
		return vm.Null, err
	}
	if werr := os.WriteFile(path, []byte(content), 0o644); werr != nil {
		return vm.Null, vm.Errorf("cannot write %s: %v", path, werr)
	}
	return vm.Null, nil
}

func osListDir(th *vm.Thread, args []vm.Value) (vm.Value, error) {
	path, err := vm.ArgString(args, 0, "path")
	if err != nil {
		return vm.Null, err
	}
	entries, rerr := os.ReadDir(path)
	if rerr != nil {
		return vm.Null, vm.Errorf("cannot list %s: %v", path, rerr)
	}
	names := make([]string, 0, len(entries))
	for _, e := range entries {
		names = append(names, e.Name())
	}
	sort.Strings(names)
	t := vm.NewTable(len(names), 0)
	for _, n := range names {
		t.Append(vm.String(n))
	}
	return vm.TableValue(t), nil
}

func osGetenv(th *vm.Thread, args []vm.Value) (vm.Value, error) {
	name, err := vm.ArgString(args, 0, "name")
	if err != nil {
		return vm.Null, err
	}
	val, ok := os.LookupEnv(name)
	if !ok {
		return vm.Null, nil
	}
	return vm.String(val), nil
}

func osCwd(th *vm.Thread, args []vm.Value) (vm.Value, error) {
	dir, err := os.Getwd()
	if err != nil {
		return vm.Null, err
	}
	return vm.String(dir), nil
}

func osExit(th *vm.Thread, args []vm.Value) (vm.Value, error) {
	th.VM().Flush()
	os.Exit(int(vm.ArgIntOr(args, 0, 0)))
	return vm.Null, nil
}
