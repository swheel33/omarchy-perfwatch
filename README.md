# omarchy-perfwatch

A lightweight Omarchy shell plugin for recording and reviewing historical
system-performance incidents. Perfwatch is intentionally not a live monitor:
use tools such as btop for current process inspection, then use Perfwatch to
see whether sustained pressure occurred while you were away.

Perfwatch is especially useful on memory-constrained laptops, including
lower-memory Dell XPS 13 configurations, where background applications and
swap activity can cause a slowdown that is difficult to explain after the
system recovers. It works on any Omarchy system with Linux pressure metrics.

## Features

- Samples Linux `/proc` pressure and resource counters every five seconds.
- Detects sustained memory PSI, CPU saturation, and I/O PSI, with swap as supporting evidence.
- Ignores isolated spikes by requiring three of four triggering samples.
- Keeps two minutes of pre-event context and records peak and recovery data.
- Records relevant CPU and I/O processes and groups the biggest memory users by application.
- Merges related incidents separated by no more than one minute.
- Provides 24-hour, 7-day, and 30-day views in a keyboard-friendly popup.
- Uses a quiet bar icon when healthy and a red indicator only while pressure is active.
- Runs without root privileges, external Python packages, or desktop notifications.

## Installation

Install and enable the plugin from its Git repository:

```sh
omarchy plugin add https://github.com/swheel33/omarchy-perfwatch --enable
```

If needed, place it on the right side of the bar:

```sh
omarchy bar move swheel33.perfwatch --section right
```

Remove the plugin with:

```sh
omarchy plugin remove swheel33.perfwatch
```

The shell hot-reloads plugin and bar changes. Click the bar icon to open the
history panel and review each incident's plain-language cause and biggest
memory users. Clearing history requires two clicks within five seconds.

## Storage And Privacy

Perfwatch reads only local `/proc` files and makes no network requests. The
collector runs only while the widget is active. It atomically writes one JSON
file to:

```text
$XDG_STATE_HOME/omarchy/perfwatch/state.json
```

When `XDG_STATE_HOME` is unset, the path is
`~/.local/state/omarchy/perfwatch/state.json`.

History is limited to 30 days, 500 records, and 512 KiB. The oldest records
are removed first. Counter resets, malformed prior state, collector restarts,
and suspend or sampling gaps are handled without treating invalid deltas as
incidents.

Process rows contain only a resolved application or executable name, PID, RSS,
CPU share, and I/O rate. Memory totals may group processes under their resolved
application or parent application. Persisted data never contains full command
lines, arguments, paths, window titles, document names, URLs, or environment
values.

## Detection

An incident begins after three of four samples cross a primary pressure
threshold. It is added to history only after recovery:

| Signal | Starting threshold |
| --- | --- |
| Memory pressure | `/proc/pressure/memory` `some avg10` at least 10% |
| Swap activity | Supporting evidence above 256 pages/s; never a standalone trigger or a high-severity signal by itself |
| CPU saturation | CPU utilization at least 95% and CPU PSI `some avg10` at least 20% |
| I/O pressure | `/proc/pressure/io` `some avg10` at least 15% |

Recovery is recorded after three consecutive clear samples. Severity increases
at higher pressure and activity levels; it is an incident-ranking aid, not a
hardware-health diagnosis.

## Resource Use

The collector is a single standard-library Python process with fixed-size
in-memory structures. Every five seconds it scans same-user `/proc` entries
and retains only the leading CPU, RSS, and I/O rows. The design target is less
than 30 MB incremental idle memory and negligible idle CPU.

## Development

Validate the manifest and Python source with:

```sh
omarchy plugin validate .
python3 -m py_compile collector.py
```

Run a one-shot collector check against a temporary state file with:

```sh
python3 collector.py --once --state-file /tmp/perfwatch-state.json
```

## License

MIT
