#!/usr/bin/env bash
set -uo pipefail

ROOT="${1:-$PWD}"
cd "$ROOT" || { echo "FATAL: tidak bisa cd ke $ROOT"; exit 1; }

for marker in build/envsetup.sh build/make/core/main.mk build/soong; do
  if [ ! -e "$marker" ]; then
    echo "FATAL: '$ROOT' bukan root source tree Android (tidak ada $marker)."
    exit 1
  fi
done

echo "=============================================================="
echo " apply-arm64-host.sh  (root=$ROOT)"
echo " host: $(uname -s -m)"
echo "=============================================================="

FAILED=0
step() { echo ""; echo "--- [$1] $2"; }
ok()   { echo "    OK  : $1"; }
skip() { echo "    SKIP: $1"; }
warn() { echo "    WARN: $1"; FAILED=$((FAILED+1)); }

insert_after() {
  local file="$1" anchor="$2" marker="$3" blockfile="$4"
  if [ ! -f "$file" ]; then warn "file tidak ada: $file"; return; fi
  if grep -qF "$marker" "$file"; then skip "sudah dipatch: $file"; return; fi
  local lineno
  lineno=$(grep -nF -- "$anchor" "$file" | head -1 | cut -d: -f1)
  if [ -z "$lineno" ]; then warn "anchor tak ditemukan di $file: $anchor"; return; fi
  sed -i "${lineno}r ${blockfile}" "$file" \
    && ok "patch diterapkan: $file (setelah baris $lineno)" \
    || warn "gagal patch: $file"
}

sed_replace() {
  local file="$1" marker="$2" old="$3" new="$4"
  if [ ! -f "$file" ]; then warn "file tidak ada: $file"; return; fi
  if grep -qF "$marker" "$file"; then skip "sudah dipatch: $file"; return; fi
  if ! grep -qE -- "$old" "$file"; then warn "pola tak ditemukan di $file: $old"; return; fi
  sed -i -E "s|$old|$new|" "$file" \
    && ok "sed diterapkan: $file" \
    || warn "sed gagal: $file"
}

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

step "0001" "envsetup.sh: get_host_prebuilt_prefix -> linux-arm64 pada aarch64"
ENVSETUP="build/make/envsetup.sh"
if [ -f "$ENVSETUP" ]; then
  if grep -q 'um="$(uname -m)"' "$ENVSETUP" 2>/dev/null || grep -qF 'linux-arm64' "$ENVSETUP"; then
    skip "sudah dipatch: $ENVSETUP"
  else
    python3 - "$ENVSETUP" <<'PY' || warn "gagal patch envsetup.sh"
import re, sys
p = sys.argv[1]
s = open(p, encoding="utf-8").read()
old = '''function get_host_prebuilt_prefix
{
  local un=$(uname)
  if [[ $un == "Linux" ]] ; then
    echo linux-x86
'''
new = '''function get_host_prebuilt_prefix
{
  local un=$(uname)
  local um=$(uname -m)
  if [[ $un == "Linux" ]] ; then
    if [[ $um == "aarch64" ]] ; then
      echo linux-arm64
    else
      echo linux-x86
    fi
'''
if old not in s:
    print("    WARN: pola get_host_prebuilt_prefix tak cocok"); sys.exit(1)
open(p, "w", encoding="utf-8").write(s.replace(old, new, 1))
print("    OK  : envsetup.sh dipatch")
PY
  fi
else
  warn "$ENVSETUP tidak ada"
fi

step "0002" "envsetup.mk: HOST_ARCH=arm64 + HOST_PREBUILT_ARCH=arm64 + clang HOST_arm64.mk"
ENVMK="build/make/core/envsetup.mk"
if [ -f "$ENVMK" ]; then
  python3 - "$ENVMK" <<'PY' || warn "gagal patch envsetup.mk"
import sys
p = sys.argv[1]
s = open(p, encoding="utf-8").read()
changed = False

anchor = '''ifneq (,$(findstring x86_64,$(UNAME)))
  HOST_ARCH := x86_64
  HOST_2ND_ARCH := x86
  HOST_IS_64_BIT := true
else
'''
add_a = '''ifneq (,$(findstring x86_64,$(UNAME)))
  HOST_ARCH := x86_64
  HOST_2ND_ARCH := x86
  HOST_IS_64_BIT := true
else
ifneq (,$(findstring aarch64,$(UNAME)))
  HOST_ARCH := arm64
  HOST_2ND_ARCH :=
  HOST_IS_64_BIT := true
else
'''
if "HOST_ARCH := arm64" in s:
    print("    SKIP: cabang HOST_ARCH arm64 sudah ada")
