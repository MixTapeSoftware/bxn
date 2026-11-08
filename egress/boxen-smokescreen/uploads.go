// egress/boxen-smokescreen/uploads.go
// The upload watch: an early warning for bulk uploads to an allowed host. The
// proxy can't see what a tunnel carries, but it sees how much. It counts the
// bytes the client sends through CONNECT tunnels, across every tunnel of this
// proxy process, over the trailing hour (in one-minute slots), against the
// limit that applies to the tunnel's host. The first time a count goes over
// its limit, it writes one log line; it writes no other for that count until
// an hour has passed.
//
// What shares a count, so that spreading an upload over many names doesn't
// multiply the limit:
//   - a host with its own entry in the limits has a count of its own;
//   - hosts a wildcard entry ("*.example.com") covers share that wildcard's
//     count, so the wildcard's limit is for all of them together;
//   - any other host gets the default limit, with a count of its own, except
//     that hosts under one wildcard of the allowlist share a count, since
//     the allowlist lets a container make up any number of such names.
//
// The counts are kept for at most uploadMaxCounts hosts with the default.
// Past that, once hosts with nothing in the hour have been dropped, any other
// such host is counted in one shared overflow count with the default limit:
// counting them together is stricter, never looser.
//
// With the cap on (and the mode enforce), a write that would take a count over
// its limit fails instead, which closes its tunnel, and so does every write
// counted there until enough of the hour's bytes have aged out.
//
// The counts live in memory: a new generation starts from zero, and a
// draining one keeps its own.
//
// boxen-proxy-run sets BOXEN_UPLOAD_LIMITS to the generation's limits file,
// one "<host>|*.<domain>|default <bytes>|off" per line, and BOXEN_UPLOAD_CAP
// to on or off.
package main

import (
	"bufio"
	"errors"
	"fmt"
	"net"
	"os"
	"strconv"
	"strings"
	"sync"
	"time"

	"github.com/sirupsen/logrus"
	acl "github.com/stripe/smokescreen/pkg/smokescreen/acl/v1"
)

// The one log line for a count over its limit; boxen-egress-ctl looks for it.
const uploadMessage = "BOXEN-UPLOAD-LIMIT"

const uploadSlots = 60 // one per minute of the hour

// How many hosts with the default limit get a count of their own. Counts
// with nothing in the hour are dropped to make room, at most once a minute.
const uploadMaxCounts = 10000

// The name the log gives the shared count for hosts past uploadMaxCounts.
const overflowCount = "overflow"

var errUploadCut = errors.New("boxen: tunnel closed by the upload cap")

type uploadWatch struct {
	limits map[string]int64 // host, "*.domain" or "default"; 0 is off
	allow  map[string]bool  // the allowlist's wildcards, as "*.domain"
	cut    bool
	now    func() time.Time
	log    *logrus.Logger

	mu       sync.Mutex
	counts   map[string]*hostUploads // by host or "*.domain"
	overflow hostUploads
	pruned   int64 // the minute counts were last pruned
}

// One count's bytes per minute, in a ring indexed by Unix minute.
type hostUploads struct {
	minute [uploadSlots]int64
	bytes  [uploadSlots]int64
	quiet  time.Time // no other log line before this
}

// uploadWatchFromEnv reads the limits and the cap that boxen-proxy-run sets.
// It returns nil when there are no limits, so nothing is counted. The caller
// sets its logger and the allowlist.
func uploadWatchFromEnv(enforce bool) (*uploadWatch, error) {
	capped := os.Getenv("BOXEN_UPLOAD_CAP")
	if capped != "" && capped != "on" && capped != "off" {
		return nil, fmt.Errorf("BOXEN_UPLOAD_CAP must be on or off, not %q", capped)
	}
	path := os.Getenv("BOXEN_UPLOAD_LIMITS")
	if path == "" {
		return nil, nil
	}
	limits, err := readUploadLimits(path)
	if err != nil {
		return nil, err
	}
	return newUploadWatch(limits, enforce && capped == "on", time.Now, nil), nil
}

func newUploadWatch(limits map[string]int64, cut bool, now func() time.Time, logger *logrus.Logger) *uploadWatch {
	return &uploadWatch{limits: limits, allow: map[string]bool{}, cut: cut, now: now, log: logger, counts: map[string]*hostUploads{}}
}

// allowWildcards takes the wildcards from smokescreen's allowlist, so that
// the hosts under each share a count. Call it before the proxy starts.
func (w *uploadWatch) allowWildcards(d acl.Decider) {
	a, ok := d.(*acl.ACL)
	if !ok || a == nil {
		return
	}
	globs := append([]string(nil), a.GlobalAllowList...)
	if a.DefaultRule != nil {
		globs = append(globs, a.DefaultRule.DomainGlobs...)
	}
	for _, r := range a.Rules {
		globs = append(globs, r.DomainGlobs...)
	}
	for _, g := range globs {
		g = strings.ToLower(strings.TrimSuffix(g, "."))
		if strings.HasPrefix(g, "*.") && len(g) > 2 {
			w.allow[g] = true
		}
	}
}

