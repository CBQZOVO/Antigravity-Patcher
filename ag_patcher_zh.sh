#!/bin/bash
# ============================================================================
#  ag_patcher.sh — Antigravity 字节级 + JS 补丁（macOS / Linux）中文版
#  方法来自 confeden/Antigravity（https://github.com/confeden/Antigravity）
#
#  依赖：bash 和 perl。不安装、不下载任何其他东西。
#  macOS 与 Ubuntu 均自带 perl（perl-base 是系统必备包）。
#
#  1) 原生二进制（language_server*、agy）：
#     "ineligible" → "inexigible"（各 10 字节，文件大小不变）。
#     这样 Language Server 在 protobuf 里就再也匹配不到资格拒绝。
#
#  2) 独立 IDE（VS Code 分支）：
#     out/main.js —— 重写 confirmUserForService（移植自 patch_ide.rs）。
#     显示 “Sorry, this account is ineligible” 的正是这段 JS。
#     extensions/.../extension.js —— 移植自 patch_extension_js。
#     回滚使用旁边的 .ag_backup：函数体被重写，函数名不变。
#
#  不碰网络：不改 DNS、/etc/hosts，也不设代理。
#  不做 https_proxy → AG_LS_PROXY 转换：这里没有本地代理。
#
#  macOS：改完 Mach-O 后必须 ad-hoc codesign 重签名，否则内核会拒绝运行。
#  Linux：无签名机制，写文件即可。
#
#  用法：
#      bash ag_patcher.sh              菜单
#      bash ag_patcher.sh patch
#      bash ag_patcher.sh unpatch
#      bash ag_patcher.sh status
#      bash ag_patcher.sh watch
#      bash ag_patcher.sh install-watch
#      bash ag_patcher.sh uninstall-watch
#  命令后可跟路径以跳过自动扫描。AG_ROOT —— 额外的安装根目录。
#  AG_YES=1 跳过确认。AG_WATCH_ONCE=1 让监视进程只跑一轮。
#  Windows：请用 ag_patcher.ps1（那边没有 perl）。
# ============================================================================

export AG_FROM="ineligible"
export AG_TO="inexigible"

OS=$(uname -s)
IS_DARWIN=0; [ "$OS" = "Darwin" ] && IS_DARWIN=1

C_OK='\033[32m'; C_WARN='\033[33m'; C_ERR='\033[31m'; C_INFO='\033[36m'; C_DIM='\033[2m'; C_N='\033[0m'
say()  { printf "%b\n" "$1"; }
ok()   { say "${C_OK}[OK]${C_N} $1"; }
warn() { say "${C_WARN}[!]${C_N} $1"; }
err()  { say "${C_ERR}[X]${C_N} $1"; }
info() { say "${C_INFO}[i]${C_N} $1"; }
dim()  { say "${C_DIM}$1${C_N}"; }

# sudo 下 $HOME 指向 root。~user 在 macOS 和 Linux 的 bash 里都能用。
if [ "$(id -u)" -eq 0 ] && [ -n "${SUDO_USER:-}" ]; then
  USER_HOME=$(eval echo "~$SUDO_USER")
  case "$USER_HOME" in "~"*|"") USER_HOME="/home/$SUDO_USER"; [ "$IS_DARWIN" -eq 1 ] && USER_HOME="/Users/$SUDO_USER" ;; esac
else
  USER_HOME="$HOME"
fi

