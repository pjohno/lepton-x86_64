# Pending tests: shared folders (issue #37)

Manual tests for branch `fix/shared-folders-37`, on a Fedora desktop and a
Steam Deck. Delete this file, or move its results into the pull request,
once every test is done.

What the branch changes:

- `LEPTON_SHARED_FOLDERS` launch option: which host folders Android sees in
  shared storage. Values are `Documents`, `Downloads` and `Videos` (Android
  names `Documents`, `Download` and `Movies` also work), separated by commas
  or spaces, or `none`. Unset keeps the old behaviour: all three, read-write.
- Round 2: the same option also takes any host folder path, shown under its
  last name (`"Downloads,~/Books,/run/media/deck/SD/Films"`), with
  `Name=/path` to choose the name and `:ro` for read-only. Folder paths are
  mounted at `/lepton/shared/<Name>` in the container, not at their host path.
  Full rules: [compat_tool/configuration.md](compat_tool/configuration.md#shared-folders).
- `lepton-play` profiles get working shared storage. Before the fix,
  `/data/media/0` pointed at an unmounted folder, so these profiles had no
  shared storage and no OBB link.

## 1. Setup

### Build a test bundle

Only launcher scripts changed, so repackage the existing `v0.4.0-test` stage
with this branch's scripts. This doesn't rebuild Android or redo the sysbake.

Round 2 uses a new bundle ID, so it installs next to round 1's
`v0.4.0-shared-folders` tool instead of over it:

```bash
git switch fix/shared-folders-37
git pull                      # or fetch from handoff
source .build-env
bash image-14/scripts/internal/deploy-compat-x86_64.sh --package-only --execute \
  --stage-dir "$LEPTON_OUTPUT_DIR/stages/v0.4.0-test" \
  --bundle-dir "$LEPTON_OUTPUT_DIR/bundles" \
  --bundle-id v0.4.0-shared-folders-2
```

Install it with its `.install.sh` on the desktop and the Deck, as the user
who will run the tests (on the Deck, copy the `.install.sh`, `.tar.gz` and
`.sha256` into one folder first). Select it as the compatibility tool of each
shortcut you test. With `lepton-play`, use
`--tool lepton_x86_64_v0_4_0_shared_folders_2`.

Run the host test once from the checkout. It needs no Android. Record the
last line in the results table:

```bash
bash tests/test-shared-folders.sh      # expect: PASS
```

It prints `SKIP: no writable folder under /mnt` on a machine where you can't
write under `/mnt`; that part is then checked by T13 instead.

### Test files and apps

- Put a marker file in each host folder, named so it is easy to find and
  delete later:

  ```bash
  for d in Documents Downloads Videos; do echo host > ~/$d/lepton-test-host-$d.txt; done
  ```
- Install a file manager APK that can browse shared storage, such as
  Material Files (`me.zhanghai.android.files`, F-Droid). Also install
  Librera Reader (`com.foobnix.pro.pdf.reader`, F-Droid), the app from the
  issue, which creates folders in Downloads. Add each with `lepton-add-game`
  as a Steam shortcut.
- A Steam game, or any shortcut that uses OBB files, for the regression test.

### Inspecting a running game

Run these in a terminal while the game is open. On the Deck, use Konsole in
Desktop Mode, or SSH while it's in Gaming Mode.

```bash
C=$(podman ps --format '{{.Names}}' | grep '^lepton-' | head -1); echo "$C"
LOG=~/.steam/steam/logs/$C.log

# Host folders mounted into the container: source -> destination, read-write?
podman inspect "$C" --format '{{range .Mounts}}{{.Source}} -> {{.Destination}} rw={{.RW}}{{"\n"}}{{end}}' |
  grep -E "^$HOME/(Documents|Downloads|Videos) |/lepton/shared/|/external "

# What Android's shared storage holds. A shared folder is a link (lrwx...):
# default folders link to their host path, others to /lepton/shared/<Name>.
# A folder that is not shared is a real directory (drwx...).
podman exec "$C" /system/bin/sh -c 'ls -la /data/media/0/'

# The same folders as apps see them, through Android's storage service
podman exec "$C" /system/bin/sh -c 'ls -la /storage/emulated/0/ /storage/emulated/0/Books/'

# Launcher messages about shared folders
grep -E 'Shared folder|shared folder|LEPTON_SHARED_FOLDERS|not linked|left unchanged|unexpected storage link' "$LOG"
```

To give the file manager all-files access without the Settings app, then
confirm it took effect:

```bash
podman exec "$C" appops set me.zhanghai.android.files MANAGE_EXTERNAL_STORAGE allow
podman exec "$C" appops get me.zhanghai.android.files MANAGE_EXTERNAL_STORAGE
```

Set launch options in the shortcut's **Properties > Launch Options**,
followed by `%command%`, for example `LEPTON_SHARED_FOLDERS=none %command%`.
For `lepton-play`, put the variable before the command:
`LEPTON_SHARED_FOLDERS=none lepton-play game.apk`.

## 2. Tests

Run each test on both machines and record the result in the table at the
end. "Linked" means `/data/media/0/<name>` is a link to the host folder, and
the host folder is in the mount list.

### T1. Default is unchanged (no launch option)

Use the file manager shortcut with no `LEPTON_SHARED_FOLDERS`.

- [ ] `Documents`, `Download` and `Movies` are linked; all three host
  folders are mounted.
- [ ] With all-files access, the file manager shows the
  `lepton-test-host-*` file in each folder.
- [ ] Create a file in `Download` from Android: it appears in `~/Downloads`
  on the host.
- [ ] No "Shared folder" messages in the log.

### T2. Sharing off: `LEPTON_SHARED_FOLDERS=none`

Same shortcut, launched after T1.

> **Round 1 Fedora result needs a re-check.** The note recorded for T2 is a
> listing with `Documents`, `Download` and `Movies` as links (`lrwxrwxrwx ...
> -> /home/paulwork/...`). That is what T1 (default) should show. With
> `none`, those three must be real directories (`drwx------`), not links. If
> that listing came from the `none` launch, sharing was not turned off, and
> T2 fails. Re-run T2 on Fedora: check the launch option was saved, run the
> `ls -la /data/media/0/` command above while the game is open, and record
> whether the three entries start with `l` or `d`. Also check the log for
> `Shared folder off: ...` lines, which appear on the first `none` launch
> after a default launch.

- [ ] The log shows `Shared folder off: Documents`, `Download` and `Movies`.
- [ ] None of the three host folders is in the mount list; no links under
  `/data/media/0`.
- [ ] The file manager doesn't show the `lepton-test-host-*` files.
- [ ] Create a file in Android's `Download`: it does not appear in
  `~/Downloads`. It is stored in the profile's
  `compatdata/<AppID>/external/Download/` instead.
- [ ] Host folders and the marker files are unchanged.
- [ ] Librera with `none`: the folders it creates stay out of `~/Downloads`
  (the issue's case).

### T3. Some folders: `LEPTON_SHARED_FOLDERS=Downloads`

- [ ] Only `Download` is linked and only `~/Downloads` is mounted.
- [ ] `Documents` and `Movies` are Android's own folders.
- [ ] Also try `LEPTON_SHARED_FOLDERS="documents, VIDEOS"`: names are not
  case-sensitive, and commas or spaces both separate them.

### T4. Turning a folder back on

1. Launch with `none`, put no files in Android's `Download`, close.
2. Launch with no option.

- [ ] All three are linked again, including `Movies`. Android puts a
  `.thumbnails/.database_uuid` marker in Movies, which counts as empty.

3. Launch with `none`, create a file in Android's `Download`, close.
4. Launch with no option.

- [ ] The game starts. The log says `Shared folder Download not linked ... has files, so it is kept`.
- [ ] `Download` is still Android's own folder with the file in it;
  `Documents` and `Movies` are linked.
- [ ] Move that file out of `compatdata/<AppID>/external/Download/`, launch
  again: `Download` is linked.

### T5. Invalid value: `LEPTON_SHARED_FOLDERS=Downloads,Pictures`

- [ ] The launch stops with `unknown folder 'Pictures'`. On the Deck this
  also shows as a popup, in Gaming Mode and in Desktop Mode.
- [ ] Links and folders are unchanged from the previous launch.

### T6. `lepton-play` profile

> Round 1 Fedora: "Seems to work". For a full pass, record each box below,
> in particular the OBB link and the mount list.

Desktop, plus the Deck in Desktop Mode. Use a game that has never been
launched with `lepton-play`, and repeat with one that has: those older
profiles had no shared storage.

```bash
lepton-play --tool lepton_x86_64_v0_4_0_shared_folders game.apk
```

- [ ] No `mkdir: '/data/media/0/Android': No such file or directory` and no
  `ln: cannot create symbolic link ... Android/obb` in the output.
- [ ] `/storage/emulated/0/` lists the standard folders (Android, DCIM,
  Download, ...), not just `Android`.
- [ ] `~/.local/share/lepton-compat-data/<package>/external` is in the mount
  list.
- [ ] `podman exec "$C" ls -la /data/media/0/Android/obb/` shows a link for
  the package.
- [ ] `LEPTON_SHARED_FOLDERS=none` works as in T2.

### T7. Regression: OBB games and Steam libraries

- [ ] A game with OBB files, from a desktop shortcut whose APK folder has an
  `obb/` folder, starts and loads its data, with default and with `none`.
- [ ] Deck: a game in a Steam library on the SD card starts with default and
  with `none`.
- [ ] A game profile created before this change starts with no option
  (links unchanged), and then with `none` (links removed, host folders
  intact).

### T8. Shared Google Play profile (GApps bundle only)

Needs a GApps bundle built from this branch. Skip if there is none.

- [ ] `LEPTON_SHARED_FOLDERS=none` on the **Google Play (Lepton)** shortcut:
  games installed through Play don't see the host folders.
- [ ] Removing the option shares them again.

### T9. Questions left from the investigation

Record what you see. These decide later work, and none of them blocks this
branch.

> Partly answered by round 2's local Android boot: every Android process,
> apps included, runs as UID 0 in the container, which is your host user
> (`--userns=keep-id:uid=0`). So a 700 or 750 folder you own is readable and
> writable by Android, and the first two questions should come out as "yes,
> both machines". Record what you see; a "no" there is a new bug.

- [ ] Host folder modes: `stat -c '%a %n' ~ ~/Downloads ~/Documents ~/Videos`.
  Typical values: Fedora 750 or 700, Deck 755.
- [ ] With default sharing, can the file manager (all-files access) read
  **and write** host Downloads? Compare the desktop with the Deck; the
  guess is that 750 folders block Android's storage service.
- [ ] Did Lepton's own grant work? Run `appops get <package> MANAGE_EXTERNAL_STORAGE` for an app that requests all-files access,
  before running `appops set`.
- [ ] Deck: does the container expose more of the home folder than expected?
  `podman exec "$C" ls -la /home/deck /home/deck/.local/share`.

### Round 2: custom folders

Make test folders first. On the Deck, use the SD card's real mount point,
shown by `ls /run/media/deck/` (or `/run/media/mmcblk0p1` on some versions).
For an external drive, plug one in and use its folder under
`/run/media/$USER/`, or under `/mnt` if you mount it there yourself.

```bash
mkdir -p ~/Books "$HOME/My Comics"
echo host > ~/Books/lepton-test-book.txt
echo host > "$HOME/My Comics/lepton-test-comic.txt"
SD=/run/media/deck/<card>            # Deck: your SD card
USB=/run/media/$USER/<drive>         # desktop: an external drive
mkdir -p "$SD/Films" "$USB/Films"
echo host > "$SD/Films/lepton-test-film.txt"; echo host > "$USB/Films/lepton-test-film.txt"
```

Use the file manager shortcut unless a test says otherwise. Each test lists
the launch option; in Steam it goes before `%command%`. Keep the quotes:
they keep paths with spaces together. "Shared" means: the folder is a link
in `/data/media/0` to `/lepton/shared/<Name>`, the mount list shows
`<host folder> -> /lepton/shared/<Name>`, and the log has
`Shared folder <Name>: <host folder> (read-write)`.

#### T10. One folder in HOME: `LEPTON_SHARED_FOLDERS="~/Books"`

- [ ] `Books` is shared. `Documents`, `Download` and `Movies` are Android's
  own folders (only folders that are listed are shared).
- [ ] The file manager (all-files access) shows `lepton-test-book.txt` in
  `Books`, can open it, and can create a file in `Books` that appears in
  `~/Books` on the host, owned by you.
- [ ] Also try `"$HOME/Books"` instead of `"~/Books"`: same result. (This
  checks Steam expands `$HOME`; if it doesn't, the launch stops with a
  message about the path, and `~/` is the form to document.)

#### T11. A folder with spaces: `LEPTON_SHARED_FOLDERS="~/My Comics"`

- [ ] `My Comics` is shared and the file manager shows the test file.
- [ ] Without quotes, `LEPTON_SHARED_FOLDERS=~/My Comics %command%`: record
  what happens. Expected: Steam splits it at the space and the launch fails
  or shares `~/My` (missing, so a warning). It must not share anything else.

#### T12. Deck: a folder on the SD card: `LEPTON_SHARED_FOLDERS="Downloads,$SD/Films"`

Write the real path in the option, e.g. `"Downloads,/run/media/deck/SD/Films"`.

- [ ] `Download` (host `~/Downloads`) and `Films` are shared.
- [ ] The file manager reads `lepton-test-film.txt` and can write a file
  that appears on the card.
- [ ] A game installed in a Steam library on the same SD card still starts
  (its library mount is separate from this option).

#### T13. Desktop: a folder on an external drive

Option `"$USB/Films"` with the real path. Repeat with a drive you mount
under `/mnt` yourself (`/mnt/<x>/Films`) if you have one: Android hides the
container's `/mnt`, and this round mounts the folder at `/lepton/shared`
instead, so it should now work.

- [ ] `Films` is shared and readable/writable from the file manager, for
  `/run/media` and for `/mnt`.
- [ ] Unplug the drive (or unmount it), launch again with the same option:
  the game starts, the log says `shared folder Films: ... is not there`,
  and nothing else changes. `Films` shows as empty or unreadable in the
  file manager; nothing is written in its place.
- [ ] Plug it back in, launch: `Films` is shared again, with the files.

#### T14. Several folders and read-only

`LEPTON_SHARED_FOLDERS="Documents,~/Books,~/My Comics:ro,Novels=$HOME/Books2"`
(make `~/Books2` first).

- [ ] `Documents`, `Books`, `My Comics` and `Novels` are shared; `Download`
  and `Movies` are not.
- [ ] `My Comics` is read-only: the mount list shows `rw=false`, the log says
  `(read-only)`, the file manager can open its files, and creating or
  deleting a file there fails with an error. The host folder is unchanged.
- [ ] Also `Downloads:ro` on its own: `Download` is shared read-only.

#### T15. Removing and changing folders between launches

Run in this order, closing the game between launches:

1. `"~/Books,~/My Comics"`
2. `"~/Books"`: `My Comics` is gone from `/data/media/0` (log: `Shared folder
   off: My Comics is no longer shared`), `Books` is unchanged.
3. `"Library=$HOME/Books"`: `Library` is shared, `Books` is gone.
4. `"Library=$HOME/Books2"`: `Library` now shows `~/Books2`; one `Library`
   mount only.
5. No option: the default three are shared, `Library` is gone.
6. Same again with no option: nothing changes (no `Shared folder` messages).

- [ ] Each step as described, and no `lepton-test-*` or Android-made file is
  lost from any host folder or from Android's own folders.
- [ ] Create a link yourself in the profile's shared storage before step 5,
  e.g. `ln -s /tmp compatdata/<AppID>/external/MyLink`: it is still there
  after step 5.

#### T16. Mistakes stop the launch and change nothing

Launch once with `"~/Books"`, then try each of these. Each must stop the
launch with a clear message (popup on the Deck), and afterwards
`/data/media/0` must be exactly as it was:

- [ ] `"~/Books,/tmp/x/Books"` (two folders called `Books`; make `/tmp/x/Books` first).
- [ ] `"Android=$HOME/Books"` and `"Download=$HOME/Books"` (names Lepton keeps).
- [ ] `"~/lepton-test-file.txt"` (a file, not a folder).
- [ ] `"/etc"`, `"$HOME"` and `"/"` (folders that can't be shared).
- [ ] `"Downloads ~/Books"` (a path not separated by a comma).
- [ ] `"~/Books,Pictures"`: only `Pictures` is wrong (not a default folder
  name or a path). The message names it, and `Books` keeps its link.

#### T17. Android apps using the folders

With `"~/Books,$SD/Films"` (Deck) or `"~/Books,$USB/Films"` (desktop):

- [ ] Librera Reader opens a PDF or EPUB placed in `~/Books`, browsing to
  `Books` itself.
- [ ] A file saved from an app (Librera's export, or the file manager's copy)
  into `Books` appears on the host.
- [ ] Media apps: does a gallery, music or video app, or an app's file
  picker, list files from `Books`/`Films`, and from the default `Download`?
  Record yes/no for each. A local test found Android's media index lists
  none of these linked folders (default ones included), so file managers
  with all-files access see them but media pickers may not. This doesn't
  block the branch; it decides whether follow-up work is needed.

#### T18. Shared profiles and `lepton-play` with custom folders

- [ ] GApps bundle: `"Downloads,~/Books"` on **Google Play (Lepton)**:
  a Play game and the file manager installed in that profile both see
  `Books`. Then remove the option: `Books` goes for every app in the profile.
- [ ] `lepton-play`: `LEPTON_SHARED_FOLDERS="~/Books" lepton-play --tool lepton_x86_64_v0_4_0_shared_folders_2 game.apk`
  shares `Books`, and the profile's `external` folder is still mounted
  (as in T6).
- [ ] A profile created before round 2 (from round 1, or older) starts with
  no option and with `"~/Books"`; its existing `Documents`/`Download`/`Movies`
  links keep working.

## 3. Results

| Test            | Desktop (Fedora)         | Steam Deck   | Notes                                                                                                                                                                                                                                                    |
| --------------- | ------------------------ | ------------ | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Host test       |                          |              | Round 2: record the PASS/SKIP lines                                                                                                                                                                                                                      |                                                                                                                                                                                                                                                          |
| T1 default      | Works                    | Works        |                                                                                                                                                                                                                                                          |
| T2 none         | Works, read/write access (re-check: see T2) | Works        | lrwxrwxrwx 1 root root  24 2026-11-26 10:38 Documents -> /home/paulwork/Documents<br />lrwxrwxrwx 1 root root  24 2026-11-26 10:38 Download -> /home/paulwork/Downloads<br />lrwxrwxrwx 1 root root  21 2026-11-26 10:38 Movies -> /home/paulwork/Videos |
| T3 some folders | Not recorded             | Works        | FEATURE: User should be allowed to link any shared folder into the container. Should accept full path and mount in the home folder of android using the child dir as the name.                                                                           |
| T4 back on      | Works                    | Works        |                                                                                                                                                                                                                                                          |
| T5 invalid      | Works,see feature        | Works        |                                                                                                                                                                                                                                                          |
| T6 lepton-play  | Seems to work            | Works        |                                                                                                                                                                                                                                                          |
| T7 regression   | Didn't test              | Didn't test  |                                                                                                                                                                                                                                                          |
| T8 Google Play  | Didn't test              | Didn't test  |                                                                                                                                                                                                                                                          |
| T9 questions    |                          |              |                                                                                                                                                                                                                                                          |
| T10 ~/Books     |                          |              |                                                                                                                                                                                                                                                          |
| T11 spaces      |                          |              |                                                                                                                                                                                                                                                          |
| T12 SD card     | n/a                      |              |                                                                                                                                                                                                                                                          |
| T13 ext. drive  |                          | n/a          |                                                                                                                                                                                                                                                          |
| T14 several, ro |                          |              |                                                                                                                                                                                                                                                          |
| T15 changes     |                          |              |                                                                                                                                                                                                                                                          |
| T16 mistakes    |                          |              |                                                                                                                                                                                                                                                          |
| T17 apps        |                          |              |                                                                                                                                                                                                                                                          |
| T18 profiles    |                          |              |                                                                                                                                                                                                                                                          |

## 4. Clean up

```bash
rm -f ~/Documents/lepton-test-host-Documents.txt ~/Downloads/lepton-test-host-Downloads.txt \
      ~/Videos/lepton-test-host-Videos.txt
# Round 2 folders: check they hold only test files before removing them
ls -la ~/Books ~/Books2 "$HOME/My Comics" "$SD/Films" "$USB/Films"
```

Remove the test shortcuts in Steam. To delete their Android data, remove
their `compatdata/<AppID>` folders, or `~/.local/share/lepton-compat-data/<package>`
for `lepton-play`, with `podman unshare rm -rf PATH`.
