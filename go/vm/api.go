package vm

// Helpers for native functions.

// Arg returns args[i] or null when out of range.
func Arg(args []Value, i int) Value {
	if i < len(args) {
		return args[i]
	}
	return Null
}

func argError(name string, i int, want string, got Value) error {
	if name == "" {
		name = itoa(i)
	}
	return Errorf("Expected %s for %s got %s", want, name, got.TypeName())
}

// ArgString returns args[i] as a string or an error.
func ArgString(args []Value, i int, name string) (string, error) {
	v := Arg(args, i)
	if v.k != KString {
		return "", argError(name, i, "String", v)
	}
	return v.o.(string), nil
}

// ArgStringOr returns args[i] as a string or def when it is not a string.
func ArgStringOr(args []Value, i int, def string) string {
	v := Arg(args, i)
	if v.k != KString {
		return def
	}
	return v.o.(string)
}

// ArgInt returns args[i] as an int or an error.
func ArgInt(args []Value, i int, name string) (int64, error) {
	v := Arg(args, i)
	if v.k != KInt {
		return 0, argError(name, i, "int", v)
	}
	return v.n, nil
}

// ArgIntOr returns args[i] as an int or def when it is not an int.
func ArgIntOr(args []Value, i int, def int64) int64 {
	v := Arg(args, i)
	if v.k != KInt {
		return def
	}
	return v.n
}

// ArgNumber returns args[i] (int or double) as float64 or an error.
func ArgNumber(args []Value, i int, name string) (float64, error) {
	v := Arg(args, i)
	if !v.IsNumber() {
		return 0, argError(name, i, "num", v)
	}
	return v.AsNumber(), nil
}

// ArgNumberOr returns args[i] as a number or def.
func ArgNumberOr(args []Value, i int, def float64) float64 {
	v := Arg(args, i)
	if !v.IsNumber() {
		return def
	}
	return v.AsNumber()
}

// ArgBool returns the truthiness of args[i]; missing arguments count as def.
func ArgBool(args []Value, i int, def bool) bool {
	if i >= len(args) || args[i].k == KNull {
		return def
	}
	return args[i].Truthy()
}

// ArgTable returns args[i] as a table or an error.
func ArgTable(args []Value, i int, name string) (*Table, error) {
	v := Arg(args, i)
	if v.k != KTable {
		return nil, argError(name, i, "SlangTable", v)
	}
	return v.o.(*Table), nil
}

// ArgFunction returns args[i] as a closure or an error.
func ArgFunction(args []Value, i int, name string) (*Closure, error) {
	v := Arg(args, i)
	if v.k != KFunction {
		return nil, argError(name, i, "Closure", v)
	}
	return v.o.(*Closure), nil
}

// ArgThread returns args[i] as a thread or an error.
func ArgThread(args []Value, i int, name string) (*Thread, error) {
	v := Arg(args, i)
	if v.k != KThread {
		return nil, argError(name, i, "Thread", v)
	}
	return v.o.(*Thread), nil
}

// ArgUserdata returns the Go value of args[i] if it is a userdata of type T.
func ArgUserdata[T any](args []Value, i int, name string) (T, error) {
	var zero T
	v := Arg(args, i)
	if v.k != KUserdata {
		return zero, argError(name, i, "userdata", v)
	}
	t, ok := v.o.(*Userdata).Value.(T)
	if !ok {
		return zero, Errorf("Expected %T for %s got %T", zero, name, v.o.(*Userdata).Value)
	}
	return t, nil
}
