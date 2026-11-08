"""Property-based, stateful test of the proxy-generation lifecycle in
egress/boxen-egress-ctl.

Hypothesis drives the real ctl through random sequences of add, gen, check,
widen, tighten, stop, remove, reboot and boot, with injected faults (a check
that fails, a generation that won't start or never acks, a stop that leaves a
generation running, the ctl killed partway through) and two commands at once.
The ctl runs against tests/lib/fake_systemd in a sandbox, set up the way
tests/egress_ctl_state_test.sh does it.

After every step the invariants below are checked against the sandbox: the
files under ETC, the fake's unit states and journal, and `ctl status`. A small
model of the expected state is compared too, but each invariant reads the
sandbox, so a wrong model can't hide a wrong ctl.

Run through tests/property_test.sh, or: python3 tests/property/test_egress_ctl.py
Settings: BOXEN_PROPERTY_EXAMPLES, BOXEN_PROPERTY_STEPS, BOXEN_PROPERTY_SEED
(an integer, or "random" to explore and keep failures in .hypothesis/),
BOXEN_PROPERTY_SHRINK=0 (report the first failure as found; shrinking a long
sequence can take many minutes), BOXEN_PROPERTY_STATS=1 (count what ran),
BOXEN_PROPERTY_CTL (a ctl other than egress/boxen-egress-ctl).
"""

import collections
import copy
import hashlib
import os
import re
import shutil
import subprocess
import sys
import tempfile
import time
from dataclasses import dataclass, field
from typing import Dict, FrozenSet, List, Optional, Set, Tuple

from hypothesis import HealthCheck, Phase, settings
from hypothesis import seed as hypothesis_seed
from hypothesis import strategies as st
from hypothesis.database import DirectoryBasedExampleDatabase
from hypothesis.stateful import (
    Bundle,
    RuleBasedStateMachine,
    initialize,
    invariant,
    multiple,
    rule,
    run_state_machine_as_test,
)

REPO = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
# BOXEN_PROPERTY_CTL runs another copy, e.g. a deliberately broken one.
CTL = os.environ.get("BOXEN_PROPERTY_CTL") or os.path.join(REPO, "egress", "boxen-egress-ctl")
FAKE = os.path.join(REPO, "tests", "lib", "fake_systemd")

MAX_DRAINING = 6  # the ctl's MAX_DRAINING
KEEP_GENS = 10  # gen keeps the newest ten directories
AGENTS = {"a": 4750, "b-c": 4751}
HOSTS = ["h1.example.com", "h2.example.com", "h3.example.com", "*.w.example.com", "x.w.example.com"]
# gen refuses these: the probe's own name, a wildcard over it, an address.
BAD_HOSTS = ["boxen-probe.invalid", "*.invalid", "1.2.3.4"]
MODES = ["enforce", "report", "off"]

GEN_RE = re.compile(r"^boxen-gen_(.+)@(\d+)\.service$")
CHECK_RE = re.compile(r"^boxen-check_(.+)@(\d+)\.service$")

OK, FAIL, KILLED = "ok", "fail", "killed"
# (command, fault, outcome) -> how often, printed at the end.
SEEN: collections.Counter = collections.Counter()


def argv(op: tuple) -> List[str]:
    """A step's command line: ("widen", agent, gen, force) -> widen agent gen [--force]."""
    if op[0] == "widen":
        return ["widen", op[1], str(op[2])] + (["--force"] if op[3] else [])
    return [str(x) for x in op]


def rc_class(rc: int) -> str:
    if rc == 0:
        return OK
    # Killed by a signal: Python reports -N.
    if rc < 0:
        return KILLED
    return FAIL


# --- faults ------------------------------------------------------------------


@dataclass(frozen=True)
class Fault:
    """One injected fault for one command, as fake_systemd knobs."""

    kind: str = "none"  # none curl_late die_check die_gen start_fail no_ack stuck
    agent: str = ""
    gen: int = 0
    signal: str = "KILL"

    def env(self) -> Dict[str, str]:
        gu = f"boxen-gen_{self.agent}@{self.gen}.service"
        cu = f"boxen-check_{self.agent}@{self.gen}.service"
        if self.kind == "curl_late":
            return {"FAKE_CURL_LATE": "1"}
        if self.kind == "die_check":
            return {"FAKE_SYSTEMD_DIE_AFTER": cu, "FAKE_SYSTEMD_DIE_SIGNAL": self.signal}
        if self.kind == "die_gen":
            return {"FAKE_SYSTEMD_DIE_AFTER": gu, "FAKE_SYSTEMD_DIE_SIGNAL": self.signal}
        if self.kind == "start_fail":
            return {"FAKE_SYSTEMD_START_FAIL": gu}
        if self.kind == "no_ack":
            return {"FAKE_SYSTEMD_NO_ACK": gu}
        if self.kind == "stuck":
            return {"FAKE_SYSTEMD_STUCK": gu}
        return {}

    def is_(self, kind: str, agent: str, gen: int) -> bool:
        return self.kind == kind and self.agent == agent and self.gen == gen


NONE = Fault()


# --- the model ---------------------------------------------------------------


@dataclass
class MAgent:
    port: int
    gens: Dict[int, Tuple[str, str, Tuple[str, ...]]] = field(default_factory=dict)
    current: Optional[int] = None
    running: Dict[int, str] = field(default_factory=dict)  # n -> active | draining
    stopping: Optional[FrozenSet[int]] = None
    hold: bool = True


