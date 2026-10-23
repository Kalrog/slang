package stdlib

import (
	"io"
	"os"
	"path/filepath"
	"strconv"
	"strings"

	"slang/vm"
)

func openCore(v *vm.VM) {
	fileMeta := makeFileMeta()
	core := natives{
		{"print", corePrint},
		{"args", coreArgs},
		{"readLine", coreReadLine},
		{"assert", coreAssert},
		{"append", coreAppend},
		{"remove", coreRemove},
		{"keys", coreKeys},
		{"values", coreValues},
		{"entries", coreEntries},
		{"concat", coreConcat},
		{"error", coreError},
		{"len", coreLen},
		{"type", coreType},
		{"set_raw", coreSetRaw},
		{"get_raw", coreGetRaw},
		{"to_int", coreToInt},
		{"string", coreString},
		{"list_push", coreListPush},
	}
	for _, n := range core {
		v.Register(n.Name, n.Fn)
	}
	v.Register("open", func(th *vm.Thread, args []vm.Value) (vm.Value, error) {
		return coreOpen(th, args, fileMeta)
	})
	v.SetGlobal("pcall", vm.FunctionValue(vm.PCallClosure()))
}

func corePrint(th *vm.Thread, args []vm.Value) (vm.Value, error) {
	var sb strings.Builder
	for _, a := range args {
		sb.WriteString(a.String())
	}
	_, err := io.WriteString(th.VM().Stdout, sb.String())
	return vm.Null, err
}

func coreArgs(th *vm.Thread, args []vm.Value) (vm.Value, error) {
	t := vm.NewTable(len(th.VM().Args), 0)
	for _, a := range th.VM().Args {
		t.Append(vm.String(a))
	}
	return vm.TableValue(t), nil
}

func coreReadLine(th *vm.Thread, args []vm.Value) (vm.Value, error) {
	th.VM().Flush()
	line, err := th.VM().Stdin.ReadString('\n')
	if err != nil && line == "" {
		return vm.Null, nil
	}
	line = strings.TrimRight(line, "\r\n")
	return vm.String(line), nil
}

func coreAssert(th *vm.Thread, args []vm.Value) (vm.Value, error) {
	if vm.Arg(args, 0).Truthy() {
		return vm.Null, nil
	}
	var sb strings.Builder
	for _, a := range args[1:] {
		sb.WriteString(a.String())
	}
	msg := sb.String()
	if msg == "" {
		msg = "assertion failed"
	}
	return vm.Null, vm.NewError(msg)
}

func coreAppend(th *vm.Thread, args []vm.Value) (vm.Value, error) {
	t, err := vm.ArgTable(args, 0, "table")
	if err != nil {
		return vm.Null, err
	}
	t.Set(vm.Int(int64(t.Len())), vm.Arg(args, 1))
	return vm.Null, nil
}

// list_push(t, v): appends v to the array part of t, keeping null slots.
func coreListPush(th *vm.Thread, args []vm.Value) (vm.Value, error) {
	t, err := vm.ArgTable(args, 0, "table")
	if err != nil {
		return vm.Null, err
	}
	t.PushSlot(vm.Arg(args, 1))
	return vm.Null, nil
}

func coreRemove(th *vm.Thread, args []vm.Value) (vm.Value, error) {
	t := vm.Arg(args, 0).AsTable()
	if t == nil {
		return vm.Null, nil
	}
	return t.Remove(vm.Arg(args, 1)), nil
}

func coreKeys(th *vm.Thread, args []vm.Value) (vm.Value, error) {
	t := vm.Arg(args, 0).AsTable()
	if t == nil {
		return vm.Null, nil
	}
	keys := t.Keys()
	i := 0
	return vm.FunctionValue(vm.NewNative("keys.next", func(th *vm.Thread, args []vm.Value) (vm.Value, error) {
		if i < len(keys) {
			k := keys[i]
			i++
			return k, nil
		}
		return vm.Null, nil
	})), nil
}

func iterTable(args []vm.Value, name string) (*vm.Table, error) {
	a := vm.Arg(args, 0)
	switch a.Kind() {
	case vm.KNull:
		return vm.NewTable(0, 0), nil
	case vm.KTable:
		return a.AsTable(), nil
	}
	return nil, vm.Errorf("%s expects a table, got %s", name, a.TypeName())
}

