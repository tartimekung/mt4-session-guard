# Session Guard (MQL4)

A time-based position guard for MetaTrader 4. It closes open positions on a schedule, flattens before the weekend, and reports whether new trades should be allowed under the configured day and session rules.

It does **not** open trades and does not generate signals.

All scheduling runs on **server time**, never terminal time. The two differ by several hours for most traders, and the gap changes twice a year with daylight saving. The EA reports both clocks and the offset between them at startup and on the chart, so a misconfigured schedule is visible before it does anything.

---

## Why this exists

Two requests come up constantly in MT4 work: *close everything at a fixed time* and *don't trade on this day*. Both look trivial and both are easy to get wrong:

- Schedules written against the terminal clock fire hours off on the client's machine
- A session that wraps past midnight (22:00–06:00) is never true when the range test is written as a single AND
- A close routine driven by a one-second timer tries to close the same position sixty times
- A close loop that counts upward silently skips positions as the order pool re-indexes

Each of those produces a plausible-looking EA that fails in a way the author never sees on their own terminal.

---

## Installation

1. Copy `SessionGuard.mq4` to `<MT4 data folder>/MQL4/Experts/`
2. Open MetaEditor and press **F7** to compile (expect `0 errors, 0 warnings`)
3. Refresh the Navigator panel
4. Drag the EA onto a chart of the symbol you want guarded
5. Enable **Allow live trading** in the Common tab

One instance guards one symbol. Attach one instance per chart for multiple symbols.

---

## Dry run

`DryRun` defaults to **true**. In this mode the EA logs every close it intends to make and closes nothing.

This is deliberate. The tool closes positions, which cannot be undone, and the most likely configuration error — entering a wall-clock time instead of a server time — is invisible until the moment it flattens an account at the wrong hour. Run in dry mode until the log shows closes firing at the times you expect, then switch it off.

---

## Inputs

### Safety

| Input | Default | Description |
|---|---|---|
| `DryRun` | true | Log intended closes without executing them |

### Order filter

| Input | Default | Description |
|---|---|---|
| `FilterMode` | All orders | Control every order on the symbol, or only those matching a magic number |
| `MagicFilter` | 0 | Magic number to match when `FilterMode` is set to magic |

Use the magic filter when another EA is running on the same account, otherwise this tool will close positions that EA is still managing.

### Daily close (server time)

| Input | Default | Description |
|---|---|---|
| `UseDailyClose` | false | Close all controlled positions once per day |
| `CloseHour` | 23 | Hour, 0–23 |
| `CloseMinute` | 45 | Minute, 0–59 |

Fires once per day. If the trigger time has already passed when the EA starts, it fires immediately on the first pass.

### Weekend flat (server time)

| Input | Default | Description |
|---|---|---|
| `UseWeekendFlat` | true | Close all controlled positions before the weekend |
| `FridayHour` | 22 | Friday hour to flatten |
| `FridayMinute` | 30 | Friday minute to flatten |

Evaluated before the daily close, so the weekend rule wins when both fall on the same minute.

### Blocked days

| Input | Default | Description |
|---|---|---|
| `BlockSunday` | true | Block the Sunday session |
| `BlockMonday` … `BlockFriday` | false | Block individual weekdays |

Blocked days affect the `IsTradingAllowed()` status and the chart panel. They do not close existing positions — use the daily close or weekend flat for that.

### Trading window

| Input | Default | Description |
|---|---|---|
| `UseWindow` | false | Restrict permitted trading to one window |
| `WindowStartHr` / `WindowStartMin` | 14:30 | Window start |
| `WindowEndHr` / `WindowEndMin` | 19:00 | Window end |

Windows may wrap past midnight: `22:00` to `06:00` is a valid overnight session. Setting start equal to end means the whole day.

### General

| Input | Default | Description |
|---|---|---|
| `Slippage` | 30 | Maximum slippage when closing |
| `ShowPanel` | true | Draw the status panel on the chart |

---

## Chart panel

```
SessionGuard  [DRY RUN]
Server time : 2026.08.04 16:53  (Tue)
Terminal    : 20:53
New trades  : ALLOWED
Positions   : 1
Window      : 10:00-20:00
Daily close : 16:43  [done today]
Weekend flat: Fri 22:30
```