class Model:
    """What the documented behaviour says the sandbox should hold."""

    def __init__(self) -> None:
        self.agents: Dict[str, MAgent] = {}
        self.checks: Set[Tuple[str, int]] = set()  # check copies left running

    # Starting a unit, as the fake does it.
    def _start_gen(self, a: str, n: int, f: Fault) -> str:
        A = self.agents[a]
        if n in A.running:
            return OK
        if f.is_("start_fail", a, n):
            return FAIL
        A.running[n] = "active"
        if f.is_("die_gen", a, n):
            return KILLED
        return OK

    def _stop(self, a: str, gens, f: Fault) -> None:
        A = self.agents[a]
        for g in list(gens):
            if g in A.running and not f.is_("stuck", a, g):
                del A.running[g]

    def _sigterm(self, a: str, gens) -> None:
        A = self.agents[a]
        for g in gens:
            if A.running.get(g) == "active":
                A.running[g] = "draining"

    def _stopping_left(self, a: str) -> List[int]:
        A = self.agents[a]
        if A.stopping is None:
            return []
        return [g for g in sorted(A.running) if g != A.current and g in A.stopping]

    def _finish_stopping(self, a: str, f: Fault) -> bool:
        A = self.agents[a]
        if A.stopping is None:
            return True
        self._stop(a, self._stopping_left(a), f)
        if self._stopping_left(a):
            return False
        A.stopping = None
        return True

    def _check(self, a: str, n: int, f: Fault) -> str:
        self.checks.clear()  # stop_checks: every leftover copy
        if f.is_("die_check", a, n):
            if f.signal == "KILL":  # SIGTERM runs the EXIT trap, which stops it
                self.checks.add((a, n))
            return KILLED
        if f.kind == "curl_late":
            return FAIL
        return OK

    def add(self, a: str, port: int) -> str:
        A = self.agents.get(a)
        if A is None:
            self.agents[a] = MAgent(port=port)
            return OK
        if A.port != port:
            return FAIL
        A.hold = True
        return OK

    def gen(self, a: str, mode: str, policy: str, hosts: List[str]) -> Tuple[str, Optional[int]]:
        A = self.agents.get(a)
        if A is None or any(h in BAD_HOSTS for h in hosts):
            return FAIL, None
        n = max(A.gens, default=0) + 1
        A.gens[n] = (mode, policy, tuple(hosts))
        for g in sorted(A.gens)[:-KEEP_GENS]:
            if g != A.current and g not in A.running:
                del A.gens[g]
        return OK, n

    def check(self, a: str, n: int, f: Fault) -> str:
        A = self.agents.get(a)
        if A is None or n not in A.gens:
            return FAIL
        return self._check(a, n, f)

    def widen(self, a: str, n: int, force: bool, f: Fault) -> str:
        A = self.agents.get(a)
        if A is None or n in A.running:
            return FAIL
        if not self._finish_stopping(a, f):
            return FAIL
        old = sorted(A.running)
        draining = [g for g in old if g != A.current]
        if len(draining) >= MAX_DRAINING and not force:
            return FAIL
        if n not in A.gens:
            return FAIL
        r = self._check(a, n, f)
        if r != OK:
            return r
        if len(draining) >= MAX_DRAINING:
            self._stop(a, [draining[0]], f)
            old.remove(draining[0])
        # Until it's current, the new generation is one that mustn't keep running.
        A.stopping = frozenset([n])
        r = self._start_gen(a, n, f)
        if r != OK:
            if r == FAIL:
                A.stopping = None
            return r
        if f.is_("no_ack", a, n):
            self._stop(a, [n], f)
            if n not in A.running:
                A.stopping = None
            return FAIL
        A.current = n
        self._sigterm(a, old)
        A.stopping = None
        return OK

    def tighten(self, a: str, n: int, f: Fault) -> str:
        A = self.agents.get(a)
        if A is None or n in A.running or n not in A.gens:
            return FAIL
        r = self._check(a, n, f)
        if r != OK:
            return r
        old = sorted(A.running)
        A.stopping = frozenset(old)
        A.current = n
        self._sigterm(a, old)
        r = self._start_gen(a, n, f)
        if r == KILLED:
            return r
        if r == FAIL or f.is_("no_ack", a, n):
            A.current = None
            self._stop(a, list(A.running), f)
            if not A.running:
                A.stopping = None
            return FAIL
        self._stop(a, old, f)
        if self._stopping_left(a):
            return FAIL
        A.stopping = None
        return OK

    def stop(self, a: str, f: Fault) -> str:
        A = self.agents.get(a)
        if A is None:
            return FAIL
        A.current = None
        self._stop(a, list(A.running), f)
        if A.running:
            return FAIL
        A.stopping = None
        return OK

    def remove(self, a: str, f: Fault) -> str:
        if a not in self.agents:
            return OK
        if self.stop(a, f) != OK:
            return FAIL
        self.checks = {c for c in self.checks if c[0] != a}
        del self.agents[a]
        return OK

    def reboot(self) -> None:
        for A in self.agents.values():
            A.running.clear()
            A.hold = False
        self.checks.clear()

    def boot(self, f: Fault) -> str:
        for a in sorted(self.agents):
            A = self.agents[a]
            self._finish_stopping(a, f)
            if A.current is None:
                continue
            A.hold = True
            if self._start_gen(a, A.current, f) == KILLED:
                return KILLED
        return OK

    def apply(self, op: tuple) -> str:
        """Runs a (command, args...) tuple, as the race rule names them."""
        name, args = op[0], op[1:]
        if name == "widen":
            return self.widen(args[0], args[1], args[2], NONE)
        if name == "tighten":
            return self.tighten(args[0], args[1], NONE)
        if name == "stop":
            return self.stop(args[0], NONE)
        if name == "check":
            return self.check(args[0], args[1], NONE)
        if name == "boot":
            return self.boot(NONE)
        raise ValueError(name)

    def snapshot(self):
        return (
            {
                a: (A.port, sorted(A.gens), A.current, dict(sorted(A.running.items())), A.stopping, A.hold)
                for a, A in sorted(self.agents.items())
            },
            sorted(self.checks),
        )


