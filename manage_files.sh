#!/usr/bin/env bash
#
# manage_files.sh - keep a directory organized in the background.
#
# Files are sorted into category folders such as images/, videos/, documents/,
# and archives/. Classification uses the extension first, then the file's
# actual MIME type when the extension is missing or unknown. Temporary and
# incomplete files are left alone, and nothing is overwritten.
#
# Commands:
#   start    Start a background watcher (default)
#   run      Watch in the foreground (for systemd/nohup)
#   stop     Stop the background watcher
#   restart  Restart the background watcher
#   status   Show watcher status
#   once     Organize once and exit
#
# Run with --help for all options.

# Associative arrays and ${var,,} need Bash 4+.
if (( BASH_VERSINFO[0] < 4 )); then
  printf 'error: bash 4.0 or newer is required\n' >&2
  exit 1
fi

set -uo pipefail

# ---------------------------------------------------------------------------
# Classification rules
# ---------------------------------------------------------------------------

# Category labels (also used as folder names)
categories=(images videos audio documents archives code executables fonts certificates ebooks design datafiles)
others_dir="others"

# Extensions for each category (index aligned with the categories array).
# Keep each extension in only one category; the first match wins.
extensions=(
  "jpg jpeg jpe jfif png gif bmp tiff tif webp heic heif avif jxl svg ico raw cr2 cr3 nef arw dng orf rw2 raf"  # images
  "mp4 mkv avi mov wmv flv webm mpeg mpg m2ts mts 3gp 3g2 ogv vob asf rm rmvb divx f4v m4v srt vtt ass ssa"     # videos
  "mp3 wav flac aac ogg m4a m4b wma alac opus aiff aif mid midi amr ape mka caf wv cue m3u m3u8 pls"            # audio
  "pdf doc docx ppt pptx xls xlsx odt ods odp rtf txt md rst adoc org tex xps oxps pages numbers nfo"           # documents
  "tar.gz tar.bz2 tar.xz tar.zst tar.lz tar.lzma tar.z tar.br tar.lz4 tar.sz zip rar 7z tar gz bz2 xz zst tgz tbz2 txz lz lzma lz4 br z iso img cab lzh lha arj cpio jar war ear"  # archives
  "py js ts jsx tsx vue svelte java c cpp h hpp cs rb php html htm css scss sass less bat pl pm swift kt kts go rs sh bash zsh fish ipynb lua r scala sc clj cljs cljc edn hs lhs ex exs erl hrl fs fsx fsi m mm asm s vim ps1 psm1 psd1 gradle groovy tf tfvars hcl nix zig nim jl sol v sv vhd vhdl tcl awk sed dart sln csproj vbproj fsproj vcxproj xcodeproj pbxproj"  # code
  "exe msi apk app deb rpm bin run dmg appimage flatpak snap elf"                                               # executables
  "ttf otf woff woff2 eot fon fnt pfb pfm ttc"                                                                 # fonts
  "pem key cer crt pfx p12 der csr p7b p7s asc gpg pgp kdbx jks keystore pub ppk"                                  # certificates
  "epub mobi azw azw3 fb2 djvu lit chm cbz cbr cb7 cbt"                                                        # ebooks
  "psd ai eps xd sketch dwg dxf indd fig xcf cdr afdesign afphoto blend obj stl fbx gltf glb 3ds ma mb ps"      # design
  "json xml yaml yml toml ini conf cfg properties plist csv tsv log sql sqlite sqlite3 db mdb accdb parquet avro ndjson jsonl h5 hdf5 npy npz pickle pkl feather arrow lock desktop service timer socket target mount ics vcf torrent"  # datafiles
)

# Checked before the simple extension, so "backup.tar.gz" is archives (not gz).
compound_extensions=(tar.gz tar.bz2 tar.xz tar.zst tar.lz tar.lzma tar.z tar.br tar.lz4 tar.sz)

# Filenames that carry their own meaning even when the extension says otherwise.
declare -A special_names=(
  [dockerfile]=code
  [containerfile]=code
  [makefile]=code
  [gnumakefile]=code
  [cmakelists.txt]=code
  [meson.build]=code
  [rakefile]=code
  [gemfile]=code
  [vagrantfile]=code
  [jenkinsfile]=code
  [procfile]=code
  [brewfile]=code
  [justfile]=code
  [pkgbuild]=code
  [apkbuild]=code
  [kconfig]=code
  [license]=documents
  [licence]=documents
  [copying]=documents
  [notice]=documents
  [readme]=documents
  [changelog]=documents
  [changes]=documents
  [authors]=documents
  [contributors]=documents
  [install]=documents
  [news]=documents
  [requirements.txt]=datafiles
  [go.mod]=datafiles
  [go.sum]=datafiles
  [pipfile]=datafiles
  [pipfile.lock]=datafiles
  [gemfile.lock]=datafiles
  [composer.lock]=datafiles
  [.gitignore]=datafiles
  [.dockerignore]=datafiles
  [.gitattributes]=datafiles
  [.editorconfig]=datafiles
  [.env]=datafiles
  [.npmrc]=datafiles
  [.bashrc]=datafiles
  [.zshrc]=datafiles
  [.profile]=datafiles
)

