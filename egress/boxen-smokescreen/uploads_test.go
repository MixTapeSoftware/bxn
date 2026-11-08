// egress/boxen-smokescreen/uploads_test.go
// The upload watch, with a fake clock: counted across tunnels, the hour's
// window, which limit applies and which count it goes to, the bound on the
// counts, one log line per crossing, the cap on and off, report mode, and the
// TLS name check alongside it.
package main

import (
	"bytes"
	"context"
	"crypto/tls"
	"encoding/json"
	"fmt"
	"io"
	"net"
	"net/http"
	"net/http/httptest"
	"net/url"
	"os"
	"path/filepath"
	"strings"
	"sync/atomic"
	"testing"
	"time"

	"github.com/sirupsen/logrus"
	"github.com/stripe/goproxy"
	"github.com/stripe/smokescreen/pkg/smokescreen"
	"github.com/stripe/smokescreen/pkg/smokescreen/conntrack"
	"github.com/stripe/smokescreen/pkg/smokescreen/metrics"
)

type fakeClock struct{ t time.Time }

func (c *fakeClock) now() time.Time { return c.t }

// watch returns a watch on a fake clock and the buffer its log goes to.
func watch(limits map[string]int64, cut bool) (*uploadWatch, *fakeClock, *bytes.Buffer) {
	clock := &fakeClock{t: time.Date(2026, 11, 6, 10, 0, 30, 0, time.UTC)}
	logs := &bytes.Buffer{}
	logger := logrus.New()
	logger.Out = logs
	logger.Formatter = &logrus.JSONFormatter{}
	return newUploadWatch(limits, cut, clock.now, logger), clock, logs
}

// uploadLines are the BOXEN-UPLOAD-LIMIT lines logged.
func uploadLines(t *testing.T, logs *bytes.Buffer) []map[string]interface{} {
	t.Helper()
	var out []map[string]interface{}
	for _, l := range strings.Split(strings.TrimSpace(logs.String()), "\n") {
		var m map[string]interface{}
		if l == "" || json.Unmarshal([]byte(l), &m) != nil || m["msg"] != uploadMessage {
			continue
		}
		out = append(out, m)
	}
	return out
}

// watchedTunnel dials a loopback listener through the hook, as for a CONNECT
// to target, and returns the conn and what the listener receives.
func watchedTunnel(t *testing.T, mode string, w *uploadWatch, target string) (net.Conn, <-chan []byte) {
	t.Helper()
	l, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { l.Close() })
	got := make(chan []byte, 1)
	go func() {
		c, err := l.Accept()
		if err != nil {
			got <- nil
			return
		}
		b, _ := io.ReadAll(c)
		got <- b
	}()
	req := &http.Request{Method: http.MethodConnect, Host: target, URL: &url.URL{Host: target}}
	ctx := context.WithValue(context.Background(), goproxy.ProxyContextKey, &goproxy.ProxyCtx{Req: req})
	conn, err := tunnelDialer(mode, w, w.log)(ctx, "tcp", l.Addr().String(), time.Second)
	if err != nil {
		t.Fatal(err)
	}
	return conn, got
}

func TestLimitFor(t *testing.T) {
	w, _, _ := watch(map[string]int64{
		"default":            100,
		"github.com":         2000,
		"*.github.com":       3000,
		"*.api.github.com":   4000,
		"uploads.github.com": 0,
	}, false)
	for host, want := range map[string]struct {
		key   string
		limit int64
	}{
		"github.com":           {"github.com", 2000},       // its own entry
		"api.github.com":       {"*.github.com", 3000},     // *.github.com covers it
		"x.api.github.com":     {"*.api.github.com", 4000}, // the longer wildcard wins
		"uploads.github.com":   {"uploads.github.com", 0},  // off
		"evilgithub.com":       {"default", 100},           // no wildcard covers it
		"example.com":          {"default", 100},           // the default
		"github.com.evil.test": {"default", 100},
	} {
		if key, limit := w.limitFor(host); key != want.key || limit != want.limit {
			t.Errorf("limitFor(%s) = %s %d, want %s %d", host, key, limit, want.key, want.limit)
		}
	}
	w, _, _ = watch(map[string]int64{"*.example.com": 10}, false)
	if _, n := w.limitFor("example.com"); n != 0 {
		t.Error("a wildcard covers subdomains only, and with no default nothing else has a limit")
	}
	if _, n := w.limitFor("a.example.com"); n != 10 {
		t.Error("the wildcard didn't cover a subdomain")
	}
}