# --- the sandbox ---------------------------------------------------------------


def allows(mode: str, hosts) -> Optional[FrozenSet[str]]:
    """The hosts a generation lets through; None means every host."""
    return None if mode in ("report", "off") else frozenset(hosts)


def covered(h: str, hosts: FrozenSet[str]) -> bool:
    if h in hosts:
        return True
    for w in hosts:
        if w.startswith("*."):
            if (h[1:] if h.startswith("*.") else h).endswith(w[1:]):
                return True
    return False


def wider(g: Optional[FrozenSet[str]], c: Optional[FrozenSet[str]]) -> bool:
    """True when g lets through a host that c doesn't."""
    if c is None:
        return False
    if g is None:
        return True
    return not all(covered(h, c) for h in g)


class Sandbox:
    """One egress container: the ctl with ETC, UNITS and /run moved into a
    fresh directory, on the fake systemd."""

    bin_dir: Optional[str] = None

    def __init__(self, root: str) -> None:
        self.root = root
        self.etc = os.path.join(root, "etc")
        self.units_dir = os.path.join(root, "units")
        self.fake = os.path.join(root, "systemd")
        for d in (self.etc, self.units_dir, os.path.join(root, "run"), self.fake):
            os.makedirs(d)
        with open(CTL) as f:
            src = f.read()
        src = re.sub(r"(?m)^ETC=.*$", f"ETC={self.etc}", src)
        src = re.sub(r"(?m)^UNITS=.*$", f"UNITS={self.units_dir}", src)
        src = src.replace("/run/", os.path.join(root, "run") + "/")
        self.ctl_path = os.path.join(root, "ctl")
        with open(self.ctl_path, "w") as f:
            f.write(src)
        self.env = dict(os.environ)
        for k in list(self.env):
            if k.startswith("FAKE_"):
                del self.env[k]
        self.env.update(
            PATH=f"{Sandbox.bin_dir}:{os.environ.get('PATH', '/usr/bin:/bin')}",
            FAKE_SYSTEMD=self.fake,
            FAKE_SYSTEMD_ETC=self.etc,
        )

    @classmethod
    def make_bin(cls, root: str) -> None:
        cls.bin_dir = os.path.join(root, "bin")
        os.makedirs(cls.bin_dir, exist_ok=True)
        for t in ("systemctl", "journalctl", "systemd-escape", "curl"):
            p = os.path.join(cls.bin_dir, t)
            if not os.path.lexists(p):
                os.symlink(FAKE, p)
        # The fake's sleep returns at once; true does the same without
        # starting bash, and the ctl's waits call it hundreds of times.
        true = shutil.which("true") or "/bin/true"
        if not os.path.lexists(os.path.join(cls.bin_dir, "sleep")):
            os.symlink(true, os.path.join(cls.bin_dir, "sleep"))

    def _cmd(self, args, extra_env=None):
        env = dict(self.env)
        env.update(extra_env or {})
        return ["bash", self.ctl_path, *args], env

    def ctl(self, *args, stdin: Optional[str] = None, fault: Fault = NONE) -> Tuple[int, str, str]:
        cmd, env = self._cmd(args, fault.env())
        p = subprocess.run(
            cmd,
            input=stdin if stdin is not None else "",
            env=env,
            capture_output=True,
            text=True,
            timeout=120,
        )
        return p.returncode, p.stdout, p.stderr

    def popen(self, *args, extra_env=None) -> subprocess.Popen:
        cmd, env = self._cmd(args, extra_env)
        return subprocess.Popen(
            cmd, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.PIPE, env=env, text=True
        )

    # What's on disk.
    def agent_dir(self, a: str) -> str:
        return os.path.join(self.etc, "agents", a)

    def agents(self) -> List[str]:
        try:
            return sorted(os.listdir(os.path.join(self.etc, "agents")))
        except FileNotFoundError:
            return []

    def read(self, *parts) -> Optional[str]:
        try:
            with open(os.path.join(*parts)) as f:
                return f.read()
        except FileNotFoundError:
            return None

    def current_raw(self, a: str) -> Optional[str]:
        return self.read(self.agent_dir(a), "current")

    def current(self, a: str) -> Optional[int]:
        c = (self.current_raw(a) or "none").strip()
        return None if c == "none" else int(c)

    def stopping(self, a: str) -> Optional[FrozenSet[int]]:
        s = self.read(self.agent_dir(a), "stopping")
        if s is None:
            return None
        return frozenset(int(x) for x in s.split())

    def gen_dirs(self, a: str) -> List[int]:
        try:
            return sorted(int(x) for x in os.listdir(os.path.join(self.agent_dir(a), "gens")) if x.isdigit())
        except FileNotFoundError:
            return []

    def gen_info(self, a: str, n: int) -> Tuple[Optional[str], Optional[str], Tuple[str, ...]]:
        d = os.path.join(self.agent_dir(a), "gens", str(n))
        mode = (self.read(d, "mode") or "").strip() or None
        policy = (self.read(d, "policy") or "").strip() or None
        hosts: List[str] = []
        indom = False
        for line in (self.read(d, "acl.yaml") or "").splitlines():
            if line == "  allowed_domains:":
                indom = True
                continue
            if indom and line.startswith("    - "):
                hosts.append(line[6:].strip('"'))
                continue
            indom = False
        return mode, policy, tuple(hosts)

    def gen_hash(self, a: str, n: int) -> str:
        d = os.path.join(self.agent_dir(a), "gens", str(n))
        h = hashlib.sha256()
        for name in sorted(os.listdir(d)):
            h.update(name.encode() + b"\0" + (self.read(d, name) or "").encode() + b"\0")
        return h.hexdigest()

    def unit_states(self) -> Dict[str, str]:
        out = {}
        d = os.path.join(self.fake, "units")
        if os.path.isdir(d):
            for u in os.listdir(d):
                out[u] = (self.read(d, u) or "inactive").split()[0]
        return out

    def running_gens(self, a: str) -> Dict[int, str]:
        out = {}
        for u, s in self.unit_states().items():
            m = GEN_RE.match(u)
            if m and m.group(1) == a and s in ("active", "draining"):
                out[int(m.group(2))] = s
        return dict(sorted(out.items()))

    def running_checks(self) -> Set[Tuple[str, int]]:
        out = set()
        for u, s in self.unit_states().items():
            m = CHECK_RE.match(u)
            if m and s in ("active", "draining"):
                out.add((m.group(1), int(m.group(2))))
        return out

    def hold_running(self, a: str) -> bool:
        return self.unit_states().get(f"boxen-hold_{a}.service") in ("active", "draining")

    def journal(self) -> List[Tuple[str, str]]:
        out = []
        for line in (self.read(self.fake, "journal") or "").splitlines():
            parts = line.split("\t", 2)
            if len(parts) == 3:
                out.append((parts[0], parts[2]))
        return out

    def snapshot(self):
        """The same shape as Model.snapshot, read from the sandbox."""
        agents = {}
        for a in self.agents():
            gens = self.gen_dirs(a)
            port = int((self.read(self.agent_dir(a), "port") or "0").strip())
            agents[a] = (port, gens, self.current(a), self.running_gens(a), self.stopping(a), self.hold_running(a))
        return agents, sorted(self.running_checks())


