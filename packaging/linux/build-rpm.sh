#!/usr/bin/env bash
# Hand-rolled .rpm around rivet's staged Linux payload — the rpm twin of
# build-deb.sh: same /opt/movebit payload, /usr/bin/movebit symlink, desktop
# entry, and pixmaps icon. Builds with rpmbuild -bb from a generated spec
# and a STAGED tree copied into the buildroot in %install — no root
# privileges, no %dist tag (one rpm validates on any rpm-based distro), and
# the libtinfo exclusion that keeps the Ubuntu-built Racket runtime
# installable on Fedora (rivet's rpm recipe).
#
# Usage: build-rpm.sh <version> <payload-dir> <arch> [output-dir]
#   <payload-dir>  rivet's staged package dir, i.e. dist/movebit-linux-<arch>/
#   <arch>         x64 | arm64  (rpm arch: x86_64 | aarch64)
set -euo pipefail

version="${1:?usage: build-rpm.sh <version> <payload-dir> <arch> [output-dir]}"
payload="${2:?usage: build-rpm.sh <version> <payload-dir> <arch> [output-dir]}"
arch="${3:?usage: build-rpm.sh <version> <payload-dir> <arch> [output-dir]}"
out_dir="${4:-dist}"
root="$(cd "$(dirname "$0")/../.." && pwd)"

case "$arch" in
  x64) rpm_arch=x86_64 ;;
  arm64) rpm_arch=aarch64 ;;
  *) echo "error: unsupported arch '$arch' (want x64 or arm64)" >&2; exit 1 ;;
esac

[[ -x "$payload/RivetHost" ]] || { echo "error: $payload/RivetHost missing" >&2; exit 1; }
[[ -f "$payload/res/core.zo" ]] || { echo "error: $payload/res/core.zo missing" >&2; exit 1; }
command -v rpmbuild >/dev/null 2>&1 || {
  echo "error: rpmbuild not found (apt-get install rpm)" >&2; exit 1; }

work="$(cd "$out_dir" 2>/dev/null && mkdir -p .rpm-build && cd .rpm-build && pwd)"
[[ -d "$work" ]] || { mkdir -p "$root/$out_dir/.rpm-build"; work="$root/$out_dir/.rpm-build"; }
topdir="$work/top"
rm -rf "$topdir"
staged="$topdir/STAGED"
mkdir -p "$staged/opt/movebit" "$staged/usr/bin" \
  "$staged/usr/share/applications" "$staged/usr/share/pixmaps" \
  "$topdir/SPECS"

cp -R "$payload"/. "$staged/opt/movebit/"
chmod +x "$staged/opt/movebit/RivetHost"
ln -s /opt/movebit/RivetHost "$staged/usr/bin/movebit"
cp "$root/assets/icon.png" "$staged/usr/share/pixmaps/movebit.png"

cat > "$staged/usr/share/applications/movebit.desktop" <<'EOF'
[Desktop Entry]
Type=Application
Name=MoveBit
Comment=Healthy work rhythm companion
Exec=/usr/bin/movebit
Icon=movebit
Terminal=false
Categories=Utility;
StartupNotify=false
EOF

cat > "$topdir/SPECS/movebit.spec" <<'EOF'
%global __requires_exclude ^libtinfo\\.so\\.6\\(NCURSES6_TINFO_.*$
Name:           movebit
Version:        __MB_VERSION__
Release:        1
Summary:        Healthy work rhythm companion
License:        Proprietary
URL:            https://movebit.jrtx.site/
BuildArch:      __MB_ARCH__
Requires:       gtk4
Requires:       ncurses-libs

%description
MoveBit tracks active work time and provides sit, water, and micro-break
reminders. The package is self-contained under /opt; GTK 4 is the only
external runtime dependency.

%prep

%build

%install
rm -rf "%{buildroot}"
mkdir -p "%{buildroot}"
cp -a "%{_topdir}/STAGED/." "%{buildroot}/"

%files
%dir "/opt/movebit"
"/opt/movebit/*"
"/usr/bin/movebit"
"/usr/share/applications/movebit.desktop"
"/usr/share/pixmaps/movebit.png"
EOF
sed -i "s/__MB_VERSION__/$version/; s/__MB_ARCH__/$rpm_arch/" "$topdir/SPECS/movebit.spec"

case "$out_dir" in
  /*) dest="$out_dir" ;;
  *) dest="$root/$out_dir" ;;
esac
mkdir -p "$dest"

rpmbuild -bb --define="_topdir $topdir" \
              --define="_rpmdir $dest" \
              --define="_build_name_fmt %{NAME}-%{VERSION}-%{RELEASE}.%{ARCH}.rpm" \
              "$topdir/SPECS/movebit.spec"

artifact="$dest/movebit-${version}-1.${rpm_arch}.rpm"
[[ -f "$artifact" ]] || { echo "error: rpmbuild did not produce $artifact" >&2; exit 1; }
# The final name carries the native rpm arch spelling (x86_64/aarch64),
# matching the family benchmark (taskly/brainfuel/payback rpms).
mv "$artifact" "$dest/movebit-${version}-linux-${rpm_arch}.rpm"
artifact="$dest/movebit-${version}-linux-${rpm_arch}.rpm"

# Verify the package metadata and payload presence.
rpm -qp --qf '%{NAME} %{VERSION} %{ARCH}\n' "$artifact" | grep -q "^movebit $version $rpm_arch$"
rpm -qpl "$artifact" | grep -q '^/opt/movebit/RivetHost$'
rpm -qpl "$artifact" | grep -q '^/opt/movebit/res/core.zo$'
rpm -qpl "$artifact" | grep -q '^/usr/share/applications/movebit.desktop$'
rpm -qpl "$artifact" | grep -q '^/usr/share/pixmaps/movebit.png$'
rpm -qpl "$artifact" | grep -q '^/usr/bin/movebit$'

hash="$(sha256sum "$artifact" | awk '{print $1}')"
printf '%s  %s\n' "$hash" "$(basename "$artifact")" > "$artifact.sha256"
rm -rf "$topdir"
echo "rpm: $artifact ($rpm_arch, $(du -h "$artifact" | cut -f1))"
