# Investigation: suspected overheating caused by NoSleep — 2026-09-22

**Status:** closed — not a defect. No code path in NoSleep can generate sustained CPU load;
the heat observed came from unrelated system daemons that the (intended) sleep prevention
allowed to keep running.

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
