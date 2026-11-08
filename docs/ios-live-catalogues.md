# iOS script live catalogues — integration status

The Flutter client now connects TVBox `lives[].api` to the existing retained
JavaScript/Python source owner through `liveContent(url)`. The URL argument stays
opaque; it is not downloaded as a catalogue when a script fails. iOS selects the
native Python host; other Flutter platforms keep their existing host selection.

Implemented paths:

- API-only live entries, relative script/extension references, per-entry or
  inherited plugin declarations, isolated identities for same-name entries.
- JavaScript/Python entries in a ZIP configuration, with package resources and
  the original live argument preserved.
- Inline JSON groups/channels, script-returned JSON or TXT/M3U, and TVBox's
  explicit Base64 live-directory wrapper, including nested groups.
- Source/group/channel/individual-stream headers, case-insensitive overrides,
  relative media/logo URLs, M3U VLC headers, TXT fallback URLs and URL fragments.
- HTTP redirects use the final catalogue URL. Credentials removed during a
  cross-origin redirect are not restored to that destination's media requests.
- The player pins the actual script owner and preserves stream headers. Owned
  proxy playback carries upstream Origin as private transport metadata; deleted
  subscriptions revoke their old proxy addresses. Privacy locking includes live
  owners as well as VOD owners.

Validation is split deliberately: local Flutter tests exercise import, storage,
decoding, the production QuickJS runtime, source-owned loopback playback and
revocation; native-dispatch tests exercise the production Dart/native bridge
contract with an owned native-channel fixture. Existing iOS simulator evidence
separately exercises actual CPython `liveContent` text/JSON and proxy lifecycles.
These checks do not establish playback of every third-party channel on a physical
iPhone. Android JAR entries without a portable adapter remain explicitly
unsupported; retaining their definitions does not claim they execute on iOS.

No public iPhone package is released by this change. Physical playback and the
remaining third-party dependency/adapter work remain release acceptance gates.
