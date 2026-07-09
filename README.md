# playwright-mcp-ohos

在 HarmonyOS PC（鸿蒙电脑，aarch64 / OHOS musl）的 hishell 终端里跑
[@playwright/mcp](https://www.npmjs.com/package/@playwright/mcp)。
GitHub Actions 云端完成全部重活（组装 + 静态审计 + 真实 arm64 冒烟测试），
设备上只做一件本地才能做的事：内核代码签名。

## 原理

鸿蒙 PC 上 Playwright 官方 Chromium 跑不起来的根因是 **glibc/musl ABI**：
Playwright 下载的 linux-arm64 Chromium 链接 `/lib/ld-linux-aarch64.so.1`，
而系统只有 `/lib/ld-musl-aarch64.so.1`。

本仓库不从源码编译 Chromium（免费 runner 编不动），而是取 **Alpine Linux
aarch64 的 chromium 包**——它本来就是 musl 链接的，ELF interpreter 与鸿蒙完全同路径，
ABI 兼容性与 musllinux pip wheel 在鸿蒙直接可用是同一条原理。CI 流程：

1. **assemble**：在 arm64 Alpine 容器中 `apk add --root` 把 chromium
   及全部依赖装进独立 prefix，裁剪无关文件，删掉 prefix 自带的 musl
   loader/libc（必须用设备的），全 ELF 打 `$ORIGIN` rpath 兜底，断言
   interpreter 为 `/lib/ld-musl-aarch64.so.1`。
2. **audit**（静态门禁）：prefix 内所有 ELF 的 NEEDED soname 与强未定义符号，
   必须由 prefix 自身 + **真机导出的 OHOS musl 符号基线**
   （`baselines/ohos-musl-symbols.txt`，从设备 `/lib/ld-musl-aarch64.so.1`
   dump）+ harmonybrew musl-compat shim 完全闭合，否则 CI 红。
3. **smoke**（动态门禁）：同一容器内用与设备完全相同的 env 契约
   （`LD_LIBRARY_PATH`/`FONTCONFIG_FILE` 等）跑 playwright-core 起浏览器、
   开页面、截图，再以 stdio JSON-RPC 完整走一遍 @playwright/mcp
   `initialize → tools/list → browser_navigate`。
4. **pack/release**：可复现 tar.zst + SHA256SUMS，tag 时发 release。

设备端 `install.sh`：下载 release → 解包 → **全量 ELF 签名 sweep**
（llvm-strip → 64KB 对齐 → `binary-sign-tool selfSign`，签名必须是最后一步）→
`npm install --ignore-scripts` 装 MCP → 生成 `mcp-config.json`。

鸿蒙侧三个关键补丁都在配置里，不改上游代码：

| 问题 | 处置 |
| --- | --- |
| node 报 `process.platform === 'openharmony'`，playwright 拒绝 | `node --require shim.cjs` 预载改为 `linux` |
| `/tmp` 是只读 erofs | `TMPDIR` 指向 `/data/storage/el2/base/cache/pw-tmp`（应用沙箱真实 ext4） |
| 内核 XPM 校验所有 exec/mmap 的 ELF | 安装时对 prefix 内全部 ELF selfSign |

## 设备要求

- HarmonyOS PC，已装 [harmonybrew](https://atomgit.com/Harmonybrew)
- `brew install node python3 zstd gnu-tar coreutils gh devel-base`
  （devel-base 提供 `binary-sign-tool` 与 llvm 工具）

## 安装

```sh
gh release download --repo jerry-271828/playwright-mcp-ohos --pattern install.sh --dir /tmp-inst 2>/dev/null || true
# 或直接 curl -LO 下载 release 里的 install.sh
sh install.sh
```

完成后按提示注册：

```sh
claude mcp add-json playwright-ohos "$(cat ~/.playwright-ohos/mcp-config.json)"
```

可选自测：`node ~/.playwright-ohos/test-local.mjs`（起一次浏览器、截一张图）。

## 排障

- 启动失败先看：`hilog -x | grep -iE "xpm|code.?sign|verity"`
  - `permission denied`（EACCES）= 有 ELF 没签上 → 重跑
    `python3 ohos_sign_sweep.py ~/.playwright-ohos/prefix`
  - `operation not permitted`（EPERM）= 签名校验失败（文件签名后被改过）
- 访问外网：Chromium 会读取继承的 `http_proxy/https_proxy/no_proxy` 环境变量；
  本仓库与生成的配置**不含任何代理地址**，需要代理就在你自己的 shell 环境里设。
- 网页字体缺字：往 `~/.playwright-ohos/prefix/usr/share/fonts` 里加字体文件即可。
- 签名后的文件受 fs-verity 保护不可修改；升级 = 重跑 install.sh（原子换目录）。

## 基线文件的来历

`baselines/*.txt` 是在目标设备上用 `llvm-readelf --dyn-symbols` 从
`/lib/ld-musl-aarch64.so.1` 和 harmonybrew `libmusl_compat.so` 导出的
动态符号清单（仅符号名，无任何个人信息）。换新系统版本后建议重新 dump。

## 许可

仓库脚本 MIT。产物 tarball 里是 Alpine Linux 打包的 Chromium 及依赖，
遵循各自上游许可（BSD 等），`prefix/.meta/manifest.txt` 有完整包清单。
