# crun

装 crun，并让 containerd 的**默认运行时**执行它（而不是 runc）。

```console
$ disk-image-create vm ubuntu-minimal block-device-kubernetes kubernetes crun
```

**3.4 MiB。** 这个体积是它能当默认的原因之一。

## handler 名字仍然叫 runc

改的是「shim 执行哪个二进制」，不是 handler 名：

```toml
[plugins.'io.containerd.cri.v1.runtime'.containerd.runtimes.runc.options]
  BinaryName = '/usr/bin/crun'
```

kubeadm、kubelet 和所有不带 RuntimeClass 的 Pod 都按 **`runc` 这个名字**找默认
handler。改名会让默认运行时直接失联。

runc 本身仍在镜像里（`runc` 元素照常装），把这一行改回 `''` 就退回去了。

## 为什么值得

crun 是 C 写的，CRI-O 在 RHEL/Fedora 上已经默认用它多年。相比 Go 写的 runc，
启动更快、**每容器常驻内存低一个量级** —— 在跑几百个 Pod 的节点上这才是重点。

## 构建期硬校验

配置改完立刻 `containerd --config ... config dump`，配置不合法当场让构建失败，
而不是等节点第一次开机。改配置那段是独立的 `crun-set-binary.py`，**可以拿真实
的 config.toml 单独测**——事实上它就是这么验的：section 头是缩进的、
`BinaryName` 本来就以 `''` 存在，两点都会让想当然的正则改错。
