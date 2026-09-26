#!/usr/bin/env python3
"""从 dist/lovekey-tweak/ 的 deb 生成扁平 APT 源索引 (repo/)。
扁平源格式: deb [trusted=yes] <base-url> ./
"""
import os, hashlib, io, lzma, gzip, tarfile, shutil, sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
DIST = os.path.join(ROOT, "dist", "lovekey-tweak")
REPO = os.path.join(ROOT, "repo")

# 索引里只发布的架构（roothide=arm64e, rootless=arm64, rootful=arm）
PUBLISH_ARCHES = ("iphoneos-arm64e", "iphoneos-arm64", "iphoneos-arm")


def read_control(deb_path):
    """从 .deb 中读出 control 文本（ar 容器 + tar.xz/gz/lzma）。"""
    data = open(deb_path, "rb").read()
    if not data.startswith(b"!<arch>\n"):
        return None
    i = 8
    while i + 60 <= len(data):
        hdr = data[i:i + 60]
        name = hdr[:16].decode("latin1").strip().rstrip("/")
        try:
            size = int(hdr[48:58].decode("latin1").strip())
        except ValueError:
            return None
        blob = data[i + 60:i + 60 + size]
        if name.startswith("control.tar"):
            try:
                if name.endswith(".gz"):
                    tf = tarfile.open(fileobj=io.BytesIO(blob), mode="r:gz")
                elif name.endswith(".xz"):
                    tf = tarfile.open(fileobj=io.BytesIO(blob), mode="r:xz")
                else:
                    tf = tarfile.open(
                        fileobj=io.BytesIO(lzma.decompress(blob, format=lzma.FORMAT_ALONE)))
                for m in tf.getmembers():
                    if m.name.endswith("control"):
                        return tf.extractfile(m).read().decode("utf-8", "replace")
            except Exception:
                return None
        i += 60 + size
        if i % 2:
            i += 1
    return None


def main():
    if not os.path.isdir(DIST):
        print("dist 目录不存在:", DIST)
        return 1

    os.makedirs(REPO, exist_ok=True)

    entries = []
    for fn in sorted(os.listdir(DIST)):
        if not fn.endswith(".deb"):
            continue
        path = os.path.join(DIST, fn)
        ctrl = read_control(path)
        if not ctrl:
            print("跳过（无法读 control）:", fn)
            continue

        fields = {}
        order = []
        for line in ctrl.splitlines():
            if ":" in line and not line.startswith(" "):
                k, v = line.split(":", 1)
                fields[k.strip()] = v.strip()
                order.append(k.strip())

        arch = fields.get("Architecture", "")
        if arch not in PUBLISH_ARCHES:
            print("跳过（架构不在发布列表）:", fn, arch)
            continue

        data = open(path, "rb").read()
        fields["Filename"] = "./" + fn
        fields["Size"] = str(len(data))
        fields["SHA256"] = hashlib.sha256(data).hexdigest()
        fields["MD5sum"] = hashlib.md5(data).hexdigest()

        # 复制 deb 进 repo（APT 要求 Filename 是源内相对路径）
        dst = os.path.join(REPO, fn)
        if os.path.abspath(dst) != os.path.abspath(path):
            shutil.copy2(path, dst)
        entries.append(fields)

    if not entries:
        print("没有可发布的 deb")
        return 1

    # 按包名+架构排序，保证输出稳定
    entries.sort(key=lambda f: (f.get("Package", ""), f.get("Architecture", ""), f.get("Version", "")))

    prefer = ["Package", "Name", "Version", "Architecture", "Description",
              "Homepage", "Section", "Depends", "Priority", "Maintainer",
              "Author", "Installed-Size", "Filename", "Size", "SHA256", "MD5sum"]
    buf = []
    for f in entries:
        keys = [k for k in prefer if k in f] + [k for k in f if k not in prefer]
        for k in keys:
            buf.append(f"{k}: {f[k]}")
        buf.append("")
    payload = "\n".join(buf).encode("utf-8")

    open(os.path.join(REPO, "Packages"), "wb").write(payload)
    with gzip.GzipFile(os.path.join(REPO, "Packages.gz"), "wb", mtime=0) as gz:
        gz.write(payload)
    with lzma.open(os.path.join(REPO, "Packages.xz"), "wb") as xz:
        xz.write(payload)

    # Release 的哈希必须与磁盘上实际写入的文件一致，否则 APT 校验失败
    files = []
    for name in ("Packages", "Packages.gz", "Packages.xz"):
        fp = os.path.join(REPO, name)
        if os.path.exists(fp):
            b = open(fp, "rb").read()
            files.append((name, len(b), hashlib.md5(b).hexdigest(), hashlib.sha256(b).hexdigest()))

    lines = [
        "Origin: awjd007",
        "Label: LovekeyTweak",
        "Suite: stable",
        "Version: 1.0",
        "Codename: ios",
        "Architectures: " + " ".join(PUBLISH_ARCHES),
        "Components: main",
        "Description: Lovekey super-msg fix repo",
        "MD5Sum:",
    ]
    lines += [" " + md5 + " " + str(size) + " " + name for name, size, md5, _ in files]
    lines.append("SHA256:")
    lines += [" " + sha + " " + str(size) + " " + name for name, size, _, sha in files]
    lines.append("")
    release = "\n".join(lines)

    open(os.path.join(REPO, "Release"), "w", newline="\n").write(release)

    print(f"已发布 {len(entries)} 个包 -> repo/")
    for f in entries:
        print(f"   {f['Package']} {f['Version']} [{f['Architecture']}] {f['Size']}B")
    return 0


if __name__ == "__main__":
    sys.exit(main())