func coreValues(th *vm.Thread, args []vm.Value) (vm.Value, error) {
	t, err := iterTable(args, "values")
	if err != nil {
		return vm.Null, err
	}
	keys := t.Keys()
	i := 0
	return vm.FunctionValue(vm.NewNative("values.next", func(th *vm.Thread, args []vm.Value) (vm.Value, error) {
		if i < len(keys) {
			v := t.Get(keys[i])
			i++
			return v, nil
		}
		return vm.Null, nil
	})), nil
}

func coreEntries(th *vm.Thread, args []vm.Value) (vm.Value, error) {
	t, err := iterTable(args, "entries")
	if err != nil {
		return vm.Null, err
	}
	keys := t.Keys()
	i := 0
	return vm.FunctionValue(vm.NewNative("entries.next", func(th *vm.Thread, args []vm.Value) (vm.Value, error) {
		if i < len(keys) {
			k := keys[i]
			i++
			return vm.TableValue(vm.NewTableFrom(k, t.Get(k))), nil
		}
		return vm.Null, nil
	})), nil
}

func coreConcat(th *vm.Thread, args []vm.Value) (vm.Value, error) {
	first := vm.Arg(args, 0)
	switch first.Kind() {
	case vm.KString:
		var sb strings.Builder
		for _, a := range args {
			sb.WriteString(a.String())
		}
		return vm.String(sb.String()), nil
	case vm.KTable:
		out := vm.NewTable(0, 0)
		for i, a := range args {
			t := a.AsTable()
			if t == nil {
				return vm.Null, vm.Errorf("concat: argument %d is not a table", i)
			}
			out.AddAll(t)
		}
		return vm.TableValue(out), nil
	}
	return vm.Null, vm.Errorf("concat requires a table or string")
}

func coreError(th *vm.Thread, args []vm.Value) (vm.Value, error) {
	var sb strings.Builder
	for _, a := range args {
		sb.WriteString(a.String())
	}
	return vm.Null, vm.NewError(sb.String())
}

func coreLen(th *vm.Thread, args []vm.Value) (vm.Value, error) {
	a := vm.Arg(args, 0)
	switch a.Kind() {
	case vm.KTable:
		return vm.Int(int64(a.AsTable().Len())), nil
	case vm.KString:
		return vm.Int(int64(len(a.AsString()))), nil
	}
	return vm.Null, vm.Errorf("len requires a table or string")
}

func coreType(th *vm.Thread, args []vm.Value) (vm.Value, error) {
	return th.TypeOf(vm.Arg(args, 0))
}

func coreSetRaw(th *vm.Thread, args []vm.Value) (vm.Value, error) {
	t, err := vm.ArgTable(args, 0, "table")
	if err != nil {
		return vm.Null, err
	}
	t.Set(vm.Arg(args, 1), vm.Arg(args, 2))
	return vm.Null, nil
}

func coreGetRaw(th *vm.Thread, args []vm.Value) (vm.Value, error) {
	t, err := vm.ArgTable(args, 0, "table")
	if err != nil {
		return vm.Null, err
	}
	return t.Get(vm.Arg(args, 1)), nil
}

func coreToInt(th *vm.Thread, args []vm.Value) (vm.Value, error) {
	a := vm.Arg(args, 0)
	switch a.Kind() {
	case vm.KInt:
		return a, nil
	case vm.KFloat:
		return vm.Int(int64(a.AsFloat())), nil
	case vm.KString:
		s := a.AsString()
		base := 10
		body := s
		neg := false
		if strings.HasPrefix(body, "-") {
			neg = true
			body = body[1:]
		} else if strings.HasPrefix(body, "+") {
			body = body[1:]
		}
		if strings.HasPrefix(body, "0x") || strings.HasPrefix(body, "0X") {
			base = 16
			body = body[2:]
		}
		n, err := strconv.ParseInt(body, base, 64)
		if err != nil {
			return vm.Null, vm.Errorf("FormatException: Invalid number: %q", s)
		}
		if neg {
			n = -n
		}
		return vm.Int(n), nil
	}
	return vm.Null, vm.Errorf("toInt requires an integer or string")
}

func coreString(th *vm.Thread, args []vm.Value) (vm.Value, error) {
	return vm.String(vm.Arg(args, 0).String()), nil
}

// Files.

type fileHandle struct {
	f    *os.File
	path string
}

func (h *fileHandle) String() string { return "File: '" + h.path + "'" }