Both clocks are shown together on purpose: the difference between them is the single most common cause of a schedule firing at the wrong hour.

---

## Implementation notes

**Server time throughout.** Every comparison uses `TimeCurrent()`. `TimeLocal()` appears only in the startup log and the panel, where it exists to be compared against the server clock rather than acted on.

**Ranges that wrap midnight.** When the end of a range is earlier than its start, the membership test flips from AND to OR:

```mql4
if(startMins < endMins) return(mins >= startMins && mins < endMins);
return(mins >= startMins || mins < endMins);
```

Written as a single AND, `22:00–06:00` is never true, because no minute is both at or past 1320 and below 360.

**Scheduled actions are idempotent for the day.** The timer runs every second, so a bare "is it 23:45" test is true for sixty consecutive passes. Each scheduled action records the date it last ran and skips the rest of that day.

**The close loop counts down.** Closing an order re-indexes the order pool, so an ascending loop skips whichever order slides into the freed slot. On a five-position account an ascending loop typically closes three.

**Transient close errors are retried.** Requote, off-quotes and price-change errors are refreshed and retried up to three times. Other errors stop that ticket immediately rather than looping.

**Triggers log even when there is nothing to do.** A scheduled action that stays silent when no positions are open is indistinguishable from one that never ran. The trigger prints its own firing, then prints separately whether anything was closed.

---

## Testing

### Demo results — XAUUSD M15, Pepperstone Razor

Verified against a live demo feed. Server time ran four hours behind the terminal, which the EA reported correctly at startup:

```
=== SessionGuard started === XAUUSD | server=2026.08.04 16:46 | terminal=2026.08.04 20:46 | terminal is server +4h
```

**Daily close** fired once at the configured minute and did not repeat:

![Daily close firing once](%3A%20docs/daily-close-log.png)

The trigger logs its own firing before it logs any close, so the schedule can be verified even on a day when nothing is open.

**Blocked days** — with `BlockTuesday` enabled on a Tuesday, the panel reported `New trades : BLOCKED`.

**Trading window** — tested in both branches of the range logic on the same afternoon, server time 16:52:

| Window | Expected | Panel |
|---|---|---|
| 22:00–06:00 (wraps midnight) | BLOCKED | BLOCKED |
| 10:00–20:00 (same day) | ALLOWED | ALLOWED |

![Overnight window blocking outside its hours](%3A%20docs/window-blocked.png)

![Same-day window allowing inside its hours](%3A%20docs/window-allowed.png)

Testing only the second case would pass on a broken implementation, since the wrapping branch is the one that fails.

### Known gaps

- **State does not survive a restart.** The "already ran today" flags live in global variables, which reset on recompile, parameter change, or terminal restart (`uninit reason` 1, 2 and 5). A client who adjusts a setting after the daily close has already fired will see it fire a second time and close positions opened since. Moving the flags to `GlobalVariableSet` is the fix and is not yet implemented — until then, avoid changing parameters between the trigger time and the end of the trading day.
- Weekend flat has not been observed firing; it requires a Friday session.
- Blocked days and the trading window are advisory only. They set the reported status but do not themselves close or prevent anything, since this EA does not place orders.

### How to test it yourself

Leave `DryRun` on. Set the daily close two or three minutes ahead of the **server** clock shown on the panel, open a small position, and watch the Experts log. Changing a parameter reloads the EA and resets the daily flag, which is convenient for repeat tests and is exactly the behaviour described under Known gaps.

The trading window can be tested instantly without waiting: the panel updates the moment the parameters are applied.

---

## Risk notice

This tool closes positions on a clock. It has no view on whether closing is a good idea at that moment.

A daily close crystallises whatever the position is worth at that minute, including losses that a wider stop would have survived. Flattening before the weekend removes gap risk and removes gap upside with it. Neither is free.

The failure mode to plan for is a schedule entered against the wrong clock. Four or five hours of error will flatten an account at a time nobody intended, and the trades are gone. Confirm the server offset on the panel before disabling dry run.

---

## Requirements

- MetaTrader 4, build 600 or later
- No external libraries or DLLs

## License

MIT
