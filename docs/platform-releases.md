# Independent platform releases

The owner allows each platform to release independently after its own checks. Version numbers do not have to match. A release must name its platform, build commit, tested fixes and remaining limitations.

**iPhone stable publication remains on hold:** the owner subsequently requires all requested subscription types and plugin routes to work before an iPhone release. The 0.5.1 iOS workflow artifact is validation-only. Do not create a stable iOS release or change its stable update feed until the requested import, catalogue, search, detail and playback paths work independently on that platform. UI tests and a successful IPA build alone do not meet this gate. The 33 outstanding Guard plugin ports remain incomplete.

On November 8 the owner explicitly requested syncing the current iOS validation package to GitHub and the mirror. [iOS 0.5.1 preview](releases/ios-v0.5.1-preview.md) is therefore published as `ios-v0.5.1-preview`, with prerelease status and a separate preview download. This exception does not claim full source compatibility or open the stable iPhone publication gate. Other platform packages and mirror styles are unchanged.

Desktop/Apple tags use `windows-vX.Y.Z`, `ios-vX.Y.Z` and `macos-vX.Y.Z`. They do not trigger the legacy `v*` all-platform publisher. Build the desired platform with the existing workflow dispatch, verify the artifact, and attach the package, SHA-256 file and corresponding source archive before publishing. Do not replace existing versioned assets. Keep the legacy all-platform release as GitHub's global latest so old clients are not directed to another platform's package.

Android phone/tablet and TV editions now have separate update feeds and explicit
`android-mobile` / `android-tv` package names. See [Android update isolation](android-update-isolation.md)
for the release tags, old-client migration aliases and runtime verification scope.
Android phone/tablet and TV 0.5.1 were independently published on November 8;
see the platform-specific records below.

See [installation package names](installation-package-names.md) for explicit
system/device and installer/portable labels across all platforms. Old-name assets
remain byte-identical compatibility aliases; mirror sync prefers the clear name
when that release actually supplies it, without changing the page layout.

Clients from 0.5.1 first read their own `movie/updates/{platform}.json` feed, then select the newest matching official GitHub release containing that platform's package. Other platform versions, drafts and prereleases are ignored. Clients at 0.5.0 still use the legacy shared feed; install the first independent platform update from the download page, then subsequent updates use the new platform feed.

The mirror runs `scripts/sync_platform_packages.py`. It patches existing download-card package URLs, byte sizes and hashes, writes the relevant platform feed, and updates only the existing changelog section with version-specific notes. It does not render a new HTML page or alter CSS, layout, images, unrelated prose/packages or legacy Android update channels. Large files retain the site's existing verified GitHub download behavior. Corresponding source remains attached to each platform's release.

## Required notes for every update

For each actual platform release, add a `docs/releases/{tag}.md` record and a platform/version entry in `CHANGELOG.md`. Use that reviewed record as the GitHub Release body. Name the platform, version, release date, additions, fixes, test scope, remaining limitations, and exact build commit. Describe only changes included in that package: an iOS build must not claim a later Android fix or unfinished plugin port. Unreleased work stays explicitly unreleased.

The mirror keeps the same complete Release body in the platform feed and `movie/updates/history/{tag}.md`, indexes versions in `movie/updates/history.json`, and shows them inside the existing changelog section. It retains older records across updates and labels preview releases separately. A new independent official release with an empty body is rejected before any mirror file is written. Updating notes does not replace package bytes, hashes, styling or other platforms' downloads. Verify the published text and platform/version mapping on GitHub and the live mirror after each release.

On November 7 the owner separately authorized a mirror layout revision. The
Movie page now puts downloads before the changelog, shows each package's own
version, supports platform filters and collapses historical entries. Release
Markdown is rendered as escaped headings, lists and paragraphs while the full
original text stays archived. Future automatic package updates preserve this
layout and update the visible version together with the package URL and hash.

The layout was deployed from mirror commit `acf776a`. Checks retained all eight
package/checksum URLs and hashes plus 47 historical release records. The live
375-pixel and 1280-pixel layouts, download and release filters were verified;
13 sync/rendering tests passed. [The subsequent automatic-sync
run](https://github.com/Pilipala9919/mtv/actions/runs/42381304827) also passed.
This website deployment did not replace any application installer.

## Published Android maintenance update

[Android phone/tablet 0.5.1](releases/android-mobile-v0.5.1.md) and
[Android TV/box 0.5.1](releases/android-tv-v0.5.1.md) use build commit
`c10becae6aea8506858a8076b7938a196d6300b8` (version code 51).
The scoped release ships adaptive phone landscape controls, Android 6 subtitle
compatibility, history/search fixes, source-host improvements and isolated edition
updates. Complete build 42449618961 and runtime packaging run 42449705860 passed.
The downloaded CI packages were signed with the existing official key; every
non-signature ZIP entry was retained, production host assets were checked against
the exact build commit, and native runtime provenance and alignment were verified.
The phone APK passes whole-package 16KB checks; the TV APK remains ARM 32-bit.

Both releases include matching source archives, SHA-256 files and byte-identical
legacy aliases. They do not replace the legacy global latest release. Users on
0.5.0 must manually select the correct device package once; thereafter each
edition follows its own update feed. The mirror receives the same version notes
and package links without changing its styles or other platforms' installers.
Automated/emulator/package checks are not universal physical-device playback
acceptance. The 33 outstanding plugin-route acceptances, full native Python
support and the iPhone publication gate remain open.

## Published Windows update

[Windows 0.5.1](https://github.com/Pilipala9919/MarcoMovie/releases/tag/windows-v0.5.1) was published from `56b2eb80b93bae98b8754952d779bff1b7a9582a` after [build 42356451432](https://github.com/Pilipala9919/MarcoMovie/actions/runs/42356451432) passed 83 Flutter tests and produced the installer/portable packages. Downloaded packages passed checksum/ZIP checks, the app and installer report 0.5.1, and all six uploaded package/source/checksum files match the local verified bytes. Native fullscreen UI evidence is recorded in `desktop-fullscreen-2026-11-07.md`.

The mirror deployment at commit `fe533ad` passed Cloudflare Pages checks. Live checks confirmed the two Windows download URLs, SHA-256 files and platform update feed. Existing CSS, the iPhone 0.5.0 download and legacy Android update channel are unchanged. No iPhone 0.5.1 release was created; its workflow artifact remains validation-only under the gate above.

## TV seek follow-up

Remote left/right taps remain 15 seconds. After a 500 ms hold delay, preview speed starts at 30 playback seconds per held second and increases linearly by 30 per second, capped at 240. The target uses elapsed time rather than key-repeat counts. Release commits the target once; cancel/back aborts, reversing direction resets acceleration, and targets clamp at the media boundaries. The status displays the current preview speed. Twenty-four seek checks cover the curve, cap, jitter, symmetry, cancellation and boundaries; this is not physical remote acceptance.
