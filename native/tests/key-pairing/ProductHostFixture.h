#pragma once
// Controlled public TSF host primitives, reused from the prior product observer.
// These objects model locks/ranges/host callbacks only; delivery is the product.
#include "ResponseParser.h"
#include <algorithm>
#include <deque>
#include <fstream>
#include <functional>
#include <memory>
#include <stdexcept>
#include <string>
#include <vector>
namespace response_owner_product_fixture {
static unsigned hostCallbackDepth = 0;
struct HostCallbackScope {
  HostCallbackScope() { ++hostCallbackDepth; }
  ~HostCallbackScope() { --hostCallbackDepth; }
};
struct Bounds { LONG start, end; };
struct CompositionState { unsigned id; bool ended; std::shared_ptr<Bounds> bounds; };
struct Store {
  std::string name;
  std::wstring text;
  LONG selectionStart = 0, selectionEnd = 0;
  TfEditCookie cookie;
  std::vector<std::weak_ptr<Bounds>> ranges;
  unsigned starts = 0, ends = 0, endAttempts = 0, writes = 0, attributeClears = 0;
  unsigned nonemptyWrites = 0, hostWrites = 0, imeWrites = 0;
  bool hostMutation = false, failEmpty = false;
  bool connected = true, selectionAvailable = true;
  unsigned selectionQueries = 0, insertionQueries = 0, selectionWrites = 0;
  std::vector<Bounds> attributeClearBounds;
  HRESULT failNextEnd = S_OK;
  std::vector<CompositionState> compositions;
  std::function<void()> afterImeWrite;
  std::function<void()> beforeRequest;
  std::function<void()> afterInsertionQuery;
  std::function<void()> afterStart;
  std::function<void()> afterSelectionQuery;
  std::function<void()> beforeRangeCompareReturn;
  unsigned ownerErrors = 0, comparisonCalls = 0;
  bool failComparison = false;
  std::ofstream* report;
  void Event(const char* operation) {
    *report << "TRACE " << name << ' ' << operation << std::endl;
  }
  std::shared_ptr<Bounds> NewBounds(LONG start, LONG end) {
    auto bounds = std::make_shared<Bounds>(Bounds{start, end});
    ranges.emplace_back(bounds);
    return bounds;
  }
};
static Store* grantingStore = nullptr;
static unsigned editRequestDepth = 0;

class Range : public ITfRange {
 public:
  Range(ITfContext* owner, const std::shared_ptr<Store>& store, LONG start, LONG end)
      : owner_(owner), store_(store), bounds_(store->NewBounds(start, end)) {}
  STDMETHODIMP QueryInterface(REFIID iid, void** out) override {
    *out = nullptr;
    if (iid != IID_IUnknown && iid != IID_ITfRange) return E_NOINTERFACE;
    *out = static_cast<ITfRange*>(this); AddRef(); return S_OK;
  }
  STDMETHODIMP_(ULONG) AddRef() override { return ++refs_; }
  STDMETHODIMP_(ULONG) Release() override {
    const ULONG n = --refs_; if (!n) delete this; return n;
  }
  STDMETHODIMP GetText(TfEditCookie ec, DWORD, WCHAR* text, ULONG capacity, ULONG* count) override {
    if (!store_->connected) return E_FAIL;
    if (!OwnCookie(ec)) return E_INVALIDARG;
    const ULONG length = static_cast<ULONG>(bounds_->end - bounds_->start);
    *count = (std::min)(capacity, length);
    std::copy_n(store_->text.data() + bounds_->start, *count, text);
    return S_OK;
  }
  STDMETHODIMP SetText(TfEditCookie ec, DWORD, const WCHAR* text, LONG length) override {
    if (!store_->connected) { store_->Event("range.SetText-disconnected"); return E_FAIL; }
    if (!OwnCookie(ec) || length < 0) return E_INVALIDARG;
    const LONG start = bounds_->start, end = bounds_->end;
    if (start < 0 || end < start || static_cast<size_t>(end) > store_->text.size()) return E_INVALIDARG;
    store_->text.replace(start, end - start, text ? std::wstring(text, length) : L"");
    ++store_->writes; if (length > 0) ++store_->nonemptyWrites;
    if (length > 0) { if (store_->hostMutation) ++store_->hostWrites; else ++store_->imeWrites; }
    store_->Event(store_->hostMutation ? "host.range.SetText" : "ime.range.SetText");
    // Only the anchor tracking used by these finite cases is modelled:
    // start anchors have backward gravity; end anchors have forward gravity.
    const LONG delta = length - (end - start);
    for (const auto& weak : store_->ranges) {
      if (auto range = weak.lock()) {
        range->start = range->start < start ? range->start :
                       range->start > end ? range->start + delta : start;
        range->end = range->end < start ? range->end :
                     range->end > end ? range->end + delta : start + length;
      }
    }
    if (length > 0 && !store_->hostMutation && store_->afterImeWrite) {
      auto callback = std::move(store_->afterImeWrite); HostCallbackScope callbackScope;
      store_->Event("host.reenter-termination-during-ime-SetText");
      callback();
    }
    return S_OK;
  }
  STDMETHODIMP GetFormattedText(TfEditCookie, IDataObject**) override { return E_NOTIMPL; }
  STDMETHODIMP GetEmbedded(TfEditCookie, REFGUID, REFIID, IUnknown**) override { return E_NOTIMPL; }
  STDMETHODIMP InsertEmbedded(TfEditCookie, DWORD, IDataObject*) override { return E_NOTIMPL; }
  STDMETHODIMP ShiftStart(TfEditCookie, LONG, LONG*, const TF_HALTCOND*) override { return E_NOTIMPL; }
  STDMETHODIMP ShiftEnd(TfEditCookie, LONG, LONG*, const TF_HALTCOND*) override { return E_NOTIMPL; }
  STDMETHODIMP ShiftStartToRange(TfEditCookie, ITfRange*, TfAnchor) override { return E_NOTIMPL; }
  STDMETHODIMP ShiftEndToRange(TfEditCookie, ITfRange*, TfAnchor) override { return E_NOTIMPL; }
  STDMETHODIMP ShiftStartRegion(TfEditCookie, TfShiftDir, BOOL*) override { return E_NOTIMPL; }
  STDMETHODIMP ShiftEndRegion(TfEditCookie, TfShiftDir, BOOL*) override { return E_NOTIMPL; }
  STDMETHODIMP IsEmpty(TfEditCookie ec, BOOL* empty) override {
    if (!store_->connected) return E_FAIL;
    if (!OwnCookie(ec)) return E_INVALIDARG;
    if (store_->failEmpty) return E_FAIL;
    *empty = bounds_->start == bounds_->end; return S_OK;
  }
  STDMETHODIMP Collapse(TfEditCookie ec, TfAnchor anchor) override {
    if (!store_->connected) return E_FAIL;
    if (!OwnCookie(ec)) return E_INVALIDARG;
    if (anchor == TF_ANCHOR_START) bounds_->end = bounds_->start;
    else bounds_->start = bounds_->end;
    return S_OK;
  }
  STDMETHODIMP IsEqualStart(TfEditCookie ec, ITfRange* other, TfAnchor anchor, BOOL* equal) override {
    LONG result; HRESULT hr = CompareStart(ec, other, anchor, &result);
    if (SUCCEEDED(hr)) *equal = result == 0; return hr;
  }
  STDMETHODIMP IsEqualEnd(TfEditCookie ec, ITfRange* other, TfAnchor anchor, BOOL* equal) override {
    LONG result; HRESULT hr = CompareEnd(ec, other, anchor, &result);
    if (SUCCEEDED(hr)) *equal = result == 0; return hr;
  }
  STDMETHODIMP CompareStart(TfEditCookie ec, ITfRange* other, TfAnchor anchor, LONG* result) override {
    return Compare(ec, bounds_->start, other, anchor, result);
  }
  STDMETHODIMP CompareEnd(TfEditCookie ec, ITfRange* other, TfAnchor anchor, LONG* result) override {
    return Compare(ec, bounds_->end, other, anchor, result);
  }
  STDMETHODIMP AdjustForInsert(TfEditCookie, ULONG, BOOL*) override { return E_NOTIMPL; }
  STDMETHODIMP GetGravity(TfGravity* start, TfGravity* end) override {
    *start = TF_GRAVITY_BACKWARD; *end = TF_GRAVITY_FORWARD; return S_OK;
  }
  STDMETHODIMP SetGravity(TfEditCookie, TfGravity, TfGravity) override { return S_OK; }
  STDMETHODIMP Clone(ITfRange** result) override {
    *result = nullptr;
    if (!store_->connected) return E_FAIL;
    *result = new Range(owner_, store_, bounds_->start, bounds_->end); return S_OK;
  }
  STDMETHODIMP GetContext(ITfContext** result) override {
    *result = owner_; (*result)->AddRef(); return S_OK;
  }
  Store* store() const { return store_.get(); }
  std::shared_ptr<Bounds> bounds() const { return bounds_; }
  LONG start() const { return bounds_->start; }
  LONG end() const { return bounds_->end; }
 private:
  bool OwnCookie(TfEditCookie ec) {
    if (ec == store_->cookie) return true;
    ++store_->ownerErrors; store_->Event("wrong-owner-cookie"); return false;
  }
  HRESULT Compare(TfEditCookie ec, LONG position, ITfRange* other, TfAnchor anchor, LONG* result) {
    if (!store_->connected) return E_FAIL;
    ++store_->comparisonCalls;
    if (!OwnCookie(ec)) return E_INVALIDARG;
    com_ptr<ITfContext> context;
    if (!other || FAILED(other->GetContext(&context)) || context != owner_) {
      ++store_->ownerErrors; store_->Event("cross-owner-range-comparison"); return E_INVALIDARG;
    }
    if (store_->failComparison) return E_FAIL;
    auto range = static_cast<Range*>(other);
    const LONG target = anchor == TF_ANCHOR_START ? range->start() : range->end();
    *result = position < target ? -1 : position > target ? 1 : 0;
    if (store_->beforeRangeCompareReturn) {
      auto callback = std::move(store_->beforeRangeCompareReturn); HostCallbackScope callbackScope;
      callback();
    }
    return S_OK;
  }
  ULONG refs_ = 1;
  com_ptr<ITfContext> owner_;
  std::shared_ptr<Store> store_;
  std::shared_ptr<Bounds> bounds_;
};

class Property : public ITfProperty {
 public:
  Property(ITfContext* context, const std::shared_ptr<Store>& store) : context_(context), store_(store) {}
  STDMETHODIMP QueryInterface(REFIID iid, void** out) override {
    *out = nullptr;
    if (iid != IID_IUnknown && iid != IID_ITfReadOnlyProperty && iid != IID_ITfProperty) return E_NOINTERFACE;
    *out = static_cast<ITfProperty*>(this); AddRef(); return S_OK;
  }
  STDMETHODIMP_(ULONG) AddRef() override { return ++refs_; }
  STDMETHODIMP_(ULONG) Release() override { const ULONG n = --refs_; if (!n) delete this; return n; }
  STDMETHODIMP GetType(GUID* guid) override { *guid = GUID_PROP_ATTRIBUTE; return S_OK; }
  STDMETHODIMP EnumRanges(TfEditCookie, IEnumTfRanges**, ITfRange*) override { return E_NOTIMPL; }
  STDMETHODIMP GetValue(TfEditCookie, ITfRange*, VARIANT*) override { return E_NOTIMPL; }
  STDMETHODIMP GetContext(ITfContext** context) override { *context = context_; (*context)->AddRef(); return S_OK; }
  STDMETHODIMP FindRange(TfEditCookie, ITfRange*, ITfRange**, TfAnchor) override { return E_NOTIMPL; }
  STDMETHODIMP SetValueStore(TfEditCookie, ITfRange*, ITfPropertyStore*) override { return E_NOTIMPL; }
  STDMETHODIMP SetValue(TfEditCookie ec, ITfRange* range, const VARIANT*) override { return OwnRange(ec, range); }
  STDMETHODIMP Clear(TfEditCookie ec, ITfRange* range) override {
    const HRESULT hr = OwnRange(ec, range);
    if (SUCCEEDED(hr)) {
      ++store_->attributeClears;
      auto concrete = static_cast<Range*>(range);
      store_->attributeClearBounds.push_back(Bounds{concrete->start(), concrete->end()});
      store_->Event("property.Clear-captured-range");
    }
    return hr;
  }
 private:
  HRESULT OwnRange(TfEditCookie ec, ITfRange* range) {
    if (!store_->connected) return E_FAIL;
    com_ptr<ITfContext> context;
    if (ec != store_->cookie || !range || FAILED(range->GetContext(&context)) || context != context_) {
      ++store_->ownerErrors; store_->Event("property-wrong-owner"); return E_INVALIDARG;
    }
    return S_OK;
  }
  ULONG refs_ = 1;
  com_ptr<ITfContext> context_;
  std::shared_ptr<Store> store_;
};

class Composition : public ITfComposition {
 public:
  Composition(ITfRange* range, ITfCompositionSink* sink, const std::shared_ptr<Store>& store)
      : sink_(sink), store_(store) {
    // The composition owns independent anchors. Collapsing the caller's
    // selection range after StartComposition must not collapse its range.
    range->Clone(&range_);
    id_ = static_cast<unsigned>(store_->compositions.size() + 1);
    store_->compositions.push_back(CompositionState{id_, false, static_cast<Range*>(range_.p)->bounds()});
  }
  STDMETHODIMP QueryInterface(REFIID iid, void** out) override {
    *out = nullptr;
    if (iid != IID_IUnknown && iid != IID_ITfComposition) return E_NOINTERFACE;
    *out = static_cast<ITfComposition*>(this); AddRef(); return S_OK;
  }
  STDMETHODIMP_(ULONG) AddRef() override { return ++refs_; }
  STDMETHODIMP_(ULONG) Release() override { const ULONG n = --refs_; if (!n) delete this; return n; }
  STDMETHODIMP GetRange(ITfRange** range) override {
    *range = nullptr;
    if (!store_->connected) return E_FAIL;
    if (store_->compositions.at(id_ - 1).ended) return E_UNEXPECTED;
    return range_->Clone(range);
  }
  STDMETHODIMP ShiftStart(TfEditCookie, ITfRange*) override { return E_NOTIMPL; }
  STDMETHODIMP ShiftEnd(TfEditCookie ec, ITfRange* end) override {
    if (!store_->connected) return E_FAIL;
    if (ec != store_->cookie) { ++store_->ownerErrors; return E_INVALIDARG; }
    if (store_->compositions.at(id_ - 1).ended) return E_UNEXPECTED;
    com_ptr<ITfContext> originalOwner, newOwner;
    if (!end || FAILED(range_->GetContext(&originalOwner)) ||
        FAILED(end->GetContext(&newOwner)) || originalOwner != newOwner)
      return E_INVALIDARG;
    const auto bounds = static_cast<Range*>(range_.p)->bounds();
    const LONG position = static_cast<Range*>(end)->end();
    if (position < bounds->start) return E_INVALIDARG;
    bounds->end = position;
    store_->Event("composition.ShiftEnd");
    return S_OK;
  }
  STDMETHODIMP EndComposition(TfEditCookie ec) override {
    if (!store_->connected) return E_FAIL;
    if (ec != store_->cookie) { ++store_->ownerErrors; store_->Event("composition-end-wrong-owner"); return E_INVALIDARG; }
    ++store_->endAttempts;
    if (FAILED(store_->failNextEnd)) {
      const HRESULT failure = store_->failNextEnd; store_->failNextEnd = S_OK;
      store_->Event("composition.End-injected-no-notification"); return failure;
    }
    // ITfComposition::EndComposition on an already ended composition fails.
    // Do not manufacture a successful second notification for the product.
    if (store_->compositions.at(id_ - 1).ended) {
      store_->Event("composition.End-already-ended-E_UNEXPECTED");
      return E_UNEXPECTED;
    }
    ++store_->ends; store_->Event("composition.End");
    // This finite fixture allows GetRange inside the termination callback,
    // then rejects GetRange/End after EndComposition returns. The callback
    // timing is a model schedule, not a complete TSF host implementation.
    const HRESULT result = sink_->OnCompositionTerminated(ec, this);
    store_->compositions.at(id_ - 1).ended = true;
    return result;
  }
 private:
  ULONG refs_ = 1;
  com_ptr<ITfRange> range_;
  unsigned id_ = 0;
  com_ptr<ITfCompositionSink> sink_;
  std::shared_ptr<Store> store_;
};

// A controlled windowless view supports native candidate registration only.
// It supplies no character geometry, layout range, screen area or READ lock.
class WindowlessView : public ITfContextView {
 public:
  STDMETHODIMP QueryInterface(REFIID iid, void** value) override {
    if (!value) return E_POINTER;
    *value = nullptr;
    if (iid != IID_IUnknown && iid != IID_ITfContextView) return E_NOINTERFACE;
    *value = static_cast<ITfContextView*>(this); AddRef(); return S_OK;
  }
  STDMETHODIMP_(ULONG) AddRef() override { return ++refs_; }
  STDMETHODIMP_(ULONG) Release() override {
    const ULONG left = --refs_; if (!left) delete this; return left;
  }
  STDMETHODIMP GetRangeFromPoint(TfEditCookie, const POINT*, DWORD, ITfRange** range) override {
    if (!range) return E_POINTER;
    *range = nullptr; return TF_E_NOLAYOUT;
  }
  STDMETHODIMP GetTextExt(TfEditCookie, ITfRange*, RECT* rect, BOOL* clipped) override {
    if (!rect || !clipped) return E_POINTER;
    SetRectEmpty(rect); *clipped = FALSE; return TF_E_NOLAYOUT;
  }
  STDMETHODIMP GetScreenExt(RECT* rect) override {
    if (!rect) return E_POINTER;
    SetRectEmpty(rect); return S_OK;
  }
  STDMETHODIMP GetWnd(HWND* window) override {
    if (!window) return E_POINTER;
    *window = nullptr; return S_OK;
  }
 private:
  ULONG refs_ = 1;
};

class Context : public ITfContext, public ITfInsertAtSelection, public ITfContextComposition {
 public:
  Context(ITfDocumentMgr* document, const char* name, TfEditCookie cookie, std::ofstream* report,
          ITfContext* keyboardFlagsContext = nullptr)
      : document_(document), keyboardFlagsContext_(keyboardFlagsContext), store(std::make_shared<Store>()) {
    store->name = name; store->cookie = cookie; store->report = report;
  }
  STDMETHODIMP QueryInterface(REFIID iid, void** out) override {
    *out = nullptr;
    if (iid == IID_IUnknown || iid == IID_ITfContext) *out = static_cast<ITfContext*>(this);
    else if (iid == IID_ITfInsertAtSelection) *out = static_cast<ITfInsertAtSelection*>(this);
    else if (iid == IID_ITfContextComposition) *out = static_cast<ITfContextComposition*>(this);
    else if (iid == IID_ITfCompartmentMgr && keyboardFlagsContext_)
      return keyboardFlagsContext_->QueryInterface(iid, out);
    else return E_NOINTERFACE;
    AddRef(); return S_OK;
  }
  STDMETHODIMP_(ULONG) AddRef() override { return ++refs_; }
  STDMETHODIMP_(ULONG) Release() override { const ULONG n = --refs_; if (!n) delete this; return n; }
  STDMETHODIMP RequestEditSession(TfClientId, ITfEditSession* session, DWORD flags, HRESULT* result) override {
    struct RequestScope {
      RequestScope() { ++editRequestDepth; }
      ~RequestScope() { --editRequestDepth; }
    } requestScope;
    // This legacy host has no read-only/F/F range model. A synchronous read
    // must fail immediately; never queue it or consume a write-failure hook.
    #include "ControlledReadGrant.inc"
    *store->report << "TRACE " << store->name << " RequestEditSession flags=" << flags
                   << " from-grant=" << (grantingStore ? grantingStore->name : "none")
                   << " request-depth=" << editRequestDepth << std::endl;
    if (store->beforeRequest) {
      auto callback = std::move(store->beforeRequest); HostCallbackScope callbackScope; callback();
    }
    if (!store->connected) { *result = E_FAIL; return E_FAIL; }
    if (FAILED(failNextRequest)) {
      const HRESULT failure = failNextRequest; failNextRequest = S_OK;
      *result = failure; return failure;
    }
    if (FAILED(failNextSession)) {
      *result = failNextSession; failNextSession = S_OK; return S_OK;
    }
    if ((flags & TF_ES_SYNC) && grantingStore) {
      *result = TF_E_SYNCHRONOUS;
      return S_OK;
    }
    const bool mustQueue = (flags & TF_ES_ASYNC) != 0;
    const bool immediate = !mustQueue && ((flags & TF_ES_SYNC) ||
        (synchronous && !grantingStore));
    if (immediate) {
      Store* previous = grantingStore; grantingStore = store.get();
      try { *result = session->DoEditSession(store->cookie); }
      catch (...) { grantingStore = previous; throw; }
      grantingStore = previous;
    } else {
      // ASYNC always means a later native-style boundary, never inline grant.
      pending.emplace_back(session);
      *result = TF_S_ASYNC;
    }
    return S_OK;
  }
  STDMETHODIMP InWriteSession(TfClientId, BOOL* active) override { *active = grantingStore == store.get(); return S_OK; }
  STDMETHODIMP GetSelection(TfEditCookie ec, ULONG, ULONG count, TF_SELECTION* selection, ULONG* fetched) override {
    if (!store->connected || !store->selectionAvailable) { *fetched = 0; return E_FAIL; }
    if (ec != store->cookie || count != 1) return E_INVALIDARG;
    ++store->selectionQueries; store->Event("selection.Query");
    selection[0].range = new Range(this, store, store->selectionStart, store->selectionEnd);
    selection[0].style.ase = TF_AE_NONE; selection[0].style.fInterimChar = FALSE;
    *fetched = 1;
    if (store->afterSelectionQuery) {
      auto callback = std::move(store->afterSelectionQuery); HostCallbackScope callbackScope; callback();
    }
    return S_OK;
  }
  STDMETHODIMP SetSelection(TfEditCookie ec, ULONG count, const TF_SELECTION* selection) override {
    if (!store->connected || !store->selectionAvailable) return E_FAIL;
    if (ec != store->cookie || count != 1) return E_INVALIDARG;
    com_ptr<ITfContext> owner;
    if (FAILED(selection[0].range->GetContext(&owner)) || owner != static_cast<ITfContext*>(this)) {
      ++store->ownerErrors; return E_INVALIDARG;
    }
    auto range = static_cast<Range*>(selection[0].range);
    store->selectionStart = range->start(); store->selectionEnd = range->end();
    ++store->selectionWrites; store->Event("selection.Set-by-product");
    return S_OK;
  }
  STDMETHODIMP GetStart(TfEditCookie, ITfRange**) override { return E_NOTIMPL; }
  STDMETHODIMP GetEnd(TfEditCookie, ITfRange**) override { return E_NOTIMPL; }
  STDMETHODIMP GetActiveView(ITfContextView** view) override {
    if (!view) return E_POINTER;
    *view = nullptr;
    if (!viewAvailable) return E_NOTIMPL;
    *view = new WindowlessView(); return S_OK;
  }
  STDMETHODIMP EnumViews(IEnumTfContextViews**) override { return E_NOTIMPL; }
  STDMETHODIMP GetStatus(TF_STATUS* status) override {
    if (!store->connected) return E_FAIL;
    status->dwDynamicFlags = 0; status->dwStaticFlags = 0; return S_OK;
  }
  STDMETHODIMP GetProperty(REFGUID guid, ITfProperty** property) override {
    *property = nullptr;
    if (guid != GUID_PROP_ATTRIBUTE) return E_NOTIMPL;
    *property = new Property(this, store); return S_OK;
  }
  STDMETHODIMP GetAppProperty(REFGUID, ITfReadOnlyProperty**) override { return E_NOTIMPL; }
  STDMETHODIMP TrackProperties(const GUID**, ULONG, const GUID**, ULONG, ITfReadOnlyProperty**) override { return E_NOTIMPL; }
  STDMETHODIMP EnumProperties(IEnumTfProperties**) override { return E_NOTIMPL; }
  STDMETHODIMP GetDocumentMgr(ITfDocumentMgr** document) override { *document = document_; (*document)->AddRef(); return S_OK; }
  STDMETHODIMP CreateRangeBackup(TfEditCookie, ITfRange*, ITfRangeBackup**) override { return E_NOTIMPL; }
  STDMETHODIMP InsertTextAtSelection(TfEditCookie ec, DWORD flags, const WCHAR* text, LONG length, ITfRange** range) override {
    *range = nullptr;
    if (!store->connected || !store->selectionAvailable) return E_FAIL;
    if (ec != store->cookie) return E_INVALIDARG;
    if (flags & TF_IAS_QUERYONLY) { ++store->insertionQueries; store->Event("insertion.QueryOnly"); }
    *range = new Range(this, store, store->selectionStart, store->selectionEnd);
    if (!(flags & TF_IAS_QUERYONLY)) return (*range)->SetText(ec, 0, text, length);
    if (store->afterInsertionQuery) {
      // The out parameter is already populated, but InsertQuery has not yet
      // returned. The product must keep that range private until revalidation.
      auto callback = std::move(store->afterInsertionQuery); HostCallbackScope callbackScope; callback();
    }
    return S_OK;
  }
  STDMETHODIMP InsertEmbeddedAtSelection(TfEditCookie, DWORD, IDataObject*, ITfRange**) override { return E_NOTIMPL; }
  STDMETHODIMP StartComposition(TfEditCookie ec, ITfRange* range, ITfCompositionSink* sink, ITfComposition** composition) override {
    if (!store->connected) return E_FAIL;
    if (ec != store->cookie) return E_INVALIDARG;
    com_ptr<ITfContext> owner;
    if (FAILED(range->GetContext(&owner)) || owner != static_cast<ITfContext*>(this)) return E_INVALIDARG;
    *composition = new Composition(range, sink, store);
    ++store->starts; store->Event("composition.Start");
    if (store->afterStart) {
      // A real composition has been returned through the out pointer, but the
      // host callback reenters before StartComposition itself returns.
      auto callback = std::move(store->afterStart); HostCallbackScope callbackScope; callback();
    }
    return S_OK;
  }
  STDMETHODIMP EnumCompositions(IEnumITfCompositionView**) override { return E_NOTIMPL; }
  STDMETHODIMP FindComposition(TfEditCookie, ITfRange*, IEnumITfCompositionView**) override { return E_NOTIMPL; }
  STDMETHODIMP TakeOwnership(TfEditCookie, ITfCompositionView*, ITfCompositionSink*, ITfComposition**) override { return E_NOTIMPL; }
  HRESULT GrantOne() {
    // A request/active native operation cannot drain its own asynchronous
    // children. Return a real error if a test accidentally attempts it.
    if (grantingStore || editRequestDepth || hostCallbackDepth) return TF_E_LOCKED;
    if (pending.empty()) return E_UNEXPECTED;
    auto session = pending.front(); pending.pop_front();
    Store* previous = grantingStore; grantingStore = store.get();
    store->Event("grant-one-queued-session");
    HRESULT result;
    try { result = session->DoEditSession(store->cookie); }
    catch (...) { grantingStore = previous; throw; }
    grantingStore = previous; return result;
  }
  void Drain() {
    if (grantingStore || editRequestDepth || hostCallbackDepth)
      throw std::runtime_error("fixture attempted recursive ASYNC drain");
    unsigned count = 0;
    while (!pending.empty()) {
      if (++count > 32) throw std::runtime_error("fixture edit queue did not settle");
      // Delivery errors remain in the original Packet and assertions.
      // Drain is a scheduling boundary, not a success conversion.
      GrantOne();
    }
  }
  // A finite host edit outside the IME range, not a generated key or IME
  // insertion. Only prefix insertion is needed, with all existing anchors
  // strictly after that insertion. This is not a Chromium DOM implementation.
  void ExternalPrefix(const std::wstring& prefix) {
    const LONG count = static_cast<LONG>(prefix.size());
    store->text.insert(0, prefix);
    for (const auto& weak : store->ranges) {
      if (auto range = weak.lock()) { range->start += count; range->end += count; }
    }
    store->selectionStart += count; store->selectionEnd += count;
    store->Event("host.external-prefix-insert");
  }
  void ResetText(const std::wstring& text, LONG start, LONG end) {
    store->text = text; store->selectionStart = start; store->selectionEnd = end;
    store->ranges.clear(); store->compositions.clear();
    store->hostWrites = store->imeWrites = 0;
    store->hostMutation = store->failEmpty = false;
    store->afterImeWrite = nullptr;
    store->beforeRequest = nullptr;
    store->afterInsertionQuery = nullptr;
    store->afterStart = nullptr;
    store->afterSelectionQuery = nullptr;
    store->starts = store->ends = store->endAttempts = store->writes = store->attributeClears = 0;
    store->ownerErrors = store->comparisonCalls = store->nonemptyWrites = 0; store->failComparison = false;
    store->connected = store->selectionAvailable = true;
    store->selectionQueries = store->insertionQueries = store->selectionWrites = 0;
    store->attributeClearBounds.clear(); store->failNextEnd = S_OK;
    failNextRequest = failNextSession = S_OK;
  }
  bool selectionProbeRead = false;
  bool synchronous = true;
  bool viewAvailable = true;
  HRESULT failNextRequest = S_OK, failNextSession = S_OK;
  std::shared_ptr<Store> store;
  std::deque<com_ptr<ITfEditSession>> pending;
 private:
  ULONG refs_ = 1;
  com_ptr<ITfDocumentMgr> document_;
  com_ptr<ITfContext> keyboardFlagsContext_;
};

class SelectionRecord : public ITfEditRecord {
 public:
  STDMETHODIMP QueryInterface(REFIID iid, void** out) override {
    *out = nullptr;
    if (iid != IID_IUnknown && iid != IID_ITfEditRecord) return E_NOINTERFACE;
    *out = static_cast<ITfEditRecord*>(this); AddRef(); return S_OK;
  }
  STDMETHODIMP_(ULONG) AddRef() override { return ++refs_; }
  STDMETHODIMP_(ULONG) Release() override { const ULONG n = --refs_; if (!n) delete this; return n; }
  STDMETHODIMP GetSelectionStatus(BOOL* changed) override { *changed = TRUE; return S_OK; }
  STDMETHODIMP GetTextAndPropertyUpdates(DWORD, const GUID**, ULONG, IEnumTfRanges** ranges) override {
    *ranges = nullptr; return S_FALSE;
  }
 private:
  ULONG refs_ = 1;
};
}  // namespace response_owner_product_fixture