# Files that are still being written or downloaded are left in place.
temporary_patterns=(
  '*.part' '*.partial' '*.crdownload' '*.download' '*.aria2' '*.opdownload'
  '*.filepart' '*.!ut' '*.!qb' '*.bc!' '*.td' '*.tmp' '*.temp'
  '*.swp' '*.swo' '*.swx' '*.kate-swp' '*~' '#*#' '.~lock.*'
  '~$*' '*.___jb_tmp___' '*.___jb_old___'
)

# ---------------------------------------------------------------------------
# Defaults (overridden by command-line options)
# ---------------------------------------------------------------------------

mode=""
target=""
target_set=0
interval=2
settle=2
settle_set=0
dry_run=0
recursive=0
hidden=0
content_first=0
force=0
quiet=0
verbose=0
use_timestamps=0

moved=0
skipped=0
errors=0
sleep_pid=""

state_dir=""
key=""
pid_file=""
log_file=""
dir_file=""
lock_file=""
script_path=""

# Extension -> category lookup, built once at startup.
declare -A ext_to_category=()
for i in "${!categories[@]}"; do
  category=${categories[$i]}
  for ext in ${extensions[$i]}; do
    ext=${ext,,}
    # First mapping wins, matching the order above.
    if [[ -z ${ext_to_category[$ext]+x} ]]; then
      ext_to_category[$ext]=$category
    fi
  done
done

# Per-category counts for the end-of-run summary.
declare -A count_by_category=()
for category in "${categories[@]}" "$others_dir"; do
  count_by_category[$category]=0
done

# Used by is_stable() so watch mode only needs one date call per scan.
NOW=0

# ---------------------------------------------------------------------------
# Output helpers
# ---------------------------------------------------------------------------

