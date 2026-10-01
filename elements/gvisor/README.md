# gvisor

Installs gVisor (`runsc`) and its containerd shim, and registers a `gvisor`
runtime handler in containerd.

Enabled by default in the publish pipeline. Building by hand, add `gvisor` to
the `disk-image-create` element list:

```console
$ disk-image-create vm ubuntu-minimal block-device-kubernetes kubernetes gvisor
```

Then schedule onto it with a RuntimeClass. On a Magnum cluster
magnum-cluster-api creates this one for you; the object is only yours to write
when you built the node another way:

```yaml
apiVersion: node.k8s.io/v1
kind: RuntimeClass
metadata:
  name: gvisor
handler: gvisor
```

## gVisor alongside Kata, not instead of it

The image ships both, so that a tenant picks per pod with `runtimeClassName`
instead of picking an image and a cluster. They fail in different places, which
is the reason to have both rather than the cheaper one.

`runsc` is a static userspace binary. With the default `systrap` platform it
needs no `/dev/kvm` and no kernel module, so it works wherever the node does -
including on a node with no hardware virtualisation available to it at all,
where every Kata handler bar the ptrace-free ones cannot start a pod.

Set `DIB_GVISOR_PLATFORM=kvm` only where `/dev/kvm` is known to be present in
the node itself. It is faster; it is also the one setting that gives `runsc`
the same prerequisite Kata has, and so gives up the property above.

## 版本与下载格式

`DIB_GVISOR_RELEASE` 默认 `latest`，但构建时会先解析成具体的日期版本（列 GCS 桶里的
`releases/release/<YYYYMMDD.N>/`，取最新且该架构已有 tarball 的那一个），日志里写明
`latest resolves to …`，镜像记录的是 `runsc --version`。流水线由 `hack/versions.sh`
统一解析（要求 x86_64 与 aarch64 都已上传），同一次运行的两种架构拿到同一版本。

上游从 **20260831.0** 起不再单独发布 `runsc` / `containerd-shim-runsc-v1`，每个架构只有
`gvisor.tar.{zstd,bz2}` 及其 `.sha512`；`latest` 目录 2026-09-17 起指向新格式后，老的逐文件
URL 一律 404，每晚构建因此全挂。现在优先下 tarball，校验 sha512 后只解出这两个文件；
钉老版本（≤ 20260817.0，逐文件格式）时自动走老路径。

**同一批新版本还多了 sidecar。** 从 20260928.0（可能更早的 tarball 版本也是）起，`runsc` 起沙箱要经
`gvisor-bin/` 里的 `gvisor_sentry` 等辅助程序，目录必须在 `runsc` **真实路径的旁边**；默认
`--sidecar-usage-policy=STRICT` 找不到就拒绝启动任何沙箱（`sidecar "gvisor_sentry" not usable`）。
只解出 `runsc` 和 shim 的镜像能构建、能注册 handler，但 gvisor Pod 永远起不来——1.36.5 首次构建时
被门禁的逐 handler 测试拦下。现在整个 tarball 装在 `/opt/gvisor/`，`/usr/bin/runsc` 与
`/usr/bin/containerd-shim-runsc-v1` 是指过去的相对符号链接（runsc 按真实路径找 `gvisor-bin/`，
`hack/verify-image.sh` 在挂载点外跟随相对链接也能检查）。verify 阶段会检查：只要 runsc 认识
`--sidecar-usage-policy`，就必须有 `gvisor-bin/gvisor_sentry`。