# --- the state machine ---------------------------------------------------------

agent_names = st.sampled_from(sorted(AGENTS))
policies = st.integers(0, 2**32 - 1).map(lambda x: f"{x:08x}")
signals = st.sampled_from(["KILL", "TERM"])


def pick(data, items: list, label: str):
    """One of items, or None. It always draws the same way, whatever items
    holds, so a replay draws alike even when a race came out the other way."""
    i = data.draw(st.integers(0, 255), label=label)
    return items[i % len(items)] if items else None


class EgressCtl(RuleBasedStateMachine):
    gens = Bundle("gens")

    def __init__(self) -> None:
        super().__init__()
        self.tmp = tempfile.mkdtemp(prefix="egress-prop-", dir=SANDBOX_ROOT)
        self.sb = Sandbox(self.tmp)
        rc, out, err = self.sb.ctl("setup", "1.1.1.1", "")
        assert rc == 0, err
        self.model = Model()
        # Bookkeeping that the invariants read, per agent.
        self.birth: Dict[str, int] = {}  # journal length when the agent was added
        self.issued: Dict[str, List[int]] = {}  # generation numbers gen printed
        self.hashes: Dict[Tuple[str, int], str] = {}  # each generation's files
        self.tight: Dict[str, bool] = {}  # a tighten returned 0, nothing since undid it
        self.may_be_down: Dict[str, str] = {}  # why current may not be running
        self.last: List[tuple] = []  # (op, rc, state before, fault) of the last step

    def teardown(self) -> None:
        shutil.rmtree(self.tmp, ignore_errors=True)

    # Running a command and keeping the books.
    def _expect(self, what: str, want: str, rc: int, out: str, err: str) -> None:
        got = rc_class(rc)
        assert got == want, f"{what}: the model expects {want}, the ctl gave rc={rc}\nstdout: {out}\nstderr: {err}"

    def _after(self, op: tuple, rc: int) -> None:
        name, a = op[0], (op[1] if len(op) > 1 else None)
        ok = rc == 0
        if name in ("widen", "tighten"):
            self.tight[a] = name == "tighten" and ok
            if ok:
                self.may_be_down.pop(a, None)
        elif name in ("stop", "remove") and not ok:
            self.tight[a] = False
        if name == "boot":
            for b in self.sb.agents():
                if ok:
                    self.may_be_down.pop(b, None)
                else:
                    self.may_be_down[b] = "boot was cut short"

    def _run(self, op: tuple, fault: Fault, stdin: Optional[str] = None):
        before = self.sb.snapshot()
        rc, out, err = self.sb.ctl(*argv(op), stdin=stdin, fault=fault)
        self.last = [(op, rc, before, fault)]
        self._after(op, rc)
        SEEN[(op[0], fault.kind, rc_class(rc))] += 1
        return rc, out, err

    @initialize(target=gens)
    def first_agent(self):
        self.add_agent("a", True)
        return self._gen("a", "enforce", "0000aaaa", [HOSTS[0]])

    @rule(a=agent_names, right_port=st.booleans())
    def add_agent(self, a: str, right_port: bool) -> None:
        port = AGENTS[a] if right_port else AGENTS[a] + 100
        new = a not in self.sb.agents()
        jlen = len(self.sb.journal())
        want = self.model.add(a, port)
        rc, out, err = self._run(("add", a, port), NONE)
        self._expect(f"add {a} {port}", want, rc, out, err)
        if new and rc == 0:
            self.birth[a] = jlen
            self.issued[a] = []
            self.tight[a] = False

    @rule(
        target=gens,
        data=st.data(),
        mode=st.sampled_from(MODES),
        policy=policies,
        hosts=st.lists(st.sampled_from(HOSTS), unique=True, max_size=4),
        bad=st.sampled_from([None] * 30 + BAD_HOSTS),
    )
    def gen(self, data, mode, policy, hosts, bad):
        # Mostly an agent that exists; sometimes one that doesn't.
        a = pick(data, sorted(self.model.agents) * 8 + sorted(AGENTS), "agent")
        if bad:
            hosts = hosts + [bad]
        return self._gen(a, mode, policy, hosts)

    @rule(
        target=gens,
        data=st.data(),
        mode=st.sampled_from(MODES),
        policy=policies,
        hosts=st.lists(st.sampled_from(HOSTS), unique=True, max_size=4),
        how=st.sampled_from(["widen", "tighten"]),
        force=st.booleans(),
    )
    def change(self, data, mode, policy, hosts, how, force):
        """What the host does: a new generation, then widen or tighten to it."""
        a = pick(data, sorted(self.model.agents), "agent")
        if a is None:
            return multiple()
        g = self._gen(a, mode, policy, hosts)
        if isinstance(g, tuple):
            if how == "widen":
                self._widen(g, force, data)
            else:
                self._tighten(g, data)
        return g

    @rule(count=st.integers(1, 8), policy=policies)
    def pile_up(self, count, policy):
        """Several widens in a row, so the limit on draining ones comes into
        play within a short sequence."""
        a = sorted(self.model.agents)[0] if self.model.agents else None
        if a is None:
            return
        for i in range(count):
            g = self._gen(a, "enforce", policy, HOSTS[: 1 + i % len(HOSTS)])
            if not isinstance(g, tuple):
                return
            want = self.model.widen(a, g[1], False, NONE)
            rc, out, err = self._run(("widen", a, g[1], False), NONE)
            self._expect(f"widen {a} {g[1]}", want, rc, out, err)
            self.promised_state()

    def _gen(self, a, mode, policy, hosts):
        want, n = self.model.gen(a, mode, policy, hosts)
        rc, out, err = self._run(("gen", a, mode, policy), NONE, stdin="".join(h + "\n" for h in hosts))
        self._expect(f"gen {a} {mode}", want, rc, out, err)
        if rc != 0:
            return multiple()
        got = int(out.strip())
        assert got == n, f"gen printed {got}, the model expected {n}"
        # Generation numbers never repeat within an agent's lifetime.
        assert all(got > g for g in self.issued[a]), f"gen {a} gave {got} after {self.issued[a]}"
        self.issued[a].append(got)
        # Its files say what was asked for.
        assert self.sb.gen_info(a, got) == (mode, policy, tuple(hosts) if mode != "off" else ()), (
            f"{a}/{got} files: {self.sb.gen_info(a, got)}"
        )
        self.hashes[(a, got)] = self.sb.gen_hash(a, got)
        return (a, got)

    def _fault(self, data, a: str, n: int, kinds: List[str]) -> Fault:
        # Half the steps have a fault, each kind as likely as the others.
        faulty = data.draw(st.booleans(), label="faulty")
        kind = data.draw(st.sampled_from(kinds), label="fault")
        if not faulty:
            return NONE
        if kind == "stuck":
            A = self.model.agents.get(a)
            choices = sorted(set(A.running) | {n}) if A else [n]
            return Fault("stuck", a, pick(data, choices, "stuck gen"))
        sig = data.draw(signals, label="signal") if kind.startswith("die") else "KILL"
        return Fault(kind, a, n, sig)

    @rule(g=gens, data=st.data())
    def check(self, g, data):
        a, n = g
        f = self._fault(data, a, n, ["curl_late", "die_check"])
        want = self.model.check(a, n, f)
        rc, out, err = self._run(("check", a, n), f)
        self._expect(f"check {a} {n} {f}", want, rc, out, err)

    def _target(self, data, g):
        """Mostly a generation that could start; sometimes any from the bundle."""
        ready = [(a, n) for a, A in sorted(self.model.agents.items()) for n in sorted(A.gens) if n not in A.running]
        use_ready = data.draw(st.integers(0, 3), label="ready") > 0
        r = pick(data, ready, "gen")
        return r if use_ready and r else g

    @rule(g=gens, force=st.booleans(), data=st.data())
    def widen(self, g, force, data):
        self._widen(self._target(data, g), force, data)

    def _widen(self, g, force, data):
        a, n = g
        f = self._fault(data, a, n, ["curl_late", "die_check", "die_gen", "start_fail", "no_ack", "stuck"])
        want = self.model.widen(a, n, force, f)
        rc, out, err = self._run(("widen", a, n, force), f)
        self._expect(f"widen {a} {n} force={force} {f}", want, rc, out, err)

    @rule(g=gens, data=st.data())
    def tighten(self, g, data):
        self._tighten(self._target(data, g), data)

    def _tighten(self, g, data):
        a, n = g
        f = self._fault(data, a, n, ["curl_late", "die_check", "die_gen", "start_fail", "no_ack", "stuck"])
        want = self.model.tighten(a, n, f)
        rc, out, err = self._run(("tighten", a, n), f)
        self._expect(f"tighten {a} {n} {f}", want, rc, out, err)

    @rule(a=agent_names, data=st.data())
    def stop(self, a, data):
        if a not in self.model.agents:
            return
        f = self._fault(data, a, 0, ["stuck"])
        want = self.model.stop(a, f)
        rc, out, err = self._run(("stop", a), f)
        self._expect(f"stop {a} {f}", want, rc, out, err)

    @rule(a=agent_names, data=st.data())
    def remove(self, a, data):
        f = self._fault(data, a, 0, ["stuck"])
        want = self.model.remove(a, f)
        rc, out, err = self._run(("remove", a), f)
        self._expect(f"remove {a} {f}", want, rc, out, err)
        if rc == 0:
            for d in (self.birth, self.issued, self.tight, self.may_be_down):
                d.pop(a, None)
            self.hashes = {k: v for k, v in self.hashes.items() if k[0] != a}

    @rule()
    def reboot(self):
        """The egress container restarts: every unit stops; boot hasn't run yet."""
        d = os.path.join(self.sb.fake, "units")
        for u in os.listdir(d):
            with open(os.path.join(d, u), "w") as fh:
                fh.write("inactive 0\n")
        try:
            os.remove(os.path.join(self.sb.fake, "port4700"))
        except FileNotFoundError:
            pass
        self.model.reboot()
        self.last = []
        for a in self.sb.agents():
            self.may_be_down[a] = "a reboot, before boot"

    @rule(data=st.data())
    def boot(self, data):
        f = NONE
        cur = [(a, A.current) for a, A in sorted(self.model.agents.items()) if A.current is not None]
        faulty = data.draw(st.booleans(), label="faulty")
        kind = data.draw(st.sampled_from(["start_fail", "die_gen", "stuck"]), label="fault")
        kind = kind if faulty else "none"
        if kind == "stuck":
            stopping = [(a, g) for a, A in sorted(self.model.agents.items()) for g in sorted(A.stopping or ())]
            t = pick(data, stopping, "stuck gen")
            if t:
                f = Fault("stuck", t[0], t[1])
        elif kind != "none":
            t = pick(data, cur, "target")
            sig = data.draw(signals, label="signal") if kind == "die_gen" else "KILL"
            if t:
                f = Fault(kind, t[0], t[1], sig)
        want = self.model.boot(f)
        rc, out, err = self._run(("boot",), f)
        self._expect(f"boot {f}", want, rc, out, err)
        if f.kind == "start_fail":
            self.may_be_down[f.agent] = "boot couldn't start it"

    @rule(g1=gens, g2=gens, ops=st.tuples(st.sampled_from(["widen", "tighten", "stop", "check", "boot"]),
                                           st.sampled_from(["widen", "tighten", "stop", "check", "boot"])))
    def race(self, g1, g2, ops):
        """Two commands at once: the lock makes the result one of the two orders."""

        def op_for(name, g):
            a, n = g
            return {
                "widen": ("widen", a, n, False),
                "tighten": ("tighten", a, n),
                "stop": ("stop", a),
                "check": ("check", a, n),
                "boot": ("boot",),
            }[name]

        o1, o2 = op_for(ops[0], g1), op_for(ops[1], g2)
        if any(o[0] == "stop" and o[1] not in self.model.agents for o in (o1, o2)):
            return
        outcomes = []
        for order in ((o1, o2), (o2, o1)):
            m = copy.deepcopy(self.model)
            rcs = [m.apply(o) for o in order]
            outcomes.append((order, rcs, m))
        # A boot goes first and is slowed while it starts a holder, which is
        # where an unlocked boot once let a tighten slip in (F1).
        if o2[0] == "boot" and o1[0] != "boot":
            o1, o2 = o2, o1
        try:
            os.remove(os.path.join(self.sb.fake, "hold-starting"))
        except FileNotFoundError:
            pass
        p1 = self.sb.popen(*argv(o1), extra_env={"FAKE_SYSTEMD_HOLD_DELAY": "0.3"} if o1[0] == "boot" else None)
        if o1[0] == "boot":
            for _ in range(100):
                if os.path.exists(os.path.join(self.sb.fake, "hold-starting")) or p1.poll() is not None:
                    break
                time.sleep(0.01)
        p2 = self.sb.popen(*argv(o2))
        r1 = p1.wait(timeout=120)
        r2 = p2.wait(timeout=120)
        got = self.sb.snapshot()
        match = None
        for order, want_rcs, m in outcomes:
            got_rcs = [rc_class(r1), rc_class(r2)] if order[0] is o1 else [rc_class(r2), rc_class(r1)]
            if m.snapshot() == got and got_rcs == want_rcs:
                match = (order, got_rcs, m)
                break
        assert match, (
            f"race {o1} | {o2}: rc {r1},{r2}; the sandbox matches neither order\n"
            f"sandbox: {got}\n" + "\n".join(f"order {o}: rcs {r} model {m.snapshot()}" for o, r, m in outcomes)
        )
        order, rcs, self.model = match
        SEEN[("race", f"{order[0][0]}|{order[1][0]}", f"{rcs[0]}|{rcs[1]}")] += 1
        for o, r in zip(order, rcs):
            self._after(o, 0 if r == OK else 1)
        # Only the second one's promise can be seen once both are done.
        # The state before it isn't known, so no check that compares with it.
        self.last = [(order[1], 0 if rcs[1] == OK else 1, None, NONE)]

    # --- invariants ---------------------------------------------------------

    @invariant()
    def matches_model(self):
        got, want = self.sb.snapshot(), self.model.snapshot()
        assert got == want, f"sandbox != model\nsandbox: {got}\nmodel:   {want}"

    @invariant()
    def one_current(self):
        """Each agent has one current pointer: a generation that exists, or none."""
        for a in self.sb.agents():
            raw = self.sb.current_raw(a)
            assert raw is not None and re.fullmatch(r"(none|[0-9]+)\n", raw), f"{a}: current is {raw!r}"
            assert not os.path.exists(os.path.join(self.sb.agent_dir(a), "current.new")), f"{a}: current.new left"
            c = self.sb.current(a)
            if c is not None:
                assert c in self.sb.gen_dirs(a), f"{a}: current {c} has no directory"

    @invariant()
    def current_passed_check_and_runs(self):
        """Current, when set, passed a check in this agent's lifetime, isn't
        draining, and runs unless a reboot or a failed start explains it."""
        journal = None
        for a in self.sb.agents():
            c = self.sb.current(a)
            if c is None or a not in self.birth:
                continue
            if journal is None:
                journal = self.sb.journal()
            mode = self.sb.gen_info(a, c)[0]
            want = {
                "enforce": ['"allow":false', '"decision_reason":"default rule policy used"'],
                "report": ['"allow":true', '"enforce_would_deny":true'],
                "off": ['"allow":true'],
            }[mode]
            unit = f"boxen-check_{a}@{c}.service"
            passed = any(
                u == unit and "CANONICAL-PROXY-DECISION" in m and all(w in m for w in want)
                for u, m in journal[self.birth[a]:]
            )
            assert passed, f"{a}: current {c} ({mode}) never passed a check"
            state = self.sb.running_gens(a).get(c)
            assert state != "draining", f"{a}: current {c} is draining"
            if state is None:
                assert a in self.may_be_down, f"{a}: current {c} isn't running, and nothing explains it"

    @invariant()
    def status_yes_means_only_current_accepts(self):
        """When status says listening=yes, no other generation accepts new
        connections: every other running one is draining."""
        for a in self.sb.agents():
            c = self.sb.current(a)
            if c is None:
                continue
            run = self.sb.running_gens(a)
            st_ = self.sb.stopping(a) or frozenset()
            stopping = any(g != c and g in st_ for g in run)
            if c in run and not stopping:
                accepting = [g for g, s in run.items() if g != c and s == "active"]
                assert not accepting, f"{a}: status would say yes, but {accepting} accept next to current {c}"

    @invariant()
    def nothing_wider_after_tighten(self):
        """After a tighten returns 0, and until a widen or a failure, no
        generation that lets through more than current's list accepts."""
        for a in self.sb.agents():
            if not self.tight.get(a):
                continue
            c = self.sb.current(a)
            cur_allows: Optional[FrozenSet[str]] = frozenset()
            if c is not None:
                mode, _, hosts = self.sb.gen_info(a, c)
                cur_allows = allows(mode, hosts)
            for g, s in self.sb.running_gens(a).items():
                if g == c or s != "active":
                    continue
                mode, _, hosts = self.sb.gen_info(a, g)
                assert not wider(allows(mode, hosts), cur_allows), (
                    f"{a}: {g} ({mode} {hosts}) accepts and is wider than current {c}"
                )

    @invariant()
    def promised_state(self):
        """A command that exits 0 leaves the state it promised."""
        for op, rc, before, fault in self.last:
            name = op[0]
            a = op[1] if len(op) > 1 else None
            if name == "widen":
                n, force = op[2], op[3]
                b_agents = before[0] if before else {}
                b_run = b_agents[a][3] if a in b_agents else {}
                b_cur = b_agents[a][2] if a in b_agents else None
                b_stop = (b_agents[a][4] or frozenset()) if a in b_agents else frozenset()
                draining_before = [g for g in b_run if g != b_cur and g not in b_stop]
                if before and not force and len(draining_before) >= MAX_DRAINING:
                    assert rc != 0, f"widen {a}/{n} without --force passed {len(draining_before)} draining"
                    assert self.sb.current(a) == b_cur, f"widen {a}/{n} was refused but moved current"
                if rc == 0:
                    run = self.sb.running_gens(a)
                    assert self.sb.current(a) == n and run.get(n) == "active", f"widen {a}/{n}: {run}"
                    others = {g: s for g, s in run.items() if g != n}
                    assert all(s == "draining" for s in others.values()), f"widen {a}/{n}: others {others}"
                    if not force:
                        assert len(others) <= MAX_DRAINING, f"widen {a}/{n}: {len(others)} draining"
            elif name == "tighten" and rc == 0:
                n = op[2]
                assert self.sb.current(a) == n, f"tighten {a}/{n}: current {self.sb.current(a)}"
                assert list(self.sb.running_gens(a)) == [n], f"tighten {a}/{n}: {self.sb.running_gens(a)}"
                assert self.sb.stopping(a) is None, f"tighten {a}/{n} left its stopping record"
            elif name == "stop" and rc == 0:
                assert self.sb.current(a) is None and not self.sb.running_gens(a), f"stop {a}"
                assert self.sb.stopping(a) is None
            elif name == "remove" and rc == 0:
                assert a not in self.sb.agents(), f"remove {a}: its directory is left"
                left = [u for u in os.listdir(self.sb.units_dir) if f"_{a}." in u or f"_{a}@" in u
                        or u == f"boxen-agent_{a.replace('-', chr(92) + 'x2d')}.slice"]
                assert not left, f"remove {a}: unit files left: {left}"
                running = [
                    u for u, s in self.sb.unit_states().items()
                    if s != "inactive" and (u.startswith(f"boxen-gen_{a}@") or u.startswith(f"boxen-check_{a}@")
                                            or u == f"boxen-hold_{a}.service")
                ]
                assert not running, f"remove {a}: units still running: {running}"
            elif name == "check" and rc == 0:
                assert not self.sb.running_checks(), f"check left {self.sb.running_checks()}"
            elif name == "boot" and rc == 0 and fault.kind == "none":
                for b in self.sb.agents():
                    c = self.sb.current(b)
                    run = self.sb.running_gens(b)
                    if c is not None:
                        assert c in run, f"boot: {b}/{c} isn't running"
                    started = set(run) - set(before[0].get(b, (0, 0, 0, {}))[3]) - {c} if before else set()
                    assert not started, f"boot started {b}/{sorted(started)}, which isn't current"
            if name in ("check", "widen", "tighten") and rc == 0:
                assert not self.sb.running_checks(), f"{name} left check copies {self.sb.running_checks()}"

    @invariant()
    def numbers_and_files(self):
        """Generation directories are ones gen printed, and never change."""
        for a in self.sb.agents():
            if a not in self.issued:
                continue
            for n in self.sb.gen_dirs(a):
                assert n in self.issued[a], f"{a}/{n} exists but gen never printed it"
                assert self.sb.gen_hash(a, n) == self.hashes[(a, n)], f"{a}/{n}: its files changed"
            for n in self.sb.running_gens(a):
                assert n in self.sb.gen_dirs(a), f"{a}/{n} runs without its directory"

    @invariant()
    def status_agrees_with_disk(self):
        rc, out, err = self.sb.ctl("status")
        assert rc == 0, f"status failed: {err}"
        lines = out.splitlines()
        agents = self.sb.agents()
        assert len(lines) == len(agents), f"status: {lines} for {agents}"
        for a, line in zip(agents, lines):
            c = self.sb.current(a)
            run = self.sb.running_gens(a)
            mode = pol = "-"
            listening = "no"
            if c is not None:
                mode, pol, _ = self.sb.gen_info(a, c)
                if c in run:
                    st_ = self.sb.stopping(a) or frozenset()
                    listening = "stopping" if any(g != c and g in st_ for g in run) else "yes"
            port = (self.sb.read(self.sb.agent_dir(a), "port") or "").strip()
            want = [a, port, str(c) if c is not None else "none", pol, mode, listening, " ".join(map(str, run))]
            assert line.split("\t") == want, f"status line {line.split(chr(9))} != disk {want}"


