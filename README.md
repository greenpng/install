# green-v6 install（公共安装仓库）

green-v6 的面向用户安装与发布测试仓库（`greenpng/install`）：

- **用户安装**：sh 脚本（`install.sh`）从 `greenpng/gv6-releases` 下载签名产物（x86_64 / aarch64）安装；可配合内置 Docker 数据服务（`install.sh --with-docker`）。
- **数据服务**：`docker/` 提供 PostgreSQL（4 库）+ Redis 容器（仅数据/缓存层；gv6 本体仍由 sh 脚本安装——官网独立部署，不进用户服务器）。
- **打包**：`release/` 本地编译并签名发布资产（镜像自 green-v7 `release/`，默认发布仓库 `greenpng/gv6-releases`）。**反破解加固流程**：每发布随机 `build_id` + 每版本临时签名密钥（根 key 签发证书）+ 模块双签（根 `sig` + 发布 `sig2`）+ 字符串混淆（详见 green-v7 `docs/07-HARDENING.md`）。
- **测试**：`.github/workflows/` 在 GitHub runner（x86_64 + aarch64 双矩阵）上分别测试 sh 安装与 docker 安装两种路径。

## 目录结构

```
install/
├── install.sh                 # 用户一键安装 (sh)
├── ota_ed25519.pk             # 模块签名公钥 (ed25519, 公开)
├── release/                   # 打包/发布脚本 (本地运行)
│   ├── build_multiarch.sh         # x86_64+aarch64 编译打包 (cross docker)
│   ├── build_and_publish.sh       # 单架构编译+上传
│   ├── build_signed_modules.sh    # 仅业务模块 .so 签名打包
│   ├── publish_modules.sh         # 模块发布
│   ├── update_runtime_from_github.sh  # 服务端运行时升级 (含 sha256 校验/回滚)
│   └── cargo_cyclonedx.py
├── docker/
│   ├── docker-compose.yml     # postgres(4库)+redis, 仅回环监听
│   ├── init-databases.sh      # 自动创建 gv6_biz/gv6_admin/gv6_assoc
│   └── .env.example
├── systemd/
│   └── green-v6.service       # systemd 单元模板 ({PREFIX} 占位)
├── test/
│   └── smoke_install.sh       # 安装后冒烟 (控制面/管理面/探测面/业务会话)
└── .github/workflows/
    ├── test-install-sh.yml        # runner: sh 安装 (x86_64+aarch64)
    └── test-install-docker.yml    # runner: docker 安装 (x86_64+aarch64)
```

## 用户安装

### 1) 仅编排服务并填写连接信息（sh 安装）

```bash
curl -fsSL -O https://raw.githubusercontent.com/greenpng/install/main/install.sh
bash install.sh --version 6.0.28
```

交互式向导按分组填写：

| 分组 | 变量 | 用途 |
|---|---|---|
| 业务面 | `GV6_DATABASE_URL` | 会话 / 探针冷存储 / 分析队列 |
| 业务面 | `GV6_BIZ_DATABASE_URL` | 业务看板 / 站点配置 |
| 业务面 | `GV6_ASSOCIATION_DATABASE_URL` | 关联分析 |
| 管理面 | `GV6_ADMIN_DATABASE_URL` | 管理面板 / 审计 / 集群 OTA |
| 缓存 | `GV5_REDIS_URL` | soft store / 多 worker 共享 L2（可选，留空=本地文件） |
| 登录 | `GV6_OFFICIAL_URL` / `GV6_OAUTH_ADMIN_EMAILS` | 管理面板 OAuth 跳转官网域名 + 管理员邮箱白名单 |

非交互（脚本化 / CI）：

```bash
curl -fsSL -O https://raw.githubusercontent.com/greenpng/install/main/install.sh
GV6_* 变量写入 my.env 后:
bash install.sh --version 6.0.28 --env-file my.env --no-systemd
```

### 2) 数据服务也由安装器管理（docker 方式）

```bash
bash install.sh --version 6.0.28 --with-docker
```

自动在本机起 `postgres(4库)+redis` 容器（`docker/.env` 随机密码，幂等复用），预填连接串后继续走 sh 安装流程。

