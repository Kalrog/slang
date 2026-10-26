package stdlib

import (
	"hash/fnv"
	"sort"
	"strconv"
	"strings"
	"unicode"
	"unicode/utf8"
	"unsafe"

	"slang/vm"
)

// slang/string. Strings are byte strings (UTF-8 by convention); positions are
// byte offsets.
func stringModule() *vm.Table {
	return makeModule(natives{
		{"join", strJoin},
		{"substring", strSubstring},
		{"byte_at", strByteAt},
		{"char_at", strCharAt},
		{"chr", strChr},
		{"from_bytes", strFromBytes},
		{"index_of", strIndexOf},
		{"starts_with", strStartsWith},
		{"ends_with", strEndsWith},
		{"line_starts", strLineStarts},
		{"split", strSplit},
		{"trim", strTrim},
		{"upper", strUpper},
		{"lower", strLower},
		{"replace", strReplace},
		{"to_number", strToNumber},
		{"char_class", strCharClass},
		{"class_match", strClassMatch},
		{"class_run", strClassRun},
		{"line_col", strLineCol},
		{"space_at", strSpaceAt},
		{"skip_space", strSkipSpace},
		{"rune_len_at", strRuneLenAt},
		{"compare", strCompare},
		{"hash", strHash},
	})
}

func strJoin(th *vm.Thread, args []vm.Value) (vm.Value, error) {
	t, err := vm.ArgTable(args, 0, "table")
	if err != nil {
		return vm.Null, err
	}
	sep := vm.ArgStringOr(args, 1, " ")
	var sb strings.Builder
	first := true
	for _, v := range t.Values() {
		if !v.IsString() {
			return vm.Null, vm.Errorf("expected string, got %s", v.String())
		}
		if !first {
			sb.WriteString(sep)
		}
		first = false
		sb.WriteString(v.AsString())
	}
	return vm.String(sb.String()), nil
}

func strSubstring(th *vm.Thread, args []vm.Value) (vm.Value, error) {
	s, err := vm.ArgString(args, 0, "str")
	if err != nil {
		return vm.Null, err
	}
	start := vm.ArgIntOr(args, 1, 0)
	end := vm.ArgIntOr(args, 2, int64(len(s)))
	if start < 0 || end > int64(len(s)) || start > end {
		return vm.Null, vm.Errorf("substring range %d..%d out of bounds for length %d", start, end, len(s))
	}
	return vm.String(s[start:end]), nil
}

// byte_at(s, i): the byte at i as an int, or null when out of range.
func strByteAt(th *vm.Thread, args []vm.Value) (vm.Value, error) {
	s, err := vm.ArgString(args, 0, "str")
	if err != nil {
		return vm.Null, err
	}
	i := vm.ArgIntOr(args, 1, -1)
	if i < 0 || i >= int64(len(s)) {
		return vm.Null, nil
	}
	return vm.Int(int64(s[i])), nil
}

// char_at(s, i): the UTF-8 character starting at byte i, or null.
func strCharAt(th *vm.Thread, args []vm.Value) (vm.Value, error) {
	s, err := vm.ArgString(args, 0, "str")
	if err != nil {
		return vm.Null, err
	}
	i := vm.ArgIntOr(args, 1, -1)
	if i < 0 || i >= int64(len(s)) {
		return vm.Null, nil
	}
	_, n := utf8.DecodeRuneInString(s[i:])
	return vm.String(s[i : int(i)+n]), nil
}

// chr(code): the character with the given code point.
func strChr(th *vm.Thread, args []vm.Value) (vm.Value, error) {
	c, err := vm.ArgInt(args, 0, "code")
	if err != nil {
		return vm.Null, err
	}
	if c < 128 {
		return vm.String(string([]byte{byte(c)})), nil
	}
	return vm.String(string(rune(c))), nil
}

// index_of(s, sub, [from]): byte index of sub in s at or after from, or -1.
func strIndexOf(th *vm.Thread, args []vm.Value) (vm.Value, error) {
	s, err := vm.ArgString(args, 0, "str")
	if err != nil {
		return vm.Null, err
	}
	sub, err := vm.ArgString(args, 1, "sub")
	if err != nil {
		return vm.Null, err
	}
	from := vm.ArgIntOr(args, 2, 0)
	if from < 0 {
		from = 0
	}
	if from > int64(len(s)) {
		return vm.Int(-1), nil
	}
	i := strings.Index(s[from:], sub)
	if i < 0 {
		return vm.Int(-1), nil
	}
	return vm.Int(from + int64(i)), nil
}