SANDBOX_ROOT: Optional[str] = None


def main() -> int:
    global SANDBOX_ROOT
    examples = int(os.environ.get("BOXEN_PROPERTY_EXAMPLES", "50"))
    steps = int(os.environ.get("BOXEN_PROPERTY_STEPS", "20"))
    seed = os.environ.get("BOXEN_PROPERTY_SEED", "")
    kw = dict(
        max_examples=examples,
        stateful_step_count=steps,
        deadline=None,
        suppress_health_check=list(HealthCheck),
        print_blob=True,
    )
    if os.environ.get("BOXEN_PROPERTY_SHRINK") == "0":
        kw["phases"] = [Phase.explicit, Phase.reuse, Phase.generate]
    machine = EgressCtl
    if seed == "random":
        kw.update(derandomize=False, database=DirectoryBasedExampleDatabase(os.path.join(REPO, ".hypothesis", "examples")))
    elif seed:
        kw.update(derandomize=False, database=None)
        machine = hypothesis_seed(int(seed))(EgressCtl)
    else:
        kw.update(derandomize=True, database=None)
    SANDBOX_ROOT = tempfile.mkdtemp(prefix="egress-prop-")
    try:
        Sandbox.make_bin(SANDBOX_ROOT)
        run_state_machine_as_test(machine, settings=settings(**kw))
    finally:
        shutil.rmtree(SANDBOX_ROOT, ignore_errors=True)
    if os.environ.get("BOXEN_PROPERTY_STATS"):
        for k, v in sorted(SEEN.items()):
            print(f"  {v:6d}  {' '.join(k)}")
    print(f"egress-ctl state machine: {examples} examples of up to {steps} steps passed")
    return 0


if __name__ == "__main__":
    sys.exit(main())