其它常用参数：`--arch auto|x86_64|aarch64`、`--prefix /opt/green-v6`、`--yes`、`--no-systemd`（无 systemd 环境，后台拉起+日志在 `$PREFIX/log/`）。

## 本地打包（发布资产）

前置：green-v6/v7 源码 + Rust 1.88 + 根签名私钥（`GV6_OTA_SIGNING_KEY` 或 `keys/ota_ed25519.sk`）。

```bash
# 本机架构构建（不对外上传）
GV6_SRC=/path/to/green-v7 SKIP_PUBLISH=1 bash release/build_multiarch.sh TARGETS=x86_64
# 双架构 (aarch64 用 docker cross, 或直接用 GitHub arm runner)
GV6_SRC=/path/to/green-v7 SKIP_PUBLISH=1 bash release/build_multiarch.sh
# 上传到 greenpng/gv6-releases
bash release/build_multiarch.sh        # 或 build_and_publish.sh
# 增量（只重签某个模块；同版本复用同一发布 key + build_id，manifest 重新签名）
GV6_SRC=/path/to/green-v7 bash release/publish_modules.sh analyze
```

每个发布自动完成：

1. `GV6_BUILD_ID=$(openssl rand -hex 12)` → 注入全部二进制 + 写入 `dist/build_id` 与 manifest `build_id`；
2. `GV6_OBF_SALT=$(openssl rand -hex 16)` → 各 crate 编译期 XOR 字符串混淆（`gv6-obf`）；
3. 生成每版本临时密钥 `dist/release-{v}/keys-release/`（**不发布**，同版本重跑复用）→ 根 key 用 `gv6 sign-cert` 签发证书 → 模块双签 → manifest 绑定三者并签名；
4. FE min 包经 javascript-obfuscator（seed 由 build_id 派生）混淆。

产物：`gv6-service-{v}-{triple}`、`libgv6_{name}-{v}-{triple}.so`（逐模块双签 + `*.artifact.json`）、`fe-{v}.tgz`、`admin-spa.tgz`、`manifest-{triple}.json` + `manifest-index.json`、`build_id`、`release_cert.sig`、`release_pubkey.hex`、`ota_ed25519.pk`、SBOM。

本地整树验证（manifest 链 + 每模块链签 + sha256）：

```bash
GV6_RT_MANIFEST=dist/release-6.0.28/manifest.json \
GV6_RT_PUBKEY=keys/ota_ed25519.pk \
GV6_RT_DIR=dist/release-6.0.28 \
cargo test -p gv6-ota --test release_tree_verify -- --nocapture
```

## 测试（GitHub runner）

两个 workflow 均矩阵覆盖 **x86_64（ubuntu-24.04）+ aarch64（ubuntu-24.04-arm）**：

- `test-install-sh.yml`：先起数据服务容器（模拟用户自备 PG/Redis，手工填连接串）→ `install.sh --env-file` 非交互安装 → 冒烟。
- `test-install-docker.yml`：`install.sh --with-docker`（安装器自动管理数据服务）→ 冒烟。

手动触发：`Actions` → 选 workflow → `Run workflow`（可指定 `version`，留空 = latest）。打 `v*` tag 也会自动跑。

冒烟断言（`test/smoke_install.sh`）：控制面 `/v1/health` 200、管理面板未认证 `{console}/api/me` 401、探测面 `/v1/health` 200、业务会话 `/v1/session/open` 成功。

## 安全说明

- 运行时/FE 下载后按 `manifest` 的 `sha256` 校验（缺失即失败）。
- 模块 `.so` 由运行时 `gv6 stage` 做**链式验签**后 `activate`：根公钥验 `sig`（旧发布兼容），绑定了 release key 的发布还须通过 `sig2`（发布密钥）与证书链（`verify_manifest_chain` / `verify_artifact_sig_chain`）；公钥为公开产物，根私钥与每版本 release 私钥仅存于打包端/CI secret，release 私钥不随资产发布。
- 服务启动时对 active 模块做完整性自检（链签 + sha256，prod 或 `GV6_STRICT_BOOT_VERIFY=1` 下失败即拒绝启动）。
- tar 解包拒绝绝对路径/`..`/符号链接（R-05）。
- 默认仅回环监听（`.env` 中 `GV6_BIND` 等 127.0.0.1），对外暴露需显式修改。
