# Native Python source owner (integration candidate)

`ios/Classes/MMPythonOwner` is the reusable native ownership component, not yet a
registered Flutter plugin or a production source backend. `CmsClient` does not
select it. The disposable iOS experiment compiles these exact files and records
their hashes separately from its fixture adapter.

`MMPythonSourceRegistry` now accepts a generic memory package through
`python.open/call/cancel/close`, using the shared Dart `PythonSourceChannel` and
`PythonSourceSessions`. Packages are typed byte maps rather than native fixture
identifiers. The trusted `native_source_entry.py` constructs the shared loader;
source import and initialization still occur inside the first operation budget.
`MMPythonTransport` binds callbacks to a native-selected owner and active call,
clamps HTTP waits to the remaining native deadline, and rejects callbacks for
cancelled or replaced operations. The registry bounds live owners and closing
records. Failed opens destroy their interpreter before returning the failure.

The generic package path is compiled/exercised by the disposable app but still
requires production runtime initialization, framework staging and backend selection.
Its additional acceptance checks must be recorded before claiming runtime proof.

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
exceptions. Production runtime initialization, protocol registration, source
package preparation, dependency selection, signatures and physical iPhone
acceptance are still required before this component can serve user subscriptions.
