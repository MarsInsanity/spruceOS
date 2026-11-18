# Working on this fork (MarsInsanity/spruceOS)

## The `mofang` branch: merge upstream first, every time

`mofang` is spruce for the Retroid Pocket Mini V2 on LightMoss (platform `RPMiniV2`, files under
`spruce/scripts/platform/lightmoss/`). Work on `mofang` itself; do not create other branches for it.

**Every time you work on `mofang`, before anything else, merge upstream spruceUI/spruceOS `Development`
into it**, and push the merge with your work:

```sh
git remote get-url upstream >/dev/null 2>&1 || git remote add upstream https://github.com/spruceUI/spruceOS
git fetch upstream Development
git checkout mofang && git pull --ff-only origin mofang
git merge --no-ff upstream/Development -m "Merge upstream spruceUI/spruceOS Development into mofang"
```

In a shallow clone, if git finds no merge base, deepen both sides first
(`git fetch --depth=1000 origin mofang` and `git fetch --depth=1000 upstream Development`).

After the merge:
- Resolve conflicts by keeping upstream's change and the RPMiniV2 port's behaviour together; never drop RPMiniV2 code
  to make a merge go through.
- Even without conflicts, check whether upstream changed what the RPMiniV2 port builds on or overrides:
  `spruce/scripts/platform/darkmoss/dArkMossCommon.sh`, `spruce/scripts/platform/device.sh`,
  `spruce/scripts/helperFunctions.sh` (the `RPMiniV2)` entry of `device_names`), `App/PyUI/launch.sh`,
  `App/PyUI/spruce-device-env.sh`, `App/PyUI/main-ui/devices/env/env_var_device.py`,
  `App/PyUI/main-ui/controller/touch_watcher.py`, `spruce/scripts/asound-setup.sh`, `spruce/scripts/bluetooth.sh`,
  `spruce/scripts/emu/lib/*_functions.sh`, `Saves/spruce/spruce-config.json`
  (`git diff <old merge base> upstream/Development -- <file>`). A function RPMiniV2 overrides that upstream renamed
  or changed in meaning is a silent break.
- Check: `busybox sh -n` (and `shellcheck -s sh -S error`) on changed shell scripts, `jq empty` on changed JSON,
  `python3 -m py_compile` on changed PyUI files. Some PyUI files use CRLF line endings: keep them byte for byte.

Push only to `origin` (this fork), never to spruceUI, and open no pull requests upstream. A push to `mofang` publishes
the `RPMiniV2` pre-release (`.github/workflows/rpminiv2-test-build.yml`); keep spruce releases from this fork
pre-releases, since a full release triggers `update-ota-on-publish.yml`, which writes to upstream's OTA repositories.