tilde() { case "$1" in "$USER_HOME"/*) echo "~${1#$USER_HOME}";; *) echo "$1";; esac; }

file_owner() {
  if [ "$IS_DARWIN" -eq 1 ]; then stat -f '%u' "$1" 2>/dev/null
  else stat -c '%u' "$1" 2>/dev/null
  fi
}

# ------------------------------------------------------------------ perl：二进制
# 用 index/substr 替换，不用正则。写入：旁边临时文件 + rename
# （同一卷上原子操作）。权限和属主从原文件复制。
PERL_BIN=$(cat <<'ENDPERL'
use strict; use warnings;
my ($mode, $path) = @ARGV;
open(my $fh, "<", $path) or die "open: $!\n";
binmode($fh);
my $data = do { local $/; <$fh> };
close($fh);
if ($mode eq "native") {
    my $m = substr($data, 0, 4);
    print((
        $m eq "\x7fELF"
        || $m eq "\xFE\xED\xFA\xCE" || $m eq "\xFE\xED\xFA\xCF"
        || $m eq "\xCE\xFA\xED\xFE" || $m eq "\xCF\xFA\xED\xFE"
        || $m eq "\xCA\xFE\xBA\xBE"
    ) ? "1\n" : "0\n");
    exit 0;
}
my ($from, $to) = ($ENV{AG_FROM}, $ENV{AG_TO});
die "signature length mismatch\n" if length($from) != length($to);
sub count_of {
    my ($hay, $needle) = @_;
    my ($n, $pos) = (0, 0);
    while ((my $i = index($hay, $needle, $pos)) >= 0) { $n++; $pos = $i + length($needle); }
    return $n;
}
if ($mode eq "count") {
    printf("%d %d\n", count_of($data, $from), count_of($data, $to));
    exit 0;
}
my ($src, $dst) = $mode eq "patch" ? ($from, $to) : ($to, $from);
my ($n, $pos) = (0, 0);
while ((my $i = index($data, $src, $pos)) >= 0) {
    substr($data, $i, length($src), $dst);
    $pos = $i + length($src);
    $n++;
}
if ($n == 0) { print "0\n"; exit 0; }
my @st = stat($path) or die "stat: $!\n";
my $tmp = "$path.agtmp.$$";
open(my $out, ">", $tmp) or die "tmp: $!\n";
binmode($out);
print {$out} $data or do { close($out); unlink($tmp); die "write: $!\n" };
close($out) or do { unlink($tmp); die "close: $!\n" };
chmod($st[2] & 07777, $tmp);
chown($st[4], $st[5], $tmp);
rename($tmp, $path) or do { unlink($tmp); die "rename: $!\n" };
print "$n\n";
ENDPERL
)

# ------------------------------------------------------------------ perl: JS IDE
# 移植自 patch_ide.rs。字符类里的 \$ 表示 JS 标识符的字面 $，
# 否则会被 perl 当成 $0 吃掉。
PERL_JS=$(cat <<'ENDPERL'
use strict; use warnings;
use File::Copy qw(copy);

my ($mode, $path) = @ARGV;
my $MARKER = "// UNLOCKED";
my $FENCE  = "/*[AG_EXT_PATCHED]*/";
my $BAK    = ".ag_backup";

my $IDE_RE = qr/async\s+([A-Za-z_\$0-9]+)\(([A-Za-z_\$0-9]+)\)\s*\{\s*if\(this\.([A-Za-z_\$0-9]+)\.send\(\{type:[A-Za-z_\$0-9]+\.isGcpTos\?"GCP_SIGN_IN":"SIGN_IN"\}\),this\.([A-Za-z_\$0-9]+)\.resetIsTierGCPTos\(\),this\.[A-Za-z_\$0-9]+\.isGoogleInternal\)\{try\{await this\.([A-Za-z_\$0-9]+)\.loadCodeAssist\([A-Za-z_\$0-9]+\);const\{settings:([A-Za-z_\$0-9]+),userTier:([A-Za-z_\$0-9]+)\}=await this\.refreshUserStatus\([A-Za-z_\$0-9]+\),([A-Za-z_\$0-9]+)=([A-Za-z_\$0-9]+)\([A-Za-z_\$0-9]+\);this\.([A-Za-z_\$0-9]+)\.pushUpdate\([A-Za-z_\$0-9]+\),this\.[A-Za-z_\$0-9]+\.send\(\{type:"AUTH_SUCCESS",tokenInfo:[A-Za-z_\$0-9]+\}\),this\.([A-Za-z_\$0-9]+)\.fire\(\{settings:[A-Za-z_\$0-9]+,userTier:[A-Za-z_\$0-9]+\}\)\}catch\(([A-Za-z_\$0-9]+)\)\{.*?(?:return\}|return;\s*\})/s;

my $EXT_RE = qr/const t=await ([A-Za-z_\$][A-Za-z_\$0-9.]*)\.UserStatus\.getUserStatus\(\);if\(!t\)return\[\];const n=\(0,([A-Za-z_\$][A-Za-z_\$0-9.]*)\)\(t,([A-Za-z_\$][A-Za-z_\$0-9.]*)\),\{email:([A-Za-z_\$][A-Za-z_\$0-9]*),name:([A-Za-z_\$][A-Za-z_\$0-9]*)\}=n;return""===([A-Za-z_\$0-9]*)\?\[\]:/;

sub is_ext { $path =~ m{/extension\.js$} }
sub has_marker {
    my ($c) = @_;
    $c =~ s/\s+\z//;
    return 0 unless length $c;
    my $last = (split /\n/, $c)[-1];
    $last =~ s/^\s+//;
    return $last =~ /^\Q$MARKER\E/;
}
sub stacked { $_[0] =~ /\/\*\[AG_PATCHED\]\*\/|\[AG_PROXY_HOOK\]/ }
sub slurp {
    open my $fh, "<:raw", $_[0] or return;
    local $/;
    my $d = <$fh>;
    close $fh;
    return $d;
}
sub write_atomic {
    my ($p, $text) = @_;
    my @st = stat($p) or die "stat: $!\n";
    my $tmp = "$p.agtmp.$$";
    open my $out, ">:raw", $tmp or die "tmp: $!\n";
    print {$out} $text or do { close $out; unlink $tmp; die "write: $!\n" };
    close $out or do { unlink $tmp; die "close: $!\n" };
    chmod($st[2] & 07777, $tmp);
    chown($st[4], $st[5], $tmp);
    rename($tmp, $p) or do { unlink $tmp; die "rename: $!\n" };
}
sub backup_once {
    my $bak = $path . $BAK;
    copy($path, $bak) unless -e $bak;
}

sub classify {
    my $c = slurp($path);
    return "unreadable" unless defined $c;
    if (is_ext()) {
        return "patched"   if index($c, $FENCE) >= 0;
        return "unpatched" if $c =~ $EXT_RE;
        return "missing";
    }
    return "stacked"   if stacked($c);
    return "patched"   if has_marker($c);
    return "unpatched" if $c =~ $IDE_RE;
    return "missing";
}

sub patch_ide {
    my ($c) = @_;
    return unless $c =~ $IDE_RE;
    my ($start, $end) = ($-[0], $+[0]);
    my ($fname, $var_t, $var_t_send, $var_y) = ($1, $2, $3, $4);
    my ($var_i, $var_func, $var_f, $var_h) = ($8, $9, $10, $11);
    my $payload = join "",
        "async $fname($var_t){\n",
        "    this.$var_t_send.send({type:$var_t.isGcpTos?\"GCP_SIGN_IN\":\"SIGN_IN\"});\n",
        "    this.$var_y.resetIsTierGCPTos();\n",
        "    try {\n",
        "        try { await this.$var_y.loadCodeAssist($var_t); } catch(_) {}\n",
        "        try { await this.$var_y.onboardUser(\"standard-tier\", $var_t); } catch(_) {\n",
        "            try { await this.$var_y.onboardUser(\"free-tier\", $var_t); } catch(__) {}\n",
        "        }\n",
        "        let __res = { settings: {}, userTier: { id: \"pro\", description: \"Pro\" } };\n",
        "        try { __res = await this.refreshUserStatus($var_t); } catch(_) {}\n",
        "        const $var_i = $var_func($var_t);\n",
        "        try { this.$var_f.pushUpdate($var_i); } catch(_) {}\n",
        "        this.$var_t_send.send({type:\"AUTH_SUCCESS\",tokenInfo:$var_t});\n",
        "        this.$var_h.fire({settings:__res.settings, userTier:__res.userTier});\n",
        "    } catch(e) {}\n",
        "    return;\n";
    my $new = substr($c, 0, $start) . $payload . substr($c, $end);
    $new .= "\n" unless $new =~ /\n\z/;
    return $new . $MARKER . "\n";
}

sub patch_ext {
    my ($c) = @_;
    return unless $c =~ $EXT_RE;
    my ($ns, $p2, $dz7, $email, $name) = ($1, $2, $3, $4, $5);
    my $repl =
        "const t=await $ns.UserStatus.getUserStatus();" .
        "let $email=\"\",$name=\"\";" .
        "try{if(t){const n=(0,$p2)(t,$dz7);" .
        "$email=n.email||\"\";$name=n.name||\"\";}}catch(_){}" .
        "if($email===\"\"){$email=\"antigravity-user\";$name=\"User\";}" .
        "return false?[]:";
    my $new = $c;
    $new =~ s/$EXT_RE/$repl/;
    return if $new eq $c;
    return "$FENCE\n$new\n$MARKER\n";
}

if ($mode eq "status") { print classify(), "\n"; exit 0; }

if ($mode eq "patch") {
    my $st = classify();
    if ($st eq "patched") { print "already\n"; exit 0; }
    print "$st\n" and exit 0 if $st eq "stacked" || $st eq "missing" || $st eq "unreadable";
    my $c = slurp($path);
    my $new = is_ext() ? patch_ext($c) : patch_ide($c);
    if (!defined $new) { print "missing\n"; exit 0; }
    backup_once();
    write_atomic($path, $new);
    print "ok\n";
    exit 0;
}

if ($mode eq "unpatch") {
    my $bak = $path . $BAK;
    if (-e $bak) {
        my $text = slurp($bak);
        die "backup unreadable\n" unless defined $text;
        write_atomic($path, $text);
        unlink $bak;
        print "ok\n";
        exit 0;
    }
    my $c = slurp($path);
    die "unreadable\n" unless defined $c;
    my $changed = 0;
    if (index($c, $FENCE) == 0) {
        $c = substr($c, length($FENCE));
        $c =~ s/^\n//;
        $changed = 1;
    }
    if (has_marker($c)) {
        $c =~ s/\s+\z//;
        my $nl = rindex($c, "\n");
        $c = $nl >= 0 ? substr($c, 0, $nl) . "\n" : "";
        $changed = 1;
    }
    if ($changed) { write_atomic($path, $c); print "marker-only\n"; }
    else { print "already\n"; }
    exit 0;
}

die "unknown mode\n";
ENDPERL
)

sig_counts() { perl -e "$PERL_BIN" count "$1" 2>/dev/null; }
sig_apply()  { perl -e "$PERL_BIN" "$2" "$1"; }
is_native()  { [ "$(perl -e "$PERL_BIN" native "$1" 2>/dev/null)" = "1" ]; }
js_tool()    { perl -e "$PERL_JS" "$1" "$2"; }
canon()      { perl -MCwd=realpath -e 'print realpath($ARGV[0]) // $ARGV[0]' "$1" 2>/dev/null || echo "$1"; }

# ------------------------------------------------------------------ 发现目标
CANDIDATES=""
JS_CANDIDATES=""
NL='
'

add_to() {
  local var="$1" f="$2" real list
  [ -f "$f" ] || return 0
  case "$f" in *.agtmp*|*.ag_backup|*.old.*|*.tmp.*|*AppImage*|*appimage*) return 0;; esac
  case "$f" in /snap/*|/var/lib/snapd/*) return 0;; esac
  real=$(canon "$f")
  eval "list=\$$var"
  case "$NL$list" in *"$NL$real$NL"*) return 0;; esac
  eval "$var=\"\$list\$real\$NL\""
}

add_candidate() {
  local f="$1"
  [ -f "$f" ] || return 0
  case "$f" in *.agtmp*|*.ag_backup|*.old.*|*.tmp.*|*AppImage*|*appimage*) return 0;; esac
  case "$f" in /snap/*|/var/lib/snapd/*) return 0;; esac
  is_native "$f" || return 0
  add_to CANDIDATES "$f"
}

add_js() { add_to JS_CANDIDATES "$1"; }

scan_dir() {
  local d="$1" f
  [ -d "$d" ] || return 0
  while IFS= read -r f; do
    [ -n "$f" ] && add_candidate "$f"
  done <<EOF
$(find "$d" -maxdepth "$2" -type f \( -name 'language_server*' -o -name 'agy' -o -name 'agy_*' \) ! -name '*.agtmp*' ! -name '*.ag_backup' ! -name '*.old.*' ! -name '*.tmp.*' 2>/dev/null)
EOF
}

# 安装根目录：二进制 + （如果在那里的）IDE JS。
add_install() {
  local root="$1"
  [ -d "$root" ] || return 0
  case "$root" in /snap/*|/var/lib/snapd/*) return 0;; esac
  scan_dir "$root" 8
  add_js "$root/Contents/Resources/app/out/main.js"
  add_js "$root/Contents/Resources/app/extensions/antigravity/dist/extension.js"
  add_js "$root/Contents/resources/app/out/main.js"
  add_js "$root/Contents/resources/app/extensions/antigravity/dist/extension.js"
  add_js "$root/resources/app/out/main.js"
  add_js "$root/resources/app/extensions/antigravity/dist/extension.js"
}

# 从 language_server 反推根目录。太宽的目录不取：否则 /opt 起点的 scan_dir
# 会遍历整个前缀。
root_from_ls() {
  local f="$1" root
  case "$f" in
    */resources/app/extensions/antigravity/bin/*) root="${f%%/resources/app/extensions/antigravity/bin/*}" ;;
    */Contents/Resources/app/extensions/antigravity/bin/*) root="${f%%/Contents/Resources/app/extensions/antigravity/bin/*}" ;;
    */Contents/resources/app/extensions/antigravity/bin/*) root="${f%%/Contents/resources/app/extensions/antigravity/bin/*}" ;;
    */Contents/Resources/bin/*) root="${f%%/Contents/Resources/bin/*}" ;;
    */Contents/resources/bin/*) root="${f%%/Contents/resources/bin/*}" ;;
    */resources/bin/*) root="${f%%/resources/bin/*}" ;;
    *) root=$(dirname "$f") ;;
  esac
  case "$root" in
    /|/usr|/usr/lib|/usr/share|/usr/local|/usr/local/share|/opt|/opt/homebrew|/home|"$USER_HOME"|"") return 1 ;;
  esac
  printf '%s\n' "$root"
}

# 深度与 Asalio 相同：目录最多 6 层，文件在第 7 层。
# 否则 IDE 的 resources/app/extensions/antigravity/bin/language_server 会被漏掉。
walk_base() {
  local base="$1" f root ext
  [ -d "$base" ] || return 0
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    case "$f" in
      *AppImage*|*appimage*|/snap/*|/var/lib/snapd/*) continue ;;
    esac
    case "$f" in
      */resources/app/out/main.js|*/Contents/Resources/app/out/main.js|*/Contents/resources/app/out/main.js)
        add_js "$f"
        ext="${f%/out/main.js}/extensions/antigravity/dist/extension.js"
        add_js "$ext"
        continue
        ;;
    esac
    case "$(basename "$f")" in
      language_server*) ;;
      *) continue ;;
    esac
    case "$f" in
      *[Aa]ntigravity*|*/resources/bin/*|*/Contents/Resources/bin/*|*/Contents/resources/bin/*) ;;
      *) continue ;;
    esac
    add_candidate "$f"
    root=$(root_from_ls "$f") || true
    [ -n "$root" ] && add_install "$root"
  done <<EOF
$(find "$base" -maxdepth 7 \
  \( -type d \( -name .git -o -name node_modules -o -name .cache -o -name proc -o -name sys \) \) -prune -o \
  -type f \( -name 'language_server*' -o -name 'main.js' \) -print 2>/dev/null)
EOF
}

collect_pkg_files() {
  local pkg out f root
  if command -v dpkg >/dev/null 2>&1; then
    for pkg in antigravity antigravity-ide; do
      out=$(dpkg -L "$pkg" 2>/dev/null || true)
      [ -n "$out" ] || continue
      while IFS= read -r f; do
        case "$f" in
          */language_server*)
            add_candidate "$f"
            root=$(root_from_ls "$f") || true
            [ -n "$root" ] && add_install "$root"
            ;;
        esac
      done <<EOF
