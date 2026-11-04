#!/usr/bin/env python3
"""Find or stop only the process running this checkout's exact app executable."""

import argparse
import ctypes
import os
import signal
import sys
import time


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("action", choices=("find", "stop"))
    parser.add_argument("executable")
    args = parser.parse_args()
    if sys.platform != "darwin":
        parser.error("This helper requires macOS.")

    expected = os.path.realpath(args.executable)
    library = ctypes.CDLL("/usr/lib/libproc.dylib", use_errno=True)
    library.proc_listallpids.argtypes = (ctypes.c_void_p, ctypes.c_int)
    library.proc_listallpids.restype = ctypes.c_int
    library.proc_pidpath.argtypes = (ctypes.c_int, ctypes.c_void_p, ctypes.c_uint32)
    library.proc_pidpath.restype = ctypes.c_int

    def matches(pid):
        buffer = ctypes.create_string_buffer(4096)
        if library.proc_pidpath(pid, buffer, len(buffer)) <= 0:
            return False
        return os.path.realpath(os.fsdecode(buffer.value)) == expected

    capacity = library.proc_listallpids(None, 0)
    if capacity <= 0:
        raise OSError("Could not enumerate running processes.")
    processes = (ctypes.c_int * (capacity + 256))()
    count = library.proc_listallpids(processes, ctypes.sizeof(processes))
    if count < 0:
        raise OSError("Could not read running processes.")
    pids = [pid for pid in processes[:count] if pid > 0 and matches(pid)]

    if args.action == "find":
        for pid in pids:
            print(pid)
        return 0 if pids else 1

    for pid in pids:
        # Recheck immediately before signalling, in case a PID has been reused.
        if matches(pid):
            try:
                os.kill(pid, signal.SIGTERM)
            except ProcessLookupError:
                pass
    deadline = time.monotonic() + 5
    while any(matches(pid) for pid in pids):
        if time.monotonic() >= deadline:
            print("The previous app did not stop; close it and retry.", file=sys.stderr)
            return 1
        time.sleep(0.1)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
