#!/usr/bin/env python3
"""CI-only xcrun/stapler shim for dropped Apple ticket-service connections."""
from pathlib import Path
import os
import re
import subprocess
import sys
import time


def command_for(tool, arguments):
    if tool == 'xcrun':
        return ['/usr/bin/xcrun', *arguments]
    if tool == 'stapler':
        return ['/usr/bin/xcrun', 'stapler', *arguments]
    raise ValueError('Invoke this CI shim as xcrun or stapler')


def execute(tool, arguments):
    command = command_for(tool, arguments)
    if len(command) < 3 or command[1] != 'stapler' or command[2] not in ('staple', 'validate'):
        os.execv(command[0], command)
    # Exit 68 also covers real ticket failures; retry only the observed transport error.
    delays = (5, 15, 30)
    for attempt in range(len(delays) + 1):
        result = subprocess.run(command, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
        print(result.stdout, end='', flush=True)
        dropped = result.returncode == 68 and re.search(r'NSURLErrorDomain\s+Code=-1005\b', result.stdout)
        if not dropped or attempt == len(delays):
            return result.returncode
        print(f'Apple ticket-service connection dropped; retrying ({attempt + 2}/4).', flush=True)
        time.sleep(delays[attempt])


if __name__ == '__main__':
    sys.exit(execute(Path(sys.argv[0]).name, sys.argv[1:]))
