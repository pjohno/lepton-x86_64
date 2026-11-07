# Pending tests for `feature/release-framework`

Delete this file when the branch is merged into `main`.

## Release framework (branch `feature/release-framework`)

Automated tests cover the logic. These need a real Steam Deck and GitHub:

1. **Dolphin and downloaded installers.**
   - On the Deck, download the three release files with the browser.
   - Confirm that double-clicking the `.install.sh` opens it as text, since the
     downloaded file isn't executable.
   - Confirm that **Open Terminal Here** + `bash …install.sh` works.
   - Confirm that **Properties > Permissions > Is executable**, then
     double-click and **Execute**, opens Konsole and installs. Note the exact
     wording Dolphin shows.
2. **A real draft and publish** with `publish-release.sh` and a real `gh`, on a
   test version such as `v0.0.1-alpha.test`.
   - The repository must be **public** for users and the release manager to see
     releases. The API currently answers 404 for `pjohno/lepton-x86_64`.
   - Check the uploaded file sizes and digests, then delete the test release
     and its tag.
3. **Lepton: Install / Update / Repair on the Deck:**
   - the menu;
   - a zenity progress bar during the download;
   - the unsigned-release warning;
   - install alongside, replace (the tool ID is kept), downgrade warning;
   - repair;
   - the cleanup prompt;
   - that Konsole shows the installer and the manager continues after it
     closes.
4. **Signing:** generate the real release key, commit it to `allowed_signers`,
   publish a signed test release, and confirm the manager verifies it. Then
   confirm it refuses a release with the signature file removed.
5. **Manager independence:** remove every install with **Lepton: Remove
   installs**. **Lepton: Install / Update / Repair** must still be on the desktop
   and still open.
