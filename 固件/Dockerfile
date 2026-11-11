# OpenWrt ImageBuilder 的运行环境（官方只提供 Linux x86_64 版；Apple 芯片上经 colima + Rosetta 运行）
FROM --platform=linux/amd64 debian:12-slim
RUN apt-get update && apt-get install -y --no-install-recommends \
    build-essential gawk gettext git file rsync wget curl unzip bzip2 xz-utils zstd python3 python3-setuptools \
    libncurses-dev zlib1g-dev libssl-dev perl ca-certificates && rm -rf /var/lib/apt/lists/*
COPY 下载/openwrt-imagebuilder-25.12.5-ramips-mt7621.Linux-x86_64.tar.zst /tmp/ib.tar.zst
RUN mkdir /ib && tar --zstd -xf /tmp/ib.tar.zst -C /ib --strip-components=1 && rm /tmp/ib.tar.zst
WORKDIR /ib
