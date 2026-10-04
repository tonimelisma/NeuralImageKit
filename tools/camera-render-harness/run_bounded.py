#!/usr/bin/env python3
"""Own one offline job and stop its process group before exhausting this Mac.

The advisory lock is shared by all experiment invocations. A job gets a private
process group, durable output and a resource receipt even when interrupted. RSS
is a conservative sum over its live descendants; system availability also covers
native graphics allocations that RSS alone cannot establish. No job is retried.
"""
import argparse
import ctypes
import errno
import fcntl
import json
import os
from pathlib import Path
import re
import signal
import subprocess
import time


# Public libproc/sys/resource.h RUSAGE_INFO_V4 layout, verified against the
# configured Xcode SDK. Footprint includes charged memory that RSS omits.
class RUsageInfoV4(ctypes.Structure):
    _fields_ = [('ri_uuid', ctypes.c_uint8 * 16)] + [(name, ctypes.c_uint64) for name in (
        'ri_user_time ri_system_time ri_pkg_idle_wkups ri_interrupt_wkups ri_pageins '
        'ri_wired_size ri_resident_size ri_phys_footprint ri_proc_start_abstime ri_proc_exit_abstime '
        'ri_child_user_time ri_child_system_time ri_child_pkg_idle_wkups ri_child_interrupt_wkups '
        'ri_child_pageins ri_child_elapsed_abstime ri_diskio_bytesread ri_diskio_byteswritten '
        'ri_cpu_time_qos_default ri_cpu_time_qos_maintenance ri_cpu_time_qos_background ri_cpu_time_qos_utility '
        'ri_cpu_time_qos_legacy ri_cpu_time_qos_user_initiated ri_cpu_time_qos_user_interactive '
        'ri_billed_system_time ri_serviced_system_time ri_logical_writes ri_lifetime_max_phys_footprint '
        'ri_instructions ri_cycles ri_billed_energy ri_serviced_energy ri_interval_max_phys_footprint ri_runnable_time'
    ).split()]


libproc = ctypes.CDLL('/usr/lib/libproc.dylib', use_errno=True)
libproc.proc_pid_rusage.argtypes = [ctypes.c_int, ctypes.c_int, ctypes.c_void_p]
libproc.proc_pid_rusage.restype = ctypes.c_int