func makeFileMeta() *vm.Table {
	meta := vm.NewTable(0, 1)
	meta.SetStr("__index", vm.TableValue(makeModule(natives{
		{"read", fileRead},
		{"write", fileWrite},
		{"readBytes", fileReadBytes},
		{"writeBytes", fileWriteBytes},
		{"close", fileClose},
	})))
	meta.SetStr("__type", vm.String("file"))
	return meta
}

func coreOpen(th *vm.Thread, args []vm.Value, meta *vm.Table) (vm.Value, error) {
	path, err := vm.ArgString(args, 0, "path")
	if err != nil {
		return vm.Null, err
	}
	mode := vm.ArgStringOr(args, 1, "r")
	r := strings.Contains(mode, "r")
	w := strings.Contains(mode, "w")
	a := strings.Contains(mode, "a")
	flags := os.O_RDONLY
	switch {
	case r && w:
		flags = os.O_RDWR | os.O_CREATE | os.O_TRUNC
	case w:
		flags = os.O_WRONLY | os.O_CREATE | os.O_TRUNC
	}
	if a {
		if w && !r {
			flags = os.O_WRONLY | os.O_CREATE | os.O_APPEND
		} else {
			flags = os.O_RDWR | os.O_CREATE | os.O_APPEND
		}
	}
	if _, serr := os.Stat(path); os.IsNotExist(serr) {
		os.MkdirAll(filepath.Dir(path), 0o755)
		if f, cerr := os.Create(path); cerr == nil {
			f.Close()
		}
	}
	f, err := os.OpenFile(path, flags, 0o644)
	if err != nil {
		return vm.Null, vm.Errorf("cannot open %s: %v", path, err)
	}
	return vm.UserdataValue(vm.NewUserdata(&fileHandle{f: f, path: path}, meta)), nil
}

func fileArg(args []vm.Value) (*fileHandle, error) {
	return vm.ArgUserdata[*fileHandle](args, 0, "file")
}

func fileReadN(args []vm.Value) ([]byte, error) {
	h, err := fileArg(args)
	if err != nil {
		return nil, err
	}
	n := vm.ArgIntOr(args, 1, -1)
	if n < 0 {
		info, serr := h.f.Stat()
		if serr != nil {
			return nil, vm.Errorf("cannot stat %s: %v", h.path, serr)
		}
		n = info.Size()
	}
	buf := make([]byte, n)
	k, rerr := io.ReadFull(h.f, buf)
	if rerr != nil && rerr != io.EOF && rerr != io.ErrUnexpectedEOF {
		return nil, vm.Errorf("read error on %s: %v", h.path, rerr)
	}
	return buf[:k], nil
}

func fileRead(th *vm.Thread, args []vm.Value) (vm.Value, error) {
	buf, err := fileReadN(args)
	if err != nil {
		return vm.Null, err
	}
	return vm.String(string(buf)), nil
}

func fileReadBytes(th *vm.Thread, args []vm.Value) (vm.Value, error) {
	buf, err := fileReadN(args)
	if err != nil {
		return vm.Null, err
	}
	t := vm.NewTable(len(buf), 0)
	for _, b := range buf {
		t.Append(vm.Int(int64(b)))
	}
	return vm.TableValue(t), nil
}

func fileWrite(th *vm.Thread, args []vm.Value) (vm.Value, error) {
	h, err := fileArg(args)
	if err != nil {
		return vm.Null, err
	}
	s, err := vm.ArgString(args, 1, "str")
	if err != nil {
		return vm.Null, err
	}
	if _, werr := h.f.WriteString(s); werr != nil {
		return vm.Null, vm.Errorf("write error on %s: %v", h.path, werr)
	}
	return vm.Null, nil
}

func fileWriteBytes(th *vm.Thread, args []vm.Value) (vm.Value, error) {
	h, err := fileArg(args)
	if err != nil {
		return vm.Null, err
	}
	t, err := vm.ArgTable(args, 1, "bytes")
	if err != nil {
		return vm.Null, err
	}
	buf := make([]byte, 0, t.Len())
	for _, b := range t.Values() {
		buf = append(buf, byte(b.AsInt()))
	}
	if _, werr := h.f.Write(buf); werr != nil {
		return vm.Null, vm.Errorf("write error on %s: %v", h.path, werr)
	}
	return vm.Null, nil
}

func fileClose(th *vm.Thread, args []vm.Value) (vm.Value, error) {
	h, err := fileArg(args)
	if err != nil {
		return vm.Null, err
	}
	h.f.Close()
	return vm.Null, nil
}
