# 自动发布流水线（fork 私有）

上游 `vexxhost/capo-image-elements` 只到「构建并发 GitHub release」为止，
且版本靠 bump PR 等人合并。本目录是 fork 侧新增的一层，把链路补成
**发现 → 构建 → 验证 → 推 Glance → 真集群门禁 → 发布**，全程无人工。

**本目录全部是新增文件，没有改动任何上游文件**，因此从上游 merge 永远不会冲突。
`ci.yaml` 原样保留，仍是上游那套 PR 门禁。

## 为什么不用 GitHub API 取版本

```bash
# ❌ 会静默给出错误答案
curl -s .../kubernetes/kubernetes/releases/latest | jq -r .tag_name
```

`/releases/latest` 按 **tag 的 `created_at`** 排序，不是 semver。Kubernetes
每个补丁日同时为所有受支持分支发版（例：2026-08-20 同天发了 `v1.36.4`、
`v1.35.8`、`v1.34.11`），只要老 minor 的 tag 建得晚一点，这个接口就返回老
minor。它不报错，就是错。

权威指针由 Kubernetes 自己发布：

| URL | 含义 |
|---|---|
| `dl.k8s.io/release/stable.txt` | 全局最新稳定版 |
| `dl.k8s.io/release/stable-1.36.txt` | 该 minor 的最新补丁 |
| `dl.k8s.io/release/latest.txt` | 含 alpha/rc，**不要用** |

「哪些 minor 还在维护」则来自 `endoflife.date`——这也是上游 `hack/bump/`
在用的源，区别只是我们在运行时查，不生成 PR。

## 脚本

| 脚本 | 职责 |
|---|---|
| `discover.sh` | 运行时算出构建矩阵：维护中的 minor × OS × 架构，扣掉已发布的组合。输出 GitHub matrix JSON |
| `verify-image.sh` | loop 挂载刚构建的 raw，**从文件系统里读回**二进制是否存在、kubelet 版本是否真等于声称的版本、containerd 是否 `SystemdCgroup = true`，写 manifest |
| `glance/push.sh` | 按 manifest 打属性传 Glance，`copy-image` 路由进 RBD store 并轮询确认。**传上去是 private** |
| `gate.sh` | 用该镜像真的开一个 Magnum 集群，等 `CREATE_COMPLETE`、等所有节点 Ready、滚一个 Deployment、核对 kubelet 版本；通过才 `--public` 并发布集群模板；无论成败都拆干净 |

## 大文件不过墙

一个成品镜像 3.3 GB。**实测数据中心与 GitHub 之间约 0.6 MB/s —— 单个镜像
25 分钟**，比构建本身还久；整个矩阵下来比其余所有环节加起来都贵。所以大文件
在两个方向上都不跨这条边界：

| | 构建在哪 | 大文件去哪 | 穿墙 |
|---|---|---|---|
| **amd64** | 自建 runner（数据中心内） | → Glance（本地读缓存） | **零** |
| **arm64** | GitHub 的 arm runner | → Release（都在 GitHub 侧） | **零** |

arm64 不推 Glance —— 本集群没有 arm64 计算节点，推上去也开不起来，还要把
3.3 GB 拉回来。

**因此 GitHub Release 里放的是 manifest 和 sha256，不是镜像本体。** 镜像的去处
是 Glance，那才是它被使用的地方。要一个可下载的归档，用数据中心内的 Ceph RGW，
本地带宽。

## 三段都可单独重跑

```
discover ─→ build ─→ release   （可选,默认关）
                  └→ glance    （可选,默认关,仅 amd64）
```

`build` 把成品放进 `IMAGE_CACHE`（默认 `/var/lib/magnum-images`，在工作区之外）：

```
<name>.raw            3.3 GB,不压缩——唯一的消费者是 Glance 上传,它要的就是 raw
<name>.manifest.json
<name>.raw.sha256
```

**上传失败可以只重跑那个 job**，不重新编译、也不用把 3.3 GB 取回来。这正是把
构建和上传解耦的目的。缓存超过 `IMAGE_CACHE_DAYS`（默认 7 天）自动清理。

两个开关：

- 手动触发时勾 `release=true` / `glance=true`
- 仓库变量 `RELEASE_ENABLED=true` / `GLANCE_ENABLED=true` 让定时任务也带上

## "已构建"由谁记录

Release 变成可选之后，就不能只靠它了。`discover.sh` 现在认两处，任一命中即跳过：