usage() {
  cat <<EOF
Usage: ${0##*/} [COMMAND] [options] [DIRECTORY]

Keep DIRECTORY (default: current directory) organized by moving files into
category folders such as images/, videos/, documents/, and archives/.

Commands:
  start        Start a background watcher (default)
  run          Watch in the foreground (for systemd/nohup)
  stop         Stop the background watcher for DIRECTORY
  restart      Restart the background watcher
  status       Show status (all watchers when DIRECTORY is omitted)
  once         Organize once and exit

Options:
  -d, --dir DIR        Directory to organize (default: current directory)
  -i, --interval SEC   Seconds between scans (default: 2)
  -s, --settle SEC     Wait SEC seconds after a file changes before moving it
                       (default: 2 for watchers, 0 for once)
  -r, --recursive      Also organize files in subdirectories
  -a, --all            Include hidden files (dotfiles)
  -c, --content        Detect type from contents even when the extension is known
  -f, --force          Move files even if an editor or downloader has them open
  -n, --dry-run        Preview only; implies "once" unless "run" is used
  -v, --verbose        Show skipped files and full destination paths
  -q, --quiet          Only show errors
  -w, --watch          Alias for the "run" command
  -h, --help           Show this help

Examples:
  ${0##*/} ~/Downloads                  # start a background watcher
  ${0##*/} run ~/Downloads              # watch in the foreground
  ${0##*/} once -n ~/Downloads          # preview a single pass
  ${0##*/} stop ~/Downloads             # stop that watcher
  ${0##*/} status                       # list all watchers
  ${0##*/} -r -a -c ~/data              # smart, recursive watcher
EOF
}

die() {
  printf 'error: %s\n' "$*" >&2
  exit 1
}

warn() {
  printf 'warning: %s\n' "$*" >&2
}

# Control messages (start/stop/status) always print.
info() {
  printf '%s\n' "$*"
}

# File-action messages are timestamped when output goes to a log/service.
timestamp() {
  if (( BASH_VERSINFO[0] > 4 || (BASH_VERSINFO[0] == 4 && BASH_VERSINFO[1] >= 2) )); then
    printf '%(%F %T)T' -1
  else
    date '+%F %T'
  fi
}

say() {
  if (( quiet )); then
    return 0
  fi
  if (( use_timestamps )); then
    printf '[%s] %s\n' "$(timestamp)" "$*"
  else
    printf '%s\n' "$*"
  fi
}

vlog() {
  if (( verbose && ! quiet )); then
    say "$*"
  fi
}

bump() {
  local category=$1
  local n=${count_by_category["$category"]:-0}
  count_by_category["$category"]=$(( n + 1 ))
}

# ---------------------------------------------------------------------------
# Classification helpers
# ---------------------------------------------------------------------------

# Extension of a filename, without the dot. Empty when there is none.
# Compound suffixes (tar.gz, ...) are returned as a whole.
get_extension() {
  local name=${1,,}
  local compound

  for compound in "${compound_extensions[@]}"; do
    if [[ $name == *".$compound" ]]; then
      printf '%s' "$compound"
      return 0
    fi
  done

  [[ $name == *.* ]] || return 0
  # ".bashrc" is a dotfile, not an extension.
  if [[ $name == .* && $name != *.*.* ]]; then
    return 0
  fi
  printf '%s' "${name##*.}"
}

# Strong filename hints, checked before the extension.
special_category() {
  local name=$1

  if [[ -n ${special_names[$name]+x} ]]; then
    printf '%s' "${special_names[$name]}"
    return 0
  fi

  case $name in
    dockerfile.*|containerfile.*|makefile.*|gnumakefile.*)
      printf 'code'
      return 0
      ;;
  esac

  return 1
}

# Ask the file command what something really is. Used when the extension is
# missing or unknown, or when --content is requested.
content_category() {
  local file=$1
  local mime

  command -v file >/dev/null 2>&1 || return 1
  # GNU file uses --mime-type; BSD/macOS file uses -I.
  mime=$(file -b --mime-type -- "$file" 2>/dev/null) ||
    mime=$(file -bI "$file" 2>/dev/null) ||
    return 1
  mime=${mime%%;*}
  [[ -n $mime ]] || return 1

  case $mime in
    application/epub+zip|application/x-mobipocket-ebook|application/vnd.amazon.ebook|application/x-fictionbook+xml|application/x-cbr|application/x-cbz)
      printf 'ebooks'
      ;;
    application/pdf|application/msword|application/rtf|application/x-tex|application/x-latex|application/vnd.openxmlformats-officedocument.*|application/vnd.oasis.opendocument.*|application/vnd.ms-excel|application/vnd.ms-powerpoint|application/vnd.apple.pages|application/vnd.apple.numbers|application/vnd.apple.keynote|text/plain|text/markdown|text/rtf)
      printf 'documents'
      ;;
    application/json|application/xml|text/xml|application/x-yaml|text/csv|text/tab-separated-values|application/x-sqlite3|application/vnd.sqlite3|application/x-ndjson|application/x-desktop|application/vnd.tcpdump.pcap)
      printf 'datafiles'
      ;;
    application/zip|application/x-zip-compressed|application/x-tar|application/gzip|application/x-gzip|application/x-bzip2|application/x-xz|application/zstd|application/x-lzip|application/x-lzma|application/x-compress|application/x-7z-compressed|application/vnd.rar|application/x-rar|application/x-rar-compressed|application/x-cpio|application/x-iso9660-image|application/java-archive|application/x-archive|application/x-lz4|application/x-brotli)
      printf 'archives'
      ;;
    application/x-executable|application/x-pie-executable|application/x-sharedlib|application/x-object|application/x-mach-binary|application/x-msdownload|application/vnd.microsoft.portable-executable|application/vnd.android.package-archive|application/vnd.debian.binary-package|application/x-deb|application/x-rpm|application/x-apple-diskimage|application/x-msi)
      printf 'executables'
      ;;
    application/postscript|image/vnd.adobe.photoshop)
      printf 'design'
      ;;
    application/x-pem-file|application/x-pkcs12|application/x-pkcs7-certificates|application/pgp-keys|application/pgp-signature|application/pkix-cert|application/x-x509-ca-cert|application/x-x509-user-cert|text/x-ssh-private-key|application/x-ssh-private-key|application/x-openssh-private-key)
      printf 'certificates'
      ;;
    font/*|application/font-*|application/x-font-*|application/vnd.ms-fontobject)
      printf 'fonts'
      ;;
    image/*)
      printf 'images'
      ;;
    video/*)
      printf 'videos'
      ;;
    audio/*)
      printf 'audio'
      ;;
    application/javascript|application/x-javascript|text/javascript|text/x-python|text/x-python3|text/x-c|text/x-c++|text/x-java|text/x-shellscript|application/x-sh|text/html|text/css|application/x-httpd-php|application/x-ruby|text/x-go|text/x-rust|text/x-perl|text/x-lua|text/x-tcl)
      printf 'code'
      ;;
    text/*)
      printf 'documents'
      ;;
    *)
      return 1
      ;;
  esac
}

classify_file() {
  local file=$1
  local name=${file##*/}
  local lower_name=${name,,}
  local ext category

  # 1. A well-known filename is the strongest signal.
  if category=$(special_category "$lower_name"); then
    printf '%s' "$category"
    return 0
  fi

  # 2. With --content, trust the contents over a possibly wrong extension.
  if (( content_first )); then
    if category=$(content_category "$file"); then
      printf '%s' "$category"
      return 0
    fi
  fi

  # 3. Normal extension lookup (including compound suffixes).
  ext=$(get_extension "$name")
  if [[ -n $ext && -n ${ext_to_category[$ext]+x} ]]; then
    printf '%s' "${ext_to_category[$ext]}"
    return 0
  fi

  # 4. Unknown extension: inspect the contents instead of giving up.
  if category=$(content_category "$file"); then
    printf '%s' "$category"
    return 0
  fi

  # 5. Unknown but executable: treat it as a program.
  if [[ -x $file ]]; then
    printf 'executables'
    return 0
  fi

  printf '%s' "$others_dir"
}

