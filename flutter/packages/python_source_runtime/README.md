# Native Python source owner (integration candidate)

`ios/Classes/MMPythonOwner` is the reusable native ownership component. The package
now registers `MMPythonRuntimePlugin`, initializes Python off the UI thread only
when requested, and exposes the same generic channel used by the disposable iOS
experiment. `CmsClient` now selects it for detected Python sources on iOS;
Android and desktop keep their existing backend. These exact native files are
compiled by the experiment and recorded separately from its fixture adapter.

`MMPythonSourceRegistry` now accepts a generic memory package through
`python.open/call/cancel/close`, using the shared Dart `PythonSourceChannel` and
`PythonSourceSessions`. Packages are typed byte maps rather than native fixture
identifiers. The trusted `native_source_entry.py` constructs the shared loader;
source import and initialization still occur inside the first operation budget.
`MMPythonTransport` binds callbacks to a native-selected owner and active call,
clamps HTTP waits to the remaining native deadline, and rejects callbacks for
cancelled or replaced operations. The registry bounds live owners and closing
records. Failed opens destroy their interpreter before returning the failure.

`scripts/prepare_ios_python_runtime.py` stages the pinned iOS framework, standard
extensions, reviewed pure dependencies and trusted source loader before linking;
it embeds these files before the final application's target validation/signing.
The existing product build invokes both steps. Stage integrity is checked before
embedding, and no experiment fixture or launch metadata enters the app.
The registered plugin and shared initializer passed 138 checks in each startup
order on an ARM64/iOS 18.5 simulator (`e76008b`, run `42458771800`, 150 matching
input hashes). The full product build is a separate gate. New backend selection,
remote module resolution and actual user subscription/device validation require
their own acceptance; installation alone is not playback proof.

The full iOS/iPadOS product build at `c9a7f9e` passed in run `42459776454` after
the screen-operation cleanup fix. All 322 Flutter tests passed. The downloaded
57,957,674-byte IPA and its legacy filename alias have the same SHA-256:
`2c5c65ba400acaf8ed4e9f92c6de0df61d4ed76ce35878c0b6b70f8bede56905`.
Inspection matched 2,659 bundled Python/dependency files and seven runtime input
hashes, found both Python and Node plugins, excluded experiment fixtures, and
checked 106 ARM64 device binaries against the iOS 14 deployment requirement.
CI also ran the application's deployment/signature validation. This is an
unpublished integration artifact from before `CmsClient` selected native Python;
it does not contain the subsequent dispatch changes or prove physical playback.

Remote packages can now explicitly supply the entry URL and source headers.
Missing sibling modules are fetched only after installed Python modules have
been considered, within the current source operation and package byte limits.
Relative imports, deferred detail imports and remote resource reads are cached
for that source lifetime. Subscription headers are inherited only on the same
origin, explicit source headers win, and redirected credentials are stripped.
Local packages never opt into network module lookup. These additions have local
host/channel coverage; the added actual-iOS checks are pending acceptance.

The product dispatcher recognizes Python content even behind PHP/extensionless
URLs, checks the native capability contract before opening a source, preserves
raw extensions and archive bytes, and reuses the same owner across catalogue,
detail and playback. Removal revokes the source and its local proxy immediately;
errors never replay source code in another engine. Local package `open`/`io.open`
use read-only buffers with CPython text codecs, entry-relative paths and sibling
imports. The 19-case local host suite passes 213 checks, including the existing
independent package I/O oracle; seven Flutter dispatch tests cover the CMS route
with a mock native channel. Actual iOS execution of these new changes is a
separate pending check. This branch is not an iPhone release.

The preceding generic-channel implementation (`2b0fa96`) passed 137 checks in
each startup order on an ARM64 iOS 18.5 simulator in run `42457911248`: 274 checks
and 146 exact-commit input hashes were audited. This covers the supplied test
package's catalogue, search, detail, 1.28 MB binary proxy, cancellation and owner
recovery. It does not prove arbitrary user sources or physical iPhone playback.

Each owner creates its bootstrap thread state on its own OS thread, then creates
one own-GIL subinterpreter. Trusted host callbacks create, invoke and dispose the
source only on that thread. No Python objects cross owners. Pending work is
bounded to four including the running call, JSON input to 64 KiB, and call
budgets to 45 seconds including queue time. Call IDs must be unique for the
owner lifetime; the caller generates secure random 128-bit identities.

Queued cancellation does not interrupt a different active call. Active
cancellation marks the result obsolete and invokes the host transport interrupt.
The enclosing registry retires that owner. Close rejects new work, cancels queued
work, waits for actual running execution, disposes the source, and destroys the
interpreter before acknowledging completion. Capacity cannot be reused just
because a Dart timeout or cancellation returned. A permanently blocked C call
continues consuming its slot. This is not hard termination or a security sandbox.

The process main interpreter must remain alive until every owner is destroyed.
The callbacks are trusted native host code and must not throw Objective-C
exceptions. Additional source dependencies, actual user subscriptions and
physical iPhone acceptance remain required before claiming broad compatibility.
