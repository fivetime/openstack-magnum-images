# SPDX-License-Identifier: Apache-2.0
#
# Point containerd's default runtime at crun.
#
# A separate file rather than a heredoc so it can be tested against a real
# generated config.toml before it ever runs in a build.
#
# Two things make a naive edit wrong:
#
#   - the section header is indented, so matching on a line-anchored pattern
#     fails and "the next section starts at \n[" is not true either;
#   - BinaryName is already present as '', so appending a second one would
#     leave two keys in the same table and containerd would reject the file.
#
# So: locate the section, then rewrite the first BinaryName line after it,
# preserving whatever indentation the file uses. If the key is absent, insert
# it directly under the header instead.
import pathlib
import re
import sys

CONFIG = pathlib.Path(sys.argv[1] if len(sys.argv) > 1 else "/etc/containerd/config.toml")
MARKER = "[plugins.'io.containerd.cri.v1.runtime'.containerd.runtimes.runc.options]"
CRUN = "/usr/bin/crun"

lines = CONFIG.read_text().splitlines(keepends=True)
start = next((i for i, line in enumerate(lines) if MARKER in line), None)
if start is None:
    raise SystemExit(f"crun: {MARKER} not found in {CONFIG}")

for i in range(start + 1, len(lines)):
    matched = re.match(r"^(\s*)BinaryName\s*=", lines[i])
    if matched:
        lines[i] = f"{matched.group(1)}BinaryName = '{CRUN}'\n"
        break
    if lines[i].lstrip().startswith("["):
        indent = re.match(r"^(\s*)", lines[start]).group(1) + "  "
        lines.insert(start + 1, f"{indent}BinaryName = '{CRUN}'\n")
        break
else:
    raise SystemExit("crun: could not place BinaryName")

CONFIG.write_text("".join(lines))
print(f"crun: containerd default runtime now executes {CRUN}")