1. **本地缓存** `$IMAGE_CACHE/<name>.manifest.json` —— 两个上传都关掉时唯一的记录
2. **Release 资产** —— 跨机器、跨缓存清空仍然有效

判据是 **manifest 名**而不是 `.raw.gz`（Release 里已经没有镜像本体了）。

它回答的只是"这个组合构建过没有"，不是"这个镜像好不好"，所以 prerelease 也算数。
要把一个已构建的组合重新喂给上传环节，用 `force=true`。

`prerelease` 标记承载的是**门禁有没有用这个镜像启动过节点**：`gate.sh` 通过后
`gh release edit --prerelease=false` 转正。同一个事实在 Glance 侧记在
`boot_verified` 属性和镜像可见性上——那才是真正能拦住别人误用的地方。

## 三条不肯让步的判据

**① 构建完成不等于构建正确。** `verify-image.sh` 的每一条断言都是把镜像挂起来
读出来的，不是复述构建时传进去的变量。装错 kubelet 的镜像不能自称正确。

**② 没验过的镜像不冒充验过的。** 门禁没跑或没过，镜像就停在 `private` +
`boot_verified=false`。本集群没有 arm64 计算节点，所以 arm64 镜像**必然**走
这条路——记录能力收窄，而不是假装通过。要放开，先有 arm64 compute。

**③ 必须是 raw，必须进 RBD store。** Cinder 只能 CoW 克隆与自己同一个 Ceph
集群里的 raw 镜像。落进别的 store 或存成 qcow2，每开一个节点都要全量拷贝一遍
——这条流水线存在的意义就是省掉它。所以 `push.sh` 在 `IMAGE_STORE` 为空时会
显式告警。

## 部署前置（一次性）

1. **自建 runner**：GitHub 托管 runner 到不了私网 Keystone/Glance。仓库变量
   `GLANCE_RUNNER` 填 ARC scale set 的标签。注意个人账号下 **1 个 scale set
   只能绑 1 个 repo**，现有的 `kubebrain` 绑的是别的仓库，需要新建一个。
2. **Secrets**：`OS_AUTH_URL` `OS_PROJECT_NAME` `OS_PROJECT_DOMAIN_NAME`
   `OS_USERNAME` `OS_USER_DOMAIN_NAME` `OS_PASSWORD` `OS_REGION_NAME`。
   该用户要能建 Magnum 集群、传公共镜像、建集群模板。
3. **仓库变量**（都有默认值）：`GLANCE_IMAGE_STORE`（默认 `rbd`）、
   `GATE_FLAVOR`（默认 `magnum-medium`）、`GATE_DNS`（默认 `192.168.4.254`）。
4. **flavor 必须存在**且带 `trait:CUSTOM_INCUS_SYSTEM_CONTAINER=forbidden`
   ——否则节点可能调度到 incus 计算节点，QCOW2/RAW 镜像在那里会
   `pylxd Image alias not found` 直接 ERROR。
5. **arm64 构建**用 GitHub 托管的 `ubuntu-24.04-arm`，私有仓库按分钟计费。
   不想要就把 `ARCH_LIST` 设成 `amd64`。

## 手动跑一次

```bash
./hack/discover.sh                      # 只看矩阵，不构建
FORCE=true ./hack/discover.sh           # 忽略已发布

# 构建（需要 root + loop device，不能在普通容器里）
export ELEMENTS_PATH=$PWD/elements DIB_RELEASE=noble DIB_KUBERNETES_VERSION=1.37.0
export DIB_CLOUD_INIT_GROWPART_DEVICES='["/"]' DIB_SKIP_BASE_PACKAGE_INSTALL=1
uv run disk-image-create -t raw -o ubuntu-24.04-v1.37.0-amd64 \
    vm ubuntu-minimal block-device-kubernetes kubernetes

sudo ./hack/verify-image.sh ubuntu-24.04-v1.37.0-amd64.raw \
    ubuntu-24.04-v1.37.0-amd64.manifest.json ubuntu 24.04 1.37.0 amd64

source /etc/openstack/admin-openrc
IMAGE_STORE=rbd ./hack/glance/push.sh ubuntu-24.04-v1.37.0-amd64.raw \
    ubuntu-24.04-v1.37.0-amd64.manifest.json
./hack/gate.sh "$(cat image-id.txt)" ubuntu-24.04-v1.37.0-amd64.manifest.json
```

`GATE_KEEP=true` 会在门禁结束后把集群留着供排查。