func TestCountsAcrossTunnelsAndLogsOnce(t *testing.T) {
	w, _, logs := watch(map[string]int64{"default": 1000}, false)
	a, gotA := watchedTunnel(t, "off", w, "up.example:443")
	b, gotB := watchedTunnel(t, "off", w, "UP.example.:443")
	chunk := bytes.Repeat([]byte("x"), 400)
	for _, c := range []net.Conn{a, b, a, b} {
		if err := send(c, chunk); err != nil {
			t.Fatalf("with the cap off a write failed: %v", err)
		}
	}
	if n := len(received(t, a, gotA)) + len(received(t, b, gotB)); n != 1600 {
		t.Fatalf("forwarded %d bytes, want 1600", n)
	}
	lines := uploadLines(t, logs)
	if len(lines) != 1 {
		t.Fatalf("want one line, got %q", logs.String())
	}
	m := lines[0]
	if m["connect_host"] != "up.example" || m["connect_port"] != float64(443) ||
		m["limit_key"] != "default" || m["counted_for"] != "up.example" ||
		m["window_bytes"] != float64(1200) || m["limit_bytes"] != float64(1000) || m["cut"] != false {
		t.Fatalf("log line %v", m)
	}
	if strings.Contains(logs.String(), "xxx") {
		t.Fatal("stream bytes were logged")
	}
}

func TestWindow(t *testing.T) {
	w, clock, logs := watch(map[string]int64{"default": 1000}, false)
	must := func(n int) {
		t.Helper()
		if err := w.add("up.example", 443, n); err != nil {
			t.Fatal(err)
		}
	}
	must(900)
	clock.t = clock.t.Add(30 * time.Minute)
	must(200) // 1100 in the hour: logged
	clock.t = clock.t.Add(20 * time.Minute)
	must(500) // still over, within the hour of the line: not logged again
	if n := len(uploadLines(t, logs)); n != 1 {
		t.Fatalf("%d lines within the hour, want 1", n)
	}
	clock.t = clock.t.Add(11 * time.Minute)
	// The first 900 has aged out: 700 in the hour.
	if got := w.counts["up.example"].sent(clock.t.Unix() / 60); got != 700 {
		t.Fatalf("sent %d in the hour, want 700", got)
	}
	must(200) // 900: under
	clock.t = clock.t.Add(30 * time.Minute)
	// 700 again; the line's hour is over.
	must(400) // 1100: over again
	lines := uploadLines(t, logs)
	if len(lines) != 2 || lines[1]["window_bytes"] != float64(1100) {
		t.Fatalf("lines %v", lines)
	}
	if _, ok := w.counts["other.example"]; ok {
		t.Fatal("a host nothing was sent to has a count")
	}
}

func TestNoLimitCountsNothing(t *testing.T) {
	w, _, logs := watch(map[string]int64{"default": 0, "small.example": 10}, true)
	if err := w.add("big.example", 443, 1<<30); err != nil || len(w.counts) != 0 || logs.Len() != 0 {
		t.Fatal("a host with no limit was counted")
	}
}

// Hosts a limit's wildcard covers share its count, so an upload spread over
// many names under it gets the limit once, not once per name.
func TestWildcardSharesCount(t *testing.T) {
	w, _, logs := watch(map[string]int64{"default": 1 << 30, "*.example.com": 1000, "own.example.com": 1000}, true)
	for i := 0; i < 9; i++ {
		if err := w.add(fmt.Sprintf("n%d.example.com", i), 443, 100); err != nil {
			t.Fatalf("name %d: %v", i, err)
		}
	}
	if err := w.add("n99.example.com", 443, 200); err != errUploadCut {
		t.Fatalf("a tenth name took the wildcard past its limit: %v", err)
	}
	// A host with its own entry has its own count.
	if err := w.add("own.example.com", 443, 1000); err != nil {
		t.Fatalf("a host with its own entry was counted with the wildcard: %v", err)
	}
	if len(w.counts) != 2 || w.counts["*.example.com"] == nil {
		t.Fatalf("counts %v", w.counts)
	}
	lines := uploadLines(t, logs)
	if len(lines) != 1 {
		t.Fatalf("lines %v", lines)
	}
	if m := lines[0]; m["connect_host"] != "n99.example.com" || m["limit_key"] != "*.example.com" ||
		m["counted_for"] != "*.example.com" || m["window_bytes"] != float64(900) || m["cut"] != true {
		t.Fatalf("log line %v", m)
	}
}

