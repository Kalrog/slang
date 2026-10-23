package vm

import (
	"errors"
	"fmt"
	"strconv"
)

// Location is a source position.
type Location struct {
	Origin string
	Line   int
	Column int
}

func (l Location) String() string {
	return l.Origin + ":" + strconv.Itoa(l.Line) + ":" + strconv.Itoa(l.Column)
}

// Error is a slang runtime error. Loc and Trace are filled in by the VM at the
// point where the error is raised, if the creator did not set them.
type Error struct {
	Message string
	Loc     *Location
	Trace   string
}

func (e *Error) Error() string {
	if e.Loc != nil {
		return e.Message + " at " + e.Loc.String()
	}
	return e.Message
}

// Errorf creates a slang error without location (the VM adds it).
func Errorf(format string, a ...any) *Error {
	return &Error{Message: fmt.Sprintf(format, a...)}
}

// NewError creates a slang error with a plain message.
func NewError(msg string) *Error { return &Error{Message: msg} }

// errYield is the sentinel returned by thread.yield; never visible to slang.
var errYield = errors.New("yield")

// ToValue converts the error to the slang error table
// {message, location: {line, column, origin}, stack}.
func (e *Error) ToValue() Value {
	t := NewTable(0, 3)
	t.SetStr("message", String(e.Message))
	if e.Loc != nil {
		loc := NewTable(0, 3)
		loc.SetStr("line", Int(int64(e.Loc.Line)))
		loc.SetStr("column", Int(int64(e.Loc.Column)))
		loc.SetStr("origin", String(e.Loc.Origin))
		t.SetStr("location", TableValue(loc))
	}
	if e.Trace != "" {
		t.SetStr("stack", String(e.Trace))
	}
	return TableValue(t)
}

func okResult(v Value) Value {
	t := NewTable(2, 0)
	t.Append(String("ok"))
	t.Append(v)
	return TableValue(t)
}

func errResult(e *Error) Value {
	t := NewTable(2, 0)
	t.Append(String("err"))
	t.Append(e.ToValue())
	return TableValue(t)
}
