# SPDX-License-Identifier: Apache-2.0
#
# Rewrite /etc/containerd/config.toml into the shape magnum-cluster-api writes,
# carrying over the sandbox image that the kubernetes element preloaded.
#
# A separate file so it can be tested against a real generated config before it
# ever runs in a build - the reason the crun element's edit is also a file.
#
# The sandbox image is read out of the existing config rather than hardcoded.
# containerd 2.x calls the key `sandbox` under
# plugins.'io.containerd.cri.v1.runtime'; the version 2 schema calls it
# `sandbox_image` under plugins."io.containerd.grpc.v1.cri". Getting this wrong
# means the first pod sandbox pulls pause from a registry instead of using the
# copy the image already carries, which on a node with no egress is a hang
# rather than an error.
import pathlib
import re
import sys

CONFIG = pathlib.Path(sys.argv[1] if len(sys.argv) > 1 else "/etc/containerd/config.toml")
text = CONFIG.read_text()

match = re.search(r"""^\s*sandbox\s*=\s*['"]([^'"]+)['"]""", text, re.M)
if not match:
    match = re.search(r"""^\s*sandbox_image\s*=\s*['"]([^'"]+)['"]""", text, re.M)
if not match:
    raise SystemExit("containerd-conf-d: no sandbox image found in the config")
sandbox = match.group(1)

CONFIG.write_text(
    f"""# Written by the containerd-conf-d element to match what
# magnum-cluster-api writes to this path at first boot, so the image is tested
# in the shape it actually runs in. Everything this image adds lives in
# /etc/containerd/conf.d/, which survives that replacement.
version = 2

imports = ["/etc/containerd/conf.d/*.toml"]

[plugins]
[plugins."io.containerd.grpc.v1.cri"]
    sandbox_image = "{sandbox}"
[plugins."io.containerd.grpc.v1.cri".containerd.runtimes.runc]
    runtime_type = "io.containerd.runc.v2"
[plugins."io.containerd.grpc.v1.cri".containerd.runtimes.runc.options]
    SystemdCgroup = true
"""
)
print(f"containerd-conf-d: config.toml reshaped, sandbox_image = {sandbox}")
