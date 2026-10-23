package stdlib

import "slang/vm"

// slang/thread: cooperative coroutines.
func threadModule() *vm.Table {
	return makeModule(natives{
		{"create", thCreate},
		{"resume", thResume},
		{"yield", thYield},
		{"state", thState},
		{"current", thCurrent},
		{"id", thID},
	})
}

// create(func): a new coroutine; it starts running on the first resume.
func thCreate(th *vm.Thread, args []vm.Value) (vm.Value, error) {
	cl, err := vm.ArgFunction(args, 0, "function")
	if err != nil {
		return vm.Null, err
	}
	return vm.ThreadValue(th.VM().NewThread(cl)), nil
}

// resume(thread, [value]): run the coroutine until it yields or returns and
// return the yielded value or result. On the first resume the value is
// passed as the function argument, later it is returned by yield.
func thResume(th *vm.Thread, args []vm.Value) (vm.Value, error) {
	co, err := vm.ArgThread(args, 0, "thread")
	if err != nil {
		return vm.Null, err
	}
	rest := make([]vm.Value, len(args)-1)
	copy(rest, args[1:])
	return co.Resume(rest)
}

// yield([value]): suspend the current coroutine.
func thYield(th *vm.Thread, args []vm.Value) (vm.Value, error) {
	v := vm.Null
	if len(args) > 0 {
		v = args[len(args)-1]
	}
	return vm.Null, th.Yield(v)
}

// state([thread]): "init", "running", "suspended" or "dead".
func thState(th *vm.Thread, args []vm.Value) (vm.Value, error) {
	target := th
	if len(args) > 0 {
		t, err := vm.ArgThread(args, 0, "thread")
		if err != nil {
			return vm.Null, err
		}
		target = t
	}
	return vm.String(target.Status().String()), nil
}

func thCurrent(th *vm.Thread, args []vm.Value) (vm.Value, error) {
	return vm.ThreadValue(th), nil
}

func thID(th *vm.Thread, args []vm.Value) (vm.Value, error) {
	return vm.Int(int64(th.ID())), nil
}
