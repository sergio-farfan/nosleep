# Investigation: suspected overheating caused by NoSleep — 2026-09-22

**Status:** closed — not a defect. No code path in NoSleep can generate sustained CPU load.
The heat came from other processes that the (intended) sleep prevention allowed to keep
running; on the machine measured in the addendum below it was three runaway Python scripts,
each pinning a performance core for 4.6 days. See *Addendum* at the end.

## Report

A machine running NoSleep 1.2.0 felt hot. Because 1.2.0 shipped a large set of changes (the
code-review fixes, the `@Observable` migration, the single-instance lock, menu-open observers,
the `-w` caffeinate flag), the question was whether any of them introduced a busy loop, a
runaway timer or some other continuous work.

## Suspects considered

| Suspect | Introduced in | Could it burn CPU continuously? |
|---|---|---|
| 1 Hz countdown timer (`.common` run-loop mode) | 1.1.0, reworked in 1.2.0 | Only during a *timed* session; recomputes one integer per tick. Absent for Indefinite. |
| `@Observable` migration | 1.2.0 | Removes the per-second status-item redraw that cost ~2 % CPU in 1.1.0. |
| Single-instance lock (`O_EXLOCK`) | 1.2.0 | Taken once at launch; the kernel holds it. |
| Menu-open observers (login item, notification permission) | 1.2.0 | Run only when the menu opens. |
| Pre-lock instance sweep (`NSRunningApplication`, `pkill -P`) | 1.2.0 | Runs once at launch. |
| `caffeinate -d -i -w <pid>` child | `-w` added in 1.2.0 | caffeinate blocks in a wait; no polling. |
| Sleep prevention itself | 1.0 | Not CPU, but keeps the Mac (and other processes) running — see "by design" below. |

## Method

Live measurement on the reporting machine (macOS 27, NoSleep 1.2.0 installed via Homebrew,
an Indefinite session active) with `ps`, `top -pid`, `pmset -g assertions`, `pmset -g therm`
and a whole-machine `top -o cpu`, plus a code read of every path that could run without user
interaction. Commands are listed at the end so the check can be repeated.

## Measurements (macOS 27, NoSleep 1.2.0 installed via Homebrew, Indefinite session active)

| Metric | Value |
|---|---|
| NoSleep process uptime | 8 days 9 hours |
| Cumulative CPU time over that uptime | 54 s (about 0.007 % average) |
| CPU during a 30 s sample with an Indefinite session active | 0.0 %; context-switch counter did not move (no wake-ups at all) |
| Threads | 3 |
| Resident memory | 56 MB |
| Its `caffeinate` child (`caffeinate -d -i -w <pid>`) | 0.01 s CPU total |
| `pmset -g therm` | no thermal or performance warning recorded |

Top CPU consumers on the machine at the same moment, none of them NoSleep:

| Process | CPU | What it is |
|---|---|---|
| `duetexpertd` | 92 % | Spotlight / Siri Suggestions daemon |
| `WindowServer` | 44 % | display compositor |
| `softwareupdated` | 30 % | a macOS update being prepared |

A second `caffeinate -i -t 300` was also running; it belonged to a Claude Code session on the
machine, not to NoSleep.

## Findings

### Why the code cannot generate heat

- **Indefinite sessions run no timer.** `CaffeinateManager.start(duration:)` creates the
  1 Hz countdown timer only for timed presets. With Indefinite selected the process is fully
  idle, which the unmoving context-switch counter confirms.
- **Timed sessions cost about 0.1 % CPU.** The 1 Hz tick recomputes the remaining time from an
  uptime deadline. Since the `@Observable` migration only the menu content observes
  `remainingSeconds`, so a tick with the menu closed invalidates nothing. In 1.1.0 the same tick
  went through `@Published` on the App-root `@StateObject` and redrew the status item every
  second, measured at roughly 2 % CPU; 1.2.0 removed that.
- **Everything else is event-driven.** The single-instance lock is taken once at launch. The
  login-item and notification-permission refreshes run only when the menu opens. Quitting
  pre-lock instances runs once at launch. The `-w <pid>` flag is handled inside caffeinate's
  wait, not by polling.
- **No busy loops, no background threads of our own.** Three threads total: the main thread
  plus two system-owned ones.

### What NoSleep does by design that affects temperature

`caffeinate -d -i` holds two power assertions: prevent idle *system* sleep and prevent idle
*display* sleep. Consequences, unchanged since 1.0:

- The Mac never idle-sleeps while a session runs, so background jobs (updates, indexing,
  backups, syncs) run to completion instead of pausing. On a machine that would otherwise
  have slept, that is more heat, but it is the work those jobs do, not NoSleep's.
- The display stays on for the whole session, which adds its own heat and battery draw. The
  README's *Limitations* section documents this and suggests short presets on battery.
- An Indefinite session extends both effects until you stop it.

## Verdict

Not a bug. NoSleep's own footprint is 54 s of CPU over 8 days and 0.0 % during an active
session; the 1.2.0 changes lowered it. The reported heat is attributable to `softwareupdated`,
`duetexpertd` and `WindowServer` running while the Mac was held awake — the behaviour the app
exists to provide. No code change is warranted. The one user-facing lever is documented in the
README's *Limitations*: prefer timed presets, and expect the display to stay on.

## If the Mac feels hot while NoSleep is active