// starts_with(s, prefix, [at]): whether s has prefix at byte offset at.
func strStartsWith(th *vm.Thread, args []vm.Value) (vm.Value, error) {
	s, err := vm.ArgString(args, 0, "str")
	if err != nil {
		return vm.Null, err
	}
	prefix, err := vm.ArgString(args, 1, "prefix")
	if err != nil {
		return vm.Null, err
	}
	at := vm.ArgIntOr(args, 2, 0)
	if at < 0 || at > int64(len(s)) {
		return vm.False, nil
	}
	return vm.Bool(strings.HasPrefix(s[at:], prefix)), nil
}

func strEndsWith(th *vm.Thread, args []vm.Value) (vm.Value, error) {
	s, err := vm.ArgString(args, 0, "str")
	if err != nil {
		return vm.Null, err
	}
	suffix, err := vm.ArgString(args, 1, "suffix")
	if err != nil {
		return vm.Null, err
	}
	return vm.Bool(strings.HasSuffix(s, suffix)), nil
}

// line_starts(s): byte offsets at which each line starts (first entry is 0).
func strLineStarts(th *vm.Thread, args []vm.Value) (vm.Value, error) {
	s, err := vm.ArgString(args, 0, "str")
	if err != nil {
		return vm.Null, err
	}
	t := vm.NewTable(strings.Count(s, "\n")+1, 0)
	t.Append(vm.Int(0))
	for i := 0; i < len(s); i++ {
		if s[i] == '\n' {
			t.Append(vm.Int(int64(i + 1)))
		}
	}
	return vm.TableValue(t), nil
}

func strSplit(th *vm.Thread, args []vm.Value) (vm.Value, error) {
	s, err := vm.ArgString(args, 0, "str")
	if err != nil {
		return vm.Null, err
	}
	sep, err := vm.ArgString(args, 1, "sep")
	if err != nil {
		return vm.Null, err
	}
	parts := strings.Split(s, sep)
	t := vm.NewTable(len(parts), 0)
	for _, p := range parts {
		t.Append(vm.String(p))
	}
	return vm.TableValue(t), nil
}

func strMap(f func(string) string) vm.NativeFunc {
	return func(th *vm.Thread, args []vm.Value) (vm.Value, error) {
		s, err := vm.ArgString(args, 0, "str")
		if err != nil {
			return vm.Null, err
		}
		return vm.String(f(s)), nil
	}
}

var (
	strTrim  = strMap(strings.TrimSpace)
	strUpper = strMap(strings.ToUpper)
	strLower = strMap(strings.ToLower)
)

func strReplace(th *vm.Thread, args []vm.Value) (vm.Value, error) {
	s, err := vm.ArgString(args, 0, "str")
	if err != nil {
		return vm.Null, err
	}
	old, err := vm.ArgString(args, 1, "old")
	if err != nil {
		return vm.Null, err
	}
	repl, err := vm.ArgString(args, 2, "new")
	if err != nil {
		return vm.Null, err
	}
	return vm.String(strings.ReplaceAll(s, old, repl)), nil
}

// to_number(s): parses an int or a double, or returns null.
func strToNumber(th *vm.Thread, args []vm.Value) (vm.Value, error) {
	s, err := vm.ArgString(args, 0, "str")
	if err != nil {
		return vm.Null, err
	}
	if i, ierr := strconv.ParseInt(s, 10, 64); ierr == nil {
		return vm.Int(i), nil
	}
	if f, ferr := strconv.ParseFloat(s, 64); ferr == nil {
		return vm.Float(f), nil
	}
	return vm.Null, nil
}

// charClass is a compiled character class in petitparser pattern syntax:
// ranges like a-z, single characters, and a leading ^ for negation.
type charClass struct {
	spec   string
	negate bool
	ranges []rune // pairs lo,hi
}