// aclFile loads an allowlist as boxen-egress-ctl writes it, through
// smokescreen's own loader.
func aclFile(t *testing.T, domains ...string) *smokescreen.Config {
	t.Helper()
	y := "version: v1\nservices: []\ndefault:\n  project: bxn\n  action: enforce\n  allowed_domains:\n"
	for _, d := range domains {
		y += "    - \"" + d + "\"\n"
	}
	path := filepath.Join(t.TempDir(), "acl.yaml")
	if err := os.WriteFile(path, []byte(y), 0o644); err != nil {
		t.Fatal(err)
	}
	conf := smokescreen.NewConfig()
	if err := conf.SetupEgressAcl(path); err != nil {
		t.Fatal(err)
	}
	return conf
}

// Hosts with the default limit under one wildcard of the allowlist share a
// count; hosts the allowlist names one by one each have their own.
func TestAllowlistWildcardSharesDefault(t *testing.T) {
	w, _, logs := watch(map[string]int64{"default": 1000, "*.limited.example": 5000}, true)
	w.allowWildcards(aclFile(t, "*.cdn.example", "*.sub.cdn.example", "one.example", "two.example", "*.limited.example").EgressACL)
	for i := 0; i < 10; i++ {
		if err := w.add(fmt.Sprintf("x%d.cdn.example", i), 443, 100); err != nil {
			t.Fatalf("name %d: %v", i, err)
		}
	}
	if err := w.add("x10.cdn.example", 443, 1); err != errUploadCut {
		t.Fatalf("an eleventh name under the allowlist's wildcard went past the default: %v", err)
	}
	// The longest wildcard of the allowlist has its own count.
	if err := w.add("a.sub.cdn.example", 443, 1000); err != nil {
		t.Fatalf("the longer wildcard was counted with the shorter: %v", err)
	}
	// A wildcard in the limits wins over one in the allowlist.
	if err := w.add("a.limited.example", 443, 4000); err != nil {
		t.Fatalf("the limits' wildcard didn't apply: %v", err)
	}
	for _, h := range []string{"one.example", "two.example"} {
		if err := w.add(h, 443, 1000); err != nil {
			t.Fatalf("%s was counted with another host: %v", h, err)
		}
	}
	for _, name := range []string{"*.cdn.example", "*.sub.cdn.example", "*.limited.example", "one.example", "two.example"} {
		if w.counts[name] == nil {
			t.Errorf("no count for %s in %v", name, w.counts)
		}
	}
	if len(w.counts) != 5 {
		t.Fatalf("counts %v", w.counts)
	}
	lines := uploadLines(t, logs)
	if len(lines) != 1 {
		t.Fatalf("lines %v", lines)
	}
	if m := lines[0]; m["connect_host"] != "x10.cdn.example" || m["limit_key"] != "default" ||
		m["counted_for"] != "*.cdn.example" || m["window_bytes"] != float64(1000) {
		t.Fatalf("log line %v", m)
	}
	// No allowlist, or not one smokescreen loaded: nothing changes.
	w.allowWildcards(nil)
}

// Hosts with the default each get a count only up to uploadMaxCounts; the
// rest share one, and counts with nothing in the hour make room again.
func TestCountsBounded(t *testing.T) {
	w, clock, logs := watch(map[string]int64{"default": 1000, "big.example": 5000, "*.wild.example": 5000}, false)
	for i := 0; i < uploadMaxCounts; i++ {
		if err := w.add(fmt.Sprintf("h%d.example", i), 443, 1); err != nil {
			t.Fatal(err)
		}
	}
	for i := 0; i < 20; i++ {
		w.add(fmt.Sprintf("more%d.example", i), 443, 60)
	}
	if len(w.counts) != uploadMaxCounts {
		t.Fatalf("%d counts, want %d", len(w.counts), uploadMaxCounts)
	}
	if got := w.overflow.sent(clock.t.Unix() / 60); got != 1200 {
		t.Fatalf("the overflow count has %d, want 1200", got)
	}
	lines := uploadLines(t, logs)
	if len(lines) != 1 || lines[0]["counted_for"] != overflowCount || lines[0]["limit_key"] != "default" ||
		lines[0]["window_bytes"] != float64(1020) || lines[0]["connect_host"] != "more16.example" {
		t.Fatalf("lines %v", lines)
	}
	// A host with its own entry or under a limit's wildcard still gets its
	// own count: there are only as many as there are entries.
	w.add("big.example", 443, 4000)
	w.add("a.wild.example", 443, 4000)
	if w.counts["big.example"] == nil || w.counts["*.wild.example"] == nil {
		t.Fatal("an entry's count went to the overflow")
	}
	// An hour on, the idle counts are dropped and a new host has its own.
	clock.t = clock.t.Add(61 * time.Minute)
	if err := w.add("new.example", 443, 1); err != nil {
		t.Fatal(err)
	}
	if len(w.counts) != 1 || w.counts["new.example"] == nil {
		t.Fatalf("%d counts after the hour", len(w.counts))
	}
}

