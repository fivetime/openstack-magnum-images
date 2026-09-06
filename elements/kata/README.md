# kata

装 Kata Containers 及其自带的 VMM（QEMU / cloud-hypervisor / OpenVMM /
Dragonball），并在 containerd 里注册五个 runtime handler。

## 拆包是 4.1.0 才发生的（这条决定了下面所有命名）

```
4.0.0:  kata-static-4.0.0-amd64.tar.zst     1953 MB   Go + Rust 都在
4.1.0:  kata-static-4.1.0-amd64.tar.zst      969 MB   只有 runtime-rs(Rust)
        kata-go-static-4.1.0-amd64.tar.zst  1219 MB   Go 运行时
```

**照 4.0.0 或 3.x 写的脚本在 4.1.0 上会静默走空** —— 拷 `configuration-qemu.toml`、
软链 `kata-runtime`/`firecracker`/`jailer` 这些步骤如果带着 `[ -f ] &&` 保护，
会一个都不匹配却不报错。

**两个包都装。** Go 线上游已弃用 —— 那是"不要在它上面做新东西"的理由，
不是"不装"的理由：**runtime-rs 目前在这里起不了 QEMU 沙箱**（见 ③），
只装 runtime-rs 就等于交一张 `kata-qemu` 不能用的镜像，而那是每篇教程都在写的名字。

两个包**共享 87 个路径**（内核、guest 镜像、VMM），所以合装约 **3.8 GB**，
而不是两个 tarball 加起来的 5.0 GB。**先解 `kata-static`、后解 `kata-go-static`**：
重叠处让 Go 的文件生效，并且让 `share/defaults/kata-containers/configuration.toml`
这个符号链接有目标（它指向 `configuration-qemu.toml`，只在 Go 包里）。

镜像里于是有：

```
/opt/kata/bin/containerd-shim-kata-v2               Go shim
/opt/kata/runtime-rs/bin/containerd-shim-kata-v2    Rust shim
/opt/kata/bin/{qemu-system-*,cloud-hypervisor,openvmm,firecracker,jailer}
/opt/kata/share/defaults/kata-containers/*.toml              Go 的配置
/opt/kata/share/defaults/kata-containers/runtime-rs/*.toml   Rust 的配置
```

## 注册了哪五个

**命名和上游 kata-deploy 完全一致**：光名字是 Go 运行时，带 `-runtime-rs` 后缀的是
Rust 运行时。

| handler | shim | 配置 |
|---|---|---|
| `kata-qemu` | Go | `configuration-qemu.toml` |
| `kata-clh` | Go | `configuration-clh.toml` |
| `kata-qemu-runtime-rs` | Rust | `configuration-qemu-runtime-rs.toml` |
| `kata-clh-runtime-rs` | Rust | `configuration-clh-runtime-rs.toml` |
| `kata-dragonball` | Rust | `configuration-dragonball.toml` |

> 早先有一版元素只装 runtime-rs，把 `kata-qemu` **别名**到 Rust shim 上 ——
> 结果是把最熟悉的那个名字挂在**唯一不能用的运行时**上。别再这么做。

**`kata-fc`（firecracker）没有注册**：它要 `devmapper` snapshotter，而 devmapper
需要真实块设备上的 LVM thin pool，镜像做不到（依赖节点的磁盘）。二进制和
`configuration-fc.toml` 都在，节点自己配好 devmapper 后用 drop-in 补上即可。

## ① 体积 —— `DIB_IMAGE_SIZE` 必须是 12

```
kata-static-*.tar.zst       ~969 MB(压缩)
kata-go-static-*.tar.zst   ~1219 MB(压缩)
合装解开后                   约 3.8 GB(共享 87 个路径)
```

流水线的默认值已经是 12；**手工跑 `disk-image-create` 时不改必然构建失败**，
而且是"文件系统满"这种毫无信息量的失败。

**这是存储成本，不是开机成本。** 镜像是 raw、Glance 后端是 RBD，所以节点是
**CoW 克隆**而不是拷贝：一个从不起 Kata Pod 的节点，不会去 fault in 那几个 GB。
真正要核对的是 **flavor 的根盘要大于镜像** —— `magnum-medium` 的 40 GB 装得下。

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

