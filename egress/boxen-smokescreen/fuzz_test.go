// egress/boxen-smokescreen/fuzz_test.go
// Fuzz targets (go test -fuzz) for the code that reads what a client or a
// file says: the ClientHello hold-back and its verdict, sameHost and
// printable, the upload limits file, and the choice of limit and count.
// Plain `go test` runs each target on its seeds (and on any input saved
// under testdata/fuzz/) as an ordinary test.
//
// To fuzz one, copy this directory into smokescreen's tree at the commit
// build-smokescreen.sh pins, as cmd/boxen-smokescreen, and from the tree's
// root run, for example:
//
//	GOFLAGS=-mod=vendor GOPROXY=off GOTOOLCHAIN=local \
//	  go test ./cmd/boxen-smokescreen/ -run '^$' -fuzz '^FuzzHelloStream$' -fuzztime 2m
//
// The targets: FuzzHelloStream, FuzzRealHello, FuzzSameHost, FuzzPrintable,
// FuzzReadUploadLimits, FuzzLimitFor. -fuzz takes one at a time. An input
// that fails is saved under testdata/fuzz/<target>/; keep it, in bxn's
// egress/boxen-smokescreen/testdata/fuzz/, only as a regression test.
//
// None of this is in the proxy: build-smokescreen.sh builds only the files
// it is given, main.go and uploads.go.
package main

import (
	"bytes"
	"encoding/json"
	"net"
	"os"
	"path/filepath"
	"regexp"
	"strconv"
	"strings"
	"testing"

	"github.com/sirupsen/logrus"
)

// The reasons a tunnel is refused for; "" is a ClientHello for its host.
var helloReasons = map[string]bool{"not_tls": true, "malformed": true, "no_name": true, "mismatch": true}

// recordConn is the far end of a tunnel: it keeps what is forwarded.
type recordConn struct {
	net.Conn
	got bytes.Buffer
}

func (c *recordConn) Write(b []byte) (int, error) { return c.got.Write(b) }

// writes cuts stream into the writes a client makes, each sizes[i] bytes
// long (in turn, cycling), where 0 means the rest; no sizes means one write.
func writes(stream, sizes []byte) [][]byte {
	var out [][]byte
	for i := 0; len(stream) > 0; i++ {
		n := len(stream)
		if len(sizes) > 0 && sizes[i%len(sizes)] != 0 && int(sizes[i%len(sizes)]) < n {
			n = int(sizes[i%len(sizes)])
		}
		out = append(out, stream[:n])
		stream = stream[n:]
	}
	return out
}

// helloRun is what a checkedConn did with a client's writes.
type helloRun struct {
	forwarded []byte
	logs      []map[string]interface{}
	failed    int // the first write that failed, or -1
	verdictAt int // how many bytes were held when the verdict came, or -1
}

// runChecked writes each part through a checkedConn for host, checking as
// it goes that it holds back no more than it may.
func runChecked(t *testing.T, host string, enforce bool, parts [][]byte) helloRun {
	t.Helper()
	far := &recordConn{}
	logs := &bytes.Buffer{}
	logger := logrus.New()
	logger.Out = logs
	logger.Formatter = &logrus.JSONFormatter{}
	c := &checkedConn{Conn: far, host: host, port: 443, enforce: enforce, log: logger}
	run := helloRun{failed: -1, verdictAt: -1}
	var sent []byte
	for i, p := range parts {
		before := c.done
		n, err := c.Write(p)
		sent = append(sent, p...)
		switch {
		case err != nil:
			if n != 0 {
				t.Fatalf("write %d failed after %d bytes", i, n)
			}
			if run.failed < 0 {
				run.failed = i
			}
		case n != len(p):
			t.Fatalf("write %d: %d of %d bytes", i, n, len(p))
		case run.failed >= 0:
			t.Fatalf("write %d went through after write %d failed", i, run.failed)
		}
		if !before && c.done {
			run.verdictAt = len(sent)
		}
		if !c.done {
			// Nothing is sent before the verdict, and less than the
			// cap is held back between writes.
			if far.got.Len() != 0 {
				t.Fatalf("write %d: %d bytes forwarded before the verdict", i, far.got.Len())
			}
			if !bytes.Equal(c.hello.held, sent) {
				t.Fatalf("write %d: holds %d bytes, sent %d", i, len(c.hello.held), len(sent))
			}
			if len(c.hello.held) >= maxHeld {
				t.Fatalf("write %d: holds %d bytes, more than %d", i, len(c.hello.held), maxHeld)
			}
		} else if len(c.hello.held) != 0 {
			t.Fatalf("write %d: still holds %d bytes after the verdict", i, len(c.hello.held))
		}
	}
	if run.verdictAt >= 0 && run.verdictAt > maxHeld+maxWrite(parts) {
		t.Fatalf("held %d bytes before the verdict", run.verdictAt)
	}
	run.forwarded = far.got.Bytes()
	for _, l := range strings.Split(strings.TrimSpace(logs.String()), "\n") {
		if l == "" {
			continue
		}
		var m map[string]interface{}
		if err := json.Unmarshal([]byte(l), &m); err != nil {
			t.Fatalf("log line %q: %v", l, err)
		}
		run.logs = append(run.logs, m)
	}
	return run
}