$out
EOF
    done
  fi
  if command -v rpm >/dev/null 2>&1; then
    for pkg in antigravity antigravity-ide; do
      out=$(rpm -ql "$pkg" 2>/dev/null || true)
      [ -n "$out" ] || continue
      while IFS= read -r f; do
        case "$f" in
          */language_server*)
            add_candidate "$f"
            root=$(root_from_ls "$f") || true
            [ -n "$root" ] && add_install "$root"
            ;;
        esac
      done <<EOF
$out
EOF
    done
  fi
}

use_only_paths() {
  CANDIDATES=""
  JS_CANDIDATES=""
  local f
  for f in "$@"; do
    [ -n "$f" ] || continue
    case "$f" in
      *.js) add_js "$f" ;;
      *) add_candidate "$f" ;;
    esac
  done
}

collect_candidates() {
  CANDIDATES=""
  JS_CANDIDATES=""
  local b d p name

  [ -n "${AG_ROOT:-}" ] && add_install "$AG_ROOT"

  if [ "$IS_DARWIN" -eq 1 ]; then
    for b in /Applications/*[Aa]ntigravity*.app "$USER_HOME"/Applications/*[Aa]ntigravity*.app; do
      add_install "$b"
    done
  else
    for d in /opt /usr/share /usr/lib /usr/local /usr/local/share \
             "$USER_HOME/.local/share" "$USER_HOME/opt" "$USER_HOME/.antigravity" "$USER_HOME"; do
      [ -d "$d" ] || continue
      for name in Antigravity "Antigravity IDE" antigravity antigravity-ide; do
        add_install "$d/$name"
      done
      # 不硬编码目录名（同原版 scan_antigravity_dirs 的思路）。
      # 通配符看不到点目录（~/.antigravity）——它们已在上面单独列出。
      for b in "$d"/*[Aa]ntigravity*; do
        add_install "$b"
      done
    done
    add_install "$USER_HOME/.agy"
    add_install "$USER_HOME/.agy/bin"
    add_install "$USER_HOME/.local/share/agy/bin"
    add_install "$USER_HOME/.gemini/bin"
  fi

  if [ "$IS_DARWIN" -eq 1 ]; then
    add_install "$USER_HOME/.agy"
    add_install "$USER_HOME/.agy/bin"
    add_install "$USER_HOME/.local/share/agy/bin"
    add_install "$USER_HOME/.gemini/bin"
    add_install "$USER_HOME/opt"
    add_install "$USER_HOME/.antigravity"
  fi

  for p in "$USER_HOME/.gemini/bin/agy" "$USER_HOME/.agy/bin/agy" \
           "$USER_HOME/.local/bin/agy" "$USER_HOME/bin/agy" \
           /usr/local/bin/agy /usr/bin/agy /opt/homebrew/bin/agy \
           "$(command -v agy 2>/dev/null)"; do
    [ -n "$p" ] || continue
    case "$p" in /snap/*|/var/lib/snapd/*) continue;; esac
    add_candidate "$p"
  done

  while IFS= read -r d; do
    [ -n "$d" ] || continue
    case "$d" in /snap|/snap/*|/var/lib/snapd|/var/lib/snapd/*) continue;; esac
    add_candidate "$d/agy"
  done <<EOF
$(printf '%s\n' "$PATH" | tr ':' '\n')
EOF

  for d in "$USER_HOME"/.vscode/extensions "$USER_HOME"/.vscode-insiders/extensions \
           "$USER_HOME"/.vscode-oss/extensions \
           "$USER_HOME"/.vscode-server/extensions "$USER_HOME"/.cursor/extensions \
           "$USER_HOME"/.cursor-server/extensions "$USER_HOME"/.windsurf/extensions \
           "$USER_HOME"/.trae/extensions "$USER_HOME"/.vscodium/extensions \
           "$USER_HOME"/.positron/extensions "$USER_HOME"/.antigravity/extensions \
           "$USER_HOME"/.antigravity-ide/extensions; do
    [ -d "$d" ] || continue
    for b in "$d"/*[Aa]ntigravity*; do
      [ -d "$b" ] && scan_dir "$b" 4
    done
  done

  for d in /opt /usr/share /usr/lib /usr/local /usr/local/share \
           "$USER_HOME/.local/share" "$USER_HOME/opt" "$USER_HOME/.antigravity" "$USER_HOME"; do
    walk_base "$d"
  done
  collect_pkg_files
}

label_for() {
  local f="$1" bundle
  bundle=$(bundle_of "$f")
  if [ -n "$bundle" ]; then
    case "$f" in
      */out/main.js) echo "$(basename "$bundle" .app) → JS auth (out/main.js)" ;;
      */dist/extension.js) echo "$(basename "$bundle" .app) → JS extension.js" ;;
      *) echo "$(basename "$bundle" .app) → $(basename "$f")" ;;
    esac
    return
  fi
  case "$f" in
    */.gemini/bin/agy) echo "CLI agy（也是 VS Code 扩展的后端）" ;;
    */out/main.js)     echo "IDE → JS auth (out/main.js)" ;;
    */dist/extension.js) echo "IDE → JS extension.js" ;;
    */extensions/*)    echo "扩展 $(echo "${f#*/extensions/}" | cut -d/ -f1)" ;;
    *)                 echo "CLI $(basename "$f")" ;;
  esac
}

