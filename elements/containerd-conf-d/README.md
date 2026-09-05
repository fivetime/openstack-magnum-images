# containerd-conf-d

把 `/etc/containerd/config.toml` 改写成 **magnum-cluster-api 会写的那个形状**，
并建出它 import 的 `/etc/containerd/conf.d/`。

`crun`、`gvisor`、`kata` 三个元素都依赖它，它们的配置全部写成 conf.d 里的
drop-in，而不是改主配置。

## 为什么必须这样

**mcapi 不是合并镜像的 containerd 配置，是整个替换掉。**
`src/features/containerd_config.rs` 通过 cloud-init `write_files` 把一份模板
写到 `/etc/containerd/config.toml` 然后重启 containerd —— 镜像放在那里的东西，
在第一个 Pod 起来之前就没了。

这不是推测，是实测出来的：镜像里配好了 crun 和 gvisor handler，
**单 VM 门禁验过是生效的**，但用同一个镜像开出来的真 Magnum 集群里：

```
$ grep -A2 'runtimes.runc.options' /etc/containerd/config.toml
[plugins."io.containerd.grpc.v1.cri".containerd.runtimes.runc.options]
    SystemdCgroup = true          ← 没有 BinaryName
$ grep -oE 'runtimes\.[a-z0-9-]+\]' /etc/containerd/config.toml
runtimes.runc]                    ← 没有 gvisor
$ ls -l /usr/bin/crun /usr/bin/runsc
-rwxr-xr-x  3580152  /usr/bin/crun     ← 二进制在,配置没了
-rwxr-xr-x 105378363 /usr/bin/runsc
```

mcapi 写的模板（`src/resources.rs`）第四行留了出口：

```toml
version = 2
imports = ["/etc/containerd/conf.d/*.toml"]
```

**conf.d 是唯一活得下来的地方。**

## 两个必须同时满足的条件

**① 内容放 conf.d。** 改主配置等于写别人的文件。

**② 版本必须是 2。** containerd 把 imports 合并成一份文档再解释，所以
drop-in 的 schema 要和主配置一致。containerd 2.x 默认生成 **version 3**
（`plugins.'io.containerd.cri.v1.runtime'`），而 mcapi 写的是 **version 2**
（`plugins."io.containerd.grpc.v1.cri"`）。版本对不上时，drop-in 里的段会被
当成不存在的插件**静默忽略** —— 不报错，就是不生效。

所以这个元素把镜像自己的主配置也改成 version 2 + imports：**镜像应该在它
真正运行的形状下被测试**，而不是在一个只有构建期存在的形状里。

`sandbox_image` 从原配置里读出来沿用，不写死 —— 它必须和 `kubernetes` 元素
预拉的 pause 一致，否则第一个 sandbox 会去 registry 拉，而节点可能没有出网。

## 构建期校验

改完立刻 `containerd --config ... config dump`，配置不合法当场失败。
`verify-image.sh` 另外断言主配置**含 `imports` 且是 version 2** ——
少任何一条，drop-in 都不会生效，而这正是最难发现的那种失败。