func maxWrite(parts [][]byte) int {
	n := 0
	for _, p := range parts {
		if len(p) > n {
			n = len(p)
		}
	}
	return n
}

// The seeds for the stream targets: real ClientHellos, whole and in
// fragments, and the refused streams of main_test.go.
func helloSeeds(f *testing.F) [][]byte {
	h := hello(f, "allowed.example")
	notHandshake := fragment(h, 40)
	notHandshake[5+40] = 23
	seeds := [][]byte{
		h,
		append(append([]byte(nil), h...), "after"...),
		hello(f, "other.example"),
		hello(f, "allowed.example.evil"),
		hello(f, ""),
		notHandshake,
		[]byte("GET / HTTP/1.1\r\nHost: other.example\r\n\r\n"),
		{22, 3, 1, 0x40, 0x01},
		{22, 3, 1, 0, 0},
		{22, 3, 1, 0, 4, 1, 0x02, 0, 0},
		{22, 3, 1, 0, 4, 2, 0, 0, 0},
		{22, 3, 1, 0, 4, 1, 0, 0xea, 0x60, 22, 3, 1, 0, 1, 0},
		{},
	}
	for _, cuts := range [][]int{{1}, {3}, {4}, {100}, {1, 2, 3, 50, 51}} {
		seeds = append(seeds, fragment(h, cuts...))
	}
	// Not the 64 KB ClientHellos of TestLargestHello: the fuzzer spends
	// its time minimizing what it grows from them.
	return seeds
}

// Any bytes, in any writes: the check never panics, holds back less than
// maxHeld between writes, decides once, with one of its reasons, and
// decides as it would on the same bytes in one write. (It didn't, for a
// ClientHello near maxHeld: TestLargestHello.)
func FuzzHelloStream(f *testing.F) {
	for i, s := range helloSeeds(f) {
		f.Add(s, []byte{byte(i), 1, 3, 0}, "allowed.example", i%2 == 0)
	}
	f.Fuzz(func(t *testing.T, stream, sizes []byte, host string, enforce bool) {
		parts := writes(stream, sizes)
		run := runChecked(t, host, enforce, parts)

		// The same bytes, held all at once.
		whole := &helloRecords{held: append([]byte(nil), stream...)}
		wName, wReason, wOK := whole.check(host)
		if wOK != (run.verdictAt >= 0) {
			t.Fatalf("decided in one write: %v, in %d: %v", wOK, len(parts), run.verdictAt >= 0)
		}
		if !wOK {
			if len(run.logs) != 0 || len(run.forwarded) != 0 || run.failed >= 0 {
				t.Fatalf("undecided, yet logged %v, forwarded %d, failed %d", run.logs, len(run.forwarded), run.failed)
			}
			if wName != "" || wReason != "" {
				t.Fatalf("undecided, with %q %q", wName, wReason)
			}
			return
		}
		if wReason != "" && !helloReasons[wReason] {
			t.Fatalf("reason %q", wReason)
		}
		if wReason == "" && (wName == "" || !sameHost(wName, host)) {
			t.Fatalf("let %q through for %q", wName, host)
		}

		// The verdict for the bytes up to it doesn't change with more.
		prefix := &helloRecords{held: append([]byte(nil), stream[:run.verdictAt]...)}
		pName, pReason, pOK := prefix.check(host)
		if !pOK {
			t.Fatalf("undecided on the %d bytes the verdict came at", run.verdictAt)
		}
		prefix.held = append(prefix.held, stream[run.verdictAt:]...)
		if n, r, ok := prefix.check(host); !ok || n != pName || r != pReason {
			t.Fatalf("verdict %q %q became %q %q %v with more bytes", pName, pReason, n, r, ok)
		}
		if pName != wName || pReason != wReason {
			t.Fatalf("in writes: %q %q, in one: %q %q", pName, pReason, wName, wReason)
		}

		// What the conn did with it.
		if pReason == "" {
			if len(run.logs) != 0 || run.failed >= 0 || !bytes.Equal(run.forwarded, stream) {
				t.Fatalf("accepted, yet logged %v, failed %d, forwarded %d of %d", run.logs, run.failed, len(run.forwarded), len(stream))
			}
			return
		}
		if len(run.logs) != 1 {
			t.Fatalf("refused (%s) with %d log lines", pReason, len(run.logs))
		}
		m := run.logs[0]
		if m["msg"] != logMessage || m["reason"] != pReason || m["tls_name"] != printable(pName) ||
			m["connect_host"] != printable(host) || m["enforced"] != enforce {
			t.Fatalf("log line %v, for %q %q", m, pName, pReason)
		}
		if enforce {
			if len(run.forwarded) != 0 || run.failed < 0 {
				t.Fatalf("refused, yet forwarded %d bytes (first failure %d)", len(run.forwarded), run.failed)
			}
		} else if run.failed >= 0 || !bytes.Equal(run.forwarded, stream) {
			t.Fatalf("report mode failed %d, forwarded %d of %d", run.failed, len(run.forwarded), len(stream))
		}
	})
}