elif anchor in s:
    s = s.replace(anchor, add_a, 1); changed = True
    print("    OK  : cabang HOST_ARCH arm64 ditambahkan")
else:
    print("    WARN: anchor HOST_ARCH tak cocok")
    sys.exit(1)

MARK_A2 = "# arm64-host: endif penutup blok HOST_ARCH"
if "HOST_ARCH := arm64" in s and MARK_A2 not in s:
    lines = s.split("\n")
    inserted = False
    for i, ln in enumerate(lines):
        if "32-bit x86 host is not supported" in ln:
            seen = 0
            for j in range(i + 1, min(len(lines), i + 12)):
                if lines[j].strip() == "endif":
                    seen += 1
                    if seen == 2:
                        lines.insert(j + 1, MARK_A2)
                        lines.insert(j + 2, "endif")
                        inserted = True
                        break
            break
    if inserted:
        s = "\n".join(lines); changed = True
        print("    OK  : endif penutup ditambahkan (blok HOST_ARCH)")
    else:
        print("    WARN: baris $(error 32-bit) / 2x endif tak ditemukan")
        sys.exit(1)
elif MARK_A2 in s:
    print("    SKIP: endif penutup sudah ada")

old_b = '''# We don't want to move all the prebuilt host tools to a $(HOST_OS)-x86_64 dir.
HOST_PREBUILT_ARCH := x86
'''
new_b = '''# We don't want to move all the prebuilt host tools to a $(HOST_OS)-x86_64 dir.
ifeq ($(HOST_ARCH),arm64)
HOST_PREBUILT_ARCH := arm64
else
HOST_PREBUILT_ARCH := x86
endif
'''
if "HOST_PREBUILT_ARCH := arm64" in s:
    print("    SKIP: HOST_PREBUILT_ARCH arm64 sudah ada")
elif old_b in s:
    s = s.replace(old_b, new_b, 1); changed = True
    print("    OK  : HOST_PREBUILT_ARCH arm64 ditambahkan")
else:
    print("    WARN: anchor HOST_PREBUILT_ARCH tak cocok")
    sys.exit(1)

if changed:
    open(p, "w", encoding="utf-8").write(s)
PY
else
  warn "$ENVMK tidak ada"
fi

CLANGMK="build/make/core/clang/HOST_arm64.mk"
if [ ! -f "$CLANGMK" ]; then
  mkdir -p "$(dirname "$CLANGMK")"
  cat > "$CLANGMK" <<'EOF'
HOST_LIBPROFILE_RT := $(LLVM_RTLIB_PATH)/libclang_rt.profile-aarch64.a
HOST_LIBCRT_BUILTINS := $(LLVM_RTLIB_PATH)/libclang_rt.builtins-aarch64.a
EOF
  ok "dibuat: $CLANGMK"
else
  skip "sudah ada: $CLANGMK"
fi

step "0006" "soong/paths.go: host-out dir naming utk host arm64"
PATHS="build/soong/android/paths.go"
if [ -f "$PATHS" ]; then
  python3 - "$PATHS" <<'PY' || warn "gagal patch soong/paths.go"
import sys
p = sys.argv[1]
s = open(p, encoding="utf-8").read()
changed = False

old1 = '''		if os == LinuxMusl && ctx.Config().UseHostMusl() {'''
new1 = '''		if os == LinuxMusl && (ctx.Config().UseHostMusl() || os == ctx.Config().BuildOS) {'''
if "os == ctx.Config().BuildOS" in s:
    print("    SKIP: collapse LinuxMusl sudah ada")
elif old1 in s:
    s = s.replace(old1, new1, 1); changed = True
    print("    OK  : collapse LinuxMusl -> linux")
else:
    print("    WARN: anchor collapse LinuxMusl tak cocok")
    sys.exit(1)

old2 = '''		archName := arch.String()
		if os.Class == Host && (arch == X86_64 || arch == Common) {
			archName = "x86"
		}
'''
new2 = '''		archName := arch.String()
		if os.Class == Host && (arch == X86_64 || arch == Common) {
			archName = "x86"
			if ctx.Config().BuildArch == Arm64 {
				archName = "arm64"
			}
		}
'''
if 'archName = "arm64"' in s:
    print("    SKIP: archName arm64 sudah ada")
elif old2 in s:
    s = s.replace(old2, new2, 1); changed = True
    print("    OK  : archName arm64 ditambahkan")
else:
    print("    WARN: anchor archName tak cocok")
    sys.exit(1)

if changed:
    open(p, "w", encoding="utf-8").write(s)
PY
else
  warn "$PATHS tidak ada"
fi

