import contextlib
import importlib.util
import io
from pathlib import Path
import subprocess
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location('apple_tool', Path(__file__).with_name('apple-tool.py'))
apple_tool = importlib.util.module_from_spec(spec)
spec.loader.exec_module(apple_tool)


class AppleToolTests(unittest.TestCase):
    def result(self, code, output):
        return subprocess.CompletedProcess([], code, output)

    def execute(self, tool, arguments, results):
        with patch.object(apple_tool.subprocess, 'run', side_effect=results) as run, \
                patch.object(apple_tool.time, 'sleep') as sleep, contextlib.redirect_stdout(io.StringIO()):
            code = apple_tool.execute(tool, arguments)
        return code, run, sleep

    def test_recovers_only_dropped_ticket_connections_for_both_entrypoints(self):
        for tool, arguments in [('stapler', ['validate', 'App.app']), ('xcrun', ['stapler', 'staple', 'App.app'])]:
            with self.subTest(tool=tool):
                code, run, sleep = self.execute(tool, arguments, [
                    self.result(68, 'Error Domain=NSURLErrorDomain Code=-1005 "The network connection was lost."'),
                    self.result(0, 'The validate action worked!'),
                ])
                self.assertEqual(code, 0)
                self.assertEqual(run.call_count, 2)
                sleep.assert_called_once_with(5)
                self.assertEqual(run.call_args.args[0][0], '/usr/bin/xcrun')

    def test_real_validation_errors_fail_immediately(self):
        for code, output in [(68, 'Ticket validation failed'), (65, 'NSURLErrorDomain Code=-1005'), (68, 'NSURLErrorDomain Code=-10050')]:
            with self.subTest(code=code, output=output):
                actual, run, sleep = self.execute('stapler', ['validate', 'App.app'], [self.result(code, output)])
                self.assertEqual(actual, code)
                run.assert_called_once()
                sleep.assert_not_called()

    def test_transport_retries_are_bounded_and_preserve_failure(self):
        code, run, sleep = self.execute('stapler', ['validate', 'App.app'], [
            self.result(68, 'NSURLErrorDomain Code=-1005') for _ in range(4)
        ])
        self.assertEqual(code, 68)
        self.assertEqual(run.call_count, 4)
        self.assertEqual([c.args[0] for c in sleep.call_args_list], [5, 15, 30])

    def test_other_xcrun_commands_are_forwarded_without_capture_or_retry(self):
        for arguments in [['notarytool', 'submit', 'App.zip'], ['--find', 'swift'], ['stapler', 'help']]:
            with self.subTest(arguments=arguments), patch.object(apple_tool.os, 'execv', side_effect=SystemExit) as forward, \
                    patch.object(apple_tool.subprocess, 'run') as run:
                with self.assertRaises(SystemExit):
                    apple_tool.execute('xcrun', arguments)
                forward.assert_called_once_with('/usr/bin/xcrun', ['/usr/bin/xcrun', *arguments])
                run.assert_not_called()
