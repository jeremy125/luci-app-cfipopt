#!/usr/bin/env python3
"""Build a noarch .ipk for luci-app-cfipopt without the OpenWRT SDK.

OpenWRT 24.10 ipk format: gzip( tar( debian-binary, control.tar.gz, data.tar.gz ) )
where control.tar.gz / data.tar.gz are gzipped tars of ./control and ./data files.
"""
import gzip
import io
import os
import tarfile

ROOT = os.path.dirname(os.path.abspath(__file__))
OUT = os.path.join(ROOT, "luci-app-cfipopt_1.0.4-1_all.ipk")

# (path-in-package, host-path, mode)
DATA = [
    ("/etc/config/cfipopt", "files/etc/config/cfipopt", 0o644),
    ("/usr/libexec/cfipopt/run.sh", "files/usr/libexec/cfipopt/run.sh", 0o755),
    ("/usr/share/rpcd/ucode/luci.cfipopt", "files/usr/share/rpcd/ucode/luci.cfipopt", 0o644),
    ("/usr/share/rpcd/acl.d/luci-app-cfipopt.json", "files/usr/share/rpcd/acl.d/luci-app-cfipopt.json", 0o644),
    ("/usr/share/luci/menu.d/luci-app-cfipopt.json", "files/usr/share/luci/menu.d/luci-app-cfipopt.json", 0o644),
    ("/www/luci-static/resources/view/cfipopt/overview.js", "htdocs/luci-static/resources/view/cfipopt/overview.js", 0o644),
]

CONTROL = """Package: luci-app-cfipopt
Version: 1.0.4-1
Depends: curl, luci-base
Section: luci
Architecture: all
Maintainer: jeremy125
Installed-Size: 32
Description: Cloudflare IP optimizer & speed test for edgetunnel.
 Outputs IP:port#remark lines usable as edgetunnel node list.
"""


def make_tar(members, prefix="./"):
    buf = io.BytesIO()
    with tarfile.open(fileobj=buf, mode="w", format=tarfile.GNU_FORMAT) as tf:
        for name, data, mode in members:
            ti = tarfile.TarInfo(prefix + name)
            if name.endswith("/"):
                ti.type = tarfile.DIRTYPE
            ti.size = len(data)
            ti.mode = mode
            ti.mtime = 0
            ti.uid = ti.gid = 0
            ti.uname = ti.gname = "root"
            tf.addfile(ti, io.BytesIO(data))
    return buf.getvalue()


def gz(data):
    return gzip.compress(data, mtime=0)


def main():
    # explicit directory entries first (opkg extracts in tar order)
    dirs = set()
    for pkg_path, _, _ in DATA:
        parts = pkg_path.lstrip("/").split("/")[:-1]
        for i in range(1, len(parts) + 1):
            dirs.add("/".join(parts[:i]))
    data_members = [(d + "/", b"", 0o755) for d in sorted(dirs, key=lambda s: s.count("/"))]
    for pkg_path, host_path, mode in DATA:
        with open(os.path.join(ROOT, host_path), "rb") as f:
            data_members.append((pkg_path.lstrip("/"), f.read(), mode))

    control_tar = gz(make_tar([("control", CONTROL.encode(), 0o644)]))
    data_tar = gz(make_tar(data_members))

    outer = make_tar([
        ("debian-binary", b"2.0\n", 0o644),
        ("data.tar.gz", data_tar, 0o644),
        ("control.tar.gz", control_tar, 0o644),
    ])

    with open(OUT, "wb") as f:
        f.write(gz(outer))

    print(f"built {OUT} ({os.path.getsize(OUT)} bytes)")


if __name__ == "__main__":
    main()
