#!/usr/bin/env python3
"""Privacy/schema smoke for the test-only Chromium protocol logger.

Uses an owned native process without a desktop, browser or real field data.
"""
from pathlib import Path
import os
import struct
import subprocess
import tempfile

HERE = Path(__file__).resolve().parent
DRIVER = r'''#define _GNU_SOURCE
#include <stdio.h>
#include <stdarg.h>
extern int __vfprintf_chk(FILE *, int, const char *, va_list);
static void checked(const char *format, ...) {
  va_list args; va_start(args,format);
  __vfprintf_chk(stderr,1,format,args); va_end(args);
}
int main(void) {
  checked("%s", "[1.000] -> zwp_text_input_v3#42.enable()\n");
  checked("[%u.%03u] -> zwp_text_input_v3#42.set_content_type(%u, %u)\n", 1u, 2u, 4u, 0u);
  checked("%s", "[1.003] zwp_text_input_v3#42.preedit_string(\"FICTIONAL_PRIVATE_MARKER\n[1.004] zwp_text_input_v3#42.done()\", 0, 0)\n");
  fputs("unrelated FICTIONAL_PRIVATE_MARKER\n",stderr);
  return 0;
}
'''
with tempfile.TemporaryDirectory(prefix="snippets-wire-smoke-") as root:
    root = Path(root)
    source = root / "driver.c"
    source.write_text(DRIVER)
    addon = root / "wire.so"
    executable = root / "chromium"
    subprocess.run(["cc", "-shared", "-fPIC", "-O2", "-Wall", "-Wextra", "-Werror",
                    str(HERE / "wire-browser.c"), "-ldl", "-lpthread", "-o", str(addon)], check=True)
    subprocess.run(["cc", "-std=c11", "-Wall", "-Wextra", "-Werror", str(source), "-o", str(executable)], check=True)
    trace = root / "trace.bin"
    trace.write_bytes(bytes(65536))
    trace.chmod(0o600)
    env = {**os.environ, "LD_PRELOAD": str(addon), "SNIPPETS_WIRE_ROLE": "browser",
           "SNIPPETS_WIRE_TRACE_FILE": str(trace)}
    process = subprocess.run([str(executable)], env=env, capture_output=True, check=True)
    assert process.stdout == process.stderr == b""
    data = trace.read_bytes()
    count = struct.unpack_from("<I", data)[0]
    rows = [struct.unpack_from("<IIIIQ", data, 16 + index * 24) for index in range(count)]
    assert [row[0] for row in rows] == [80, 87, 86], rows
    assert all(row[2] >> 16 == 3 for row in rows)
    assert rows[1][2] & 65535 == 136 and rows[1][3] == 0
    assert b"FICTIONAL_PRIVATE_MARKER" not in data
    print("PASS: fortified browser logging emits only closed numeric events; forged argument header ignored")