is_temporary() {
  local name=${1,,}
  local pattern

  for pattern in "${temporary_patterns[@]}"; do
    if [[ $name == $pattern ]]; then
      return 0
    fi
  done
  return 1
}

# True when an editor's lock or swap file sits next to $file, meaning the
# file may still be open. Covers Vim, Kate, LibreOffice, MS Office/WPS,
# Emacs, nano, and JetBrains IDEs. Sets editor_lock_path for logging.
editor_lock_path=""
has_editor_lock() {
  local file=$1
  local dir=${file%/*}
  local base=${file##*/}
  local candidate

  for candidate in \
    "$dir/.$base.swp" \
    "$dir/.$base.swo" \
    "$dir/.$base.swn" \
    "$dir/.$base.kate-swp" \
    "$dir/.~lock.$base#" \
    "$dir/~\$$base" \
    "$dir/.#$base" \
    "$dir/$base.save" \
    "$dir/$base.___jb_tmp___" \
    "$dir/$base.___jb_old___"
  do
    if [[ -e $candidate || -L $candidate ]]; then
      editor_lock_path=$candidate
      return 0
    fi
  done
  return 1
}

# True when some process currently has $file open. This catches downloads
# written straight to their final name and files an editor is holding.
is_in_use() {
  local file=$1

  # fuser from psmisc does not support "--"; $file is always absolute here,
  # so a leading dash in a filename cannot be mistaken for an option.
  if command -v fuser >/dev/null 2>&1; then
    fuser -s "$file" >/dev/null 2>&1 && return 0
    return 1
  fi
  if command -v lsof >/dev/null 2>&1; then
    [[ -n $(lsof -t -- "$file" 2>/dev/null) ]] && return 0
  fi
  return 1
}