# ------------------------------------------------------------------ 状态
state_of() {
  local counts
  counts=$(sig_counts "$1")
  [ -z "$counts" ] && { echo "unreadable 0 0"; return; }
  local a b; a=${counts%% *}; b=${counts##* }
  if   [ "$b" -gt 0 ] && [ "$a" -eq 0 ]; then echo "patched $a $b"
  elif [ "$a" -gt 0 ]; then echo "unpatched $a $b"
  else echo "missing 0 0"
  fi
}

kind_of() {
  case "$1" in
    *.js) js_tool status "$1" ;;
    *) state_of "$1" | awk '{print $1}' ;;
  esac
}

all_targets() { printf "%s" "$CANDIDATES$JS_CANDIDATES"; }

writable() { [ -w "$1" ] && [ -w "$(dirname "$1")" ]; }

perm_hint() {
  local f="$1" owner
  owner=$(file_owner "$f")
  if [ -n "$owner" ] && [ "$owner" != "$(id -u)" ] && [ "$(id -u)" -ne 0 ]; then
    echo "文件属于其他用户——请用 sudo 重新运行"
  elif [ "$IS_DARWIN" -eq 1 ] && [ -n "$(bundle_of "$f")" ]; then
    echo "macOS 保护该应用：系统设置 → 隐私与安全性 → 应用管理 → 允许你的终端，重启终端后重试"
  else
    echo "没有写权限——请用 sudo 重新运行"
  fi
}

