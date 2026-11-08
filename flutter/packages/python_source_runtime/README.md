# Native Python source owner (integration candidate)

`ios/Classes/MMPythonOwner` is the reusable native ownership component. The package
now registers `MMPythonRuntimePlugin`, initializes Python off the UI thread only
when requested, and exposes the same generic channel used by the disposable iOS
experiment. `CmsClient` does not select it yet. These exact native files are
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
The new registered plugin/build integration still requires its own compiled and
runtime acceptance. Backend selection, remote module resolution and actual user
subscription/device validation remain open; installation alone is not playback proof.

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
exceptions. Source package preparation, backend selection, additional source
dependencies, signatures and physical iPhone acceptance are still required before
this component can serve user subscriptions.
