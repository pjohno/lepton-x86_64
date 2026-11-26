# Isolated Android 14 sysbake on Fedora / Ubuntu x86_64

This is the development-host replacement for `.ci_scripts/build-sysbake-14.sh`.
Do **not** run the upstream CI script on an existing host: it contains
`podman system reset --force`, system-wide cgroup changes, and sudo commands.

The runner needs a previously staged Android 14 x86_64 rootfs and compatibility
tool, including provisioned `tools/bin/inotifywait`. It uses headless Weston
with Pixman; no logged-in graphical desktop is required. Android defaults to
software rendering (SwiftShader), independently of Weston. Optional
`--rendering amd` (RADV) or `--rendering intel` (ANV, Gen9 or newer) pins the
Android driver and requires that driver in the staged rootfs and an accessible
matching host GPU. The bundle wrappers expose this as
`--sysbake-rendering software|amd|intel`. Runtime GPU validation still applies;
unsupported hardware is never silently switched to software.

```bash
source .build-env
stage="$LEPTON_OUTPUT_DIR/stages/clean-ubuntu26"
bash image-14/scripts/internal/sysbake-isolated-x86_64.sh --check --stage-dir "$stage"
```

After reviewing `--check`, use `--execute` in a **tmux session** so an SSH
logout does not interrupt Android initialization:

```bash
bash image-14/scripts/internal/sysbake-isolated-x86_64.sh --execute --stage-dir "$stage"
```

The script does not use the ordinary Podman graphroot or runroot: it generates a
`podman` command wrapper with explicit `--root`, `--runroot`, and
`--storage-driver=overlay` / `fuse-overlayfs` flags, then checks the returned
storage directories before invoking Lepton. Rootless Podman still uses host
resources such as networking and the `lepton-sysbake.slice` user-systemd unit;
this is **storage and data isolation**, not a full VM or host isolation.

### Workspaces with POSIX ACLs

If the workspace (or any parent) has **default ACLs**, for example to give
another account read access, every new directory inherits them. Inside a
rootless user namespace those entries name unmapped UIDs, and Podman fails
with errors such as `creating /etc/mtab symlink: invalid argument` or
`get xattr system.posix_acl_access ... Invalid argument`.

* The fresh `.sysbake-work.*` directory and the private runroot are made
  private (mode 0700, no setgid, no access/default ACL) before anything is
  created in them. Only those new, empty directories are changed; the run
  stops if that cannot be done. `getfacl`/`setfacl` are not required.
* The staged rootfs is Lepton's `--rootfs …:O` lower layer under
  `--userns=keep-id`, so ACLs on it break the boot as well. The runner never
  modifies the stage: `--check` fails and lists affected paths. Recreate the
  stage in a folder without a default ACL (`mkdir DIR && setfacl -k DIR`).
  Don't strip the ACLs from an existing stage: `setfacl -b` rewrites each
  file's group permission bits from the ACL's group entry, so the rootfs no
  longer matches what the stage recorded and sysbake refuses it. Stage
  creation (`lepton-customize`, `inject --output-stage`, `restore`) and
  `make-deck-bundle-x86_64.sh` refuse such a location up front.

It copies the compat tool to an isolated work directory under the stage, but
**symlinks the staged rootfs** to avoid copying over 1 GiB of Android files.
The private launcher disables its normal management of the user's
`podman.service` and uses a private Lepton lock. `HOME` points to a private
empty directory, so `cleanup_all` cannot erase the user's existing Lepton
contexts. These launcher modifications affect only the disposable copy.

Outputs are published only after a successful boot and validation:

* `stage/compat_tool/sysbake/system/packages.xml`
* `stage/compat_tool/sysbake.xattrs`

Both Fedora-specific Ethernet paths must be absent from the published bake:

* `sysbake/misc/ethernet/ipconfig.txt`
* `sysbake/misc/apexdata/com.android.tethering/misc/ethernet/ipconfig.txt`

`security.selinux` host labels are deliberately excluded from the generated
xattrs file, and the file is checked with `setfattr --restore` before publish.

The per-run `.sysbake-work.*` directory (including `sysbake.log` and
`weston.log`) is **retained** for diagnosis. The script stops its Weston
process, tries to remove `lepton-sysbake` from its isolated Podman storage, and
stops only `lepton-sysbake.slice`. It does not prune or reset the user's Podman
store. A runroot with leftover metadata can also remain under
`$XDG_RUNTIME_DIR`; inspect before manual removal. Existing sysbake outputs
are never overwritten by the runner.

**Current status:** Script syntax verified, but the first Fedora Android boot
using this isolated runner must still be tested. The CI script's behaviour is
not a guarantee that rootless cgroup setup, filesystem permissions, and the
new Android build will all pass on Fedora.