step "0007" "soong/rule_builder.go: stage libc_musl.so utk BuiltTool musl"
RB="build/soong/android/rule_builder.go"
if [ -f "$RB" ]; then
  python3 - "$RB" <<'PY' || warn "gagal patch soong/rule_builder.go"
import sys
p = sys.argv[1]
s = open(p, encoding="utf-8").read()
old = '''	if c.rule.ctx.Config().UseHostMusl() {'''
new = '''	if c.rule.ctx.Config().UseHostMusl() || c.rule.ctx.Config().BuildOS == LinuxMusl {'''
if "c.rule.ctx.Config().BuildOS == LinuxMusl" in s:
    print("    SKIP: rule_builder sudah dipatch")
elif old in s:
    s = s.replace(old, new, 1)
    open(p, "w", encoding="utf-8").write(s)
    print("    OK  : rule_builder.go dipatch")
else:
    print("    WARN: anchor rule_builder tak cocok")
    sys.exit(1)
PY
else
  warn "$RB tidak ada"
fi

step "0004" "prebuilts/build-tools/Android.bp: enable arm64 utk bison/flex/m4/make"
BT="prebuilts/build-tools/Android.bp"
if [ -f "$BT" ]; then
  python3 - "$BT" <<'PY' || warn "gagal patch build-tools/Android.bp"
import re, sys
p = sys.argv[1]
s = open(p, encoding="utf-8").read()
if 'src: "linux-arm64/bin/' in s:
    print("    SKIP: build-tools arm64 sudah ada"); sys.exit(0)

names = ["bison", "flex", "m4", "make"]
count = 0
for n in names:
    pat = re.compile(
        r'(\n        linux: \{\n            src: "linux-x86/bin/' + n + r'")')
    repl = ('\n        linux_musl_arm64: {\n'
            '            src: "linux-arm64/bin/' + n + '",\n'
            '            deps: ["linux-arm64/lib64/libc_musl.so"],\n'
            '        },' + r'\1')
    s2, k = pat.subn(repl, s, count=1)
    if k:
        s = s2; count += 1

pat2 = re.compile(r'(        x86_64: \{\n            enabled: true,\n        \},\n    \},)')
s, k2 = pat2.subn(
    '        x86_64: {\n            enabled: true,\n        },\n'
    '        arm64: {\n            enabled: true,\n        },\n    },', s)
count += k2

if count == 0:
    print("    WARN: tidak ada anchor build-tools yang cocok")
    sys.exit(1)
open(p, "w", encoding="utf-8").write(s)
print("    OK  : build-tools dipatch (target=%d, arch=%d)" % (count - k2, k2))
PY
else
  warn "$BT tidak ada"
fi

step "0003" "soong/rust/toolchain_library.go: prefix linux-x86 (TIDAK diubah - lihat catatan)"
skip "sengaja tidak dipatch: prefix crate-source linux-x86 memang benar (arch-independent)"

step "0009" "soong/rust/builder.go: DILEWATI (tidak terbukti / premis sudah ada upstream)"
if [ -f "build/soong/rust/builder.go" ]; then
  skip "0009 tidak diterapkan — lihat komentar & README"
else
  skip "build/soong/rust/builder.go tidak ada (0009 memang tidak diterapkan)"
fi

step "0002b" "core/clang/config.mk: pakai clang arm64 utk host arm64"
CLANGCFG="build/make/core/clang/config.mk"
if [ -f "$CLANGCFG" ]; then
  python3 - "$CLANGCFG" <<'PY' || warn "gagal patch clang/config.mk"
import sys
p = sys.argv[1]
s = open(p, encoding="utf-8").read()
if "arm64-host" in s:
    print("    SKIP: clang/config.mk sudah dipatch")
    sys.exit(0)  # exit 0 -> tidak error, tapi script bash harus cek return code
old = '''## Clang configurations.

LLVM_READOBJ := $(LLVM_PREBUILTS_BASE)/$(BUILD_OS)-x86/$(LLVM_PREBUILTS_VERSION)/bin/llvm-readobj

LLVM_RTLIB_PATH := $(LLVM_PREBUILTS_BASE)/linux-x86/$(LLVM_PREBUILTS_VERSION)/lib/clang/$(LLVM_RELEASE_VERSION)/lib/linux/
'''
new = '''## Clang configurations.

ifeq ($(HOST_ARCH),arm64)
LLVM_HOST_PREBUILT_ARCH := arm64
else
LLVM_HOST_PREBUILT_ARCH := x86
endif

LLVM_READOBJ := $(LLVM_PREBUILTS_BASE)/$(BUILD_OS)-$(LLVM_HOST_PREBUILT_ARCH)/$(LLVM_PREBUILTS_VERSION)/bin/llvm-readobj

LLVM_RTLIB_PATH := $(LLVM_PREBUILTS_BASE)/linux-$(LLVM_HOST_PREBUILT_ARCH)/$(LLVM_PREBUILTS_VERSION)/lib/clang/$(LLVM_RELEASE_VERSION)/lib/linux/
'''
if old in s:
    s = s.replace(old, new, 1)
    open(p, "w", encoding="utf-8").write(s)
    print("    OK  : clang/config.mk dipatch (LLVM_READOBJ + RTLIB_PATH arm64)")