func TestCapCuts(t *testing.T) {
	w, clock, logs := watch(map[string]int64{"default": 1000}, true)
	a, gotA := watchedTunnel(t, "off", w, "up.example:443")
	if err := send(a, make([]byte, 800)); err != nil {
		t.Fatal(err)
	}
	if err := send(a, make([]byte, 300)); err != errUploadCut {
		t.Fatalf("the write past the limit returned %v", err)
	}
	if n := len(received(t, a, gotA)); n != 800 {
		t.Fatalf("forwarded %d bytes, want 800", n)
	}
	// Another tunnel to the host can't send past the limit either, and
	// another host isn't affected.
	b, gotB := watchedTunnel(t, "off", w, "up.example:443")
	if send(b, make([]byte, 300)) == nil {
		t.Fatal("a new tunnel went past the limit")
	}
	received(t, b, gotB)
	if err := w.add("other.example", 443, 900); err != nil {
		t.Fatal("another host was cut")
	}
	lines := uploadLines(t, logs)
	if len(lines) != 1 || lines[0]["cut"] != true || lines[0]["window_bytes"] != float64(800) {
		t.Fatalf("lines %v", lines)
	}
	// Once the hour has moved on there is room again.
	clock.t = clock.t.Add(61 * time.Minute)
	if err := w.add("up.example", 443, 900); err != nil {
		t.Fatalf("still cut an hour later: %v", err)
	}
}

