#!/usr/bin/env python3
"""Low-overhead /proc sampler and incident recorder for Perfwatch."""

from __future__ import annotations

import argparse
import collections
import contextlib
import datetime as dt
import fcntl
import json
import os
import re
import shlex
import signal
import tempfile
import time
from pathlib import Path
from typing import Any, Iterable

SAMPLE_SECONDS = 5
PRE_EVENT_SAMPLES = 24
SUSTAINED_SAMPLES = 3
SUSTAINED_WINDOW = 4
RECOVERY_SAMPLES = 3
MAX_GAP_SECONDS = 30
MERGE_GAP_SECONDS = 60
RETENTION_DAYS = 30
MAX_RECORDS = 500
MAX_FILE_BYTES = 512 * 1024
SCHEMA_VERSION = 1
PROCESS_ROWS_PER_RESOURCE = 5


def parse_pressure(text: str) -> dict[str, float]:
    result: dict[str, float] = {}
    for line in text.splitlines():
        fields = line.split()
        if not fields or fields[0] not in ("some", "full"):
            continue
        for field in fields[1:]:
            key, separator, value = field.partition("=")
            if separator and key in ("avg10", "avg60", "avg300", "total"):
                try:
                    result[f"{fields[0]}_{key}"] = float(value)
                except ValueError:
                    pass
    return result


def parse_proc_stat(text: str) -> tuple[int, int]:
    line = next((line for line in text.splitlines() if line.startswith("cpu ")), "")
    values = [int(value) for value in line.split()[1:] if value.isdigit()]
    if len(values) < 4:
        raise ValueError("missing aggregate CPU counters")
    idle = values[3] + (values[4] if len(values) > 4 else 0)
    return sum(values), idle


def parse_vmstat(text: str) -> dict[str, int]:
    wanted = {"pswpin", "pswpout"}
    result: dict[str, int] = {}
    for line in text.splitlines():
        fields = line.split()
        if len(fields) == 2 and fields[0] in wanted:
            try:
                result[fields[0]] = int(fields[1])
            except ValueError:
                pass
    return result


def parse_meminfo(text: str) -> dict[str, int]:
    result: dict[str, int] = {}
    for line in text.splitlines():
        key, separator, rest = line.partition(":")
        if not separator:
            continue
        fields = rest.split()
        try:
            result[key] = int(fields[0])
        except (IndexError, ValueError):
            pass
    return result


def counter_delta(current: int, previous: int) -> int | None:
    return current - previous if current >= previous else None


def cpu_utilization(current: tuple[int, int], previous: tuple[int, int]) -> float | None:
    total = counter_delta(current[0], previous[0])
    idle = counter_delta(current[1], previous[1])
    if total is None or idle is None or total <= 0 or idle > total:
        return None
    return max(0.0, min(1.0, (total - idle) / total))


def read_text(path: Path) -> str:
    with path.open("r", encoding="ascii", errors="replace") as handle:
        return handle.read()


def normalize_app_id(value: str) -> str:
    return re.sub(r"[^a-z0-9]", "", value.lower())


class DesktopNames:
    """Resolve executable and systemd app identities to desktop entry names."""

    def __init__(self) -> None:
        self.by_executable: dict[str, str] = {}
        self.by_id: dict[str, str] = {}
        data_home = Path(os.environ.get("XDG_DATA_HOME", Path.home() / ".local/share"))
        data_dirs = os.environ.get("XDG_DATA_DIRS", "/usr/local/share:/usr/share").split(":")
        for base in [data_home, *(Path(item) for item in data_dirs if item)]:
            self._scan(base / "applications")

    def _scan(self, directory: Path) -> None:
        if not directory.is_dir():
            return
        with contextlib.suppress(OSError):
            for path in directory.rglob("*.desktop"):
                self._read_entry(path)

    def _read_entry(self, path: Path) -> None:
        try:
            lines = path.read_text(encoding="utf-8", errors="replace").splitlines()
        except OSError:
            return
        values: dict[str, str] = {}
        in_entry = False
        for line in lines:
            stripped = line.strip()
            if stripped.startswith("["):
                in_entry = stripped == "[Desktop Entry]"
                continue
            if not in_entry or "=" not in line:
                continue
            key, value = line.split("=", 1)
            if key in ("Name", "Exec", "Type", "NoDisplay"):
                values[key] = value.strip()
        name = values.get("Name", "").strip()
        if not name or values.get("Type", "Application") != "Application":
            return
        desktop_id = normalize_app_id(path.stem)
        if desktop_id:
            self.by_id.setdefault(desktop_id, name)
        try:
            command = shlex.split(values.get("Exec", ""))
        except ValueError:
            command = []
        if not command:
            return
        executable = Path(command[0]).name
        if executable == "env":
            command = [item for item in command[1:] if "=" not in item]
            executable = Path(command[0]).name if command else ""
        if executable not in ("", "flatpak", "gtk-launch"):
            self.by_executable.setdefault(executable, name)

    def resolve(self, executable: str, cgroup: str) -> str:
        normalized = normalize_app_id(cgroup)
        matches = [(len(app_id), name) for app_id, name in self.by_id.items() if len(app_id) >= 6 and app_id in normalized]
        if matches:
            return max(matches)[1]
        return self.by_executable.get(executable, "")