else:
    print("    WARN: anchor clang/config.mk tak cocok")
    sys.exit(1)
PY
else
  warn "$CLANGCFG tidak ada"
fi

step "0005" "prebuilts/jdk/jdk21/Android.bp: enable javap utk arm64 host"
JDKBP="prebuilts/jdk/jdk21/Android.bp"
if [ -f "$JDKBP" ]; then
  python3 - "$JDKBP" <<'PY' || warn "gagal patch jdk21/Android.bp"
import sys
p = sys.argv[1]
s = open(p, encoding="utf-8").read()
if "linux_musl_arm64" in s:
    print("    SKIP: javap arm64 sudah ada"); sys.exit(0)
old = '''        x86_64: {
            enabled: true,
        },
    },
    target: {
        linux: {
            src: "linux-x86/bin/javap",'''
new = '''        x86_64: {
            enabled: true,
        },
        arm64: {
            enabled: true,
        },
    },
    target: {
        linux_musl_arm64: {
            src: "linux-arm64/bin/javap",
            deps: [
                "linux-arm64/lib/libjli.so",
                "linux-arm64/lib/jrt-fs.jar",
                "linux-arm64/lib/jvm.cfg",
                "linux-arm64/lib/server/libjvm.so",
                "linux-arm64/lib/libverify.so",
                "linux-arm64/lib/libjava.so",
                "linux-arm64/lib/libzip.so",
                "linux-arm64/lib/libjimage.so",
                "linux-arm64/lib/modules",
                "linux-arm64/lib/libnio.so",
                "linux-arm64/lib/libnet.so",
                "linux-arm64/lib/tzdb.dat",
                "linux-arm64/lib/libawt.so",
                "linux-arm64/lib/libawt_headless.so",
                "linux-arm64/lib/libjavajpeg.so",
                "linux-arm64/lib/liblcms.so",
                "linux-arm64/lib/libmanagement.so",
                "linux-arm64/lib/libmanagement_ext.so",
                "linux-arm64/conf/security/java.security",
            ],
        },
        linux: {
            src: "linux-x86/bin/javap",'''
if old in s:
    s = s.replace(old, new, 1)
    open(p, "w", encoding="utf-8").write(s)
    print("    OK  : javap arm64 ditambahkan")
else:
    print("    WARN: anchor jdk21/Android.bp tak cocok")
    sys.exit(1)
PY
else
  warn "$JDKBP tidak ada"
fi

step "0012" "system/sepolicy: getopt() -> int (bukan char) utk aarch64"
SEP_FILES="system/sepolicy/tools/checkfc.c
system/sepolicy/tools/sepolicy-analyze/attribute.c
system/sepolicy/tools/sepolicy-analyze/neverallow.c
system/sepolicy/tools/sepolicy-check.c"
for f in $SEP_FILES; do
  if [ ! -f "$f" ]; then warn "tidak ada: $f"; continue; fi
  if grep -qE '^\s*char (c|ch);' "$f"; then
    sed -i -E 's/^([[:space:]]*)char (c|ch);/\1int \2;/' "$f" \
      && ok "getopt int: $f" || warn "gagal: $f"
  else
    skip "sudah int / pola tak ada: $f"
  fi
done

step "0014" "soong/scripts/jar-wrapper.sh: default -Xmx3g utk java_binary_host"
JW="build/soong/scripts/jar-wrapper.sh"
if [ -f "$JW" ]; then
  if grep -qF 'exec java -Xmx3g' "$JW" || grep -qF 'exec java -Xmx8g' "$JW"; then
    skip "sudah dipatch: $JW"
  elif grep -qF 'exec java "${javaOpts[@]}" -jar ${jardir}/${jarfile} "$@"' "$JW"; then
    python3 - "$JW" <<'PY' || warn "gagal patch jar-wrapper.sh"
import sys
p = sys.argv[1]
s = open(p, encoding="utf-8").read()
old = 'exec java "${javaOpts[@]}" -jar ${jardir}/${jarfile} "$@"'
new = ('# arm64-host (#28): default max-heap supaya tool hemat (metalava) tidak OOM;\n'
       '# -J-Xmx... dari tool ditambahkan setelahnya dan menimpa (JVM pakai -Xmx terakhir).\n'
       'exec java -Xmx3g "${javaOpts[@]}" -jar ${jardir}/${jarfile} "$@"')
