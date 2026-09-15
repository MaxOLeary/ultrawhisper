# Release checklist

Run through this before `--ship`. The failures here are quiet: a build that
looks fine and gets bounced by Gatekeeper on someone else's Mac.

## 1. Code is green

```sh
swift build -c release --arch arm64
```

- [ ] Builds clean, no warnings you have not read.

## 2. Repo is clean

- [ ] `git status` clean.
- [ ] Everything pushed (`git log origin/main..main` is empty).

## 3. Ship

```sh
./build.sh --ship
```

Read the three verdicts it prints:

- [ ] `Signing identity:` is `Developer ID Application: ...` or `Postit Dev`.
      Never `-`. The script refuses to ship ad-hoc, but look anyway.
- [ ] `codesign verify: OK`, then `flags=0x10000(runtime)` and an `Authority=` line.
- [ ] `spctl verdict` says `rejected` with `origin=Postit Dev` (today), or
      `accepted` once notarized. If it says `revoked`, stop. That is the
      Malware Blocked dialog nobody can click past, and it means the build
      went out unsigned.

## 4. It survives being downloaded

- [ ] Open <https://github.com/MaxOLeary/whisper/releases/latest/download/Whisper.zip>
      in Safari, unzip, double-click it once.
- [ ] Until notarized: the Open Anyway path in the README still matches
      what macOS shows. If the guide is wrong, the guide is the bug.
