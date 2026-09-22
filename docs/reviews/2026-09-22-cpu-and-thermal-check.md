# Can NoSleep overheat a Mac? CPU and thermal check — 2026-09-22

Question asked after the 1.2.0 improvements landed: can NoSleep cause a machine to overheat,
and did any of the recent code changes introduce something that could?

**Answer: no.** NoSleep does no continuous work, its own CPU use is effectively zero, and the
1.2.0 changes made it lighter than 1.1.0. What it does by design is keep the Mac awake and the
display on, so whatever else is running keeps running instead of pausing for sleep.

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

## Why the code cannot generate heat

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

## What NoSleep does by design that affects temperature

`caffeinate -d -i` holds two power assertions: prevent idle *system* sleep and prevent idle
*display* sleep. Consequences, unchanged since 1.0:

- The Mac never idle-sleeps while a session runs, so background jobs (updates, indexing,
  backups, syncs) run to completion instead of pausing. On a machine that would otherwise
  have slept, that is more heat, but it is the work those jobs do, not NoSleep's.
- The display stays on for the whole session, which adds its own heat and battery draw. The
  README's *Limitations* section documents this and suggests short presets on battery.
- An Indefinite session extends both effects until you stop it.

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