def parse_process_stat(text: str) -> tuple[str, int, int, int]:
    left = text.find("(")
    right = text.rfind(")")
    if left < 0 or right <= left:
        raise ValueError("malformed process stat")
    fields = text[right + 2 :].split()
    if len(fields) < 22:
        raise ValueError("short process stat")
    return text[left + 1 : right], int(fields[11]) + int(fields[12]), int(fields[19]), int(fields[21])


def parse_process_io(text: str) -> int:
    total = 0
    for line in text.splitlines():
        key, separator, value = line.partition(":")
        if separator and key in ("read_bytes", "write_bytes"):
            with contextlib.suppress(ValueError):
                total += int(value.strip())
    return total


def script_basename(proc_path: Path, executable: str) -> str:
    interpreters = {"python", "python3", "pypy", "pypy3", "node", "ruby", "perl", "bash", "sh"}
    if executable not in interpreters:
        return ""
    try:
        arguments = (proc_path / "cmdline").read_bytes().split(b"\0")[1:4]
    except OSError:
        return ""
    for argument in arguments:
        value = argument.decode("utf-8", errors="replace")
        if value and not value.startswith("-") and Path(value).suffix.lower() in (".py", ".js", ".mjs", ".rb", ".pl", ".sh"):
            return Path(value).name[:80]
    return ""


class ProcessTracker:
    def __init__(self) -> None:
        self.desktop_names = DesktopNames()
        self.previous: dict[tuple[int, int], tuple[int, int]] = {}
        self.clock_ticks = max(1, int(os.sysconf("SC_CLK_TCK")))
        self.page_size = max(1, int(os.sysconf("SC_PAGE_SIZE")))
        self.cpu_count = max(1, os.cpu_count() or 1)
        self.uid = os.geteuid()
        self.last_monotonic: float | None = None
        self.current_pids: set[int] = set()

    def sample(self, proc: Path, monotonic: float) -> list[dict[str, Any]]:
        elapsed = monotonic - self.last_monotonic if self.last_monotonic is not None else 0
        current: dict[tuple[int, int], tuple[int, int]] = {}
        rows: list[dict[str, Any]] = []
        try:
            entries = list(proc.iterdir())
        except OSError:
            return []
        for process_path in entries:
            if not process_path.name.isdigit():
                continue
            try:
                if process_path.stat().st_uid != self.uid:
                    continue
                pid = int(process_path.name)
                comm, ticks, started, rss_pages = parse_process_stat(read_text(process_path / "stat"))
                io_bytes = parse_process_io(read_text(process_path / "io"))
                executable = Path(os.readlink(process_path / "exe")).name
                cgroup = read_text(process_path / "cgroup")
            except (OSError, ValueError):
                continue
            identity = (pid, started)
            current[identity] = (ticks, io_bytes)
            old = self.previous.get(identity)
            cpu_percent = 0.0
            io_mib_per_second = 0.0
            if old and 0 < elapsed <= MAX_GAP_SECONDS:
                tick_delta = counter_delta(ticks, old[0])
                io_delta = counter_delta(io_bytes, old[1])
                if tick_delta is not None:
                    cpu_percent = 100 * tick_delta / self.clock_ticks / elapsed / self.cpu_count
                if io_delta is not None:
                    io_mib_per_second = io_delta / elapsed / (1024 * 1024)
            name = self.desktop_names.resolve(executable, cgroup)
            if not name:
                name = script_basename(process_path, executable) or executable or comm
            rows.append({
                "key": f"{pid}:{started}",
                "pid": pid,
                "name": name[:80],
                "rssMiB": round(max(0, rss_pages) * self.page_size / (1024 * 1024), 1),
                "cpuPercent": round(max(0.0, cpu_percent), 1),
                "ioMiBPerSecond": round(max(0.0, io_mib_per_second), 2),
            })
        self.previous = current
        self.current_pids = {identity[0] for identity in current}
        self.last_monotonic = monotonic
        selected: dict[str, dict[str, Any]] = {}
        for key in ("rssMiB", "cpuPercent", "ioMiBPerSecond"):
            for row in sorted(rows, key=lambda item: float(item[key]), reverse=True)[:PROCESS_ROWS_PER_RESOURCE]:
                selected[row["key"]] = row
        return list(selected.values())


