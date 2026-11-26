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

> Round 1 Fedora note: the listing recorded for T2 was taken with sharing
> on (default), to show the links' permissions. It is not a T2 result; T2
> itself passed.

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

### Round 3: five default folders, XDG folders, safety

Round 3 bundle: same command as above with `--bundle-id v0.4.0-shared-folders-3`
(tool `lepton_x86_64_v0_4_0_shared_folders_3`). It changes, compared with
round 2:

- Defaults are five folders: Documents, Downloads, Videos, **Music** and
  **Pictures**, taken from `~/.config/user-dirs.dirs` when it sets them
  (translated or moved folders), otherwise `~/Music` etc. Missing ones are
  not created.
- Every shared folder, default ones included, is now mounted at
  `/lepton/shared/<Name>`; the link in `/data/media/0` points there. Links
  made by round 1/2 (`Download -> /home/<you>/Downloads`) are replaced at the
  next launch; the log says `link updated`.
- `Music`, `Pictures`, `Documents`, `Download`, `Movies` can be given to a
  path (`Music=/mnt/Media/Music`) in place of the default; only `Android`
  is refused.
- More folders are refused: `/home`, `/var` (other than `/var/home`,
  `/var/mnt`), `/mnt` and `/run/media/<user>` themselves, hidden folders in
  your home (`~/.ssh`, `~/.local`, ...), and Lepton's own data and
  installation.

In the inspection commands, the mount list now shows
`<host folder> -> /lepton/shared/<Name>` for the default folders too, and
`grep -E 'Shared folder|shared folder|link updated'` covers the new
messages.

Check what your desktop has configured first, and record it in the notes:

```bash
cat ~/.config/user-dirs.dirs 2>/dev/null | grep -v '^#'
for d in DOCUMENTS DOWNLOAD VIDEOS MUSIC PICTURES; do printf '%s: ' $d; xdg-user-dir $d; done
```

#### T19. Five default folders on an existing profile

Use a shortcut that ran with round 1 or 2 and the default setting (the file
manager from T1). Put a marker in Music and Pictures first:
`echo host > ~/Music/lepton-test-music.txt; echo host > ~/Pictures/lepton-test-pictures.txt`.

- [ ] Launch with no option. All five are links to `/lepton/shared/<Name>`;
  the log shows `link updated` for Documents, Download and Movies, once.
- [ ] `Music` and `Pictures`: if Android's own folders were empty, they are
  now links and the file manager shows the marker files. If either held
  files (a game's saves or screenshots), it is kept, the log says
  `Shared folder Music not linked ... has files, so it is kept`, and the
  game starts. Record which happened.
- [ ] Launch again: no `link updated`, nothing changes.
- [ ] `LEPTON_SHARED_FOLDERS="Documents Videos Downloads"` (round 1's three):
  Music and Pictures go (`Shared folder off: Music ...`), the others stay.

#### T20. XDG folders

Desktop. Do this with a copy of the file and restore it afterwards:
`cp ~/.config/user-dirs.dirs ~/user-dirs.dirs.bak`. Log out and back in is
not needed: Lepton reads the file at each launch.

1. Moved folder: `mkdir -p ~/Media/Tunes`, set
   `XDG_MUSIC_DIR="$HOME/Media/Tunes"`, launch with no option.
   - [ ] `Music` shows `~/Media/Tunes`.
2. Folder on another drive: set `XDG_PICTURES_DIR="/run/media/$USER/<drive>/Pictures"`
   (make it first), launch.
   - [ ] `Pictures` shows the drive's folder. Unplug the drive, launch: the
     game starts, `Pictures` keeps its link, nothing is created at that path.
3. Turned off: set `XDG_VIDEOS_DIR="$HOME/"`, launch with no option.
   - [ ] `Movies` is not shared; the log warns `your Movies folder is set to
     your home folder`; the mount list has no mount of your home folder.
   - [ ] With `LEPTON_SHARED_FOLDERS=Videos` the launch stops with that
     message instead, and nothing changes.
4. Protected: set `XDG_DOCUMENTS_DIR="/etc"`, launch with no option.
   - [ ] `Documents` is not shared, with a warning; the game starts.
5. Translated names, if you have a non-English desktop or can set
   `XDG_DOWNLOAD_DIR="$HOME/Téléchargements"` (make it first):
   - [ ] `Download` shows that folder.

Restore: `mv ~/user-dirs.dirs.bak ~/.config/user-dirs.dirs`.

#### T21. Music and Pictures as custom names (round 2 settings)

- [ ] A shortcut set to `"~/Music,~/Pictures"` in round 2 still starts, with
  both shared.
- [ ] `"Music=$HOME/Media/Tunes"` shares that folder as `Music`, in place of
  `~/Music`.
- [ ] `"Music,~/Music"` stops the launch: `Music is already used by another item`.

#### T22. Safety

Each must stop the launch with the message shown, and change nothing:

- [ ] `"Keys=~/.ssh"`: `inside a hidden folder of your home`.
- [ ] `"/home"` and (Fedora Atomic / Deck) `"/var/home"`: `holds your whole home folder`.
- [ ] `"/run/media/$USER"`: `lists whole drives`. `"/run/media/$USER/<drive>"`
  is accepted.
- [ ] `"/var/log"`: `is a system folder`.
- [ ] A link to a protected folder: `ln -s ~/.ssh ~/Keys`, then `"~/Keys"`:
  refused like `~/.ssh`. Remove `~/Keys` afterwards.

#### T23. Media apps and file pickers

A local test found that Android's media index (used by gallery, music and
video apps) lists no files from shared storage at all on this image, not
even from Android's own `DCIM`, so it isn't caused by shared folders. This
test records what that means for real apps. Use a game or app with a file
picker, and if you can, a gallery and a music app (e.g. from F-Droid: Aves,
Fossify Gallery, Fossify Music Player, VLC).

- [ ] File manager with all-files access: sees files in Music, Pictures,
  Movies and a custom folder.
- [ ] An app's file picker (Android's "Open from" screen): can you browse to
  `Pictures` and pick a file? Do the "Images"/"Audio"/"Recent" views show
  anything?