# ------------------------------------------------------------------ 签名（仅 macOS）
resign_file() {
  [ "$IS_DARWIN" -eq 1 ] || return 0
  xattr -d com.apple.quarantine "$1" 2>/dev/null
  if ! codesign --force --sign - "$1" >/dev/null 2>&1; then
    err "codesign 签名失败：$(tilde "$1") —— 二进制将无法运行"
    warn "    请先安装 Command Line Tools（xcode-select --install）后重试"
    return 1
  fi
}

resign_bundle() {
  local bundle="$1"
  [ "$IS_DARWIN" -eq 1 ] || return 0
  [ -n "$bundle" ] || return 0
  info "正在重签名应用包（约需一分钟）：$(tilde "$bundle")"
  xattr -dr com.apple.quarantine "$bundle" 2>/dev/null
  if codesign --force --deep --sign - "$bundle" >/dev/null 2>&1; then
    ok "应用包已 ad-hoc 重签名——可从 Finder/Launchpad 正常启动"
  else
    err "重签名失败：$(tilde "$bundle")"
    warn "系统设置 → 隐私与安全性 → 应用管理 → 允许你的终端后，"
    warn "重新运行补丁。"
  fi
}

bundle_of() {
  case "$1" in
    *.app/*) echo "${1%%.app/*}.app" ;;
    *) echo "" ;;
  esac
}

# ------------------------------------------------------------------ 进程
# 自身进程及其父进程：否则 antigravity-patcher 仓库路径
# 和参数 …/agy 会被误判成应用本身。
in_self_tree() {
  local pid="$1" cur=$$
  while [ -n "$cur" ] && [ "$cur" -gt 1 ] 2>/dev/null; do
    [ "$pid" = "$cur" ] && return 0
    cur=$(ps -o ppid= -p "$cur" 2>/dev/null | tr -d ' ' || true)
    [ -z "$cur" ] && return 1
  done
  return 1
}

# 0 —— 文件正被运行中的进程占用（ETXTBSY）。
file_busy() {
  perl -e 'open(my $fh, "+<", $ARGV[0]) and do { close $fh; exit 1 }; exit($!{ETXTBSY} ? 0 : 1);' -- "$1"
}

is_editor_exe() {
  case "$(basename "$1")" in
    Code|Code.exe|Cursor|Cursor.exe|code|cursor|codium|vscodium) return 0 ;;
  esac
  return 1
}

# 文件上溯 6 层内的 Desktop 或 IDE。CLI agy 不会走到这里。
owner_app() {
  local f="$1" dir i cand
  if [ "$IS_DARWIN" -eq 1 ]; then
    bundle_of "$f"
    return 0
  fi
  dir=$(dirname "$(canon "$f")")
  i=0
  while [ "$i" -lt 6 ] && [ -n "$dir" ] && [ "$dir" != "/" ]; do
    for cand in "$dir/antigravity" "$dir/Antigravity" "$dir/Antigravity IDE" "$dir/antigravity-ide"; do
      if [ -f "$cand" ] && [ -x "$cand" ]; then
        echo "$cand"
        return 0
      fi
    done
    dir=$(dirname "$dir")
    i=$((i + 1))
  done
}

darwin_main_exe() {
  local mac cand
  mac="$1/Contents/MacOS"
  [ -d "$mac" ] || return 0
  for cand in "$mac"/*; do
    [ -f "$cand" ] && [ -x "$cand" ] || continue
    case "$cand" in *Helper*|*helper*) continue ;; esac
    echo "$cand"
    return 0
  done
}

pids_for_exe() {
  local want="$1" pid exe
  want=$(canon "$want")
  [ -n "$want" ] || return 0
  if [ "$IS_DARWIN" -eq 1 ]; then
    command -v lsof >/dev/null 2>&1 || return 0
    lsof -t -- "$want" 2>/dev/null | while IFS= read -r pid; do
      [ -n "$pid" ] || continue
      exe=$(lsof -a -p "$pid" -d txt -Fn 2>/dev/null | sed -n 's/^n//p' | head -n 1)
      [ -n "$exe" ] || continue
      [ "$(canon "$exe")" = "$want" ] && echo "$pid"
    done
    return 0
  fi
  for pid in /proc/[0-9]*; do
    pid=${pid#/proc/}
    exe=$(readlink "/proc/$pid/exe" 2>/dev/null) || continue
    exe=${exe%" (deleted)"}
    [ "$(canon "$exe")" = "$want" ] && echo "$pid"
  done
}

kill_exe() {
  local exe="$1" pid
  [ -n "$exe" ] || return 0
  is_editor_exe "$exe" && return 0
  while IFS= read -r pid; do
    [ -n "$pid" ] || continue
    in_self_tree "$pid" && continue
    kill "$pid" 2>/dev/null || true
  done <<EOF
$(pids_for_exe "$exe")
EOF
}

# 只关闭占用目标文件（或其 desktop/IDE）的进程。
# RELAUNCH —— 补丁成功后要重新打开的东西。
stop_busy_files() {
  local f owner exe
  RELAUNCH=""
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    file_busy "$f" || continue
    kill_exe "$f"
    owner=$(owner_app "$f")
    [ -n "$owner" ] || continue
    if [ "$IS_DARWIN" -eq 1 ]; then
      exe=$(darwin_main_exe "$owner")
      kill_exe "$exe"
    else
      kill_exe "$owner"
    fi
    case "$NL$RELAUNCH" in
      *"$NL$owner$NL"*) ;;
      *) RELAUNCH="$RELAUNCH$owner$NL" ;;
    esac
  done <<EOF
$1
EOF
}

relaunch_apps() {
  local app
  while IFS= read -r app; do
    [ -n "$app" ] || continue
    if [ "$IS_DARWIN" -eq 1 ]; then
      open "$app" >/dev/null 2>&1 || true
    else
      nohup "$app" >/dev/null 2>&1 &
    fi
  done <<EOF
$RELAUNCH
EOF
}

confirm() {
  [ -n "${AG_YES:-}" ] && return 0
  local a
  printf "%b" "${C_WARN}[?]${C_N} $1 [y/N]: "
  read -r a </dev/tty 2>/dev/null || return 1
  case "$a" in y|Y|д|Д|是) return 0;; *) return 1;; esac
}

# ------------------------------------------------------------------ 报告
report_one() {
  local f="$1" kind extra=""
  kind=$(kind_of "$f")
  case "$kind" in
    patched)   ok   "已打补丁 — $(label_for "$f")" ;;
    unpatched) warn "未打补丁 — $(label_for "$f")" ;;
    missing)   warn "未找到特征（新版本编译变了？）— $(label_for "$f")" ;;
    stacked)   err  "存在旧的第三方 JS 补丁——请重装 IDE 后重试：$(label_for "$f")" ;;
    *)         err  "无法读取 — $(label_for "$f")" ;;
  esac
  case "$f" in
    *.js) extra="JS $(basename "$f")" ;;
    *)
      local st a b
      st=$(state_of "$f"); a=$(echo "$st" | awk '{print $2}'); b=$(echo "$st" | awk '{print $3}')
      extra="ineligible: $a, inexigible: $b"
      ;;
  esac
  dim "      $(tilde "$f")   [$extra]"
  writable "$f" || say "      ${C_WARN}无法写入：$(perm_hint "$f")${C_N}"
}

report() {
  local f n=0
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    n=$((n+1))
    report_one "$f"
  done <<EOF
$(all_targets)
EOF
  [ "$n" -eq 0 ] && return 1
  return 0
}

# ------------------------------------------------------------------ 动作
note_bundle() {
  local b="$1"
  [ -n "$b" ] || return 0
  case "$NL$bundles" in *"$NL$b$NL"*) ;; *) bundles="$bundles$b$NL" ;; esac
}

apply_one() {
  local mode="$1" f="$2" kind out expect
  kind=$(kind_of "$f")
  if [ "$kind" != "$want" ]; then
    case "$kind" in
      patched)   [ "$mode" = "patch" ] && [ -z "${AG_WATCH:-}" ] && dim "  跳过（已是补丁状态）：$(tilde "$f")" ;;
      unpatched) [ "$mode" = "unpatch" ] && [ -z "${AG_WATCH:-}" ] && dim "  跳过（已是原始状态）：$(tilde "$f")" ;;
      missing)   warn "未找到特征，不做修改：$(tilde "$f")" ;;
      stacked)   err  "$(tilde "$f") 中有旧 JS 补丁——请重装 IDE" ; failed=$((failed+1)) ;;
      *)         err  "无法读取：$(tilde "$f")" ; failed=$((failed+1)) ;;
    esac
    return 0
  fi

  case "$f" in
    *.js)
      out=$(js_tool "$mode" "$f" 2>&1)
      if [ "$out" != "ok" ] && [ "$out" != "marker-only" ]; then
        err "JS $(tilde "$f"): $out"
        failed=$((failed+1))
        return 0
      fi
      ;;
    *)
      out=$(sig_apply "$f" "$mode" 2>&1)
      if [ $? -ne 0 ] || ! echo "$out" | grep -qE '^[0-9]+$'; then
        err "写入失败：$(tilde "$f"): $out"
        failed=$((failed+1))
        return 0
      fi
      resign_file "$f" || failed=$((failed+1))
      ;;
  esac

  [ "$mode" = "patch" ] && expect="patched" || expect="unpatched"
  kind=$(kind_of "$f")
  if [ "$kind" = "$expect" ]; then
    ok "$([ "$mode" = "patch" ] && echo "已打补丁" || echo "已还原"): $(tilde "$f")"
    changed=$((changed+1))
    note_bundle "$(bundle_of "$f")"
  else
    err "写入后校验不一致：$(tilde "$f")（状态：$kind）"
    failed=$((failed+1))
  fi
}

run_patch() {
  local mode="$1" f kind want out changed=0 failed=0 bundles="" b
  case "$mode" in
    patch)   want="unpatched" ;;
    unpatch) want="patched"   ;;
  esac

  local blocked=0
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    kind=$(kind_of "$f"); [ "$kind" = "$want" ] || continue
    if ! writable "$f"; then
      blocked=$((blocked+1))
      err "$(tilde "$f")"
      warn "    $(perm_hint "$f")"
    fi
  done <<EOF
$(all_targets)
EOF
  if [ "$blocked" -gt 0 ]; then
    err "有 $blocked 个目标无写权限，未做任何修改。"
    return 1
  fi

  RELAUNCH=""
  local busy=""
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    kind=$(kind_of "$f"); [ "$kind" = "$want" ] || continue
    if file_busy "$f"; then
      busy="$busy$f$NL"
    fi
  done <<EOF
$(all_targets)
EOF
  if [ -n "$busy" ]; then
    warn "部分文件正被运行中的 Antigravity 占用。"
    while IFS= read -r f; do [ -n "$f" ] && dim "      $(tilde "$f")"; done <<EOF
$busy
EOF
    warn "修改运行中应用的文件可能导致其崩溃。"
    confirm "关闭 Antigravity 并继续？" || { info "已取消。"; return 1; }
    stop_busy_files "$busy"
    sleep 2
  fi

  while IFS= read -r f; do
    [ -n "$f" ] && apply_one "$mode" "$f"
  done <<EOF
$(all_targets)
EOF

  while IFS= read -r b; do
    [ -n "$b" ] && resign_bundle "$b"
  done <<EOF
$bundles
EOF

  if [ "$mode" = "patch" ] && [ "$failed" -eq 0 ] && [ -n "$RELAUNCH" ]; then
    local still=0
    while IFS= read -r f; do
      [ -n "$f" ] || continue
      file_busy "$f" && still=1
    done <<EOF
$busy
EOF
    [ "$still" -eq 0 ] && relaunch_apps
  fi

  if [ "$changed" -eq 0 ] && [ "$failed" -eq 0 ]; then
    [ -n "${AG_WATCH:-}" ] || info "无需修改——一切已在目标状态。"
  else
    info "已修改文件：$changed 个，出错：$failed 个"
    if [ "$mode" = "patch" ] && [ "$changed" -gt 0 ]; then
      info "请启动 Antigravity 并登录 Google 账号。"
      info "应用更新后补丁会被覆盖——重新运行本脚本即可。"
    elif [ "$changed" -gt 0 ]; then
      info "JS 已从 .ag_backup 还原；二进制为字节级反向替换。"
      [ "$IS_DARWIN" -eq 1 ] && info "macOS 上签名仍为 ad-hoc——不影响运行。"
    fi
  fi
  [ "$failed" -eq 0 ]
}

# ------------------------------------------------------------------ 监视
file_sig() {
  local f mt
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    if [ "$IS_DARWIN" -eq 1 ]; then mt=$(stat -f '%m %z' "$f" 2>/dev/null)
    else mt=$(stat -c '%Y %s' "$f" 2>/dev/null)
    fi
    printf '%s %s\n' "$f" "$mt"
  done <<EOF
$(all_targets)
EOF
}

needs_patch() {
  local f k
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    k=$(kind_of "$f")
    [ "$k" = "unpatched" ] && return 0
  done <<EOF
$(all_targets)
EOF
  return 1
}

installer_busy() {
  local f d
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    d=$(dirname "$f")
    [ -f "$d/.agy-install.lock" ] && return 0
    compgen -G "$d/agy.tmp.*" >/dev/null && return 0
  done <<EOF
$(all_targets)
EOF
  return 1
}

load_targets() {
  if [ "$#" -gt 0 ]; then
    use_only_paths "$@"
  else
    collect_candidates
  fi
}

watch_main() {
  local state sig prev="" skip=0 clean="" once="${AG_WATCH_ONCE:-}"
  state="${XDG_STATE_HOME:-$HOME/.local/state}/ag-patcher"
  mkdir -p "$state"
  if [ "$once" != 1 ]; then
    local pidfile="$state/watch.pid" old
    if [ -f "$pidfile" ]; then
      old=$(cat "$pidfile" 2>/dev/null || true)
      if [ -n "$old" ] && kill -0 "$old" 2>/dev/null; then
        info "监视进程已在运行（pid $old）"
        return 0
      fi
    fi
    echo $$ > "$pidfile"
    trap 'rm -f "$pidfile"' EXIT
  fi
  export AG_YES=1
  export AG_WATCH=1
  local last_scan=0 now
  while true; do
    now=$(date +%s)
    # 全量扫描 $HOME 开销大。两次扫描之间只看已知文件的 mtime。
    if [ "$once" = 1 ] || [ $((now - last_scan)) -ge 30 ]; then
      load_targets "$@"
      last_scan=$now
    fi
    if installer_busy; then
      [ "$once" = 1 ] && return 0
      sleep 5
      continue
    fi
    if [ "$once" = 1 ]; then
      run_patch patch
      return $?
    fi
    sig=$(file_sig)
    if [ -n "$prev" ] && [ "$sig" != "$prev" ]; then
      prev=$sig
      skip=1
      clean=""
    elif [ "$skip" -gt 0 ]; then
      prev=$sig
      skip=0
    else
      prev=$sig
      if [ "$sig" != "$clean" ]; then
        if needs_patch; then
          run_patch patch && clean=$sig
        else
          clean=$sig
        fi
      fi
    fi
    sleep 5
  done
}

install_watch() {
  local self unit plist domain
  self=$(canon "$0")
  if [ "$IS_DARWIN" -eq 1 ]; then
    plist="$HOME/Library/LaunchAgents/com.ag.patcher.plist"
    mkdir -p "$(dirname "$plist")"
    cat > "$plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>com.ag.patcher</string>
  <key>ProgramArguments</key>
  <array>
    <string>/bin/bash</string>
    <string>$self</string>
    <string>watch</string>
  </array>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key>
  <dict>
    <key>SuccessfulExit</key><false/>
  </dict>
  <key>EnvironmentVariables</key>
  <dict>
    <key>AG_YES</key><string>1</string>
  </dict>
</dict>
</plist>
EOF
    domain="gui/$(id -u)"
    launchctl bootout "$domain" "$plist" >/dev/null 2>&1 || true
    if launchctl bootstrap "$domain" "$plist" >/dev/null 2>&1 || launchctl load -w "$plist" >/dev/null 2>&1; then
      ok "已启用开机自启：$(tilde "$plist")"
    else
      err "launchctl 加载代理失败"
      return 1
    fi
  else
    unit="$HOME/.config/systemd/user/ag-patcher.service"
    mkdir -p "$(dirname "$unit")"
    cat > "$unit" <<EOF
[Unit]
Description=Antigravity patcher watch
After=default.target

[Service]
Type=simple
ExecStart=/bin/bash "$self" watch
Restart=on-failure
Environment=AG_YES=1

[Install]
WantedBy=default.target
EOF
    systemctl --user daemon-reload
    if systemctl --user enable --now ag-patcher.service; then
      ok "已启用开机自启：$(tilde "$unit")"
    else
      err "systemctl --user 未能启用 ag-patcher.service"
      return 1
    fi
  fi
  info "文件被占用时，监视进程会先关闭占用它的进程以及 Antigravity/IDE 窗口，打完补丁后再重新打开。"
}

uninstall_watch() {
  local unit plist domain
  if [ "$IS_DARWIN" -eq 1 ]; then
    plist="$HOME/Library/LaunchAgents/com.ag.patcher.plist"
    domain="gui/$(id -u)"
    launchctl bootout "$domain" "$plist" >/dev/null 2>&1 || launchctl unload "$plist" >/dev/null 2>&1 || true
    rm -f "$plist"
  else
    unit="$HOME/.config/systemd/user/ag-patcher.service"
    systemctl --user disable --now ag-patcher.service >/dev/null 2>&1 || true
    rm -f "$unit"
    systemctl --user daemon-reload >/dev/null 2>&1 || true
  fi
  ok "已关闭开机自启。"
}

run_paths_or_scan() {
  if [ "$#" -gt 0 ]; then
    use_only_paths "$@"
    if [ -z "$CANDIDATES" ] && [ -z "$JS_CANDIDATES" ]; then
      err "未找到任何目标。"
      return 1
    fi
    say ""
    report
    say ""
    return 0
  fi
  scan
}

# ------------------------------------------------------------------ 主流程
case "$OS" in Darwin|Linux) ;; *) err "仅支持 macOS 和 Linux。Windows 请用：powershell -File ag_patcher.ps1"; exit 1 ;; esac
command -v perl >/dev/null || { err "需要 perl（macOS 和 Ubuntu 自带）。"; exit 1; }

scan() {
  info "正在扫描 Antigravity 安装…"
  collect_candidates
  if [ -z "$CANDIDATES" ] && [ -z "$JS_CANDIDATES" ]; then
    err "未找到任何目标。"
    if [ "$IS_DARWIN" -eq 1 ]; then
      warn "预期位置：/Applications/Antigravity.app、/Applications/Antigravity IDE.app、"
    else
      warn "预期位置：/opt/Antigravity、/usr/share/antigravity、~/.local/share/Antigravity、"
    fi
    warn "CLI：~/.local/bin/agy 或 ~/.gemini/bin/agy（VS Code 扩展也会装到这里）。"
    return 1
  fi
  say ""
  report
  say ""
  return 0
}

case "${1:-}" in
  patch)
    shift
    run_paths_or_scan "$@" || exit 1
    run_patch patch
    exit $? ;;
  unpatch)
    shift
    run_paths_or_scan "$@" || exit 1
    run_patch unpatch
    exit $? ;;
  status)
    shift
    run_paths_or_scan "$@"
    exit $? ;;
  watch)
    shift
    watch_main "$@"
    exit $? ;;
  install-watch) install_watch; exit $? ;;
  uninstall-watch) uninstall_watch; exit $? ;;
  -h|--help|help)
    say "用法：bash $0 [patch|unpatch|status|watch|install-watch|uninstall-watch] [文件...]"
    say "  patch            —— 给所有找到的二进制和 IDE JS 打补丁"
    say "  unpatch          —— 还原补丁"
    say "  status           —— 仅查看状态"
    say "  watch            —— 在当前终端运行监视循环"
    say "  install-watch    —— 开机自启监视（systemd --user 或 LaunchAgent）"
    say "  uninstall-watch  —— 移除开机自启"
    say "  无参数           —— 交互菜单"
    say "命令后可跟路径以跳过扫描。AG_ROOT —— 额外目录。"
    say "需要 bash 和 perl。支持 macOS 和 Linux。Windows：ag_patcher.ps1。"
    exit 0 ;;
  "") ;;
  *) err "未知命令：$1（见 --help）"; exit 1 ;;
esac

scan
while true; do
  say "===== Antigravity 补丁工具（macOS / Linux）====="
  say " 1) 给所有找到的目标打补丁"
  say " 2) 还原补丁"
  say " 3) 在当前终端运行监视"
  say " 4) 启用开机自启"
  say " 5) 关闭开机自启"
  say " 0) 退出"
  printf "请选择："
  read -r choice || { say ""; exit 0; }
  say ""
  case "$choice" in
    1) run_patch patch;   say ""; scan ;;
    2) run_patch unpatch; say ""; scan ;;
    3) watch_main; exit $? ;;
    4) install_watch; say "" ;;
    5) uninstall_watch; say "" ;;
    0) exit 0 ;;
    *) warn "未知菜单项"; say "" ;;
  esac
done