// fuzzName makes a name crypto/tls sends as is: letters, digits, '-' and
// '.', starting with a letter (so it's no IP address) and with no trailing
// dot (which crypto/tls would trim).
func fuzzName(b []byte) string {
	const alphabet = "abcdefghijklmnopqrstuvwxyz0123456789-."
	if len(b) > 200 {
		b = b[:200]
	}
	s := []byte{'h'}
	for _, c := range b {
		s = append(s, alphabet[int(c)%len(alphabet)])
	}
	return strings.TrimRight(string(s), ".")
}

// fuzzCase changes the case of the letters of s that flags pick.
func fuzzCase(s string, flags []byte) string {
	b := []byte(s)
	for i := range b {
		if len(flags) > 0 && flags[i%len(flags)]>>(uint(i)%8)&1 == 1 && 'a' <= b[i] && b[i] <= 'z' {
			b[i] -= 'a' - 'A'
		}
	}
	return string(b)
}

// cutsFor turns bytes into increasing offsets inside a message of n bytes.
func cutsFor(b []byte, n int) []int {
	var cuts []int
	at := 0
	for _, c := range b {
		at += int(c) + 1
		if at >= n {
			break
		}
		cuts = append(cuts, at)
	}
	return cuts
}

// A real ClientHello from crypto/tls, in fragments and writes: it passes
// for its own name in any case, with or without one trailing dot, and is
// refused as a mismatch for any other.
func FuzzRealHello(f *testing.F) {
	f.Add([]byte("allowed.example"), []byte{}, []byte{0}, "", []byte{}, false, []byte("after"))
	f.Add([]byte("allowed.example"), []byte{0xff, 0x0f}, []byte{40}, "", []byte{1}, true, []byte{})
	f.Add([]byte("allowed.example"), []byte{}, []byte{0, 1, 2, 46}, "other.example", []byte{3}, true, []byte("x"))
	f.Add([]byte("allowed.example"), []byte{}, []byte{99}, "allowed.example.evil", []byte{}, false, []byte{})
	f.Add([]byte("k.example"), []byte{}, []byte{}, "K.example", []byte{}, true, []byte{})
	f.Fuzz(func(t *testing.T, nameBytes, caseFlags, cutBytes []byte, other string, sizes []byte, dot bool, after []byte) {
		name := fuzzName(nameBytes)
		h := hello(t, name)
		stream := fragment(h, cutsFor(cutBytes, len(h)-5)...)
		stream = append(stream, after...)

		host := other
		if host == "" {
			host = fuzzCase(name, caseFlags)
			if dot {
				host += "."
			}
		}
		for _, enforce := range []bool{true, false} {
			run := runChecked(t, host, enforce, writes(stream, sizes))
			if sameHost(name, host) {
				if len(run.logs) != 0 || run.failed >= 0 || !bytes.Equal(run.forwarded, stream) {
					t.Fatalf("%q for %q: logged %v, failed %d, forwarded %d of %d", name, host, run.logs, run.failed, len(run.forwarded), len(stream))
				}
				continue
			}
			if len(run.logs) != 1 || run.logs[0]["reason"] != "mismatch" || run.logs[0]["tls_name"] != name {
				t.Fatalf("%q for %q: logged %v", name, host, run.logs)
			}
			if enforce && (len(run.forwarded) != 0 || run.failed < 0) {
				t.Fatalf("%q for %q: forwarded %d, failed %d", name, host, len(run.forwarded), run.failed)
			}
		}
	})
}

