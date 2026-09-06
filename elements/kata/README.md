# kata

装 Kata Containers 及其自带的 VMM（QEMU / cloud-hypervisor / OpenVMM /
Dragonball），并在 containerd 里注册五个 runtime handler。

## 4.x 只有 Rust 运行时（这条决定了下面所有命名）

Kata 4.x **把发行包拆成了两个**：

```
kata-static-4.1.0-amd64.tar.zst       969 MB   只有 runtime-rs(Rust)
kata-go-static-4.1.0-amd64.tar.zst   1219 MB   Go 运行时
```

本元素只装前者。所以镜像里：

```
/opt/kata/runtime-rs/bin/containerd-shim-kata-v2    唯一的 shim
/opt/kata/bin/{qemu-system-*,cloud-hypervisor,openvmm}
/opt/kata/share/defaults/kata-containers/runtime-rs/*.toml
```

**没有 kata-runtime、kata-monitor、firecracker、jailer**，而且
`share/defaults/kata-containers/configuration.toml` 是个**指向不存在文件的
悬空符号链接**（指 `configuration-qemu.toml`，那个文件在 Go 包里）。照 3.x
写的元素在这里会一个配置都拷不出来 —— 2026-09-06 就是这么炸的，被元素**自己
末尾那段校验**拦下的，所以那段校验必须留着。

Go 运行时上游已经弃用，为了保住几个名字再塞 1.2 GB 不划算。**改成把那几个
名字做成别名。**

## 注册了哪五个

| handler | 实际运行 | 配置 |
|---|---|---|
| `kata-qemu` | runtime-rs + QEMU | `configuration-qemu-runtime-rs.toml` |
| `kata-qemu-runtime-rs` | 同上（同一个 shim、同一份配置） | 同上 |
| `kata-clh` | runtime-rs + cloud-hypervisor | `configuration-clh-runtime-rs.toml` |
| `kata-clh-runtime-rs` | 同上 | 同上 |
| `kata-dragonball` | runtime-rs，Dragonball 内置于 shim | `configuration-dragonball.toml` |

`kata-qemu` / `kata-clh` 是**别名**。上游把这两个名字留给 Go 运行时，但我们
不装 Go 运行时，所以不冲突；而**每一篇教程、每一个 RuntimeClass 例子、
magnum-cluster-api 那份清单写的都是这两个名字**，租户写熟悉的名字应该得到一个
Pod，而不是一个 Forbidden。哪天真把 Go 运行时加进来，冲突会**在这个文件里
当场炸掉**，而不是在运行时静悄悄走错分支。

**`kata-fc`（firecracker）没有注册**，4.x 里也注册不了 —— **二进制根本不在这个
包里**。它还要 `devmapper` snapshotter，而 devmapper 需要真实块设备上的 LVM
thin pool，镜像做不到（依赖节点的磁盘）。

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

## ③ 但 QEMU 在第三层起不来 —— 实测结论

2026-09-06 在一个真 Magnum 集群（`ubuntu-24.04-v1.37.0-amd64`，每个 handler 一个
Pod，读 `/proc/version`）上的结果：

| RuntimeClass | 结果 | `/proc/version` |
|---|---|---|
| 不写 | ✅ | `6.8.0-139-generic`（宿主内核，crun） |
| `gvisor` | ✅ | `4.19.0-gvisor` |
| `kata-clh` | ✅ | **`6.18.35` 真 guest 内核** |
| `kata-clh-runtime-rs` | ✅ | `6.18.35` |
| `kata-dragonball` | ✅ | `6.18.35` |
| `kata-qemu` | ❌ | 起不来 |
| `kata-qemu-runtime-rs` | ❌ | 起不来 |

**别被 shim 报的错带偏。** 它报的是

```
vsock: failed to connect to Vsock { vsock_cid: …, port: 1024 } within 10s
```

看着像 vsock/vhost 的问题，但那只是症状。节点 journal 里 QEMU 自己的话才是真因：

```
qemu stderr: "error: kvm run failed Bad address"
EIP=000f070e  CR0=00000011  EFER=0      ← 还在 SeaBIOS,实模式/保护模式早期
```

**VM 在固件阶段就死了，agent 根本没机会启动。** 10 次重试报错完全一致。

关键在于 **cloud-hypervisor 和 Dragonball 直接引导内核、不过固件**，而 QEMU
(`machine_type = "q35"`, `firmware = ""`) 要先跑 SeaBIOS。两个配置指向的**内核和
根镜像是同一份**，文件都在 —— 所以这不是"嵌套虚拟化不可用"，**是 SeaBIOS 这条路径
在第三层不可用**。

因此 `magnum_cluster_api` 只自动创建 `gvisor` / `kata-clh` / `kata-dragonball`
三个 RuntimeClass。**qemu 的 handler 仍然注册着** —— 换硬件、或者计算节点改用
`cpu_mode=host-passthrough` 之后想再试，自己建一个 RuntimeClass 即可。

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

`kata-qemu`、`kata-qemu-runtime-rs`、`kata-clh-runtime-rs` 同理 ——
**handler 在镜像里已经注册好了，只是没被自动创建成 RuntimeClass**。
驱动那份清单只列**实测能跑起 Pod 的**，理由是不对称：RuntimeClass 在、但那个
runtime 起不来，Pod 会**通过准入然后在建容器时挂**，比直接被 Forbidden 拒掉
难查得多。

## 构建期硬校验

注册完 handler 立刻 `containerd --config ... config dump`，配置不合法当场让构建
失败，而不是等节点第一次开机。`vhost_vsock` / `vhost_net` 写进
`modules-load.d`（chroot 里用的是构建机内核，不能在构建期加载）。