def read_sample(proc: Path = Path("/proc"), process_tracker: ProcessTracker | None = None) -> dict[str, Any]:
    memory = parse_pressure(read_text(proc / "pressure/memory"))
    cpu_pressure = parse_pressure(read_text(proc / "pressure/cpu"))
    io = parse_pressure(read_text(proc / "pressure/io"))
    vmstat = parse_vmstat(read_text(proc / "vmstat"))
    meminfo = parse_meminfo(read_text(proc / "meminfo"))
    available = meminfo.get("MemAvailable", 0)
    total_memory = meminfo.get("MemTotal", 0)
    swap_total = meminfo.get("SwapTotal", 0)
    swap_free = meminfo.get("SwapFree", 0)
    monotonic = time.monotonic()
    sample = {
        "monotonic": monotonic,
        "timestamp": time.time(),
        "cpuCounters": parse_proc_stat(read_text(proc / "stat")),
        "swapIn": vmstat.get("pswpin", 0),
        "swapOut": vmstat.get("pswpout", 0),
        "memoryPsi": memory.get("some_avg10", 0.0),
        "memoryFullPsi": memory.get("full_avg10", 0.0),
        "cpuPsi": cpu_pressure.get("some_avg10", 0.0),
        "ioPsi": io.get("some_avg10", 0.0),
        "ioFullPsi": io.get("full_avg10", 0.0),
        "memoryAvailableMiB": round(available / 1024, 1),
        "memoryUsedPercent": round(100 * (1 - available / total_memory), 1) if total_memory else 0.0,
        "swapUsedMiB": round((swap_total - swap_free) / 1024, 1),
    }
    sample["processes"] = process_tracker.sample(proc, monotonic) if process_tracker else []
    sample["processPids"] = sorted(process_tracker.current_pids) if process_tracker else []
    return sample


def derive_metrics(current: dict[str, Any], previous: dict[str, Any] | None) -> dict[str, Any]:
    metrics = {key: value for key, value in current.items() if key not in ("cpuCounters", "monotonic")}
    metrics["cpuPercent"] = 0.0
    metrics["swapPagesPerSecond"] = 0.0
    if previous is None:
        return metrics
    elapsed = current["monotonic"] - previous["monotonic"]
    if elapsed <= 0 or elapsed > MAX_GAP_SECONDS:
        metrics["gap"] = True
        return metrics
    utilization = cpu_utilization(current["cpuCounters"], previous["cpuCounters"])
    if utilization is not None:
        metrics["cpuPercent"] = round(utilization * 100, 1)
    swap_in = counter_delta(current["swapIn"], previous["swapIn"])
    swap_out = counter_delta(current["swapOut"], previous["swapOut"])
    if swap_in is not None and swap_out is not None:
        metrics["swapPagesPerSecond"] = round((swap_in + swap_out) / elapsed, 2)
    else:
        metrics["counterReset"] = True
    return metrics


