# ffmpeg-bionic

为 Android App 内直接执行而构建的 **bionic 动态链接 ffmpeg**（FFmpeg n7.1 + openssl，启用网络功能）。

## 为什么需要它

Android App 进程受 seccomp 白名单限制，常见现成二进制全部不可用：

| 来源 | 问题 |
|------|------|
| 静态构建（johnvansickle / ffmpeg-static 等） | musl 链接，x86_64 上走 legacy stat/lstat/fstat syscall → 被 seccomp 杀（SIGSYS） |
| 普通 Linux 发行版构建 | glibc 动态链接，Android 没有 glibc，interpreter not found |
| Termux 包 | 50+ 动态依赖链，无法逐个塞进 APK |
| **本仓库（NDK 自编 bionic 版）** | ✅ 只 NEEDED `libm.so libdl.so libc.so`，可过 seccomp 白名单 |

## 产物

| 文件 | 架构 | 大小 | SHA256 |
|------|------|------|--------|
| `libffmpeg-arm64-bionic.so` | arm64-v8a（真机） | 19.7 MB | `54fa39d5…87d88cb` |
| `libffmpeg-x64-bionic.so` | x86_64（模拟器） | 23.2 MB | `6de4ca03…1ec9d49` |

完整校验和见 `SHA256SUMS.txt`。

特性：FFmpeg n7.1、openssl（https/网络可用）、非 free、动态链接 bionic。
configure 关键参数踩坑记录见 `build-bionic-ffmpeg.sh` 头部注释。

## 直接下载

```bash
# 方式一：git clone（双站均可，最可靠）
git clone https://gitee.com/giteesunc/ffmpeg-bionic.git   # 国内推荐
git clone https://github.com/sunc-Q/ffmpeg-bionic.git

# 方式二：raw 直链（仅 GitHub；Gitee 平台对大文件匿名 raw 返回 403，需登录后下载）
curl -LO https://raw.githubusercontent.com/sunc-Q/ffmpeg-bionic/main/libffmpeg-arm64-bionic.so
```

> 注意：Gitee 平台策略限制超过 1MB 的文件匿名 raw 访问（403 require login），
> .so 文件请通过 `git clone` 或登录 Gitee 后从仓库页面下载。下载后可用 `SHA256SUMS.txt` 校验：
> `sha256sum -c SHA256SUMS.txt`

## 用法（Android App 内）

1. 文件名已符合 `lib*.so` 规范，直接放进 APK 工程 `app/src/main/jniLibs/<abi>/`；
   Manifest 设 `android:extractNativeLibs="true"`，启动时 `System.loadLibrary` 触发解压。
2. 运行路径 = `applicationInfo.nativeLibraryDir + "/libffmpeg-arm64-bionic.so"`。
3. 网络功能需要 CA 证书：Android 无默认 CA 路径，把 certifi 的 `cacert.pem`
   改名 `libcacert.so` 一起放进 jniLibs，执行前设 `SSL_CERT_FILE` 指向它。
4. 启动前建议探测：跑一次 `<path> -version`，exit 0 且输出含 `ffmpeg version` 才启用。

## 构建方式（复现）

环境：WSL Ubuntu 24.04 + Linux 版 NDK r27c + openssl/FFmpeg 源码。
脚本：`build-bionic-ffmpeg.sh`（在 WSL 内执行）。

关键点：
- openssl `./Configure android` 目标 + `-D__ANDROID_API__=21`；
- NDK 必须用 `unzip` 解压（`python -m zipfile` 会丢执行权限和符号链接）；
- ffmpeg configure：`--cpu=x86-64`（写 `x86_64` 会生成非法 `-march` 参数）、
  `--host-cc=gcc --host-ld=gcc --strip=llvm-strip`；
- 构建于 2026-09-22，源头项目：bililive-go Android 移植。

## License

ffmpeg 产物含非 free 组件（openssl），遵循 FFmpeg/openssl 各自许可证；
仅用于技术研究，请自行评估商用合规。