func (c *charClass) String() string { return "[" + c.spec + "]" }

func (c *charClass) match(r rune) bool {
	hit := false
	for i := 0; i+1 < len(c.ranges); i += 2 {
		if r >= c.ranges[i] && r <= c.ranges[i+1] {
			hit = true
			break
		}
	}
	return hit != c.negate
}

func compileCharClass(spec string) *charClass {
	c := &charClass{spec: spec}
	rs := []rune(spec)
	i := 0
	if len(rs) > 0 && rs[0] == '^' {
		c.negate = true
		i = 1
	}
	for i < len(rs) {
		lo := rs[i]
		if i+2 < len(rs) && rs[i+1] == '-' {
			c.ranges = append(c.ranges, lo, rs[i+2])
			i += 3
			continue
		}
		c.ranges = append(c.ranges, lo, lo)
		i++
	}
	return c
}

// char_class(spec): compiles a character class.
func strCharClass(th *vm.Thread, args []vm.Value) (vm.Value, error) {
	spec, err := vm.ArgString(args, 0, "spec")
	if err != nil {
		return vm.Null, err
	}
	return vm.UserdataValue(vm.NewUserdata(compileCharClass(spec), nil)), nil
}

// class_match(class, s, pos): byte length of the character at pos if it is in
// the class, otherwise 0.
func strClassMatch(th *vm.Thread, args []vm.Value) (vm.Value, error) {
	c, err := vm.ArgUserdata[*charClass](args, 0, "class")
	if err != nil {
		return vm.Null, err
	}
	s, err := vm.ArgString(args, 1, "str")
	if err != nil {
		return vm.Null, err
	}
	pos := vm.ArgIntOr(args, 2, 0)
	if pos < 0 || pos >= int64(len(s)) {
		return vm.Int(0), nil
	}
	r, n := utf8.DecodeRuneInString(s[pos:])
	if c.match(r) {
		return vm.Int(int64(n)), nil
	}
	return vm.Int(0), nil
}

// class_run(class, s, pos): the position after the longest run of characters
// in the class starting at pos (pos itself when there is none).
func strClassRun(th *vm.Thread, args []vm.Value) (vm.Value, error) {
	c, err := vm.ArgUserdata[*charClass](args, 0, "class")
	if err != nil {
		return vm.Null, err
	}
	s, err := vm.ArgString(args, 1, "str")
	if err != nil {
		return vm.Null, err
	}
	pos := int(vm.ArgIntOr(args, 2, 0))
	if pos < 0 {
		pos = 0
	}
	for pos < len(s) {
		b := s[pos]
		if b < utf8.RuneSelf {
			if !c.match(rune(b)) {
				break
			}
			pos++
			continue
		}
		r, n := utf8.DecodeRuneInString(s[pos:])
		if !c.match(r) {
			break
		}
		pos += n
	}
	return vm.Int(int64(pos)), nil
}

// lineIndexCache remembers the line starts of the most recently used buffer
// (parsers call line_col once per token on the same buffer).
var lineIndexCache struct {
	data   *byte
	length int
	starts []int
}

func lineStartsOf(s string) []int {
	data := unsafe.StringData(s)
	if lineIndexCache.data == data && lineIndexCache.length == len(s) {
		return lineIndexCache.starts
	}
	starts := make([]int, 1, strings.Count(s, "\n")+1)
	starts[0] = 0
	for i := 0; i < len(s); i++ {
		if s[i] == '\n' {
			starts = append(starts, i+1)
		}
	}
	lineIndexCache.data = data
	lineIndexCache.length = len(s)
	lineIndexCache.starts = starts
	return starts
}

// line_col(s, pos): {line, column} (1-based) of byte offset pos.
func strLineCol(th *vm.Thread, args []vm.Value) (vm.Value, error) {
	s, err := vm.ArgString(args, 0, "str")
	if err != nil {
		return vm.Null, err
	}
	pos := int(vm.ArgIntOr(args, 1, 0))
	starts := lineStartsOf(s)
	line := sort.Search(len(starts), func(i int) bool { return starts[i] > pos }) - 1
	if line < 0 {
		line = 0
	}
	return vm.TableValue(vm.NewTableFrom(vm.Int(int64(line+1)), vm.Int(int64(pos-starts[line]+1)))), nil
}