def trigger_levels(metrics: dict[str, Any]) -> dict[str, int]:
    levels: dict[str, int] = {}
    memory = float(metrics.get("memoryPsi", 0))
    cpu = float(metrics.get("cpuPercent", 0))
    cpu_psi = float(metrics.get("cpuPsi", 0))
    io = float(metrics.get("ioPsi", 0))
    swap = float(metrics.get("swapPagesPerSecond", 0))
    if memory >= 10:
        levels["memory"] = 3 if memory >= 30 else 2 if memory >= 20 else 1
    if cpu >= 95 and cpu_psi >= 20:
        levels["cpu"] = 3 if cpu >= 99 or cpu_psi >= 50 else 2 if cpu >= 98 or cpu_psi >= 35 else 1
    if io >= 15:
        levels["io"] = 3 if io >= 50 else 2 if io >= 30 else 1
    # Compressed swap can move many pages without slowing the system. Treat
    # swap as an incident only when throughput coincides with real pressure.
    memory_used = float(metrics.get("memoryUsedPercent", 0))
    if swap >= 256 and (memory >= 5 or io >= 5 or memory_used >= 90):
        levels["swap"] = 3 if swap >= 4096 else 2 if swap >= 1024 else 1
    return levels


def likely_cause(causes: Iterable[str]) -> str:
    names = set(causes)
    if "memory" in names and "swap" in names:
        return "Memory pressure with swapping"
    if "io" in names and "swap" in names:
        return "Swap-driven storage contention"
    labels = {"memory": "Memory pressure", "swap": "Swap activity", "cpu": "CPU saturation", "io": "I/O pressure"}
    return " and ".join(labels[name] for name in ("memory", "swap", "cpu", "io") if name in names) or "Resource pressure"


def severity_name(level: int) -> str:
    return ("low", "moderate", "high", "critical")[max(0, min(3, level))]


def metric_snapshot(metrics: dict[str, Any]) -> dict[str, float]:
    keys = ("cpuPercent", "cpuPsi", "memoryPsi", "memoryFullPsi", "ioPsi", "ioFullPsi", "swapPagesPerSecond", "swapUsedMiB", "memoryAvailableMiB", "memoryUsedPercent")
    return {key: round(float(metrics.get(key, 0)), 2) for key in keys}


def baseline_summary(samples: Iterable[dict[str, Any]]) -> dict[str, float]:
    rows = list(samples)
    keys = ("cpuPercent", "memoryPsi", "ioPsi", "swapPagesPerSecond", "memoryAvailableMiB")
    if not rows:
        return {}
    return {key: round(sum(float(row.get(key, 0)) for row in rows) / len(rows), 2) for key in keys}


def offender_score(row: dict[str, Any], causes: Iterable[str]) -> float:
    names = set(causes)
    scores = []
    if "memory" in names or "swap" in names:
        scores.append(float(row.get("rssMiB", 0)) / 10)
    if "cpu" in names:
        scores.append(float(row.get("cpuPercent", 0)))
    if "io" in names:
        scores.append(float(row.get("ioMiBPerSecond", 0)) * 10)
    return max(scores, default=0.0)


def top_offenders(samples: Iterable[dict[str, Any]], causes: Iterable[str]) -> list[dict[str, Any]]:
    best: dict[str, dict[str, Any]] = {}
    for sample in samples:
        for raw in sample.get("processes", []):
            if not isinstance(raw, dict):
                continue
            identity = str(raw.get("key") or f"{raw.get('pid', 0)}:{raw.get('name', '')}")
            row = {
                "pid": int(raw.get("pid", 0)),
                "name": str(raw.get("name", "Unknown"))[:80],
                "rssMiB": round(float(raw.get("rssMiB", 0)), 1),
                "cpuPercent": round(float(raw.get("cpuPercent", 0)), 1),
                "ioMiBPerSecond": round(float(raw.get("ioMiBPerSecond", 0)), 2),
            }
            previous = best.get(identity)
            if previous:
                row["rssMiB"] = max(row["rssMiB"], previous["rssMiB"])
                row["cpuPercent"] = max(row["cpuPercent"], previous["cpuPercent"])
                row["ioMiBPerSecond"] = max(row["ioMiBPerSecond"], previous["ioMiBPerSecond"])
            best[identity] = row
    ranked = sorted(best.values(), key=lambda row: offender_score(row, causes), reverse=True)
    return [row for row in ranked if offender_score(row, causes) > 0][:PROCESS_ROWS_PER_RESOURCE]


def recovery_note(peak: list[dict[str, Any]], present_pids: Iterable[int]) -> str:
    recovery_pids = {int(pid) for pid in present_pids}
    for row in peak:
        if int(row.get("pid", 0)) not in recovery_pids:
            return f"{row.get('name', 'A top process')} exited before recovery"
    return "Pressure returned below the recovery threshold"