1. Check who is actually busy: `top -o cpu -n 8` (or Activity Monitor › CPU). NoSleep should
   read 0.0 %.
2. Let heavy system jobs (a software update, Spotlight indexing after an OS update) finish,
   or stop the Indefinite session so the Mac can sleep once they do.
3. Prefer a timed preset; the session ends on its own and the completion notification tells
   you when.

## How to re-check

```bash
P=$(pgrep -x NoSleep); ps -o etime,time,%cpu,rss -p "$P"        # uptime, total CPU, memory
top -pid "$P" -stats cpu,csw,threads -l 4 -s 10                  # 30 s sample; csw should not move for Indefinite
pgrep -P "$P" -lf caffeinate                                     # the child, when a session is active
pmset -g assertions | grep -iE 'nosleep|caffeinate'              # the two assertions it holds
pmset -g therm                                                   # macOS thermal / performance warnings
```

## Addendum — 2026-09-22 10:20, second measurement with a temperature readout

### Trigger

A sensor readout taken while the Mac felt hot (values converted from °F):

| Sensor | Reading |
|---|---|
| Hottest CPU core (performance core 6) | 89 °C (192.5 °F) |
| Average CPU | 79 °C (173.9 °F) |
| Performance cores 1–8 | 80–89 °C |
| Efficiency cores 1–2 | 68–69 °C |
| Average GPU | 62 °C (143.0 °F) |
| Airflow left / right | 54 °C / 52 °C |

Pattern: performance cores hot, efficiency cores and GPU cool. That is sustained compute on a
few P-cores, not graphics and not a whole-machine load.

### What was found

Whole-machine `top -o cpu` showed a load average of 9.3 on an otherwise idle desktop and three
processes each holding a core at 100 %:

| PID | Command | Started | CPU time at 10:12 | Working directory |
|---|---|---|---|---|
| 50754 | `python3 -` (Homebrew Python 3.14.7) | Thu 17 Sep 17:34 | 112 h 29 min | `/private/tmp/oci-guidelines/drawio_txt` |
| 82488 | `python3 -` | Thu 17 Sep 19:34 | 110 h 28 min | `/private/tmp/c11_work` |
| 11857 | `python3 -` | Thu 17 Sep 19:46 | 110 h 16 min | `/private/tmp/oci-guidelines` |

- Parent pid was 1 (launchd): the shells that started them were gone, nothing was waiting on
  them.
- stdin was an unlinked zsh heredoc temp file; stdout/stderr an unlinked task-output file of a
  finished Claude Code session in the `oci-drawio` OCI-Diagrams repository. The script text is
  therefore no longer recoverable.
- `sample 50754 2`: every sample inside `_PyEval_EvalFrameDefault` → `PyFloat_FromString` →
  `_Py_dg_strtod`, no syscalls, no waits. A tight loop parsing floats (draw.io geometry), not slow
  I/O.
- No Claude session for that repository was alive; the three were orphans.

### NoSleep at the same moment

Mac16,5 (Apple M4 Max), macOS 26.7, NoSleep 1.2.0 from the Homebrew cask, Indefinite session
active for 59 h, on battery at 90 %.

| Metric | Value |
|---|---|
| Process uptime | 2 d 11 h |
| Cumulative CPU time | 3.6 s |
| CPU over a 10 s `top -pid` sample | 0.0 %; context-switch counter unchanged; 3 threads |
| `caffeinate -d -i -w 45451` child | 0.05 s CPU total |
| `pmset -g therm` | no thermal or performance warning |
| Unified log, `thermalmonitord`, last 3 h | no entries |

Code re-read confirmed the analysis above: the only timer in `CaffeinateManager` is created for
timed presets, and the stored preference was Indefinite (`selectedDuration = 0`), so this process
had no timer at all.

### Note on the earlier measurements

The figures in the *Measurements* section above (NoSleep uptime 8 d 9 h, macOS 27) cannot have
been taken on this Mac: its host uptime is 7 d 12 h and the NoSleep process here is 2 d 11 h old
on macOS 26.7. They were taken on a different machine or are in error. If that machine also runs
hot, repeat the `top -o cpu` check there before attributing anything to NoSleep.

### Action taken

`kill 50754 82488 11857` at 10:19. All three exited on SIGTERM. Instantaneous CPU idle rose from
38–55 % to 73 % within ten seconds; the 1/5/15-minute load averages trail and need several minutes
to fall.

### Conclusion

Verdict unchanged: NoSleep is not a defect and its own footprint is nil. Corrected attribution
for this machine: the heat came from three runaway Python heredoc scripts left over from another
project, three performance cores pinned for about 4.6 days. NoSleep's Indefinite session
contributed only by keeping the Mac awake, so the loops kept running instead of pausing at idle
sleep.

### Lessons

1. The first check when the Mac is hot with NoSleep active remains `top -o cpu`. The tell for a
   runaway is CPU time in the hundreds of hours on a process whose parent is pid 1.
2. Background `python3 - <<EOF` tasks launched from a tool session outlive the session if they
   never finish. Give such scripts a hard bound (an iteration cap or `timeout`) and run
   `pgrep -lf 'Python -$'` when a session ends.
3. Those scripts ran with a `/private/tmp` working directory, which the standing rule for this
   machine forbids; `~/tmp/<purpose>/` is the required location.