s = s.replace(old, new, 1)
open(p, "w", encoding="utf-8").write(s)
print("    OK  : jar-wrapper.sh dipatch")
PY
  else
    warn "anchor jar-wrapper tak cocok"
  fi
else
  warn "$JW tidak ada"
fi

step "0015" "soong/android/arch.go: OsType Linux + Arm64 (host aarch64)"
ARCHGO="build/soong/android/arch.go"
if [ -f "$ARCHGO" ]; then
  python3 - "$ARCHGO" <<'PY' || warn "gagal patch soong/android/arch.go"
import sys
p = sys.argv[1]
s = open(p, encoding="utf-8").read()

MARK = "arm64-host: host aarch64 juga butuh varian linux_glibc_arm64"
if MARK in s:
    print("    SKIP: sudah dipatch"); sys.exit(0)

old = '\tLinux = newOsType("linux_glibc", Host, false, X86, X86_64)'
new = ('\t// arm64-host: host aarch64 juga butuh varian linux_glibc_arm64\n'
       '\t// di property struct "target" (lihat PATCH 0016 & 0017).\n'
       '\tLinux = newOsType("linux_glibc", Host, false, X86, X86_64, Arm64)')

if old not in s:
    print("    WARN: anchor 'Linux = newOsType(\"linux_glibc\"' tak cocok")
    sys.exit(1)
    sys.exit(0)

s = s.replace(old, new, 1)
open(p, "w", encoding="utf-8").write(s)
print("    OK  : Linux OsType kini dukung Arm64")
PY
else
  warn "$ARCHGO tidak ada"
fi

step "0016" "soong/rust/config/arm_linux_host.go: toolchain rust host glibc aarch64"
RUSTCFG="build/soong/rust/config/arm_linux_host.go"
if [ -f "$RUSTCFG" ]; then
  python3 - "$RUSTCFG" <<'PY' || warn "gagal patch rust/config/arm_linux_host.go"
import sys
p = sys.argv[1]
s = open(p, encoding="utf-8").read()

MARK = "arm64-host: toolchain rust host glibc untuk aarch64"
if MARK in s:
    print("    SKIP: sudah dipatch"); sys.exit(0)

old = '''\tregisterToolchainFactory(android.LinuxMusl, android.Arm64, linuxMuslArm64ToolchainFactory)
\tregisterToolchainFactory(android.LinuxMusl, android.Arm, linuxMuslArmToolchainFactory)'''

new = '''\tregisterToolchainFactory(android.LinuxMusl, android.Arm64, linuxMuslArm64ToolchainFactory)
\tregisterToolchainFactory(android.LinuxMusl, android.Arm, linuxMuslArmToolchainFactory)

\t// arm64-host: toolchain rust host glibc untuk aarch64.
\tregisterToolchainFactory(android.Linux, android.Arm64, linuxGlibcArm64ToolchainFactory)'''

append = '''
// Specialization of the 64-bit linux rust toolchain for glibc on aarch64
// hosts. Adds the gnu rust triple and sysroot linker flags.
// arm64-host: toolchain rust host glibc untuk aarch64.
type toolchainLinuxGlibcArm64 struct {
\ttoolchainLinuxArm64
}

func (t *toolchainLinuxGlibcArm64) RustTriple() string {
\treturn "aarch64-unknown-linux-gnu"
}

func (t *toolchainLinuxGlibcArm64) ToolchainLinkFlags() string {
\treturn t.toolchainLinuxArm64.ToolchainLinkFlags() + " " + "${config.LinuxGlibcToolchainLinkFlags}"
}

func linuxGlibcArm64ToolchainFactory(arch android.Arch) Toolchain {
\treturn toolchainLinuxGlibcArm64Singleton
}

var toolchainLinuxGlibcArm64Singleton Toolchain = &toolchainLinuxGlibcArm64{}
'''

if old not in s:
    print("    WARN: anchor init() arm_linux_host.go tak cocok")
    sys.exit(1)
    sys.exit(0)

s = s.replace(old, new, 1)
s += append
open(p, "w", encoding="utf-8").write(s)
print("    OK  : toolchainLinuxGlibcArm64 ditambahkan")
PY
else
  warn "$RUSTCFG tidak ada"
fi

step "0017" "prebuilts/rust/soong/rustprebuilts.go: prebuilt std host arm64"
RPRE="prebuilts/rust/soong/rustprebuilts.go"
if [ -f "$RPRE" ]; then
  python3 - "$RPRE" <<'PY' || warn "gagal patch rustprebuilts.go"