def iso_time(timestamp: float) -> str:
    return dt.datetime.fromtimestamp(timestamp, dt.timezone.utc).isoformat().replace("+00:00", "Z")


class Detector:
    def __init__(self) -> None:
        self.ring: collections.deque[dict[str, Any]] = collections.deque(maxlen=PRE_EVENT_SAMPLES)
        self.windows = {name: collections.deque(maxlen=SUSTAINED_WINDOW) for name in ("memory", "swap", "cpu", "io")}
        self.recovery_streak = 0
        self.active: dict[str, Any] | None = None

    def restore(self, active: Any, now: float) -> dict[str, Any] | None:
        if not isinstance(active, dict):
            return None
        last = float(active.get("lastTimestamp", 0))
        if last and 0 <= now - last <= MAX_GAP_SECONDS:
            self.active = active
            return None
        return None

    def reset_after_gap(self, timestamp: float) -> dict[str, Any] | None:
        self.active = None
        self.ring.clear()
        self.windows = {name: collections.deque(maxlen=SUSTAINED_WINDOW) for name in self.windows}
        self.recovery_streak = 0
        return None

    def update(self, metrics: dict[str, Any]) -> dict[str, Any] | None:
        timestamp = float(metrics["timestamp"])
        if metrics.get("gap"):
            return self.reset_after_gap(timestamp)
        levels = trigger_levels(metrics)
        for name, window in self.windows.items():
            window.append(name in levels)
        sustained = {name: levels[name] for name in levels if sum(self.windows[name]) >= SUSTAINED_SAMPLES}
        primary = {name: level for name, level in sustained.items() if name != "swap"}
        if self.active is None and primary:
            self.active = {
                "id": f"{int(timestamp * 1000)}-{os.getpid()}",
                "startTime": iso_time(timestamp - (SUSTAINED_WINDOW - 1) * SAMPLE_SECONDS),
                "startTimestamp": timestamp - (SUSTAINED_WINDOW - 1) * SAMPLE_SECONDS,
                "lastTimestamp": timestamp,
                "causes": sorted(sustained),
                "likelyCause": likely_cause(sustained),
                "severity": severity_name(max(sustained.values())),
                "severityLevel": max(sustained.values()),
                "peak": metric_snapshot(metrics),
                "preEvent": baseline_summary(self.ring),
                "offenders": {
                    "preEvent": top_offenders(self.ring, sustained),
                    "peak": top_offenders([metrics], sustained),
                },
            }
        elif self.active is not None:
            causes = set(self.active.get("causes", [])) | set(sustained)
            self.active["causes"] = sorted(causes)
            self.active["likelyCause"] = likely_cause(causes)
            self.active["lastTimestamp"] = timestamp
            level = max([int(self.active.get("severityLevel", 0)), *sustained.values()])
            self.active["severityLevel"] = level
            self.active["severity"] = severity_name(level)
            peak = self.active.setdefault("peak", {})
            for key, value in metric_snapshot(metrics).items():
                if key == "memoryAvailableMiB":
                    peak[key] = min(float(peak.get(key, value)), value)
                else:
                    peak[key] = max(float(peak.get(key, 0)), value)
            offenders = self.active.setdefault("offenders", {})
            peak_rows = offenders.get("peak", [])
            offenders["peak"] = top_offenders([{"processes": peak_rows}, metrics], causes)
        if self.active:
            self.recovery_streak = self.recovery_streak + 1 if self._below_recovery(metrics) else 0
            if self.recovery_streak >= RECOVERY_SAMPLES:
                recovery_rows = top_offenders([metrics], self.active.get("causes", []))
                peak_rows = self.active.get("offenders", {}).get("peak", [])
                completed = self._finish(timestamp, {
                    "reason": "recovered",
                    "metrics": metric_snapshot(metrics),
                    "offenders": recovery_rows,
                    "summary": recovery_note(peak_rows, metrics.get("processPids", [])),
                })
                self.ring.append(metrics)
                return completed
        self.ring.append(metrics)
        return None

    def _below_recovery(self, metrics: dict[str, Any]) -> bool:
        causes = set(self.active.get("causes", [])) if self.active else set()
        if "memory" in causes and float(metrics.get("memoryPsi", 0)) >= 5:
            return False
        if "cpu" in causes and float(metrics.get("cpuPsi", 0)) >= 10 and float(metrics.get("cpuPercent", 0)) >= 85:
            return False
        if "io" in causes and float(metrics.get("ioPsi", 0)) >= 7:
            return False
        return True

    def _finish(self, timestamp: float, recovery: dict[str, Any]) -> dict[str, Any]:
        incident = self.active or {}
        start = float(incident.pop("startTimestamp", timestamp))
        incident.pop("lastTimestamp", None)
        incident["endTime"] = iso_time(timestamp)
        incident["durationSeconds"] = max(0, round(timestamp - start))
        incident["recovery"] = recovery
        self.active = None
        self.recovery_streak = 0
        return incident


