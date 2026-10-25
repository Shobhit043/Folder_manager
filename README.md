# Folder Manager

`manage_files.sh` is an always-on file organizer. Point it at a directory and
it keeps that directory tidy in the background: new downloads, screenshots,
documents, and archives are moved into category folders such as `images/`,
`videos/`, `audio/`, `documents/`, `archives/`, `code/`, `datafiles/`, and
`others/`.

## Quick start

```bash
# Start a background watcher for ~/Downloads
./manage_files.sh ~/Downloads

# Check on it
./manage_files.sh status

# Stop it
./manage_files.sh stop ~/Downloads
```

The script daemonizes itself, so the command returns immediately and keeps
running after you close the terminal. Only one watcher can manage a given
directory at a time.

## Commands

| Command | Description |
| --- | --- |
| `start` | Start a background watcher (default when no command is given) |
| `run` | Watch in the foreground (useful for systemd, `nohup`, or debugging) |
| `stop` | Stop the background watcher for a directory |
| `restart` | Restart the background watcher |
| `status` | Show status; with no directory, list every running watcher |
| `once` | Organize once and exit |

## Options

| Option | Description |
| --- | --- |
| `-d, --dir DIR` | Directory to organize (default: current directory) |
| `-i, --interval SEC` | Seconds between scans (default: `2`) |
| `-s, --settle SEC` | Wait `SEC` seconds after a file changes before moving it (default: `2` for watchers, `0` for `once`) |
| `-r, --recursive` | Also organize files in subdirectories |
| `-a, --all` | Include hidden files (dotfiles) |
| `-c, --content` | Detect type from file contents even when the extension is known |
| `-f, --force` | Move files even if an editor or downloader has them open |
| `-n, --dry-run` | Preview only; implies `once` unless `run` is given |
| `-v, --verbose` | Show skipped files and full destination paths |
| `-q, --quiet` | Only show errors |
| `-w, --watch` | Alias for `run` |
| `-h, --help` | Show help |

## Examples

```bash
# Prefer file contents over extensions (catches renamed/mislabelled files)
./manage_files.sh -c ~/Downloads

# Watch recursively, include dotfiles, and use content detection
./manage_files.sh -r -a -c ~/data

# Preview a single pass without changing anything
./manage_files.sh once -n ~/Downloads

# Run in the foreground (systemd, nohup, or a terminal)
./manage_files.sh run ~/Downloads

# Status for every watcher, then stop one
./manage_files.sh status
./manage_files.sh stop ~/Downloads
```

## Smarter allocation

- **Extension lookup first.** Common and compound extensions such as
  `tar.gz`, `tar.bz2`, `tar.xz`, and `tar.zst` are recognized as archives.
- **Filename hints.** Files like `Dockerfile`, `Makefile`, `CMakeLists.txt`,
  `requirements.txt`, `LICENSE`, and `README` are classified even when their
  extension is misleading.
- **Content fallback.** If an extension is missing or unknown, the script asks
  `file --mime-type` and routes images, video, audio, archives, executables,
  fonts, documents, and data files correctly. An extensionless ZIP becomes
  `archives/` instead of `others/`.
- **`--content` override.** Use it when a file's extension lies (for example a
  ZIP renamed to `.txt` or a PNG renamed to `.bin`).
- **Temporary files are skipped.** `.part`, `.crdownload`, `.download`,
  `.aria2`, `.tmp`, editor swap files, Office/WPS lock files (`~$report.docx`),
  JetBrains `___jb_tmp___` files, and similar in-progress files stay put until
  they are renamed or finished.
- **Nothing is overwritten.** A second `photo.jpg` becomes `photo (1).jpg`,
  then `photo (2).jpg`, and so on.
- **Safe defaults.** Hidden files and symlinks are left alone unless you opt
  in with `-a`; the running script is never moved.
- **Recursive mode flattens.** Files in subdirectories are moved into the
  category folders at the target root. Files already inside a category folder
  are left where they are.

## Downloads and editing

A watcher scans every `--interval` seconds (default `2`) and only moves files
that have been unchanged for `--settle` seconds (default `2`), so a finished
download is organized roughly **2–4 seconds** after it completes. Partial
downloads such as `.crdownload`, `.part`, and `.aria2` are ignored until the
downloader renames them.

The watcher also refuses to move a file that is still held open (checked with
`fuser`, falling back to `lsof`) or that has an editor lock next to it:

| Editor | Companion file that blocks the move |
| --- | --- |
| Vim / Kate | `.file.swp`, `.file.swo`, `.file.kate-swp` |
| LibreOffice | `.~lock.file#` |
| MS Office / WPS | `~$file` |
| Emacs | `.#file` |
| nano | `file.save` |
| JetBrains | `file.___jb_tmp___`, `file.___jb_old___` |

So a document you are actively editing, and the temporary files created while
saving it, stay where they are. `--force` bypasses both checks if you want the
aggressive behavior.

Caveats:

- A few editors keep no lock file and close the document between saves (for
  example Sublime Text). Editing inside a watched directory can still let a
  save recreate the file at its old path, leaving a duplicate behind. Keep
  working documents out of the watched folder.
- A stale swap or lock file left after an editor crash keeps that file from
  being organized. Delete the stale companion or use `--force`.
- Tools that write directly to the final filename (`curl -O`, `wget`) are
  covered by the open-file check, but an unusual writer can still slip
  through. Raising `--settle` gives slow transfers more room.

## Background operation

Watcher state and logs live under:

```
${XDG_STATE_HOME:-$HOME/.local/state}/folder-manager/
```

Each watched directory gets its own PID, log, and lock file, so multiple
directories can be watched at the same time. Logs are timestamped and are
rotated to `.log.1` at startup when they exceed 5 MB. `stop` sends `SIGTERM`
and waits up to 10 seconds before forcing the process down.

### systemd user service

For automatic start at login, use the foreground `run` command instead of
`start`:

```ini
[Unit]
Description=Folder manager for %h/Downloads
After=default.target

[Service]
Type=simple
ExecStart=%h/Folder_manager/manage_files.sh run --settle 2 %h/Downloads
Restart=on-failure
RestartSec=5
TimeoutStopSec=15
NoNewPrivileges=yes

[Install]
WantedBy=default.target
```

Save it as `~/.config/systemd/user/folder-manager.service`, then:

```bash
systemctl --user daemon-reload
systemctl --user enable --now folder-manager.service
```

## Customizing categories

Edit the `categories` and `extensions` arrays near the top of the script. The
arrays are index-aligned, so the first `extensions` entry belongs to the first
`categories` entry. Add compound suffixes to `compound_extensions`, and add
exact filenames to `special_names`. Put each extension in only one category;
the first match wins.

## Requirements

- Bash 4 or newer
- Linux, macOS, or another Unix-like system
- Optional: `file` for MIME detection, `flock` for locking, `setsid` for
  detaching, and `fuser` or `lsof` for the open-file check. The script falls
  back gracefully when they are unavailable.