import sys
p = sys.argv[1]
s = open(p, encoding="utf-8").read()

MARK = "arm64-host: prebuilt std Rust untuk host aarch64"
if MARK in s:
    print("    SKIP: sudah dipatch"); sys.exit(0)

old1 = '''\tTarget  struct {
\t\tLinux_glibc_x86_64 targetProps
\t\tLinux_glibc_x86    targetProps
\t\tLinux_musl_x86_64  targetProps
\t\tLinux_musl_x86     targetProps
\t\tDarwin_x86_64      targetProps
\t}'''
new1 = '''\tTarget  struct {
\t\tLinux_glibc_x86_64 targetProps
\t\tLinux_glibc_x86    targetProps
\t\t// arm64-host: prebuilt std Rust untuk host aarch64.
\t\tLinux_glibc_arm64 targetProps
\t\tLinux_musl_x86_64 targetProps
\t\tLinux_musl_x86    targetProps
\t\tDarwin_x86_64     targetProps
\t}'''

old2 = '''\t\tif ctx.Config().BuildOS == android.Linux {
\t\t\tp.Target.Linux_glibc_x86_64.addPrebuiltToTarget(ctx, name, rustDir, "linux-x86", "x86_64-unknown-linux-gnu", rlib, solib)
\t\t\tp.Target.Linux_glibc_x86.addPrebuiltToTarget(ctx, name, rustDir, "linux-x86", "i686-unknown-linux-gnu", rlib, solib)
\t\t} else if ctx.Config().BuildOS == android.LinuxMusl {'''
new2 = '''\t\tif ctx.Config().BuildOS == android.Linux {
\t\t\tp.Target.Linux_glibc_x86_64.addPrebuiltToTarget(ctx, name, rustDir, "linux-x86", "x86_64-unknown-linux-gnu", rlib, solib)
\t\t\tp.Target.Linux_glibc_x86.addPrebuiltToTarget(ctx, name, rustDir, "linux-x86", "i686-unknown-linux-gnu", rlib, solib)
\t\t\t// arm64-host: prebuilt std Rust untuk host aarch64.
\t\t\tif ctx.Config().BuildArch == android.Arm64 {
\t\t\t\tp.Target.Linux_glibc_arm64.addPrebuiltToTarget(ctx, name, rustDir, "linux-arm64", "aarch64-unknown-linux-gnu", rlib, solib)
\t\t\t}
\t\t} else if ctx.Config().BuildOS == android.LinuxMusl {'''

old3 = '''\t\tif ctx.Config().BuildOS == android.Linux {
\t\t\tif ctx.Config().BuildArch == android.X86_64 {
\t\t\t\tarchTriple = "x86_64-unknown-linux-gnu"
\t\t\t} else {
\t\t\t\tarchTriple = "i686-unknown-linux-gnu"
\t\t\t}'''
new3 = '''\t\tif ctx.Config().BuildOS == android.Linux {
\t\t\tif ctx.Config().BuildArch == android.X86_64 {
\t\t\t\tarchTriple = "x86_64-unknown-linux-gnu"
\t\t\t} else if ctx.Config().BuildArch == android.Arm64 {
\t\t\t\t// arm64-host: prebuilt std Rust untuk host aarch64.
\t\t\t\tarchTriple = "aarch64-unknown-linux-gnu"
\t\t\t} else {
\t\t\t\tarchTriple = "i686-unknown-linux-gnu"
\t\t\t}'''

for idx, (o, n) in enumerate([(old1, new1), (old2, new2), (old3, new3)], start=1):
    if o not in s:
        print("    WARN: anchor #%d tak cocok, patch dibatalkan" % idx)
        sys.exit(1)
        sys.exit(0)

s = s.replace(old1, new1, 1)
s = s.replace(old2, new2, 1)
s = s.replace(old3, new3, 1)
open(p, "w", encoding="utf-8").write(s)
print("    OK  : props.Target + constructLibProps + archTriple arm64")
PY
else
  warn "$RPRE tidak ada"
fi

step "0018" "prebuilts/rust/soong/rustprebuilts.go: prebuilt std host musl aarch64"
RPRE="prebuilts/rust/soong/rustprebuilts.go"
if [ -f "$RPRE" ]; then
  python3 - "$RPRE" <<'PY'
import re, sys
p = sys.argv[1]
s = open(p, encoding="utf-8").read()

MARK = "arm64-host: prebuilt std Rust musl untuk host aarch64"
if MARK in s:
    print("    SKIP: sudah dipatch"); sys.exit(0)

m = re.search(r'\t\tDarwin_x86_64\s+targetProps', s)
if not m:
    print("    WARN: anchor #1 (struct props.Target) tak cocok"); sys.exit(1)