def merge_incident(incidents: list[dict[str, Any]], incident: dict[str, Any]) -> list[dict[str, Any]]:
    if incidents:
        newest = incidents[0]
        try:
            previous_end = dt.datetime.fromisoformat(str(newest["endTime"]).replace("Z", "+00:00")).timestamp()
            current_start = dt.datetime.fromisoformat(str(incident["startTime"]).replace("Z", "+00:00")).timestamp()
        except (KeyError, TypeError, ValueError):
            previous_end = current_start = -MERGE_GAP_SECONDS - 1
        related = bool(set(newest.get("causes", [])) & set(incident.get("causes", [])))
        if related and 0 <= current_start - previous_end <= MERGE_GAP_SECONDS:
            merged = dict(newest)
            causes = set(newest.get("causes", [])) | set(incident.get("causes", []))
            merged["causes"] = sorted(causes)
            merged["likelyCause"] = likely_cause(causes)
            merged["endTime"] = incident.get("endTime")
            start = dt.datetime.fromisoformat(str(merged["startTime"]).replace("Z", "+00:00")).timestamp()
            end = dt.datetime.fromisoformat(str(merged["endTime"]).replace("Z", "+00:00")).timestamp()
            merged["durationSeconds"] = max(0, round(end - start))
            merged["severityLevel"] = max(int(newest.get("severityLevel", 0)), int(incident.get("severityLevel", 0)))
            merged["severity"] = severity_name(merged["severityLevel"])
            peak = dict(newest.get("peak", {}))
            for key, value in incident.get("peak", {}).items():
                peak[key] = min(float(peak.get(key, value)), value) if key == "memoryAvailableMiB" else max(float(peak.get(key, 0)), value)
            merged["peak"] = peak
            merged["recovery"] = incident.get("recovery", {})
            old_offenders = newest.get("offenders", {})
            new_offenders = incident.get("offenders", {})
            merged["offenders"] = {
                "preEvent": old_offenders.get("preEvent", []),
                "peak": top_offenders(
                    [{"processes": old_offenders.get("peak", [])}, {"processes": new_offenders.get("peak", [])}],
                    causes,
                ),
            }
            return [merged, *incidents[1:]]
    return [incident, *incidents]


def valid_incidents(value: Any) -> list[dict[str, Any]]:
    return [row for row in value if isinstance(row, dict) and isinstance(row.get("startTime"), str)] if isinstance(value, list) else []


def load_state(path: Path) -> dict[str, Any]:
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, UnicodeError, json.JSONDecodeError):
        return {}
    return data if isinstance(data, dict) and data.get("schemaVersion") == SCHEMA_VERSION else {}


def prune_incidents(incidents: list[dict[str, Any]], now: float) -> list[dict[str, Any]]:
    cutoff = now - RETENTION_DAYS * 86400
    retained = []
    for incident in incidents[:MAX_RECORDS]:
        try:
            timestamp = dt.datetime.fromisoformat(str(incident["startTime"]).replace("Z", "+00:00")).timestamp()
        except (KeyError, TypeError, ValueError):
            continue
        if timestamp >= cutoff:
            retained.append(incident)
    return retained


def encoded_state(state: dict[str, Any]) -> bytes:
    state = dict(state)
    incidents = list(state.get("incidents", []))
    while True:
        state["incidents"] = incidents
        encoded = (json.dumps(state, separators=(",", ":"), ensure_ascii=True) + "\n").encode("utf-8")
        if len(encoded) <= MAX_FILE_BYTES or not incidents:
            return encoded
        incidents.pop()


