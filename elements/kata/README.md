# kata

装 Kata Containers 及其自带的 VMM（QEMU / cloud-hypervisor / firecracker /
Dragonball），并在 containerd 里注册 `kata-qemu`、`kata-clh`、`kata-dragonball`
三个 runtime handler。

**默认不启用。** 启用前先读完下面两条。

## 启用要改的三处

| 在哪 | 名字 | 值 |
|---|---|---|
| 仓库变量 | `EXTRA_ELEMENTS` | `node-tuning crun gvisor kata` |
| 仓库变量 | **`DIB_IMAGE_SIZE`** | **`8`**（默认 3，不改必然构建失败） |
| 可选 | `DIB_KATA_VERSION` | 默认 `4.1.0` |

手动触发时也可以用 `elements` 这个输入代替 `EXTRA_ELEMENTS`，但
`DIB_IMAGE_SIZE` **只有仓库变量**这一个入口。

## ① 体积

```
kata-static-4.1.0-amd64.tar.zst    925 MiB(压缩) → 解开约 2.5 GB
```

节点镜像从 3.3 GB 涨到 6–7 GB。**每个节点都要 CoW 克隆这个体积**，而里面的
QEMU、cloud-hypervisor、firecracker、guest 内核和 initrd，多数节点永远用不上。

## ② 嵌套虚拟化 —— 这条是硬门槛

除少数无 VMM 的形态外，Kata 每个 Pod 都要**真的起一台虚拟机**，所以节点里必须
有 `/dev/kvm`。

而 Magnum 节点是"计算节点上的 guest"，计算节点本身又常常是 guest。此时 Kata 就是
**第三层嵌套** —— 规范上支持，实际不可用。

**启用前在一台节点 VM 里跑：**

```bash
grep -c vmx /proc/cpuinfo     # 0 = 宿主没把 vmx 透传进来
ls -l /dev/kvm                # 不存在 = Kata 起不来
```

没有 `/dev/kvm` 就别开，用 `gvisor` —— `runsc` 的 systrap 平台是纯用户态，
不需要任何硬件虚拟化，而且只有约 50 MiB。

## 集群里怎么用

镜像只提供 handler，调度还要 RuntimeClass：

```yaml
apiVersion: node.k8s.io/v1
kind: RuntimeClass
metadata:
  name: kata-qemu
handler: kata-qemu
```

`kata-clh`、`kata-dragonball` 同理。

## 构建期硬校验

注册完 handler 立刻 `containerd --config ... config dump`，配置不合法当场让构建
失败，而不是等节点第一次开机。`vhost_vsock` / `vhost_net` 写进
`modules-load.d`（chroot 里用的是构建机内核，不能在构建期加载）。
