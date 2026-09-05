# node-tuning

把生产调优作为**静态文件**烘进镜像：内核模块、sysctl、limits、systemd 单元
限制。全部在 `static/` 下，节点开机由 `systemd-modules-load` /
`systemd-sysctl` 正常加载，运行期不跑任何脚本。

```console
$ disk-image-create vm ubuntu-minimal block-device-kubernetes kubernetes node-tuning
```

## 落地的文件

| 路径 | 内容 |
|---|---|
| `modules-load.d/99-container.conf` | overlay、br_netfilter、nf_conntrack、bonding、8021q、**tcp_bbr** |
| `modules-load.d/99-ipvs.conf` | ip_vs 系列（kube-proxy IPVS 模式用；Cilium kube-proxy replacement 下用不到，留着不花钱） |
| `modprobe.d/99-bonding.conf` | `options bonding max_bonds=0` |
| `sysctl.d/99-production.conf` | TCP/内存/邻居表/conntrack/bridge-netfilter/BPF |
| `sysctl.d/99-security.conf` | 加固项，每条都写明代价 |
| `security/limits.d/99-production.conf` | nofile/nproc/memlock/core/stack |
| `systemd/system/{kubelet,containerd}.service.d/99-limits.conf` | 单元级 limits |

## 相对原始配置改了四处

**① 删掉 `nf_conntrack_ipv4` / `nf_conntrack_ipv6`。** 这两个模块在
Linux 4.19 就并进 `nf_conntrack` 了，现在的内核里根本不存在。留着的唯一效果
是每次开机 `systemd-modules-load.service` 失败一次——而且没人会看见。

**② 补上 `tcp_bbr`。** `net.ipv4.tcp_congestion_control = bbr` 只有在模块
存在时才生效，否则内核**静默保持 cubic**——sysctl 写入不报错，你以为开了 BBR。

**③ 给 bonding 加 `max_bonds=0`。** 加载 bonding 模块会立刻创建 `bond0`
（`max_bonds` 默认是 1）。CAPI 节点只有一张 virtio 网卡，多出来一个永远 DOWN
的 bond0 会让 CNI 的接口枚举和 node-exporter 都跟着犯迷糊。模块照样可用，
只是不凭空造设备。

**④ 拆出 systemd 单元 limits。** `limits.d` 只对 PAM 会话生效，systemd 拉起
的服务**根本不读它**。kubelet 和 containerd 的 `LimitNOFILE` 必须写在单元的
drop-in 里，否则 limits.d 里那 1048576 对它们一点用没有——这是最常见的
"我明明调了 fd 上限"的假象。

## 构建期硬校验

`post-install.d/86-node-tuning` 在构建时就把三件事验掉，而不是留到节点上线：

1. **modules-load.d 里每个模块都必须在本镜像的内核里存在**
   （`modprobe --dry-run --set-version`）。这条就是抓出 `nf_conntrack_ipv4` 的。
2. **sysctl 文件每一行都必须是合法的 `key = value`**。值没法在这里应用——
   chroot 用的是构建机的内核、模块也没加载，`bridge.*` / `netfilter.*` 这些
   键还不存在——但语法错能当场抓住。
3. **有 drop-in 就必须有对应的 unit**。给不存在的 unit 写 drop-in 是惰性的，
   而这恰恰是所有人都以为已经生效的那类调优。

## 明确保留的两个判断

**`vm.overcommit_memory = 1`**：内核不再拒绝任何分配，超卖由 OOM killer 兜底。
对 Redis/ES 这类应用是对的；如果你希望 kubelet 的 eviction 在 OOM 之前先动手，
改成 `0`。

**`kernel.kptr_restrict = 2` 与 `perf_event_paranoid = 3`**：会让
`/proc/kallsyms` 全零、非特权 `perf_event_open` 全禁。Cilium 数据面不受影响
（tc/XDP 挂载不需要 kallsyms），但 Parca / Pyroscope / bpftrace 这类工具在这个
节点上会拿不到内核栈。要跑持续 profiling 就把这两条分别降到 `1` 和 `2`。
文件里每条都标了 `COST:`，按需删单条，不要整份删掉。