func TestFromEnv(t *testing.T) {
	path := filepath.Join(t.TempDir(), "upload-limits")
	if err := os.WriteFile(path, []byte("default 1000\n*.example.com off\ngithub.com 2000\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	t.Setenv("BOXEN_UPLOAD_LIMITS", path)
	for _, tc := range []struct {
		capped  string
		enforce bool
		cut     bool
	}{
		{"on", true, true},
		{"on", false, false}, // report mode only logs
		{"off", true, false},
		{"", true, false},
	} {
		t.Setenv("BOXEN_UPLOAD_CAP", tc.capped)
		w, err := uploadWatchFromEnv(tc.enforce)
		if err != nil || w == nil || w.cut != tc.cut {
			t.Fatalf("cap %q enforce %v: %v, %v", tc.capped, tc.enforce, w, err)
		}
		if w.limits["default"] != 1000 || w.limits["*.example.com"] != 0 || w.limits["github.com"] != 2000 {
			t.Fatalf("limits %v", w.limits)
		}
	}
	t.Setenv("BOXEN_UPLOAD_CAP", "yes")
	if _, err := uploadWatchFromEnv(true); err == nil {
		t.Fatal("an unknown cap value was accepted")
	}
	t.Setenv("BOXEN_UPLOAD_CAP", "")
	for _, bad := range []string{"default\n", "default 1G\n", "a b 1\n", "x -1\n"} {
		os.WriteFile(path, []byte(bad), 0o644)
		if _, err := uploadWatchFromEnv(true); err == nil {
			t.Fatalf("accepted %q", bad)
		}
	}
	t.Setenv("BOXEN_UPLOAD_LIMITS", "")
	if w, err := uploadWatchFromEnv(true); w != nil || err != nil {
		t.Fatal("no limits file should mean no watch")
	}
}

func TestNameCheckStillEnforced(t *testing.T) {
	w, _, logs := watch(map[string]int64{"default": 1 << 20}, true)
	conn, got := watchedTunnel(t, "enforce", w, "allowed.example:443")
	if send(conn, hello(t, "other.example")) == nil {
		t.Fatal("another name got through with the watch on")
	}
	if b := received(t, conn, got); len(b) != 0 {
		t.Fatalf("forwarded %d bytes", len(b))
	}
	if !strings.Contains(logs.String(), `"msg":"`+logMessage+`"`) {
		t.Fatalf("no name check line in %s", logs.String())
	}
	// A matching name is counted, ClientHello included, and cut at the limit.
	h := hello(t, "allowed.example")
	conn, got = watchedTunnel(t, "enforce", w, "allowed.example:443")
	if err := send(conn, h, make([]byte, 1<<20-len(h))); err != nil {
		t.Fatal(err)
	}
	if send(conn, []byte("x")) != errUploadCut {
		t.Fatal("not cut at the limit")
	}
	if n := len(received(t, conn, got)); n != 1<<20 {
		t.Fatalf("forwarded %d bytes", n)
	}
	if lines := uploadLines(t, logs); len(lines) != 1 || lines[0]["cut"] != true {
		t.Fatalf("lines %v", lines)
	}
}

// Through smokescreen: the cap closes a tunnel mid-upload, and smokescreen's
// own close record counts the client's bytes as bytes_out, which is what
// `bxn egress log --uploads` adds up.
func TestCapThroughSmokescreen(t *testing.T) {
	var got int64
	site := httptest.NewTLSServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		n, _ := io.Copy(io.Discard, r.Body)
		atomic.AddInt64(&got, n)
	}))
	defer site.Close()
	_, port, _ := net.SplitHostPort(site.Listener.Addr().String())

	logs := &syncBuffer{}
	conf := smokescreen.NewConfig()
	conf.Log.Out = logs
	conf.Log.Formatter = &logrus.JSONFormatter{}
	conf.AllowMissingRole = true
	if err := conf.SetAllowAddresses([]string{"127.0.0.1"}); err != nil {
		t.Fatal(err)
	}
	conf.ConnTracker = conntrack.NewTracker(conf.IdleTimeout, metrics.NewNoOpMetricsClient(), conf.Log, atomic.Value{}, nil)
	w := newUploadWatch(map[string]int64{"default": 64 << 10}, true, time.Now, conf.Log)
	conf.ProxyDialTimeout = tunnelDialer("enforce", w, conf.Log)
	proxy := httptest.NewServer(smokescreen.BuildProxy(conf))
	defer proxy.Close()

	post := func(n int) error {
		proxyURL, _ := url.Parse(proxy.URL)
		tr := &http.Transport{Proxy: http.ProxyURL(proxyURL), TLSClientConfig: &tls.Config{ServerName: "localhost", InsecureSkipVerify: true}}
		defer tr.CloseIdleConnections()
		c := &http.Client{Timeout: 5 * time.Second, Transport: tr}
		resp, err := c.Post("https://localhost:"+port+"/", "application/octet-stream", bytes.NewReader(make([]byte, n)))
		if err == nil {
			resp.Body.Close()
		}
		return err
	}
	if err := post(10 << 10); err != nil {
		t.Fatalf("a small upload failed: %v", err)
	}
	if err := post(256 << 10); err == nil {
		t.Fatal("an upload past the limit got through")
	}
	// The site read the first body and part of the second, up to the cut.
	if n := atomic.LoadInt64(&got); n < 10<<10 || n >= 64<<10 {
		t.Fatalf("the site got %d bytes", n)
	}
	deadline := time.Now().Add(5 * time.Second)
	for !strings.Contains(logs.String(), `"msg":"`+uploadMessage+`"`) ||
		strings.Count(logs.String(), conntrack.CanonicalProxyConnClose) < 2 {
		if time.Now().After(deadline) {
			t.Fatalf("missing log lines in %s", logs.String())
		}
		time.Sleep(50 * time.Millisecond)
	}
	var out []float64
	for _, l := range strings.Split(logs.String(), "\n") {
		var m map[string]interface{}
		if json.Unmarshal([]byte(l), &m) == nil && m["msg"] == conntrack.CanonicalProxyConnClose {
			out = append(out, m["bytes_out"].(float64))
		}
	}
	// The first tunnel sent the 10K body and TLS framing; the second was cut
	// before 64K.
	if len(out) != 2 || out[0] < 10<<10 || out[0]+out[1] > 64<<10 {
		t.Fatalf("bytes_out %v", out)
	}
}