- [ ] Gallery app: does it list `Pictures`? Music app: does it list songs in
  `Music`? VLC (which can also browse folders): does its Video/Audio view
  list `Movies`/`Music`; does its folder browser?
- [ ] Take a screenshot or save an image from an app into `Pictures`: does a
  gallery app then show it? (Files created by apps through Android may be
  indexed even though existing files are not.)

#### Round 3 results

| Test | Desktop (Fedora) | Steam Deck | Notes |
| --- | --- | --- | --- |
| Host test | PASS (SKIP /mnt) | | Intel Fedora 44, `lepton-play` + Material Files, 2026-11-26 |
| T19 five defaults | Works (fresh profile) | Works (-2 profile to -4) | All five linked to `/lepton/shared/<Name>`, markers visible, Android writes reach the host as the user; user checked in the file manager. Upgrade of a round 1/2 profile not tested here. Deck: a round 2 profile started on -4 without a reset; `link updated` once each for Documents, Download, Movies; second launch quiet. Going back from -4 to -2 stops with `unexpected storage link` (round 2 doesn't know the new links): safe, not supported. A profile from another build (an uninstalled tool, fingerprint `fb9fe3c1`) needed `LEPTON_RESET_APP_DATA`, as expected |
| T20 XDG | Works | n/a | Moved Music (`~/Media/Tunes`), translated Download (`~/Téléchargements`) shared; `XDG_VIDEOS_DIR=$HOME/` warns and skips Movies, `=Videos` stops the launch; `XDG_DOCUMENTS_DIR=/etc` warns, game starts. Folder "unplugged" (renamed): game starts, Pictures link kept, nothing created, but no log message (custom folders get `is not there`). No real drive: used `~/lepton-drive`; a `/var/tmp` path was refused as a system folder, as documented |
| T21 custom Music | Works | | `~/Music,~/Pictures` shared; `Music=~/Media/Tunes` replaces Music; `Music,~/Music` stops: `already used by another item` |
| T22 safety | Works | | `Keys=~/.ssh`, `/home`, `/var/log`, link `~/Keys -> ~/.ssh` stop the launch, nothing changed. `/var/home` and `/run/media/$USER` don't exist here: warned `is not there` and launched, so their refusal is untested on this machine |
| T23 media apps | | | |

### Round 4: folders are added to the defaults; clearer popups

Round 4 bundle: `--bundle-id v0.4.0-shared-folders-5` (tool
`lepton_x86_64_v0_4_0_shared_folders_5`). It changes, compared with round 3:

- Folders you give are **added** to the five default folders. Naming default
  folders (`Music,Pictures`) still shares only those, and `none` none:
  `"Books"` and `"/run/media/deck/SD/Films"` keep all five defaults;
  `"Downloads,Books"` shares Download and Books; `"none,Books"` only Books.
  Round 2/3 tests that expect the defaults to go when only a path is given
  (T10, T14, T15) now see them stay.
- A name alone that isn't a default folder is a folder in your home:
  `Books` is `~/Books`, `My Comics` (with its space) is `~/My Comics`. It
  must exist, so a misspelt default (`Picture`) stops the launch.
- A launch stopped by the setting shows the problem in the popup: each
  problem from the log, the value used, and where to fix it.

#### T24. Adding folders

- [ ] `LEPTON_SHARED_FOLDERS=Books` (make `~/Books` first): Books and all
  five defaults are shared.
- [ ] `"/run/media/deck/<card>/Films"`: Films and the five defaults.
- [ ] `"My Comics"` with quotes (make `~/My Comics`): shared as `My Comics`.
- [ ] `"Downloads,Books"`: only Download and Books. `"none,Books"`: only Books.

#### T25. Popups

Each must stop the launch and show a popup naming the problem, the value
and Properties > General > Launch Options; nothing changes:

- [ ] `Picture` (a typo): `there is no folder Picture in your home folder`.
- [ ] `"/etc,Android=~/Books"`: both problems listed in one popup.
- [ ] In Gaming Mode the popup is readable (size, line breaks).

#### Round 4 results

| Test | Desktop (Fedora) | Steam Deck | Notes |
| --- | --- | --- | --- |
| Host test | PASS (SKIP /mnt) | | |
| T24 adding | Works | Works | Deck, bundle -5: runs as expected. Intel, `lepton-play`: `Books`, `~/lepton-sf/Films` (defaults kept), `none,Books` (only Books) |
| T25 popups | Works | Works | Deck, bundle -5: error message clear in the popup. Intel desktop popup text checked: typo, and two problems in one popup with the value |

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
| T10 ~/Books | Works |              | `~/Books` and `$HOME/Books` (env, not Steam). Only Books shared; Android write reached host as the user. Documents/Download then missing from the profile (see notes below) |
| T11 spaces | Works |              | `~/My Comics` shared (quoted). Unquoted Steam form not tested (no Steam) |
| T12 SD card | n/a | Works | Deck, bundle -4. Expected the listed folder to be added to the defaults, and a bare home folder name to work: led to round 4 |
| T13 ext. drive  |                          | n/a          |                                                                                                                                                                                                                                                          |
| T14 several, ro | Works |              | Four shared; `My Comics:ro` rw=false, `(read-only)` logged, write and delete refused (Read-only file system), host unchanged; `Downloads:ro` read-only |
| T15 changes | Works |              | Off messages, `Library` rename and re-point, back to defaults, second default launch silent; own link `MyLink -> /tmp` kept |
| T16 mistakes | Works |              | Duplicate name, `Android=`, a file, `/etc`, `$HOME`, `/`, no comma, bad name all stop with unchanged storage. `Download=$HOME/Books` is now accepted (round 3 lets a path replace a default folder): update T16 |
| T17 apps        |                          |              |                                                                                                                                                                                                                                                          |
| T18 profiles    |                          |              |                                                                                                                                                                                                                                                          |

Findings from the Intel run (2026-11-26):

- When `Documents` or `Download` stops being shared, Lepton removes its link
  but no folder replaces it, and Android doesn't recreate these two (it does
  recreate Movies, Music and Pictures). Seen in round 1 too. The docs say
  Android keeps private folders; the launcher should create the empty
  folders when it removes the links. **Fixed** in bundle
  `v0.4.0-shared-folders-4`: the launcher now makes an empty folder of
  Android's own for each default folder that is not shared. Intel check:
  `none` gives real, writable `Documents` and `Download`; back to the
  default, the empty one is replaced by the link, one with files is kept
  with the `not linked` message, and is linked once emptied.
- A default folder that is missing (drive unplugged) is skipped silently and
  its old link is left pointing at nothing; custom folders log `is not there`.
- `lepton-play` ignores Ctrl-C when started in the background by a script
  (bash ignores SIGINT in background jobs); `kill` (TERM) stops it cleanly
  in about 5 s.

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