## ③ `/dev/shm` 必须大于客户机内存 —— 否则每个 QEMU 沙箱都起不来

kata 把客户机内存放在 `/dev/shm` 的一个文件里（virtio-fs 要求这个映射是共享的）：

```
-m 2048M,slots=10,maxmem=...
-object memory-backend-file,id=dimm1,size=2048M,mem-path=/dev/shm,share=on
-numa node,memdev=dimm1
```

**systemd 给 `/dev/shm` 的默认值是内存的一半，而 kata 的 `default_memory` 是固定
2048 MB。** 4 GB 的节点（`magnum-medium`）上就是 **1955 MB 的 shm 装 2048 MB 的客户机**
—— 映射铺不满，客户机第一次碰到没有后备页的地址就是

```
error: kvm run failed Bad address
EIP=000f070e  CR0=00000011  EFER=0
```

**而 shim 报出来的是 `vsock ... within 10s`**，看着像 `vhost_vsock` 的问题。它不是。
真因永远在节点 journal 里 QEMU 自己那几行，见 `journalctl -t kata`。

cloud-hypervisor 和 Dragonball **不把客户机内存放在 `/dev/shm`**，所以不受影响 ——
这就是为什么一台节点可以 `kata-clh` 正常、每个 `kata-qemu` 都失败，也是为什么这个
现象长期被误判成"QEMU 的问题"或"三层嵌套的问题"。**两者都不是。**

元素因此往 `/etc/fstab` 写一行：

```
tmpfs /dev/shm tmpfs rw,nosuid,nodev,inode64,size=75% 0 0
```

用 fstab 而不是 unit 文件，是因为 systemd 自己挂 `/dev/shm`、没有可覆盖的 unit，
而 `systemd-fstab-generator` 会替我们生成一个。tmpfs 只按实际使用的页计费，
所以把上限从 50% 提到 75% 在用起来之前不花任何代价。

### 实测矩阵（修好 shm 之后）

| RuntimeClass | 结果 | `/proc/version` |
|---|---|---|
| 不写 | ✅ | `6.8.0-139-generic`（宿主内核，crun） |
| `gvisor` | ✅ | `4.19.0-gvisor` |
| `kata-qemu`（Go） | ✅ | `6.18.35` |
| `kata-clh`（Go） | ✅ | `6.18.35` |
| `kata-clh-runtime-rs` | ✅ | `6.18.35` |
| `kata-dragonball` | ✅ | `6.18.35` |
| `kata-qemu-runtime-rs` | ❌ | 仍然起不来 |

**只剩 runtime-rs 的 QEMU 一个**，而且它的失败日志里已经没有 `kvm run failed` 了 ——
是 runtime-rs 自己的另一个问题，和 shm、和嵌套都无关。这也是**必须装
`kata-go-static` 的实证理由**：不装它，`kata-qemu` 这个名字就只能落在唯一不能用的
运行时上。

### 曾经据此得出的两个结论都是错的，留在这里免得重踩

1. **"固件路径在三层嵌套下不可用"** —— 不成立。把 kata 自带的
   `/opt/kata/bin/qemu-system-x86_64` 直接拿来起空 VM（`-machine q35,accel=kvm`，
   加 `-cpu host`、加 `nvdimm=on` 都试过），在第三层和第二层**都正常跑到 SeaBIOS 的
   "No bootable device"**。
2. **"runtime-rs 起不了 QEMU,所以要装 Go"** —— 理由是错的（结论侥幸对）。当时
   Go 那条路**同样是坏的**，只是我用 `ctr` 测的那次绕开了共享内存后端。真因是 shm。

## 集群里怎么用

镜像只提供 handler，调度还要 RuntimeClass。**Magnum 集群不用自己建** ——
magnum-cluster-api 会为每个集群创建一组 RuntimeClass
（见 `magnum_cluster_api/resources.py` 的 `NODE_IMAGE_RUNTIME_HANDLERS`）。
**那份清单只列实测能跑起 Pod 的 handler**，和这里注册的五个不是一回事。

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