// sameHost by its documentation: equal once one trailing dot is dropped
// from each and ASCII letters are lowercased, and not empty.
func FuzzSameHost(f *testing.F) {
	for _, s := range [][2]string{
		{"Ab.example", "ab.example."}, {"K.example", "k.example"}, {"K.example", "k.example"},
		{"", "."}, {"a..", "a."}, {"allowed.example", "allowed.example.evil"}, {"é", "É"}, {"\xff", "\xff."},
	} {
		f.Add(s[0], s[1])
	}
	// ASCII letters only, as against strings.ToLower and ToUpper.
	lower := func(s string) string {
		b := []byte(s)
		for i, c := range b {
			if 'A' <= c && c <= 'Z' {
				b[i] = c + 'a' - 'A'
			}
		}
		return string(b)
	}
	upper := func(s string) string {
		b := []byte(s)
		for i, c := range b {
			if 'a' <= c && c <= 'z' {
				b[i] = c - ('a' - 'A')
			}
		}
		return string(b)
	}
	f.Fuzz(func(t *testing.T, a, b string) {
		got := sameHost(a, b)
		if got != sameHost(b, a) {
			t.Fatalf("sameHost(%q, %q) isn't symmetric", a, b)
		}
		ta, tb := strings.TrimSuffix(a, "."), strings.TrimSuffix(b, ".")
		if want := ta != "" && lower(ta) == lower(tb); got != want {
			t.Fatalf("sameHost(%q, %q) = %v", a, b, got)
		}
		// Where they match, every byte but an ASCII letter's case is the
		// same: no other fold, such as the Kelvin sign's into k.
		if got {
			for i := 0; i < len(ta); i++ {
				if ta[i] != tb[i] && lower(ta[i:i+1]) != lower(tb[i:i+1]) {
					t.Fatalf("sameHost(%q, %q) matched byte %d", a, b, i)
				}
			}
		}
		// A name matches itself in another case, and with a dot added.
		if ta != "" {
			if !sameHost(a, upper(a)) || !sameHost(lower(a), a) {
				t.Fatalf("sameHost(%q) in another case", a)
			}
		}
		if ta != "" && !strings.HasSuffix(ta, ".") {
			if !sameHost(ta, ta+".") {
				t.Fatalf("sameHost(%q, %q.)", ta, ta)
			}
			if sameHost(ta, ta+"..") {
				t.Fatalf("sameHost ignored two trailing dots of %q..", ta)
			}
		}
	})
}

// printable's output is printable ASCII, at most 253 bytes, and what it was
// given when that was already so.
func FuzzPrintable(f *testing.F) {
	for _, s := range []string{"", "a\x1b]0;x\x07bé", "allowed.example", strings.Repeat("a", 300), strings.Repeat("é", 200), "\xff\xfe", " \x7f"} {
		f.Add(s)
	}
	ok := regexp.MustCompile(`^[\x21-\x7e]*$`)
	f.Fuzz(func(t *testing.T, s string) {
		p := printable(s)
		if !ok.MatchString(p) || len(p) > 253 || len(p) > len(s) {
			t.Fatalf("printable(%q) = %q", s, p)
		}
		if ok.MatchString(s) && len(s) <= 253 && p != s {
			t.Fatalf("printable(%q) changed it to %q", s, p)
		}
	})
}

// The grammar of a limits file, as uploads.go documents it: each line
// blank, or a name and then a size in bytes (decimal digits) or off,
// separated by white space.
var limitsLine = regexp.MustCompile(`^([^\s\v]+)[\s\v]+([0-9]+|off)$`)

