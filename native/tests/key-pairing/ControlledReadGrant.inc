// Replacement for ONLY the existing synchronous READ rejection block in the
// generated ProductHostFixture.h used by these standalone controlled modes.
// Add `bool selectionProbeRead = false;` to Context's public host controls.
// This is not a range-gravity model and must not run the original 259 suite
// with the option enabled. No product state is installed by this host branch.
if ((flags & TF_ES_SYNC) && (flags & TF_ES_READWRITE) == TF_ES_READ) {
  if (!selectionProbeRead || grantingStore) {
    *result = TF_E_SYNCHRONOUS;
    return S_OK;
  }
  Store* previous = grantingStore;
  grantingStore = store.get();
  try { *result = session->DoEditSession(store->cookie); }
  catch (...) { grantingStore = previous; throw; }
  grantingStore = previous;
  return S_OK;
}
