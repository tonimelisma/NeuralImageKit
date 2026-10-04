#!/usr/bin/env python3
"""Observable resource-owner checks using real, disposable child processes."""
import contextlib
import importlib.util
import io
import json
import os
import signal
import time
from pathlib import Path
import subprocess
import sys
import tempfile
from types import SimpleNamespace
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location('bounded', Path(__file__).with_name('run_bounded.py'))
bounded = importlib.util.module_from_spec(spec)
spec.loader.exec_module(bounded)


class ResourceOwnerTests(unittest.TestCase):
    def args(self, root, code, limit=256):
        return SimpleNamespace(name='fixture', log=root/'output.log', report=root/'report.json',
                               lock=root/'job.lock', max_rss_mib=limit, max_footprint_mib=4096, min_available_percent=25,
                               poll_seconds=.1, command=[sys.executable, '-c', code])

    def test_completed_child_has_receipt_and_output(self):
        with tempfile.TemporaryDirectory() as tmp, patch.object(bounded, 'available_percent', return_value=80), contextlib.redirect_stdout(io.StringIO()):
            args = self.args(Path(tmp), "print('finished')")
            self.assertEqual(bounded.run(args), 0)
            self.assertEqual(json.loads(args.report.read_text())['status'], 'completed')
            self.assertEqual(args.log.read_text().strip(), 'finished')
            with self.assertRaises(FileExistsError):
                bounded.run(args)

    def test_budget_stops_allocating_child(self):
        with tempfile.TemporaryDirectory() as tmp, patch.object(bounded, 'available_percent', return_value=80), contextlib.redirect_stdout(io.StringIO()):
            args = self.args(Path(tmp), 'import time; data=bytearray(100*1024*1024); time.sleep(10)', limit=64)
            self.assertEqual(bounded.run(args), 1)
            report = json.loads(args.report.read_text())
            self.assertEqual(report['status'], 'resident-budget-exceeded')
            self.assertGreater(report['sampledPeakResidentKiB'], 64*1024)
            self.assertNotEqual(report['childExitCode'], 0)

    def test_physical_footprint_budget_stops_child(self):
        with tempfile.TemporaryDirectory() as tmp, patch.object(bounded, 'available_percent', return_value=80), contextlib.redirect_stdout(io.StringIO()):
            args = self.args(Path(tmp), 'import time; data=bytearray(100*1024*1024); time.sleep(10)')
            args.max_footprint_mib = 64
            self.assertEqual(bounded.run(args), 1)
            report = json.loads(args.report.read_text())
            self.assertEqual(report['status'], 'physical-footprint-budget-exceeded')
            self.assertGreater(report['sampledPeakPhysicalFootprintKiB'], 64*1024)

    def test_parent_completion_does_not_leave_child_running(self):
        with tempfile.TemporaryDirectory() as tmp, patch.object(bounded, 'available_percent', return_value=80), contextlib.redirect_stdout(io.StringIO()):
            root = Path(tmp)
            code = "import subprocess,time; from pathlib import Path; p=subprocess.Popen(['sleep','20']); Path(%r).write_text(str(p.pid)); time.sleep(.2)" % str(root/'pid')
            self.assertEqual(bounded.run(self.args(root, code)), 0)
            pid = int((root/'pid').read_text())
            status = subprocess.run(['ps', '-o', 'stat=', '-p', str(pid)], capture_output=True, text=True).stdout.strip()
            self.assertTrue(not status or status.startswith('Z'), status)

    def test_cli_termination_stops_child_and_writes_receipt(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            code = "import os,time; from pathlib import Path; Path(%r).write_text(str(os.getpid())); time.sleep(20)" % str(root/'pid')
            owner = subprocess.Popen([sys.executable, str(Path(__file__).with_name('run_bounded.py')),
                                      '--name', 'termination-fixture', '--log', str(root/'output.log'),
                                      '--report', str(root/'report.json'), '--lock', str(root/'job.lock'),
                                      '--min-available-percent', '1', '--', sys.executable, '-c', code],
                                     stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            try:
                deadline = time.monotonic() + 10
                while not (root/'pid').exists() and owner.poll() is None and time.monotonic() < deadline:
                    time.sleep(.05)
                self.assertTrue((root/'pid').exists())
                pid = int((root/'pid').read_text())
                owner.send_signal(signal.SIGTERM)
                self.assertEqual(owner.wait(timeout=10), 1)
                self.assertEqual(json.loads((root/'report.json').read_text())['status'], 'interrupted')
                status = subprocess.run(['ps', '-o', 'stat=', '-p', str(pid)], capture_output=True, text=True).stdout.strip()
                self.assertTrue(not status or status.startswith('Z'), status)
            finally:
                if owner.poll() is None:
                    owner.kill()
                    owner.wait()
                if (root/'pid').exists():
                    try:
                        os.killpg(int((root/'pid').read_text()), signal.SIGKILL)
                    except ProcessLookupError:
                        pass

    def test_pressure_prevents_starting_child(self):
        with tempfile.TemporaryDirectory() as tmp, patch.object(bounded, 'available_percent', return_value=10), contextlib.redirect_stdout(io.StringIO()):
            args = self.args(Path(tmp), "print('must not run')")
            self.assertEqual(bounded.run(args), 1)
            self.assertEqual(json.loads(args.report.read_text())['status'], 'insufficient-system-memory-before-start')
            self.assertEqual(args.log.read_text(), '')

    def test_exclusive_lock_prevents_another_job(self):
        with tempfile.TemporaryDirectory() as tmp:
            args = self.args(Path(tmp), "print('must not run')")
            with args.lock.open('a') as lock:
                bounded.fcntl.flock(lock, bounded.fcntl.LOCK_EX | bounded.fcntl.LOCK_NB)
                with self.assertRaises(BlockingIOError):
                    bounded.run(args)
            self.assertFalse(args.log.exists())

    def test_failed_cleanup_records_and_blocks_next_job(self):
        with tempfile.TemporaryDirectory() as tmp, patch.object(bounded, 'available_percent', side_effect=[80, RuntimeError('unavailable')]), contextlib.redirect_stdout(io.StringIO()):
            args = self.args(Path(tmp), 'import time; time.sleep(20)')
            captured = []
            def denied(child):
                captured.append(child)
                raise PermissionError('denied')
            try:
                with patch.object(bounded, 'stop_group', side_effect=denied):
                    self.assertEqual(bounded.run(args), 1)
                self.assertEqual(json.loads(args.report.read_text())['status'], 'process-cleanup-failed:PermissionError')
                with self.assertRaisesRegex(RuntimeError, 'cleanup unverified'):
                    bounded.run(args)
            finally:
                blocked = args.lock.with_name(args.lock.name + '.blocked')
                self.assertEqual(json.loads(blocked.read_text())['processGroup'], captured[0].pid)
                bounded.stop_group(captured[0])

    def test_monitor_failure_stops_job(self):
        with tempfile.TemporaryDirectory() as tmp, patch.object(bounded, 'available_percent', side_effect=[80, RuntimeError('unavailable')]), contextlib.redirect_stdout(io.StringIO()):
            args = self.args(Path(tmp), 'import time; time.sleep(20)')
            self.assertEqual(bounded.run(args), 1)
            report = json.loads(args.report.read_text())
            self.assertEqual(report['status'], 'resource-monitor-failed:RuntimeError')
            self.assertNotEqual(report['childExitCode'], 0)


if __name__ == '__main__':
    unittest.main()