# Return a destination path that does not collide with an existing entry.
# "photo.jpg" becomes "photo (1).jpg", "photo (2).jpg", and so on.
unique_destination() {
  local dest=$1
  if [[ ! -e $dest && ! -L $dest ]]; then
    printf '%s' "$dest"
    return 0
  fi

  local dir=${dest%/*}
  local base=${dest##*/}
  local stem=$base
  local ext=""
  local n=1
  local candidate

  if [[ $base == *.* && $base != .* ]]; then
    stem=${base%.*}
    ext=.${base##*.}
  fi

  while :; do
    candidate="$dir/$stem ($n)$ext"
    if [[ ! -e $candidate && ! -L $candidate ]]; then
      printf '%s' "$candidate"
      return 0
    fi
    n=$(( n + 1 ))
  done
}

# File change time as Unix seconds (GNU stat, then BSD/macOS stat).
# ctime is used instead of mtime because writers cannot preserve it.
file_ctime() {
  local file=$1
  if stat -c %Z "$file" >/dev/null 2>&1; then
    stat -c %Z "$file"
  else
    stat -f %c "$file"
  fi
}

# True when the file is old enough that it is probably not still being written.
is_stable() {
  local file=$1
  local ctime

  (( settle > 0 )) || return 0
  ctime=$(file_ctime "$file") || return 0
  (( NOW - ctime >= settle ))
}

# ---------------------------------------------------------------------------
# Moving files
# ---------------------------------------------------------------------------

move_file() {
  local file=$1
  local name=${file##*/}
  local rel=${file#"$target"/}
  local category destdir dest final
  local c

  # Never move the script that is currently running.
  if [[ $file -ef $script_path ]]; then
    vlog "skip (this script): $rel"
    skipped=$(( skipped + 1 ))
    return 0
  fi

  # Leave downloads/temporary files alone until they get their final name.
  if is_temporary "$name"; then
    vlog "skip (temporary/incomplete): $rel"
    skipped=$(( skipped + 1 ))
    return 0
  fi

  # Skip hidden files and anything inside a hidden directory.
  if (( ! hidden )) && [[ $rel == .* || $rel == */.* ]]; then
    vlog "skip (hidden): $rel"
    skipped=$(( skipped + 1 ))
    return 0
  fi

  # In recursive mode, leave already-organized files alone.
  if (( recursive )); then
    for c in "${categories[@]}" "$others_dir"; do
      if [[ $rel == "$c"/* || $rel == */"$c"/* ]]; then
        vlog "skip (already sorted): $rel"
        skipped=$(( skipped + 1 ))
        return 0
      fi
    done
  fi

  # Give writers a chance to finish before moving.
  if ! is_stable "$file"; then
    vlog "skip (recently modified): $rel"
    return 0
  fi

  # Skip files a downloader is still writing or an editor still has open.
  # The settle check alone cannot see a transfer that stalled mid-file.
  if (( ! force )); then
    editor_lock_path=""
    if has_editor_lock "$file"; then
      vlog "skip (editor lock: ${editor_lock_path##*/}): $rel"
      skipped=$(( skipped + 1 ))
      return 0
    fi
    if is_in_use "$file"; then
      vlog "skip (in use): $rel"
      skipped=$(( skipped + 1 ))
      return 0
    fi
  fi

  category=$(classify_file "$file")
  destdir="$target/$category"
  dest="$destdir/$name"

  if (( dry_run )); then
    final=$(unique_destination "$dest")
    say "would move: $rel -> $category/"
    vlog "  destination: ${final#"$target"/}"
    moved=$(( moved + 1 ))
    bump "$category"
    return 0
  fi

  # Create the category folder only when it is actually needed.
  if [[ ! -d $destdir ]]; then
    if ! mkdir -p -- "$destdir"; then
      printf 'error: cannot create directory: %s\n' "$destdir" >&2
      errors=$(( errors + 1 ))
      return 1
    fi
  fi

  final=$(unique_destination "$dest")
  if mv -- "$file" "$final"; then
    say "moved: $rel -> $category/"
    vlog "  destination: ${final#"$target"/}"
    moved=$(( moved + 1 ))
    bump "$category"
    return 0
  fi

  printf 'error: failed to move: %s\n' "$file" >&2
  errors=$(( errors + 1 ))
  return 1
}

# Scan the target directory once and organize every matching file.
organize_once() {
  local -a find_cmd
  local file

  # "skipped" describes one scan; "moved" and "errors" accumulate.
  skipped=0

  if (( settle > 0 )); then
    NOW=$(date +%s)
  fi

  if (( recursive )); then
    # Walk the tree, but do not descend into our own category folders or
    # hidden directories (for example .git) when hidden files are excluded.
    find_cmd=( find "$target" )
    for c in "${categories[@]}" "$others_dir"; do
      find_cmd+=( -path "$target/$c" -type d -prune -o )
    done
    if (( ! hidden )) && [[ ${target##*/} != .* ]]; then
      find_cmd+=( -name '.*' -prune -o )
    fi
    find_cmd+=( -type f -print0 )
  else
    find_cmd=( find "$target" -maxdepth 1 -type f -print0 )
  fi

  # -print0 / read -d '' keeps filenames with spaces and newlines intact.
  # fd 9 is the watcher lock; close it in the child so it is not inherited.
  while IFS= read -r -d '' file; do
    move_file "$file"
  done < <("${find_cmd[@]}" 9>&- 2>/dev/null)
}

print_summary() {
  if (( quiet )); then
    return 0
  fi

  local verb="moved"
  if (( dry_run )); then
    verb="would move"
  fi

  say "Summary: $verb $moved file(s), skipped $skipped, errors $errors."

  if (( moved > 0 )); then
    local -a parts=()
    local c
    for c in "${categories[@]}" "$others_dir"; do
      if (( count_by_category[$c] > 0 )); then
        parts+=("$c: ${count_by_category[$c]}")
      fi
    done
    say "  ${parts[*]}"
  fi
}

on_stop() {
  local code=$1
  if (( ! quiet )); then
    printf '\n' >&2
  fi
  print_summary
  exit "$code"
}

# ---------------------------------------------------------------------------
# Background watcher state
# ---------------------------------------------------------------------------

set_state_root() {
  if [[ -n ${XDG_STATE_HOME:-} ]]; then
    state_dir="$XDG_STATE_HOME/folder-manager"
  elif [[ -n ${HOME:-} ]]; then
    state_dir="$HOME/.local/state/folder-manager"
  else
    state_dir="/tmp/folder-manager-${UID:-0}"
  fi
}

setup_state() {
  local sum

  set_state_root
  if command -v sha256sum >/dev/null 2>&1; then
    sum=$(printf '%s' "$target" | sha256sum)
  elif command -v shasum >/dev/null 2>&1; then
    sum=$(printf '%s' "$target" | shasum -a 256)
  else
    sum=$(printf '%s' "$target" | cksum)
  fi
  key=${sum%% *}
  pid_file="$state_dir/$key.pid"
  log_file="$state_dir/$key.log"
  dir_file="$state_dir/$key.dir"
  lock_file="$state_dir/$key.lock"
}

ensure_state_dir() {
  if [[ ! -d $state_dir ]]; then
    mkdir -p -- "$state_dir" || die "cannot create state directory: $state_dir"
  fi
  chmod 700 "$state_dir" 2>/dev/null || true
}

read_pid() {
  local pid
  [[ -r $pid_file ]] || return 1
  pid=$(<"$pid_file") || return 1
  pid=${pid//[[:space:]]/}
  [[ $pid =~ ^[0-9]+$ ]] || return 1
  printf '%s' "$pid"
}

# A free lock means no watcher owns this directory, even if a PID was reused.
lock_is_held() {
  local lock=$1

  command -v flock >/dev/null 2>&1 || return 0
  exec 8>>"$lock" || return 0
  if flock -n 8; then
    exec 8>&-
    return 1
  fi
  exec 8>&-
  return 0
}

pid_is_running() {
  local pid=$1
  local lock=${2:-$lock_file}
  local cmd

  [[ $pid =~ ^[0-9]+$ ]] || return 1
  kill -0 "$pid" 2>/dev/null || return 1
  lock_is_held "$lock" || return 1

  # Make sure a reused PID is still one of our watchers.
  if [[ -r /proc/$pid/cmdline ]]; then
    cmd=$(tr '\0' ' ' < "/proc/$pid/cmdline" 2>/dev/null) || return 1
    [[ $cmd == *"${script_path##*/}"* ]] || return 1
  elif command -v ps >/dev/null 2>&1; then
    cmd=$(ps -p "$pid" -o command= 2>/dev/null) || return 1
    [[ $cmd == *"${script_path##*/}"* ]] || return 1
  fi
  return 0
}

is_running() {
  local pid
  pid=$(read_pid) || return 1
  pid_is_running "$pid"
}

# Hold a per-directory lock for the lifetime of the watcher, so two watchers
# cannot manage the same directory at the same time.
acquire_lock() {
  ensure_state_dir

  if command -v flock >/dev/null 2>&1; then
    exec 9>>"$lock_file" || return 1
    flock -n 9 || return 1
    return 0
  fi

  # Fallback for systems without flock: the PID file is the lock.
  if ( set -o noclobber; printf '%s\n' "$$" > "$pid_file" ) 2>/dev/null; then
    return 0
  fi
  if ! is_running; then
    rm -f -- "$pid_file"
    if ( set -o noclobber; printf '%s\n' "$$" > "$pid_file" ) 2>/dev/null; then
      return 0
    fi
  fi
  return 1
}

cleanup() {
  local pid

  if [[ -n ${sleep_pid:-} ]]; then
    kill "$sleep_pid" 2>/dev/null || true
  fi
  if pid=$(read_pid 2>/dev/null) && [[ $pid == "$$" ]]; then
    rm -f -- "$pid_file" "$dir_file"
  fi
}

rotate_log_if_needed() {
  local size
  [[ -f $log_file ]] || return 0
  size=$(wc -c < "$log_file" 2>/dev/null) || return 0
  if (( size > 5 * 1024 * 1024 )); then
    mv -f -- "$log_file" "$log_file.1" || true
  fi
}

start_daemon() {
  local -a args
  local i

  if (( dry_run )); then
    die "dry-run cannot start a background watcher; use 'once' or 'run'"
  fi

  ensure_state_dir

  if is_running; then
    die "already running (pid $(read_pid)): $target; use restart"
  fi
  rm -f -- "$pid_file"

  rotate_log_if_needed
  {
    printf '\n=== %s start: %s ===\n' "$(date '+%F %T')" "$target"
  } >> "$log_file" 2>/dev/null || die "cannot write log file: $log_file"

  args=( run --dir "$target" --interval "$interval" --settle "$settle" )
  if (( recursive )); then args+=( --recursive ); fi
  if (( hidden )); then args+=( --all ); fi
  if (( content_first )); then args+=( --content ); fi
  if (( force )); then args+=( --force ); fi
  if (( verbose )); then args+=( --verbose ); fi
  if (( quiet )); then args+=( --quiet ); fi

  # Detach from the terminal. The child writes its own PID file.
  if command -v setsid >/dev/null 2>&1; then
    setsid "$script_path" "${args[@]}" >>"$log_file" 2>&1 < /dev/null &
  else
    nohup "$script_path" "${args[@]}" >>"$log_file" 2>&1 < /dev/null &
  fi

  for i in {1..50}; do
    if is_running; then
      info "Started watcher (pid $(read_pid))"
      info "  directory: $target"
      info "  log:       $log_file"
      return 0
    fi
    sleep 0.1
  done

  printf 'error: failed to start watcher: %s\n' "$target" >&2
  if [[ -s $log_file ]]; then
    printf '%s\n' '--- recent log ---' >&2
    tail -n 20 "$log_file" >&2 || true
  fi
  return 1
}

stop_daemon() {
  local pid
  local i

  if ! pid=$(read_pid) || ! pid_is_running "$pid"; then
    info "Not running: $target"
    rm -f -- "$pid_file" "$dir_file"
    return 0
  fi

  info "Stopping watcher (pid $pid): $target"
  kill -TERM "$pid" 2>/dev/null || true

  for i in {1..100}; do
    if ! kill -0 "$pid" 2>/dev/null; then
      info "Stopped."
      rm -f -- "$pid_file" "$dir_file"
      return 0
    fi
    sleep 0.1
  done

  warn "watcher did not stop within 10s; sending SIGKILL"
  kill -KILL "$pid" 2>/dev/null || true
  sleep 0.2
  rm -f -- "$pid_file" "$dir_file"
  info "Stopped (forced)."
}

restart_daemon() {
  stop_daemon
  start_daemon
}

list_instances() {
  local f pid dir found=0

  shopt -s nullglob
  for f in "$state_dir"/*.pid; do
    pid=$(cat "$f" 2>/dev/null) || continue
    if pid_is_running "$pid" "${f%.pid}.lock"; then
      dir=$(cat "${f%.pid}.dir" 2>/dev/null || printf '?')
      info "running (pid $pid): $dir"
      found=1
    else
      rm -f -- "$f" "${f%.pid}.dir"
    fi
  done

  if (( ! found )); then
    info "No watchers running."
  fi
}

status_instance() {
  local pid dir

  if pid=$(read_pid) && pid_is_running "$pid"; then
    dir=$(cat "$dir_file" 2>/dev/null || printf '%s' "$target")
    info "running (pid $pid): $dir"
    info "  log: $log_file"
    return 0
  fi

  info "not running: $target"
  return 1
}

# Foreground watch loop. Used by "run" and by the background child.
run_watch() {
  ensure_state_dir
  if ! acquire_lock; then
    if is_running; then
      die "another watcher is already running for $target (pid $(read_pid))"
    fi
    die "cannot acquire watcher lock for $target"
  fi

  printf '%s\n' "$$" > "$pid_file"
  printf '%s\n' "$target" > "$dir_file"

  trap cleanup EXIT
  trap 'on_stop 130' INT
  trap 'on_stop 0' TERM HUP

  say "Watching $target (interval ${interval}s, settle ${settle}s)"

  organize_once

  while :; do
    # Background sleep + wait so SIGTERM is handled immediately.
    # Close the watcher lock fd in the sleep child so it cannot survive a crash.
    sleep "$interval" 9>&- &
    sleep_pid=$!
    wait "$sleep_pid" 2>/dev/null || true
    sleep_pid=""

    if [[ ! -d $target ]]; then
      printf 'error: directory disappeared: %s\n' "$target" >&2
      errors=$(( errors + 1 ))
      break
    fi
    organize_once
  done

  print_summary
}

do_once() {
  # A real pass takes the same lock as a watcher so they cannot race on names.
  if (( ! dry_run )); then
    ensure_state_dir
    if ! acquire_lock; then
      die "another watcher is already running for $target; stop it first"
    fi
    printf '%s\n' "$$" > "$pid_file"
    printf '%s\n' "$target" > "$dir_file"
    trap cleanup EXIT
  fi

  organize_once
  print_summary
  (( errors == 0 ))
}

# ---------------------------------------------------------------------------
# Command line
# ---------------------------------------------------------------------------

parse_args() {
  while (( $# > 0 )); do
    case $1 in
      start|run|stop|restart|status|once)
        mode=$1
        shift
        ;;
      -d|--dir)
        (( $# >= 2 )) || die "option $1 requires an argument"
        target=$2
        target_set=1
        shift 2
        ;;
      --dir=*)
        target=${1#*=}
        target_set=1
        shift
        ;;
      -i|--interval)
        (( $# >= 2 )) || die "option $1 requires an argument"
        interval=$2
        shift 2
        ;;
      --interval=*)
        interval=${1#*=}
        shift
        ;;
      -s|--settle)
        (( $# >= 2 )) || die "option $1 requires an argument"
        settle=$2
        settle_set=1
        shift 2
        ;;
      --settle=*)
        settle=${1#*=}
        settle_set=1
        shift
        ;;
      -r|--recursive)
        recursive=1
        shift
        ;;
      -a|--all|--hidden)
        hidden=1
        shift
        ;;
      -c|--content)
        content_first=1
        shift
        ;;
      -f|--force)
        force=1
        shift
        ;;
      -n|--dry-run)
        dry_run=1
        shift
        ;;
      -v|--verbose)
        verbose=1
        shift
        ;;
      -q|--quiet)
        quiet=1
        shift
        ;;
      -w|--watch|--foreground)
        mode="run"
        shift
        ;;
      --once)
        mode="once"
        shift
        ;;
      -h|--help)
        usage
        exit 0
        ;;
      --)
        shift
        while (( $# > 0 )); do
          target=$1
          target_set=1
          shift
        done
        ;;
      -*)
        die "unknown option: $1 (try --help)"
        ;;
      *)
        target=$1
        target_set=1
        shift
        ;;
    esac
  done
}

resolve_script_path() {
  local dir

  if [[ $0 == */* ]]; then
    dir=$(cd -- "${0%/*}" 2>/dev/null && pwd) || dir=${0%/*}
    script_path="$dir/${0##*/}"
    return 0
  fi

  # Bare name: first look in the current directory, then in PATH.
  if [[ -f $0 ]]; then
    script_path="$(pwd)/$0"
    return 0
  fi

  script_path=$(command -v -- "$0" 2>/dev/null || printf '%s' "$0")
  if [[ $script_path != /* ]]; then
    dir=$(cd -- "$(dirname -- "$script_path")" 2>/dev/null && pwd) || dir=.
    script_path="$dir/$(basename -- "$script_path")"
  fi
}

normalize_target() {
  if [[ -d $target ]]; then
    target=$(cd -- "$target" && pwd -P) || return 1
  else
    [[ $target == /* ]] || target="${PWD:-.}/$target"
    while [[ $target == */ && $target != / ]]; do
      target=${target%/}
    done
  fi
  return 0
}

main() {
  if [[ ! -t 1 ]]; then
    use_timestamps=1
  fi

  parse_args "$@"
  resolve_script_path
  set_state_root

  # Default to a background watcher; dry-run defaults to a single preview.
  if [[ -z $mode ]]; then
    if (( dry_run )); then
      mode="once"
    else
      mode="start"
    fi
  fi

  if (( dry_run )) && [[ $mode == "start" || $mode == "restart" ]]; then
    die "dry-run cannot start a background watcher; use 'once' or 'run'"
  fi

  if (( target_set )) && [[ -z $target ]]; then
    die "directory argument is empty"
  fi

  [[ $interval =~ ^[0-9]+([.][0-9]+)?$ ]] || die "invalid interval: $interval"
  if [[ $interval =~ ^0*([.]0*)?$ ]]; then
    die "interval must be greater than 0"
  fi
  [[ $settle =~ ^[0-9]+$ ]] || die "invalid settle value: $settle"

  if (( ! settle_set )); then
    case $mode in
      start|run) settle=2 ;;
      *) settle=0 ;;
    esac
  fi

  # "status" with no directory lists every running watcher.
  if [[ $mode == "status" && $target_set -eq 0 ]]; then
    list_instances
    return 0
  fi

  if [[ -z $target ]]; then
    target=${PWD:-.}
  fi

  case $mode in
    start|run|restart|once)
      [[ -d $target ]] || die "not a directory: $target"
      ;;
  esac

  normalize_target || die "cannot access directory: $target"
  setup_state

  case $mode in
    start) start_daemon ;;
    run) run_watch ;;
    stop) stop_daemon ;;
    restart) restart_daemon ;;
    status) status_instance ;;
    once) do_once ;;
    *) die "unknown command: $mode" ;;
  esac
}

main "$@"