ins = (m.group(0)
       + '\n\t\t// arm64-host: prebuilt std Rust musl untuk host aarch64.\n'
       + '\t\tLinux_musl_arm64 targetProps')
s = s.replace(m.group(0), ins, 1)

old2 = 'p.Target.Linux_glibc_arm64.addPrebuiltToTarget(ctx, name, rustDir, "linux-arm64", "aarch64-unknown-linux-gnu", rlib, solib)'
if old2 not in s:
    print("    WARN: anchor #2 (constructLibProps glibc arm64) tak cocok"); sys.exit(1)
new2 = (old2
        + '\n\t\t\t// arm64-host: prebuilt std Rust musl untuk host aarch64.\n'
        + '\t\t\tp.Target.Linux_musl_arm64.addPrebuiltToTarget(ctx, name, rustDir, "linux-arm64", "aarch64-unknown-linux-musl", rlib, solib)')
s = s.replace(old2, new2, 1)

pat3 = re.compile(r'(archTriple = "x86_64-unknown-linux-musl"\n)(\t+)\} else \{\n(\t+)(archTriple = "i686-unknown-linux-musl"\n)(\t+)\}')
def r3(m):
    t = m.group(2)
    return (m.group(1) + t + '} else if ctx.Config().BuildArch == android.Arm64 {\n'
            + t + '\t// arm64-host: prebuilt std Rust musl untuk host aarch64.\n'
            + t + '\tarchTriple = "aarch64-unknown-linux-musl"\n'
            + t + '} else {\n' + m.group(3) + m.group(4) + m.group(5) + '}')
s2, n = pat3.subn(r3, s, count=1)
if n == 1:
    s = s2
else:
    print("    WARN: anchor #3 (filegroup LinuxMusl) tak cocok"); sys.exit(1)

open(p, "w", encoding="utf-8").write(s)
print("    OK  : props.Target + constructLibProps glibc+arm64 + archTriple musl arm64")
PY
else
  warn "$RPRE tidak ada"
fi
if grep -q "arm64-host: prebuilt std Rust musl untuk host aarch64" "$RPRE" 2>/dev/null; then
  ok "0018 rustprebuilts musl arm64"
else
  warn "verifikasi GAGAL: 0018 rustprebuilts musl arm64 ($RPRE belum dipatch)"
fi

step "0019" "prebuilts/rust/soong/rustprebuilts.go: HostSupported (varian host lengkap)"
RPRE="prebuilts/rust/soong/rustprebuilts.go"
if [ -f "$RPRE" ]; then
  python3 - "$RPRE" <<'PY' || warn "gagal patch rustprebuilts.go HostSupported"
import sys
p = sys.argv[1]
s = open(p, encoding="utf-8").read()

MARK = "arm64-host: prebuilts rust std host support semua host target (musl arm64)"
if MARK in s:
    print("    SKIP: sudah dipatch"); sys.exit(0)

old = 'module, _ := rust.NewPrebuiltLibrary(android.HostSupportedNoCross)'
new = ('// arm64-host: prebuilts rust std host support semua host target (musl arm64).\n'
       '\tmodule, _ := rust.NewPrebuiltLibrary(android.HostSupported)')
if old not in s:
    print("    WARN: anchor NewPrebuiltLibrary tak cocok"); sys.exit(1)
s = s.replace(old, new, 1)
open(p, "w", encoding="utf-8").write(s)
print("    OK  : rustHostPrebuiltSysrootLibraryFactory kini HostSupported")
PY
else
  warn "$RPRE tidak ada"
fi
if grep -q "prebuilts rust std host support semua host target" "$RPRE" 2>/dev/null; then
  ok "0019 rustprebuilts HostSupported"
else
  warn "verifikasi GAGAL: 0019 rustprebuilts HostSupported"
fi

step "0020" "prebuilts/rust/soong/rustprebuilts.go: module-level enabled=true (WAJIB - run #177/#178 mandek jika false)"
RPRE="prebuilts/rust/soong/rustprebuilts.go"
if [ -f "$RPRE" ]; then
  python3 - "$RPRE" <<'PY' || warn "gagal patch rustprebuilts.go enabled"
import sys
p = sys.argv[1]
s = open(p, encoding="utf-8").read()

MARK = "arm64-host: prebuilts rust std enabled di level modul"
if MARK in s:
    print("    SKIP: sudah dipatch"); sys.exit(0)

import re as RE
m = RE.search(r'(\t+)p := props\{\}\n(\t+)p\.Enabled = proptools\.BoolPtr\(false\)', s)
if not m:
    print("    WARN: anchor constructLibProps p.Enabled tak cocok"); sys.exit(1)
