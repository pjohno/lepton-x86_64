# Pending tests: shared folders (issue #37)

Manual tests for branch `fix/shared-folders-37`, on a Fedora desktop and a
Steam Deck. Delete this file, or move its results into the pull request,
once every test is done.

What the branch changes:

- `LEPTON_SHARED_FOLDERS` launch option: which host folders Android sees in
  shared storage. Values are `Documents`, `Downloads` and `Videos` (Android
  names `Documents`, `Download` and `Movies` also work), separated by commas
  or spaces, or `none`. Unset keeps the old behaviour: all three, read-write.
- `lepton-play` profiles get working shared storage. Before the fix,
  `/data/media/0` pointed at an unmounted folder, so these profiles had no
  shared storage and no OBB link.

## 1. Setup

### Build a test bundle

Only launcher scripts changed, so repackage the existing `v0.4.0-test` stage
with this branch's scripts. This doesn't rebuild Android or redo the sysbake.

```bash
git switch fix/shared-folders-37
source .build-env
bash image-14/scripts/internal/deploy-compat-x86_64.sh --package-only --execute \
  --stage-dir "$LEPTON_OUTPUT_DIR/stages/v0.4.0-test" \
  --bundle-dir "$LEPTON_OUTPUT_DIR/bundles" \
  --bundle-id v0.4.0-shared-folders
```

Install it with its `.install.sh` on the desktop and the Deck, as the user
who will run the tests. Select it as the compatibility tool of each shortcut
you test.

Run the host test once from the checkout. It needs no Android:

```bash
bash tests/test-shared-folders.sh      # expect: PASS
```

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

# Host folders mounted into the container
podman inspect "$C" --format '{{range .Mounts}}{{.Source}}{{"\n"}}{{end}}' |
  grep -E "^$HOME/(Documents|Downloads|Videos)$|/external$"

# What Android's shared storage holds (links point at host folders)
podman exec "$C" /system/bin/sh -c 'ls -la /data/media/0/; ls /storage/emulated/0/'

# Launcher messages about shared folders
grep -E 'Shared folder|LEPTON_SHARED_FOLDERS|not linked|left unchanged' "$LOG"
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

- [ ] Host folder modes: `stat -c '%a %n' ~ ~/Downloads ~/Documents ~/Videos`.
  Typical values: Fedora 750 or 700, Deck 755.
- [ ] With default sharing, can the file manager (all-files access) read
  **and write** host Downloads? Compare the desktop with the Deck; the
  guess is that 750 folders block Android's storage service.
- [ ] Did Lepton's own grant work? Run `appops get <package> MANAGE_EXTERNAL_STORAGE` for an app that requests all-files access,
  before running `appops set`.
- [ ] Deck: does the container expose more of the home folder than expected?
  `podman exec "$C" ls -la /home/deck /home/deck/.local/share`.

## 3. Results

| Test            | Desktop (Fedora)         | Steam Deck   | Notes                                                                                                                                                                                                                                                    |
| --------------- | ------------------------ | ------------ | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Host test       |                          |              |                                                                                                                                                                                                                                                          |
| T1 default      | Works                    | Works        |                                                                                                                                                                                                                                                          |
| T2 none         | Works, read/write access | Works        | lrwxrwxrwx 1 root root  24 2026-11-26 10:38 Documents -> /home/paulwork/Documents<br />lrwxrwxrwx 1 root root  24 2026-11-26 10:38 Download -> /home/paulwork/Downloads<br />lrwxrwxrwx 1 root root  21 2026-11-26 10:38 Movies -> /home/paulwork/Videos |
| T3 some folders |                          | Works        | FEATURE: User should be allowed to link any shared folder into the container. Should accept full path and mount in the home folder of android using the child dir as the name.                                                                           |
| T4 back on      | Works                    | Works        |                                                                                                                                                                                                                                                          |
| T5 invalid      | Works,see feature        | Works        |                                                                                                                                                                                                                                                          |
| T6 lepton-play  | Seems to work            | Works        |                                                                                                                                                                                                                                                          |
| T7 regression   | Didn't test              | Didn't test  |                                                                                                                                                                                                                                                          |
| T8 Google Play  | Didn't test              | Didn't test  |                                                                                                                                                                                                                                                          |
| T9 questions    |                          |              |                                                                                                                                                                                                                                                          |

## 4. Clean up

```bash
rm -f ~/Documents/lepton-test-host-Documents.txt ~/Downloads/lepton-test-host-Downloads.txt \
      ~/Videos/lepton-test-host-Videos.txt
```

Remove the test shortcuts in Steam. To delete their Android data, remove
their `compatdata/<AppID>` folders, or `~/.local/share/lepton-compat-data/<package>`
for `lepton-play`, with `podman unshare rm -rf PATH`.