// space_at(s, pos): byte length of the whitespace character at pos, or 0.
func strSpaceAt(th *vm.Thread, args []vm.Value) (vm.Value, error) {
	s, err := vm.ArgString(args, 0, "str")
	if err != nil {
		return vm.Null, err
	}
	pos := vm.ArgIntOr(args, 1, 0)
	if pos < 0 || pos >= int64(len(s)) {
		return vm.Int(0), nil
	}
	if b := s[pos]; b < utf8.RuneSelf {
		if b == ' ' || b == '\t' || b == '\n' || b == '\r' || b == '\f' || b == '\v' {
			return vm.Int(1), nil
		}
		return vm.Int(0), nil
	}
	r, n := utf8.DecodeRuneInString(s[pos:])
	if unicode.IsSpace(r) {
		return vm.Int(int64(n)), nil
	}
	return vm.Int(0), nil
}

// skip_space(s, pos): the position after any run of whitespace and
// line comments (// up to, not including, the newline) starting at pos.
func strSkipSpace(th *vm.Thread, args []vm.Value) (vm.Value, error) {
	s, err := vm.ArgString(args, 0, "str")
	if err != nil {
		return vm.Null, err
	}
	pos := int(vm.ArgIntOr(args, 1, 0))
	if pos < 0 {
		pos = 0
	}
	n := len(s)
	for pos < n {
		b := s[pos]
		if b == ' ' || b == '\t' || b == '\n' || b == '\r' || b == '\f' || b == '\v' {
			pos++
			continue
		}
		if b == '/' && pos+1 < n && s[pos+1] == '/' {
			pos += 2
			for pos < n && s[pos] != '\n' {
				pos++
			}
			continue
		}
		if b >= utf8.RuneSelf {
			r, size := utf8.DecodeRuneInString(s[pos:])
			if unicode.IsSpace(r) {
				pos += size
				continue
			}
		}
		break
	}
	return vm.Int(int64(pos)), nil
}

// rune_len_at(s, pos): byte length of the character at pos, or 0 at the end.
func strRuneLenAt(th *vm.Thread, args []vm.Value) (vm.Value, error) {
	s, err := vm.ArgString(args, 0, "str")
	if err != nil {
		return vm.Null, err
	}
	pos := vm.ArgIntOr(args, 1, 0)
	if pos < 0 || pos >= int64(len(s)) {
		return vm.Int(0), nil
	}
	_, n := utf8.DecodeRuneInString(s[pos:])
	return vm.Int(int64(n)), nil
}

// hash(s): a stable 64-bit hash of s as 16 hex digits (FNV-1a).
func strHash(th *vm.Thread, args []vm.Value) (vm.Value, error) {
	s, err := vm.ArgString(args, 0, "str")
	if err != nil {
		return vm.Null, err
	}
	h := fnv.New64a()
	h.Write([]byte(s))
	return vm.String(strconv.FormatUint(h.Sum64(), 16)), nil
}

// compare(a, b): -1, 0 or 1 (byte-wise).
func strCompare(th *vm.Thread, args []vm.Value) (vm.Value, error) {
	a, err := vm.ArgString(args, 0, "a")
	if err != nil {
		return vm.Null, err
	}
	b, err := vm.ArgString(args, 1, "b")
	if err != nil {
		return vm.Null, err
	}
	return vm.Int(int64(strings.Compare(a, b))), nil
}

// from_bytes(list) -> string: a string from a table of byte values (0-255).
func strFromBytes(th *vm.Thread, args []vm.Value) (vm.Value, error) {
	t, err := vm.ArgTable(args, 0, "bytes")
	if err != nil {
		return vm.Null, err
	}
	n := t.Len()
	buf := make([]byte, n)
	for i := 0; i < n; i++ {
		v := t.GetInt(int64(i))
		if v.Kind() != vm.KInt || v.AsInt() < 0 || v.AsInt() > 255 {
			return vm.Null, vm.Errorf("from_bytes: element %d is not a byte value: %s", i, v.String())
		}
		buf[i] = byte(v.AsInt())
	}
	return vm.String(string(buf)), nil
}