t1 = m.group(1)
new = (t1 + 'p := props{}\n'
       + t1 + '// arm64-host: module-level enabled=true WAJIB.\n'
       + t1 + '// Dengan false, analisis soong MANDEEK >25 menit (run #177/#178,\n'
       + t1 + '// exit 143, tanpa progres) - host module yang tak resolve varian sysroot.\n'
       + t1 + '// Dengan true, source libstd HOST dimatikan (PATCH 0021) supaya tidak\n'
       + t1 + '// bentrok di Make (pelajaran run #175).\n'
       + m.group(2) + 'p.Enabled = proptools.BoolPtr(true)')
s = s.replace(m.group(0), new, 1)
open(p, "w", encoding="utf-8").write(s)
print("    OK  : constructLibProps module-level enabled -> true")
PY
else
  warn "$RPRE tidak ada"
fi
if grep -q "arm64-host: module-level enabled=true WAJIB" "$RPRE" 2>/dev/null; then
  ok "0020 rustprebuilts module-level enabled=true"
else
  warn "verifikasi GAGAL: 0020 rustprebuilts module-level enabled"
fi

echo ""
echo "=============================================================="
echo " VERIFIKASI apply-arm64-host.sh"
echo "=============================================================="

require_marker() {
  if [ -f "$2" ] && grep -qF -- "$3" "$2" 2>/dev/null; then
    ok "$1"
  else
    warn "verifikasi GAGAL: $1 ($2 tidak memuat '$3')"
  fi
}

require_marker "0001 envsetup.sh linux-arm64"           build/make/envsetup.sh "linux-arm64"
require_marker "0002a HOST_ARCH arm64"                  build/make/core/envsetup.mk "HOST_ARCH := arm64"
require_marker "0002a2 endif penutup blok HOST_ARCH"    build/make/core/envsetup.mk "# arm64-host: endif penutup blok HOST_ARCH"
require_marker "0002b HOST_PREBUILT_ARCH arm64"         build/make/core/envsetup.mk "HOST_PREBUILT_ARCH := arm64"
require_marker "0002c clang HOST_arm64.mk"              build/make/core/clang/HOST_arm64.mk "HOST_LIBCRT_BUILTINS"
require_marker "0006a paths.go collapse LinuxMusl"      build/soong/android/paths.go "os == ctx.Config().BuildOS"
require_marker "0006b paths.go archName arm64"          build/soong/android/paths.go 'archName = "arm64"'
require_marker "0007 rule_builder.go BuildOS LinuxMusl" build/soong/android/rule_builder.go "c.rule.ctx.Config().BuildOS == LinuxMusl"
require_marker "0004 build-tools linux-arm64"           prebuilts/build-tools/Android.bp "linux-arm64/bin/"
require_marker "0002b clang/config.mk arm64"            build/make/core/clang/config.mk "LLVM_HOST_PREBUILT_ARCH := arm64"
require_marker "0005 jdk21 javap arm64"                 prebuilts/jdk/jdk21/Android.bp "linux_musl_arm64"
require_marker "0012 sepolicy getopt int"               system/sepolicy/tools/checkfc.c "int c;"
require_marker "0014 jar-wrapper -Xmx3g"                build/soong/scripts/jar-wrapper.sh "exec java -Xmx3g"
require_marker "0015 arch.go Linux + Arm64"             build/soong/android/arch.go "arm64-host: host aarch64 juga butuh varian linux_glibc_arm64"
require_marker "0016 rust glibc arm64 toolchain"        build/soong/rust/config/arm_linux_host.go "linuxGlibcArm64ToolchainFactory"
require_marker "0017 rustprebuilts arm64"               prebuilts/rust/soong/rustprebuilts.go "arm64-host: prebuilt std Rust untuk host aarch64"
require_marker "0018 rustprebuilts musl arm64"           prebuilts/rust/soong/rustprebuilts.go "arm64-host: prebuilt std Rust musl untuk host aarch64"

echo "--- info tambahan ---"
grep -q 'filepath.Join("linux-x86", GetRustPrebuiltVersion' build/soong/rust/toolchain_library.go 2>/dev/null \
  && echo "    OK  : hardcode linux-x86 dipertahankan (prefix crate arch-independent; PATCH 0003 sengaja di-skip)" \
  || echo "    CATATAN: hardcode linux-x86 rust tidak ada (PATCH 0003 terpasang?)"

echo "=============================================================="
if [ "$FAILED" -gt 0 ]; then
  echo " HASIL: GAGAL — $FAILED masalah (lihat WARN/verifikasi di atas)"
  echo "=============================================================="
  exit 1
fi
echo " HASIL: SEMUA PATCH WAJIB TERPASANG"
echo "=============================================================="
exit 0
