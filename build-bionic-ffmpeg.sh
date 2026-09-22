#!/usr/bin/env bash
# 在 WSL(Ubuntu 24.04) 中构建 bionic 版 ffmpeg（动态链接 bionic，可过 Android seccomp 白名单）。
# 无 root 方案：NDK 解压到 $HOME，make 用 deb 解包。
set -euo pipefail

W=/mnt/f/sunc/ProjectGit/fork/bililive-go-ffmpeg-build   # Windows 侧工作目录（放产物）
H=$HOME/ffbuild
mkdir -p "$H"
cd "$H"

export http_proxy=http://127.0.0.1:7897 https_proxy=http://127.0.0.1:7897

# ---------- 0. 编译工具（已由 wsl -u root apt 安装 make/gcc；保留 deb hack 作后备） ----------
if ! command -v make >/dev/null 2>&1 || ! command -v gcc >/dev/null 2>&1; then
  echo "!! 系统缺 make/gcc —— 请用: wsl -u root -e bash -c 'apt-get install -y make gcc'" >&2
  exit 1
fi
echo "==> $(make --version | head -1)"; echo "==> $(gcc --version | head -1)"

# ---------- 1. NDK (Linux 版) ----------
# 无 root 弄一个真 unzip（python3 zipfile 会丢失执行权限和符号链接）
if ! command -v unzip >/dev/null 2>&1; then
  mkdir -p "$H/local/bin" 2>/dev/null
  if [ ! -e "$H/local/usr/bin/unzip" ]; then
    echo "==> 安装 unzip（无 root）"
    ( cd "$H" && apt-get download unzip >/dev/null 2>&1 && \
      dpkg -x unzip_*.deb "$H/local" && \
      for d in $(dpkg -I unzip_*.deb | sed -n 's/^ *Depends: //p' | tr ',' '\n' | sed 's/ (.*//' | tr -d ' '); do
        apt-get download "$d" >/dev/null 2>&1 && dpkg -x "${d}_*.deb" "$H/local" || true
      done )
  fi
  export PATH="$H/local/usr/bin:$PATH"
fi

NDK_DIR=$H/android-ndk-r27c
if [ ! -x "$NDK_DIR/toolchains/llvm/prebuilt/linux-x86_64/bin/clang" ]; then
  rm -rf "$NDK_DIR"
  if [ ! -f android-ndk-r27c-linux.zip ]; then
    echo "==> 下载 NDK r27c (linux, ~700MB)"
    curl -sSL -o android-ndk-r27c-linux.zip https://dl.google.com/android/repository/android-ndk-r27c-linux.zip
  fi
  echo "==> 解压 NDK（真 unzip，保留权限/符号链接）"
  unzip -q android-ndk-r27c-linux.zip
  chmod -R u+rwX "$NDK_DIR"
  chmod +x "$NDK_DIR"/toolchains/llvm/prebuilt/*/bin/* 2>/dev/null || true
fi
export ANDROID_NDK_ROOT=$NDK_DIR
export PATH="$NDK_DIR/toolchains/llvm/prebuilt/linux-x86_64/bin:$PATH"

# openssl 的 android 目标按老式命名找 triple-gcc，补软链
for t in x86_64-linux-android aarch64-linux-android; do
  for s in gcc g++; do
    [ -e "$NDK_DIR/toolchains/llvm/prebuilt/linux-x86_64/bin/$t-$s" ] || \
      ln -s "${t}21-clang$( [ "$s" = g++ ] && echo ++ )" \
           "$NDK_DIR/toolchains/llvm/prebuilt/linux-x86_64/bin/$t-$s"
  done
done

# ---------- 2. openssl（静态库，供 ffmpeg TLS） ----------
SSL_VER=3.3.2
SSL_SRC=$H/openssl-$SSL_VER
if [ ! -d "$SSL_SRC" ]; then
  echo "==> 下载 openssl $SSL_VER"
  curl -sSL -o ssl.tar.gz https://github.com/openssl/openssl/releases/download/openssl-$SSL_VER/openssl-$SSL_VER.tar.gz
  tar xzf ssl.tar.gz
fi
build_ssl () {
  local TGT=$1 OUT=$2
  [ -f "$H/$OUT/lib/libssl.a" ] && return 0
  echo "==> 构建 openssl: $TGT"
  rm -rf "$SSL_SRC-$TGT"; cp -r "$SSL_SRC" "$SSL_SRC-$TGT"
  ( cd "$SSL_SRC-$TGT" && ./Configure "$TGT" -D__ANDROID_API__=21 no-shared no-tests \
      --prefix="$H/$OUT" > cfg.log 2>&1 \
    && make -j"$(nproc)" -s > build.log 2>&1 \
    && make install_sw > install.log 2>&1 )
  echo "    openssl $TGT 完成"
}
build_ssl android-x86_64 ssl-x64
build_ssl android-arm64  ssl-arm64

# ---------- 3. ffmpeg（bionic 动态链接） ----------
FF_TGZ=/mnt/f/sunc/ProjectGit/fork/bililive-go-ffmpeg-build/ffmpeg-src.tgz
build_ff () {
  local ARCH=$1 CPU=$2 TRIPLE=$3 SSL=$4 OUT=$5
  [ -f "$W/$OUT" ] && { echo "==> $OUT 已存在，跳过"; return 0; }
  echo "==> 构建 ffmpeg: $ARCH"
  rm -rf "$H/ff-$ARCH"
  mkdir -p "$H/ff-$ARCH"
  tar xzf "$FF_TGZ" -C "$H/ff-$ARCH" --strip-components=1
  ( cd "$H/ff-$ARCH" && ./configure \
      --target-os=android --enable-cross-compile --arch="$ARCH" --cpu="$CPU" \
      --cc="$NDK_DIR/toolchains/llvm/prebuilt/linux-x86_64/bin/${TRIPLE}21-clang" \
      --cxx="$NDK_DIR/toolchains/llvm/prebuilt/linux-x86_64/bin/${TRIPLE}21-clang++" \
      --disable-programs --enable-ffmpeg --disable-ffplay --disable-ffprobe \
      --disable-doc --disable-debug --disable-autodetect --enable-small \
      --enable-openssl --enable-nonfree --enable-network \
      --host-cc=gcc --host-ld=gcc --strip=llvm-strip \
      --extra-cflags="-I$H/$SSL/include -Os" \
      --extra-ldflags="-L$H/$SSL/lib" \
      > cfg.log 2>&1 \
    && make -j"$(nproc)" ffmpeg > build.log 2>&1 )
  llvm-strip -o "$W/$OUT" "$H/ff-$ARCH/ffmpeg"
  echo "    ffmpeg $ARCH 完成 -> $OUT"
}
build_ff x86_64  x86-64 x86_64-linux-android  ssl-x64   libffmpeg-x64-bionic.so
build_ff aarch64 armv8-a aarch64-linux-android ssl-arm64 libffmpeg-arm64-bionic.so

echo "===> BUILD-DONE"
ls -la "$W"/libffmpeg-*-bionic.so