def process_resources(pid):
    rows = subprocess.check_output(['ps', '-axo', 'pid,ppid,rss'], text=True)
    facts = [tuple(map(int, line.split())) for line in rows.splitlines()[1:] if len(line.split()) == 3]
    owned = {pid}
    while True:
        expanded = owned | {child for child, parent, _ in facts if parent in owned}
        if expanded == owned:
            break
        owned = expanded
    footprint = 0
    lifetime_peak = 0
    for member in owned:
        info = RUsageInfoV4()
        if libproc.proc_pid_rusage(member, 4, ctypes.byref(info)) != 0:
            code = ctypes.get_errno()
            if code == errno.ESRCH:  # Process exited between inventory and observation.
                continue
            raise OSError(code, 'process footprint unavailable')
        footprint += info.ri_phys_footprint
        lifetime_peak += info.ri_lifetime_max_phys_footprint
    return {'residentKiB': sum(rss for child, _, rss in facts if child in owned),
            'physicalFootprintKiB': footprint // 1024,
            'summedLifetimePeakFootprintKiB': lifetime_peak // 1024}


def available_percent():
    output = subprocess.check_output(['/usr/bin/memory_pressure'], text=True, timeout=10)
    match = re.search(r'System-wide memory free percentage:\s*(\d+)%', output)
    if match is None:
        raise RuntimeError('memory availability unavailable')
    return int(match[1])


def stop_group(child):
    try:
        os.killpg(child.pid, signal.SIGTERM)
    except ProcessLookupError:
        child.wait()
        return
    # Kill the entire group after a grace period, including any descendants
    # whose parent exited first. A new job cannot overlap surviving children.
    time.sleep(1)
    child.poll()  # Reap an exited leader before signalling surviving descendants.
    try:
        os.killpg(child.pid, signal.SIGKILL)
    except ProcessLookupError:
        pass
    child.wait()


def run(args):
    if args.max_rss_mib <= 0 or args.max_footprint_mib <= 0 or not 0 < args.min_available_percent < 100 or not 0 < args.poll_seconds <= 5:
        raise ValueError('invalid resource budget')
    command = args.command[1:] if args.command[:1] == ['--'] else args.command
    if not command:
        raise ValueError('missing command')
    for path in [args.log, args.report, args.lock]:
        path.parent.mkdir(parents=True, exist_ok=True)
    blocked = args.lock.with_name(args.lock.name + '.blocked')
    if blocked.exists():
        raise RuntimeError('prior job cleanup unverified; inspect the recorded process group first')
    if args.log.exists() or args.report.exists():
        raise FileExistsError('job outputs already exist')
    started = time.monotonic()
    samples = []
    child = None
    reason = 'completed'
    with args.lock.open('a') as lock:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        with args.log.open('x') as output:
            try:
                before = available_percent()
                if before < args.min_available_percent:
                    reason = 'insufficient-system-memory-before-start'
                else:
                    child = subprocess.Popen(command, stdout=output, stderr=subprocess.STDOUT,
                                             stdin=subprocess.DEVNULL, start_new_session=True)
                    while child.poll() is None:
                        resources = process_resources(child.pid)
                        rss = resources["residentKiB"]
                        footprint = resources["physicalFootprintKiB"]
                        available = available_percent()
                        samples.append({'elapsedSeconds': time.monotonic() - started,
                                        **resources, 'systemAvailablePercent': available})
                        print(f'op=experiment.resource job={args.name} rssMiB={rss / 1024:.1f} footprintMiB={footprint / 1024:.1f} availablePercent={available}', flush=True)
                        if rss > args.max_rss_mib * 1024:
                            reason = 'resident-budget-exceeded'
                            break
                        if max(footprint, resources['summedLifetimePeakFootprintKiB']) > args.max_footprint_mib * 1024:
                            reason = 'physical-footprint-budget-exceeded'
                            break
                        if available < args.min_available_percent:
                            reason = 'system-memory-budget-exceeded'
                            break
                        time.sleep(args.poll_seconds)
            except KeyboardInterrupt:
                reason = 'interrupted'
            except Exception as error:
                reason = f'resource-monitor-failed:{type(error).__name__}'
            finally:
                if child is not None:
                    try:
                        stop_group(child)
                    except OSError as error:
                        reason = f'process-cleanup-failed:{type(error).__name__}'
                        blocked.write_text(json.dumps({'job': args.name, 'processGroup': child.pid}) + '\n')
                exit_code = child.poll() if child is not None else None
                if reason == 'completed' and exit_code != 0:
                    reason = 'child-failed'
                report = {'contractVersion': 2, 'job': args.name, 'status': reason,
                          'childExitCode': exit_code, 'elapsedSeconds': time.monotonic() - started,
                          'maxResidentMiBBudget': args.max_rss_mib, 'maxPhysicalFootprintMiBBudget': args.max_footprint_mib,
                          'minSystemAvailablePercentBudget': args.min_available_percent,
                          'sampledPeakResidentKiB': max((s['residentKiB'] for s in samples), default=0),
                          'sampledPeakPhysicalFootprintKiB': max((s['physicalFootprintKiB'] for s in samples), default=0),
                          'observedSummedLifetimePeakFootprintKiB': max((s['summedLifetimePeakFootprintKiB'] for s in samples), default=0),
                          'samplingIntervalSeconds': args.poll_seconds, 'samples': samples}
                args.report.write_text(json.dumps(report, indent=2) + '\n')
                print(f'op=experiment.finished job={args.name} status={reason} exit={exit_code}', flush=True)
    return 0 if reason == 'completed' else 1


def interrupt_job(_signum, _frame):
    # CLI termination follows the same durable cleanup path as Ctrl-C.
    raise KeyboardInterrupt


if __name__ == '__main__':
    signal.signal(signal.SIGTERM, interrupt_job)
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--name', required=True)
    parser.add_argument('--log', required=True, type=Path)
    parser.add_argument('--report', required=True, type=Path)
    parser.add_argument('--lock', required=True, type=Path)
    parser.add_argument('--max-rss-mib', type=int, default=4096)
    parser.add_argument('--max-footprint-mib', type=int, default=4096)
    parser.add_argument('--min-available-percent', type=int, default=25)
    parser.add_argument('--poll-seconds', type=float, default=1)
    parser.add_argument('command', nargs=argparse.REMAINDER)
    raise SystemExit(run(parser.parse_args()))