func readUploadLimits(path string) (map[string]int64, error) {
	f, err := os.Open(path)
	if err != nil {
		return nil, err
	}
	defer f.Close()
	limits := map[string]int64{}
	s := bufio.NewScanner(f)
	for line := 1; s.Scan(); line++ {
		w := strings.Fields(s.Text())
		if len(w) == 0 {
			continue
		}
		n, err := strconv.ParseInt(w[len(w)-1], 10, 64)
		if w[len(w)-1] == "off" {
			n, err = 0, nil
		}
		if len(w) != 2 || err != nil || n < 0 {
			return nil, fmt.Errorf("%s line %d: want <host> <bytes>|off", path, line)
		}
		limits[w[0]] = n
	}
	return limits, s.Err()
}

// wildcardFor is the longest wildcard in set that covers host ("*.d" covers
// subdomains of d, not d itself, as in the allowlist), or "".
func wildcardFor(set func(string) bool, host string) string {
	for d := host; strings.Contains(d, "."); {
		d = d[strings.Index(d, ".")+1:]
		if set("*." + d) {
			return "*." + d
		}
	}
	return ""
}

// limitFor is host's limit and the entry it comes from: its own entry, else
// the longest wildcard that covers it, else "default". 0 means no limit.
func (w *uploadWatch) limitFor(host string) (string, int64) {
	if n, ok := w.limits[host]; ok {
		return host, n
	}
	has := func(k string) bool { _, ok := w.limits[k]; return ok }
	if k := wildcardFor(has, host); k != "" {
		return k, w.limits[k]
	}
	return "default", w.limits["default"]
}

// countFor names the count host's bytes go to, given the entry its limit
// comes from: the entry itself, unless that is the default, which is counted
// per host or per wildcard of the allowlist.
func (w *uploadWatch) countFor(host, key string) string {
	if key != "default" {
		return key
	}
	if k := wildcardFor(func(k string) bool { return w.allow[k] }, host); k != "" {
		return k
	}
	return host
}

// add decides on n more bytes for host. It counts them and returns nil, or,
// when the cap is on and they would take host's count over its limit, counts
// nothing and returns an error.
func (w *uploadWatch) add(host string, port, n int) error {
	key, limit := w.limitFor(host)
	if limit == 0 {
		return nil
	}
	name := w.countFor(host, key)
	w.mu.Lock()
	defer w.mu.Unlock()
	now := w.now()
	m := now.Unix() / 60
	h := w.counts[name]
	if h == nil {
		// Only hosts with the default and no allowlist wildcard can be
		// any number; entries and wildcards are as many as their files.
		bounded := key != "default" || name != host
		if !bounded && len(w.counts) >= uploadMaxCounts && w.pruned != m {
			w.prune(now, m)
			w.pruned = m
		}
		if bounded || len(w.counts) < uploadMaxCounts {
			h = &hostUploads{}
			w.counts[name] = h
		} else {
			h, name = &w.overflow, overflowCount
		}
	}
	sent := h.sent(m)
	if sent+int64(n) <= limit {
		h.count(m, int64(n))
		return nil
	}
	if w.cut {
		w.report(h, now, host, port, key, name, sent, limit)
		return errUploadCut
	}
	h.count(m, int64(n))
	w.report(h, now, host, port, key, name, sent+int64(n), limit)
	return nil
}

// report writes the count's log line, at most once an hour: the host whose
// write crossed the limit, the entry the limit comes from, the count it went
// to (the host, a wildcard, or the overflow), what that count was sent in the
// hour, the limit and whether the tunnel was cut. Never bytes of the stream.
func (w *uploadWatch) report(h *hostUploads, now time.Time, host string, port int, key, name string, sent, limit int64) {
	if now.Before(h.quiet) {
		return
	}
	h.quiet = now.Add(uploadSlots * time.Minute)
	w.log.WithFields(logrus.Fields{
		"connect_host": printable(host),
		"connect_port": port,
		"limit_key":    printable(key),
		"counted_for":  printable(name),
		"window_bytes": sent,
		"limit_bytes":  limit,
		"cut":          w.cut,
	}).Warn(uploadMessage)
}

// sent is the count's total for the hour up to minute m.
func (h *hostUploads) sent(m int64) int64 {
	var t int64
	for i := range h.bytes {
		if h.minute[i] > m-uploadSlots {
			t += h.bytes[i]
		}
	}
	return t
}

func (h *hostUploads) count(m, n int64) {
	i := m % uploadSlots
	if h.minute[i] != m {
		h.minute[i], h.bytes[i] = m, 0
	}
	h.bytes[i] += n
}

// prune drops counts with nothing in the hour and no log line to hold back.
func (w *uploadWatch) prune(now time.Time, m int64) {
	for name, h := range w.counts {
		if h.sent(m) == 0 && !now.Before(h.quiet) {
			delete(w.counts, name)
		}
	}
}

// countedConn passes each write the client sends through the watch.
type countedConn struct {
	net.Conn
	host  string
	port  int
	watch *uploadWatch
}

func (c *countedConn) Write(b []byte) (int, error) {
	if err := c.watch.add(c.host, c.port, len(b)); err != nil {
		return 0, err
	}
	return c.Conn.Write(b)
}