// FuzzReadUploadLimits: any file contents read without a panic, and are
// accepted, with the same entries, exactly when every line is in the grammar.
func FuzzReadUploadLimits(f *testing.F) {
	for _, s := range []string{
		"default 1000\n*.example.com off\ngithub.com 2000\n",
		"default\n", "default 1G\n", "a b 1\n", "x -1\n", "x +1\n", "x -0\n", "x 0\n",
		"x 9223372036854775807\n", "x 9223372036854775808\n", "\n\n  \t\nx 1", "x\t1\r\n", "x 1\n",
	} {
		f.Add([]byte(s))
	}
	if b, err := os.ReadFile("../upload-limits.txt"); err == nil {
		f.Add(b) // sizes with K/M/G and comments: refused
	}
	dir := f.TempDir()
	f.Fuzz(func(t *testing.T, data []byte) {
		// bufio.Scanner refuses a line of 64K or more; keep away from it.
		if len(data) >= 60000 {
			return
		}
		path := filepath.Join(dir, "upload-limits")
		if err := os.WriteFile(path, data, 0o600); err != nil {
			t.Fatal(err)
		}
		got, err := readUploadLimits(path)
		// The regexp's white space is ASCII; the reader's is Unicode's.
		// A file with other white space proves nothing either way.
		if strings.IndexFunc(string(data), isOtherSpace) >= 0 {
			return
		}

		want, valid := map[string]int64{}, true
		lines := strings.Split(string(data), "\n")
		for _, l := range lines {
			l = strings.TrimSpace(strings.TrimSuffix(l, "\r"))
			if l == "" {
				continue
			}
			m := limitsLine.FindStringSubmatch(l)
			if m == nil {
				valid = false
				break
			}
			n := int64(0)
			if m[2] != "off" {
				var perr error
				if n, perr = strconv.ParseInt(m[2], 10, 64); perr != nil {
					valid = false
					break
				}
			}
			want[m[1]] = n
		}
		if valid != (err == nil) {
			t.Fatalf("%q: read %v, %v; in the grammar: %v", data, got, err, valid)
		}
		if valid && !mapsEqual(got, want) {
			t.Fatalf("%q: read %v, want %v", data, got, want)
		}
	})
}

func isOtherSpace(r rune) bool {
	return r > 0x7f && strings.TrimSpace(string(r)) == ""
}

func mapsEqual(a, b map[string]int64) bool {
	if len(a) != len(b) {
		return false
	}
	for k, v := range a {
		if w, ok := b[k]; !ok || w != v {
			return false
		}
	}
	return true
}

// covers says whether the wildcard k ("*.d") covers host: a name under d,
// not d itself.
func covers(k, host string) bool {
	return strings.HasPrefix(k, "*.") && strings.HasSuffix(host, "."+k[2:])
}

// longestCover is the longest wildcard among keys that covers host, or "".
func longestCover(keys []string, host string) string {
	best := ""
	for _, k := range keys {
		if covers(k, host) && len(k) > len(best) {
			best = k
		}
	}
	return best
}

// FuzzLimitFor: for any limits and allowlist wildcards (one name per line;
// a name is in the allowlist too when its line ends in " +"), the limit a
// host gets is its own entry's, else the longest covering wildcard's, else
// the default's, every time; and its count is that entry's, unless it is
// the default, which is counted under the longest allowlist wildcard that
// covers it, else by host.
func FuzzLimitFor(f *testing.F) {
	limits := "default\ngithub.com\n*.github.com\n*.api.github.com\nuploads.github.com"
	for _, h := range []string{"github.com", "api.github.com", "x.api.github.com", "uploads.github.com", "evilgithub.com", "example.com", "github.com.evil.test"} {
		f.Add(limits, h)
	}
	f.Add("*.example.com", "example.com")
	f.Add("*.example.com", "a.example.com")
	f.Add("default\n*.cdn.example +\n*.sub.cdn.example +\n*.limited.example\n*.limited.example +", "a.sub.cdn.example")
	f.Add("*.\n*..b", "a..b")
	f.Fuzz(func(t *testing.T, entries, host string) {
		lim := map[string]int64{}
		var keys, allowKeys []string
		for i, l := range strings.Split(entries, "\n") {
			allowed := strings.HasSuffix(l, " +")
			l = strings.TrimSuffix(l, " +")
			if allowed {
				allowKeys = append(allowKeys, l)
				continue
			}
			lim[l] = int64(i + 1)
			keys = append(keys, l)
		}
		w := newUploadWatch(lim, false, nil, logrus.New())
		for _, k := range allowKeys {
			w.allow[k] = true
		}
		key, n := w.limitFor(host)
		if k2, n2 := w.limitFor(host); k2 != key || n2 != n {
			t.Fatalf("limitFor(%q): %q %d, then %q %d", host, key, n, k2, n2)
		}
		want := host
		if _, own := lim[host]; !own {
			if want = longestCover(keys, host); want == "" {
				want = "default"
			}
		}
		if key != want || n != lim[want] {
			t.Fatalf("limitFor(%q) = %q %d, want %q %d (limits %v)", host, key, n, want, lim[want], lim)
		}
		if key != host && key != "default" && (!covers(key, host) || host == key[2:]) {
			t.Fatalf("limitFor(%q) = %q, which doesn't cover it", host, key)
		}
		name := w.countFor(host, key)
		wantName := key
		if key == "default" {
			if wantName = longestCover(allowKeys, host); wantName == "" {
				wantName = host
			}
		}
		if name != wantName {
			t.Fatalf("countFor(%q, %q) = %q, want %q (allowlist %v)", host, key, name, wantName, allowKeys)
		}
	})
}