def atomic_write(path: Path, state: dict[str, Any]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    payload = encoded_state(state)
    descriptor, temporary = tempfile.mkstemp(prefix=f".{path.name}.", dir=path.parent)
    try:
        os.fchmod(descriptor, 0o600)
        with os.fdopen(descriptor, "wb") as handle:
            handle.write(payload)
            handle.flush()
            os.fsync(handle.fileno())
        os.replace(temporary, path)
        directory = os.open(path.parent, os.O_RDONLY | getattr(os, "O_DIRECTORY", 0))
        try:
            os.fsync(directory)
        finally:
            os.close(directory)
    finally:
        with contextlib.suppress(FileNotFoundError):
            os.unlink(temporary)


def state_path() -> Path:
    base = Path(os.environ.get("XDG_STATE_HOME", Path.home() / ".local/state"))
    return base / "omarchy/perfwatch/state.json"


@contextlib.contextmanager
def state_lock(path: Path):
    path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    with (path.parent / ".lock").open("a", encoding="ascii") as handle:
        fcntl.flock(handle, fcntl.LOCK_EX)
        yield


def clear_history(path: Path) -> None:
    with state_lock(path):
        state = load_state(path)
        state.update({"schemaVersion": SCHEMA_VERSION, "updatedAt": iso_time(time.time()), "incidents": [], "clearGeneration": int(state.get("clearGeneration", 0)) + 1})
        state.pop("activeIncident", None)
        atomic_write(path, state)


def public_active(active: dict[str, Any] | None, now: float) -> dict[str, Any] | None:
    if not active:
        return None
    result = dict(active)
    result["durationSeconds"] = max(0, round(now - float(active.get("startTimestamp", now))))
    return result


def run(path: Path, once: bool = False) -> None:
    running = True

    def stop(_signum: int, _frame: Any) -> None:
        nonlocal running
        running = False

    signal.signal(signal.SIGTERM, stop)
    signal.signal(signal.SIGINT, stop)
    detector = Detector()
    process_tracker = ProcessTracker()
    initial = load_state(path)
    incidents = valid_incidents(initial.get("incidents"))
    clear_generation = int(initial.get("clearGeneration", 0))
    interrupted = detector.restore(initial.get("activeIncident"), time.time())
    if interrupted:
        incidents = merge_incident(incidents, interrupted)
    previous = None
    started = time.time()
    while running:
        loop_start = time.monotonic()
        try:
            sample = read_sample(process_tracker=process_tracker)
            metrics = derive_metrics(sample, previous)
            previous = sample
            completed = detector.update(metrics)
            with state_lock(path):
                disk_state = load_state(path)
                disk_generation = int(disk_state.get("clearGeneration", clear_generation))
                if disk_generation != clear_generation:
                    clear_generation = disk_generation
                    incidents = []
                    detector.active = None
                    completed = None
                if completed:
                    incidents = merge_incident(incidents, completed)
                incidents = prune_incidents(incidents, sample["timestamp"])
                active = public_active(detector.active, sample["timestamp"])
                state = {
                    "schemaVersion": SCHEMA_VERSION,
                    "updatedAt": iso_time(sample["timestamp"]),
                    "collector": {"pid": os.getpid(), "startedAt": iso_time(started), "sampleSeconds": SAMPLE_SECONDS},
                    "healthy": active is None,
                    "current": metric_snapshot(metrics),
                    "incidents": incidents,
                    "clearGeneration": clear_generation,
                }
                if active:
                    state["activeIncident"] = active
                atomic_write(path, state)
        except (OSError, ValueError) as error:
            with state_lock(path):
                state = load_state(path)
                state.update({"schemaVersion": SCHEMA_VERSION, "updatedAt": iso_time(time.time()), "collectorError": str(error), "incidents": valid_incidents(state.get("incidents"))})
                atomic_write(path, state)
        if once:
            break
        remaining = SAMPLE_SECONDS - (time.monotonic() - loop_start)
        if remaining > 0:
            time.sleep(remaining)


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--clear", action="store_true", help="clear stored incident history")
    parser.add_argument("--once", action="store_true", help=argparse.SUPPRESS)
    parser.add_argument("--state-file", type=Path, default=state_path(), help=argparse.SUPPRESS)
    arguments = parser.parse_args()
    if arguments.clear:
        clear_history(arguments.state_file)
    else:
        run(arguments.state_file, arguments.once)


if __name__ == "__main__":
    main()
