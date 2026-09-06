# kata

装 Kata Containers 及其自带的 VMM（QEMU / cloud-hypervisor / firecracker /
Dragonball），并在 containerd 里注册五个 runtime handler：

```
kata-qemu              Go 运行时 + QEMU
kata-clh               Go 运行时 + cloud-hypervisor
kata-qemu-runtime-rs   Rust 运行时 + QEMU
kata-clh-runtime-rs    Rust 运行时 + cloud-hypervisor
kata-dragonball        Rust 运行时,Dragonball 内置于 shim
```

**`kata-fc`（firecracker）没有注册** —— 它要 `devmapper` snapshotter，而
devmapper 需要真实块设备上的 LVM thin pool，镜像做不到（依赖节点的磁盘）。
硬注册只会得到一个"收下 Pod 然后失败"的 handler。`configuration-fc.toml`
已经装进镜像，节点自己配好 devmapper 后用 drop-in 补上即可。

**默认启用**，和 `gvisor`、`crun` 一起烘进同一张镜像 —— 租户在自己的 Pod 里写
`runtimeClassName` 选，而不是换一张镜像、换一个集群。下面两条是启用它带来的
后果，不是启用前的门槛。

## ① 体积 —— `DIB_IMAGE_SIZE` 必须是 8

```
kata-static-*-amd64.tar.zst    约 925 MiB(压缩) → 解开约 2.5 GB
```

节点镜像从约 3.3 GB 涨到 6–7 GB，`DIB_IMAGE_SIZE` 从 3 提到 8。流水线的默认值
已经是 8；**手工跑 `disk-image-create` 时不改必然构建失败**，而且是"文件系统满"
这种毫无信息量的失败。

**这是存储成本，不是开机成本。** 镜像是 raw、Glance 后端是 RBD，所以节点是
**CoW 克隆**而不是拷贝：一个从不起 Kata Pod 的节点，不会去 fault in 那 2.5 GB。
真正要核对的是 **flavor 的根盘要大于镜像** —— `magnum-medium` 的 40 GB 装得下
好几倍。

版本不用管：`hack/versions.sh` 每次构建从 GitHub 解析 kata 的最新发行版，
元素里那个数字只是给手工跑 `disk-image-create` 的人兜底。

## ② 嵌套虚拟化 —— 这里是第三层，实测可用

除少数无 VMM 的形态外，Kata 每个 Pod 都要**真的起一台虚拟机**，所以节点里必须
有 `/dev/kvm`。而本环境里 Magnum 节点是"计算节点上的 guest"，计算节点自己又是
DL360 上的 guest，于是 Kata VM 是**第三层嵌套**。

这曾经是不启用它的理由（"规范上支持，实际不可用"）。**2026-09-06 实测证伪**：
在一台 Nova 实例（也就是节点所在的那一层）里 ——

```
vmx_count=4              # host-model 把 vmx 透传进来了
nested=Y                 # 客户机里的 kvm_intel 自己也开着嵌套
/dev/kvm                 # crw-rw---- root kvm
KVM_GET_API_VERSION = 12
KVM_CREATE_VM fd = 4     # 真的在实例内部建出了一台 VM
```

判据要选 `KVM_CREATE_VM` 而不是 `ls /dev/kvm`：设备节点存在只说明模块加载了，
建得出 VM 才说明第三层真的能用。

换个环境要重新验，在一台节点 VM 里跑：

```bash
grep -c vmx /proc/cpuinfo     # 0 = 宿主没把 vmx 透传进来
ls -l /dev/kvm                # 不存在 = Kata 起不来
```

没有 `/dev/kvm` 也不用换镜像：同一张镜像里的 `gvisor` 照常能用 —— `runsc` 的
systrap 平台是纯用户态，不需要任何硬件虚拟化。**同时带两个就是为了这个。**

## 集群里怎么用

镜像只提供 handler，调度还要 RuntimeClass。**Magnum 集群不用自己建** ——
magnum-cluster-api 会为每个集群创建 `gvisor` / `kata-qemu` / `kata-clh`
（见 `magnum_cluster_api/resources.py` 的 `NODE_IMAGE_RUNTIME_HANDLERS`）。

自己建节点、或者想用没有被自动创建的那几个 handler 时：

```yaml
apiVersion: node.k8s.io/v1
kind: RuntimeClass
metadata:
  name: kata-qemu
handler: kata-qemu
```

`kata-dragonball`、`kata-qemu-runtime-rs`、`kata-clh-runtime-rs` 同理 ——
**handler 在镜像里已经注册好了，只是没被自动创建成 RuntimeClass**，因为它们没在
这批节点上验过。驱动那份清单只列验过的，理由是：RuntimeClass 在、handler 不在，
Pod 会通过准入然后在建容器时挂，比直接被拒难查得多。

## 构建期硬校验

注册完 handler 立刻 `containerd --config ... config dump`，配置不合法当场让构建
失败，而不是等节点第一次开机。`vhost_vsock` / `vhost_net` 写进
`modules-load.d`（chroot 里用的是构建机内核，不能在构建期加载）。
