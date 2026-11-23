// Instrumented candidate only. The host primitives control TSF grants; all
// production/capture/cancel/delivery state below belongs to the real product.
#include "ProductHostFixture.h"
#include <utility>
#include <cstdlib>
#include <cstring>

// Research-only observation at the real producer IPC entry.
unsigned rymcpRetainedKeyCalls = 0;

#ifdef _M_IX86
#pragma comment(linker, "/EXPORT:RunResponseOwnerProductTests=_RunResponseOwnerProductTests")
#endif

// Test-host sink only. Real Msctf ITfUIElementMgr issues all notifications.
// Never add this to the frozen product or replace CCandidateList::UpdateUI.
#include <exception>
#include <functional>
#include <vector>

static unsigned retainedUiCallbackDepth = 0;
struct RetainedUiCallbackScope {
  RetainedUiCallbackScope() {
    ++retainedUiCallbackDepth;
    ++response_owner_product_fixture::hostCallbackDepth;
  }
  ~RetainedUiCallbackScope() {
    --response_owner_product_fixture::hostCallbackDepth;
    --retainedUiCallbackDepth;
  }
};

class NormalUiElementSink : public ITfUIElementSink {
 public:
  STDMETHODIMP QueryInterface(REFIID iid, void** value) override {
    if (!value) return E_POINTER;
    *value = nullptr;
    if (iid != IID_IUnknown && iid != IID_ITfUIElementSink) return E_NOINTERFACE;
    *value = static_cast<ITfUIElementSink*>(this);
    AddRef();
    return S_OK;
  }
  STDMETHODIMP_(ULONG) AddRef() override { return ++refs_; }
  STDMETHODIMP_(ULONG) Release() override {
    const ULONG refs = --refs_;
    if (!refs) delete this;
    return refs;
  }
  STDMETHODIMP BeginUIElement(DWORD id, BOOL* show) override {
    RetainedUiCallbackScope callbackScope;
    if (!show) return E_POINTER;
    beginIds.push_back(id);
    beginOrdinals.push_back(++notificationOrdinal);
    // Host A elects integrated UI; B asks the text service to draw normally.
    *show = beginIds.size() == 1 ? FALSE : TRUE;
    beginChoices.push_back(*show);
    return S_OK;
  }
  STDMETHODIMP UpdateUIElement(DWORD id) override {
    RetainedUiCallbackScope callbackScope;
    updateIds.push_back(id);
    if (onUpdate) {
      auto callback = std::move(onUpdate);
      onUpdate = {};
      // COM callback must not unwind a C++ exception through Msctf.
      try { callback(id); }
      catch (...) { failure = std::current_exception(); return E_FAIL; }
    }
    return S_OK;
  }
  STDMETHODIMP EndUIElement(DWORD id) override {
    RetainedUiCallbackScope callbackScope;
    endIds.push_back(id);
    endOrdinals.push_back(++notificationOrdinal);
    return S_OK;
  }
  std::vector<DWORD> beginIds, updateIds, endIds;
  std::vector<unsigned> beginOrdinals, endOrdinals;
  unsigned notificationOrdinal = 0;
  std::vector<BOOL> beginChoices;
  std::function<void(DWORD)> onUpdate;
  std::exception_ptr failure;
 private:
  ULONG refs_ = 1;
};

class NormalUiSinkScope {
 public:
  NormalUiSinkScope() { sink.Attach(new NormalUiElementSink()); }
  ~NormalUiSinkScope() {
    sink->onUpdate = {};
    if (source_ && cookie_ != TF_INVALID_COOKIE) source_->UnadviseSink(cookie_);
  }
  HRESULT Advise(ITfThreadMgr* thread) {
    com_ptr<ITfUIElementMgr> manager;
    HRESULT result = thread->QueryInterface(IID_ITfUIElementMgr,
        reinterpret_cast<void**>(&manager));
    if (FAILED(result)) return result;
    result = manager->QueryInterface(IID_ITfSource,
        reinterpret_cast<void**>(&source_));
    if (FAILED(result)) return result;
    return source_->AdviseSink(IID_ITfUIElementSink, sink, &cookie_);
  }
  com_ptr<NormalUiElementSink> sink;
 private:
  com_ptr<ITfSource> source_;
  DWORD cookie_ = TF_INVALID_COOKIE;
};

class ResponseOwnerProductFixture {
 public:
  static int Run(const wchar_t* path) {
    std::ofstream out(path);
    if (!out) return 2;
    if (FAILED(CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED))) return 2;
    int result = 1;
    {
      ResponseOwnerProductFixture fixture(out);
      try { fixture.Initialize();
        const char* probe = std::getenv("RIME_CUSTOM_DELTA_PROBE");
        if (probe && *probe) fixture.RunProbe(probe); else fixture.RunAll(); }
      catch (const std::exception& error) { fixture.Check("suite-exception", false); out << "ERROR " << error.what() << std::endl; }
      fixture.CleanupService();
      if (fixture.savedKeys_) SetKeyboardState(fixture.originalKeys_);
      if (fixture.docA_) fixture.docA_->Pop(TF_POPF_ALL);
      if (fixture.docB_) fixture.docB_->Pop(TF_POPF_ALL);
      if (fixture.manager_) fixture.manager_->Deactivate();
      out << "RESULT passed=" << fixture.passed_ << " failed=" << fixture.failed_
          << " groups=" << fixture.groups_ << std::endl;
      const char* probe = std::getenv("RIME_CUSTOM_DELTA_PROBE");
      const unsigned expectedGroups = probe && *probe ? 1 : 22;
      result = fixture.failed_ || fixture.groups_ != expectedGroups ? 1 : 0;
    }
    CoUninitialize();
    return result;
  }

 private:
  using Context = response_owner_product_fixture::Context;
  using SelectionRecord = response_owner_product_fixture::SelectionRecord;
  using Packet = response_owner::Packet;
  using Stage = response_owner::Stage;
  explicit ResponseOwnerProductFixture(std::ofstream& out) : out_(out) {}

  static void Require(HRESULT hr, const char* operation) {
    if (FAILED(hr)) throw std::runtime_error(operation);
  }
  static std::string Hex(const std::wstring& text) {
    const char* digits = "0123456789ABCDEF";
    std::string result;
    for (wchar_t ch : text) {
      if (!result.empty()) result += ',';
      for (int shift = 12; shift >= 0; shift -= 4) result += digits[(ch >> shift) & 15];
    }
    return result.empty() ? "empty" : result;
  }
  static const char* StageName(Stage value) {
    switch (value) {
      case Stage::Prepared: return "Prepared";
      case Stage::AwaitEndpoint: return "AwaitEndpoint";
      case Stage::Ready: return "Ready";
      case Stage::Writing: return "Writing";
      case Stage::Written: return "Written";
      case Stage::Done: return "Done";
      case Stage::NoCommit: return "NoCommit";
      case Stage::Closing: return "Closing";
      case Stage::Failed: return "Failed";
      case Stage::UnsupportedEndpoint: return "UnsupportedEndpoint";
    }
    return "invalid";
  }
  void SettleNormalDelivery(const char* label) {
    out_ << "BOUNDARY " << label << " active-grant="
         << (response_owner_product_fixture::grantingStore ? 1 : 0)
         << " request-depth=" << response_owner_product_fixture::editRequestDepth
         << " host-callback-depth=" << response_owner_product_fixture::hostCallbackDepth
         << " ui-callback-depth=" << retainedUiCallbackDepth
         << std::endl;
    if (response_owner_product_fixture::grantingStore ||
        response_owner_product_fixture::editRequestDepth ||
        response_owner_product_fixture::hostCallbackDepth || retainedUiCallbackDepth) return;
    // Each context has its own FIFO/availability. This selection order is only
    // a finite controlled host schedule, not a claimed Windows global FIFO.
    unsigned rounds = 0;
    for (;;) {
      const bool readyA = a_ && a_->synchronous && !a_->pending.empty();
      const bool readyB = b_ && b_->synchronous && !b_->pending.empty();
      if (!readyA && !readyB) return;
      if (++rounds > 64) throw std::runtime_error("normal delivery did not settle");
      if (readyA) a_->GrantOne();
      if (readyB) b_->GrantOne();
    }
  }
  void Check(const char* name, bool condition) {
    out_ << (condition ? "PASS " : "FAIL ") << name << std::endl;
    condition ? ++passed_ : ++failed_;
  }
  void Initialize() {
    Require(CoCreateInstance(CLSID_TF_ThreadMgr, nullptr, CLSCTX_INPROC_SERVER,
        IID_ITfThreadMgr, reinterpret_cast<void**>(&manager_)), "real TSF manager");
    Require(manager_->Activate(&clientId_), "activate TSF manager");
    Require(manager_->CreateDocumentMgr(&docA_), "document A");
    Require(manager_->CreateDocumentMgr(&docB_), "document B");
    com_ptr<ITfContext> realA, realB;
    TfEditCookie unused;
    Require(docA_->CreateContext(clientId_, 0, nullptr, &realA, &unused), "real A context");
    Require(docB_->CreateContext(clientId_, 0, nullptr, &realB, &unused), "real B context");
    Require(docA_->Push(realA), "push A"); Require(docB_->Push(realB), "push B");
    NormalKeyboardFlags(realA); NormalKeyboardFlags(realB);
    if (!GetKeyboardState(originalKeys_)) throw std::runtime_error("save runner thread keyboard state");
    savedKeys_ = true;
    {
      com_ptr<Context> probe;
      probe.Attach(new Context(docA_, "windowless-model", 0xcc03, &out_));
      com_ptr<ITfContextView> view;
      Require(probe->GetActiveView(&view), "windowless model view");
      HWND window = reinterpret_cast<HWND>(1);
      RECT rect = {1,1,2,2}; BOOL clipped = TRUE;
      if (!view || view->GetWnd(&window) != S_OK || window != nullptr ||
          view->GetTextExt(0, nullptr, &rect, &clipped) != TF_E_NOLAYOUT ||
          !IsRectEmpty(&rect) || view->GetScreenExt(&rect) != S_OK || !IsRectEmpty(&rect))
        throw std::runtime_error("windowless model must not invent layout or HWND");
      probe->viewAvailable = false;
      view.Release();
      if (probe->GetActiveView(&view) != E_NOTIMPL || view)
        throw std::runtime_error("unsupported-view model control did not remain unsupported");
      out_ << "MODEL_CAPABILITY windowless=1 null-hwnd=1 no-layout=1 unsupported-view=1 sync-read=0 ff-gravity=0" << std::endl;
    }
    BYTE neutral[256] = {};
    if (!SetKeyboardState(neutral)) throw std::runtime_error("neutral runner thread keyboard state");
    out_ << "MODE source-design-async-retained-flags-correct real-IPC native-three-word-fixture" << std::endl;
    out_ << "LIMIT controlled-host no-private-data no-OS-mouse no-unnotified-DOM no-field-cause" << std::endl;
    out_ << "BEFORE_REFERENCE V1 saved-39474496831-body-late-read-can-lose-A no-new-baseline-run" << std::endl;
    out_ << "BEFORE_REFERENCE V4 saved-39474496831-Select-focus-B-can-misroute-cn01 no-new-baseline-run" << std::endl;
  }
  void NormalKeyboardFlags(ITfContext* context) {
    com_ptr<ITfCompartmentMgr> manager;
    Require(context->QueryInterface(IID_ITfCompartmentMgr, reinterpret_cast<void**>(&manager)), "real keyboard compartments");
    const GUID* keys[] = {&GUID_COMPARTMENT_KEYBOARD_DISABLED, &GUID_COMPARTMENT_EMPTYCONTEXT};
    for (const GUID* key : keys) {
      com_ptr<ITfCompartment> compartment;
      Require(manager->GetCompartment(*key, &compartment), "normal keyboard compartment");
      VARIANT value; VariantInit(&value); value.vt = VT_I4; value.lVal = 0;
      Require(compartment->SetValue(clientId_, &value), "normal callback keyboard flags");
    }
  }
  void CleanupService() {
    if (!service_) return;
    if (a_) { a_->store->connected = true; a_->pending.clear(); }
    if (b_) { b_->store->connected = true; b_->pending.clear(); }
    service_->_FinalizeComposition();
    if (savedOpen_) { service_->_SetKeyboardOpen(originalOpen_); savedOpen_ = false; }
    service_->_cand->DestroyAll(); service_->_cand = nullptr;
    service_->_InitTextEditSink(nullptr); service_->_pEditSessionContext = nullptr;
    service_->m_client.ClearComposition(); service_->m_client.EndSession(); service_->m_client.Disconnect();
    // Teardown only: release references after all assertions, including failed
    // packets retaining their original endpoint. No state is repaired for PASS.
    service_->_lastResponse.reset(); service_->_producerResponse.reset();
    service_->_responseIntent.reset(); service_->_engineResponseIntent.reset();
    service_->_responseIntents.clear();
    Require(service_->Deactivate(), "retained activation-cell teardown");
    service_ = nullptr; a_ = nullptr; b_ = nullptr;
  }
  void Fresh() {
    CleanupService(); observed_.clear(); realCommits_ = 0;
    Require(manager_->SetFocus(docA_), "focus A");
    com_ptr<ITfContext> flagsA, flagsB;
    Require(docA_->GetTop(&flagsA), "A keyboard flags context");
    Require(docB_->GetTop(&flagsB), "B keyboard flags context");
    a_.Attach(new Context(docA_, "A", 0xca01, &out_, flagsA));
    b_.Attach(new Context(docB_, "B", 0xcb02, &out_, flagsB));
    a_->ResetText(L"prefix|", 7, 7); b_->ResetText(L"other|", 6, 6);
    service_.Attach(new WeaselTSF());
    // Historical model fixture: a real manager/client in one activation cell,
    // not a claim that full public ActivateEx or physical dispatch was reached.
    auto activation = std::make_shared<WeaselTSF::ActivationBindings>();
    activation->client = clientId_;
    service_->_activation = activation;
    activation->thread = manager_;
    if (!service_->_cand) service_->_cand.Attach(new CCandidateList(service_));
    originalOpen_ = service_->_IsKeyboardOpen(); savedOpen_ = true;
    Require(service_->_SetKeyboardOpen(TRUE), "open synthetic fixture keyboard");
    service_->_Reconnect();
    if (!service_->m_client.Echo()) throw std::runtime_error("public IPC server unavailable");
  }
  template<class Action> void Group(const char* id, Action action) {
    const unsigned before = failed_;
    out_ << "BEGIN " << id << std::endl;
    try { Fresh(); action(); State(id, a_); State(id, b_); }
    catch (const std::exception& error) {
      Check("group-exception", false); out_ << "ERROR " << id << ' ' << error.what() << std::endl;
    }
    out_ << "GROUP " << id << (failed_ == before ? " PASS" : " FAIL") << std::endl;
    ++groups_;
  }
  std::shared_ptr<Packet> Record(const std::shared_ptr<Packet>& packet) {
    if (!packet || !packet->response) {
      // A pure Test can observe no content, including a Prepared packet while
      // an Actual is still resolving its owner before the first engine call.
      out_ << "OBSERVE_NO_CONTENT packetPresent=" << bool(packet)
           << " stage=" << (packet ? StageName(packet->stage) : "none") << std::endl;
      return nullptr;
    }
    if (std::find(observed_.begin(), observed_.end(), packet->response->generation) == observed_.end()) {
      observed_.push_back(packet->response->generation);
      if (!packet->response->commit.empty()) ++realCommits_;
      out_ << "BODY generation=" << packet->response->generation
           << " commitUtf16=" << Hex(packet->response->commit)
           << " preeditUtf16=" << Hex(packet->response->context.preedit.str)
           << " composing=" << packet->response->status.composing << std::endl;
      if (packet->response->generation == 0 || packet->response->status.schema_id != L"gui_test" ||
          packet->response->config.inline_preedit)
        throw std::runtime_error("expected genuine public noninline gui_test response");
    }
    TracePacket(packet); return packet;
  }
  std::shared_ptr<Packet> Produce(Context* owner, int key) {
    service_->_ProduceKeyResponse(owner, weasel::KeyEvent(key, 0));
    const auto packet = service_->_lastResponse;
    SettleNormalDelivery("normal-produce-return");
    return Record(packet);
  }
  void Type(Context* owner, const std::string& raw) {
    for (char ch : raw) Produce(owner, ch);
  }
  std::shared_ptr<Packet> CallbackKey(Context* owner, UINT virtualKey) {
    BOOL tested = FALSE, eaten = FALSE;
    const LPARAM info = 1 | (static_cast<LPARAM>(MapVirtualKey(virtualKey, MAPVK_VK_TO_VSC)) << 16);
    const auto before = service_->_lastResponse;
    Require(service_->OnTestKeyDown(owner, virtualKey, info, &tested), "real TestKeyDown");
    const auto afterTest = service_->_lastResponse;
    Require(service_->OnKeyDown(owner, virtualKey, info, &eaten), "real KeyDown");
    auto packet = service_->_lastResponse;
    SettleNormalDelivery("assert:V5-Test-is-pure-KeyDown-publishes-one-product-packet");
    Check("V5-Test-is-pure-KeyDown-publishes-one-product-packet",
        tested && afterTest == before && packet && packet != before);
    return Record(packet);
  }
  void Replay(const std::shared_ptr<Packet>& packet) {
    // Request the same real Packet again. Scheduled work is idempotent;
    // no removed follower/resume field is recreated by the fixture.
    service_->_QueueResponse(packet);
  }
  void TracePacket(const std::shared_ptr<Packet>& packet) {
    if (!packet || !packet->response) {
      out_ << "PACKET none no-content-response-produced-at-this-phase" << std::endl;
      return;
    }
    const auto source = packet->source;
    out_ << "PACKET id=" << reinterpret_cast<std::uintptr_t>(packet.get())
         << " generation=" << packet->response->generation
         << " token=" << (source ? source->token : 0)
         << " owner=" << (!source ? "none" : source->owner.p == a_.p ? "A" : source->owner.p == b_.p ? "B" : "other")
         << " stage=" << StageName(packet->stage)
         << " writeAttempts=" << packet->writeAttempts << " textWritten=" << packet->textWritten
         << " captureHr=" << packet->captureResult << " writeHr=" << packet->writeResult
         << " cleanupHr=" << packet->cleanupResult
         << " valid=" << (source && source->valid) << " cancelled=" << (source && source->cancelled)
         << " terminated=" << (source && source->terminated) << std::endl;
  }
  void State(const char* id, Context* context) {
    if (!context) return;
    out_ << "STATE " << id << " owner=" << context->store->name
         << " hostUtf16=" << Hex(context->store->text) << " imeWrites=" << context->store->imeWrites
         << " hostWrites=" << context->store->hostWrites << " endAttempts=" << context->store->endAttempts
         << " ends=" << context->store->ends << " attributeClears=" << context->store->attributeClears
         << " selectionQueries=" << context->store->selectionQueries
         << " insertionQueries=" << context->store->insertionQueries
         << " queued=" << context->pending.size() << " cookieErrors=" << context->store->ownerErrors
         << " observedRealCommits=" << realCommits_ << std::endl;
  }
  void NoHostOrCookieErrors(const char* label) {
    SettleNormalDelivery("assert:conditional-assertion");
    Check(label, a_->store->hostWrites == 0 && b_->store->hostWrites == 0 &&
        a_->store->ownerErrors == 0 && b_->store->ownerErrors == 0);
  }
  void Reentry(bool deferred) {
    Type(a_, "abc");
    auto victim = service_->_pComposition;
    if (!victim) throw std::runtime_error("product preedit composition missing");
    std::shared_ptr<Packet> saved;
    bool reentered = false;
    a_->store->afterImeWrite = [&, victim]() {
      reentered = true; saved = Record(service_->_lastResponse);
      SettleNormalDelivery("assert:V7-SetText-enters-product-Writing-before-reentry");
      Check("V7-SetText-enters-product-Writing-before-reentry", saved->stage == Stage::Writing);
      if (deferred) a_->synchronous = false;
      Require(victim->EndComposition(a_->store->cookie), "host End within actual SetText");
      Type(b_, "x"); Replay(saved);
    };
    service_->_ProduceKeyResponse(a_, weasel::KeyEvent(0x20, 0));
    a_->Drain(); b_->Drain();
    SettleNormalDelivery("assert:V7-known-termination-keeps-A-once-and-finishes");
    Check("V7-known-termination-keeps-A-once-and-finishes", reentered && saved &&
        saved->stage == Stage::Done && saved->textWritten && saved->writeAttempts == 1 &&
        a_->store->text == L"prefix|cn01" && a_->store->imeWrites == 1);
    SettleNormalDelivery("assert:V7-known-End-not-repeated-and-B-owner-survives");
    Check("V7-known-End-not-repeated-and-B-owner-survives", a_->store->endAttempts == 1 &&
        service_->_IsComposing() && service_->_pEditSessionContext.p == b_.p);
    bool fullRange = false;
    for (const auto& bounds : a_->store->attributeClearBounds)
      if (bounds.start == 7 && bounds.end == 11) fullRange = true;
    SettleNormalDelivery("assert:V7-clears-full-written-range");
    Check("V7-clears-full-written-range", fullRange);
    auto probe = Produce(b_, 0xff0d);
    SettleNormalDelivery("assert:V7-late-A-cleanup-keeps-B-real-x");
    Check("V7-late-A-cleanup-keeps-B-real-x", probe->response->commit == L"x" && b_->store->text == L"other|x");
    if (saved) TracePacket(saved);
    NoHostOrCookieErrors("V7-no-artificial-host-write-or-cross-owner-cookie");
  }

  UINT CandidateCount() {
    UINT count = 0;
    Require(service_->_cand->GetCount(&count), "read actual candidate UI data");
    return count;
  }
  bool EmptyEngineResponse(const std::shared_ptr<Packet>& packet) {
    return packet && packet->response && packet->response->commit.empty() &&
        !packet->response->status.composing && packet->response->context.preedit.str.empty() &&
        packet->response->context.cinfo.candies.empty();
  }
  void ObserveUI(const char* label) {
    BOOL shown = FALSE;
    Require(service_->_cand->IsShown(&shown), "read actual candidate UI visibility");
    out_ << "UI " << label << " candidateCount=" << CandidateCount() << " shown=" << shown
         << " localComposition=" << service_->_IsComposing()
         << " cachedComposing=" << service_->_status.composing
         << " pending=" << a_->pending.size() << std::endl;
  }
  std::shared_ptr<Packet> EscapeStroke(Context* owner) {
    const LPARAM scan = static_cast<LPARAM>(MapVirtualKey(VK_ESCAPE, MAPVK_VK_TO_VSC)) << 16;
    const LPARAM down = 1 | scan;
    const LPARAM up = down | (static_cast<LPARAM>(1) << 30) | (static_cast<LPARAM>(1) << 31);
    BOOL tested = FALSE, eaten = FALSE;
    Require(service_->OnTestKeyDown(owner, VK_ESCAPE, down, &tested), "real Esc TestKeyDown");
    // Test reports interest. A genuine response exists only after Actual.
    if (tested) Require(service_->OnKeyDown(owner, VK_ESCAPE, down, &eaten), "real Esc KeyDown");
    auto pressed = service_->_lastResponse;
    Record(pressed);
    tested = eaten = FALSE;
    Require(service_->OnTestKeyUp(owner, VK_ESCAPE, up, &tested), "real Esc TestKeyUp");
    if (tested) Require(service_->OnKeyUp(owner, VK_ESCAPE, up, &eaten), "real Esc KeyUp");
    auto released = service_->_lastResponse;
    Record(released);
    SettleNormalDelivery("assert:Esc-real-down-up-both-report-empty-engine");
    Check("Esc-real-down-up-both-report-empty-engine", released != pressed &&
        EmptyEngineResponse(pressed) && EmptyEngineResponse(released));
    return released;
  }
  void CommitThenEscape(bool rejectLatest, bool rejectGrant = false) {
    Type(a_, "abc");
    SettleNormalDelivery("assert:precondition-genuine-preedit-has-candidate-data");
    Check("precondition-genuine-preedit-has-candidate-data", CandidateCount() > 0 &&
        service_->_status.composing && service_->_IsComposing());
    ObserveUI("before-full-commit");
    a_->synchronous = false;
    auto committed = Produce(a_, 0x20); // real full candidate selection / IPC
    SettleNormalDelivery("assert:precondition-full-commit-reports-engine-empty");
    Check("precondition-full-commit-reports-engine-empty", committed->response->commit == L"cn01" &&
        !committed->response->status.composing && committed->response->context.preedit.str.empty() &&
        committed->response->context.cinfo.candies.empty() && !committed->textWritten);
    auto clear = EscapeStroke(a_);
    SettleNormalDelivery("assert:Esc-latest-empty-packet-follows-pending-full-commit");
    Check("Esc-latest-empty-packet-follows-pending-full-commit", service_->_lastResponse == clear &&
        clear->kind == response_owner::WorkKind::EndDraft && clear->compositionClosed &&
        clear->stage == Stage::Done && a_->pending.size() == 1 && !committed->textWritten);
    ObserveUI("before-commit-grant");
    out_ << "LEGACY_ASSUMPTION empty terminal UI requested RW after P; "
         << "new pipeline may make the old rejection hook unreachable" << std::endl;
    unsigned followingRequests = 0;
    if (rejectLatest) {
      // The two real Esc events follow P. Admit down, refuse only the latest
      // up/empty packet's RequestEditSession using existing host capability.
      a_->store->beforeRequest = [&]() {
        ++followingRequests;
        a_->store->beforeRequest = [&]() {
          ++followingRequests;
          if (rejectGrant)
            a_->failNextSession = TF_E_SYNCHRONOUS;
          else
            a_->failNextRequest = E_FAIL;
        };
      };
    }
    Require(a_->GrantOne(), "grant only full-commit P");
    SettleNormalDelivery("assert:P-full-text-delivered-once-and-composition-closed");
    Check("P-full-text-delivered-once-and-composition-closed", committed->stage == Stage::Done &&
        committed->textWritten && committed->writeAttempts == 1 && committed->compositionClosed &&
        a_->store->text == L"prefix|cn01" && a_->store->imeWrites == 1 && !service_->_IsComposing());
    ObserveUI("after-only-P-grant");
    TracePacket(committed); TracePacket(clear);
    if (rejectLatest) {
      SettleNormalDelivery("assert:V15-only-latest-empty-E-grant-is-rejected-after-S_OK-request");
      Check(rejectGrant ? "V15-only-latest-empty-E-grant-is-rejected-after-S_OK-request" :
          "V12-only-latest-empty-E-request-is-rejected", followingRequests == 2 &&
          clear->stage == Stage::Failed && FAILED(clear->writeResult) && a_->pending.size() == 1 &&
          (!rejectGrant || clear->writeResult == TF_E_SYNCHRONOUS));
    } else {
      SettleNormalDelivery("assert:V11-empty-E-is-still-pending-after-P");
      Check("V11-empty-E-is-still-pending-after-P", clear->stage == Stage::NoCommit && a_->pending.size() == 2);
    }
    a_->Drain(); // normal old/down packet is discarded; latest/up owns UI
    ObserveUI("after-drain");
    TracePacket(clear);
    SettleNormalDelivery("assert:full-commit-and-Esc-never-clear-or-duplicate-host-text");
    Check("full-commit-and-Esc-never-clear-or-duplicate-host-text", a_->pending.empty() &&
        a_->store->text == L"prefix|cn01" && a_->store->imeWrites == 1 && a_->store->writes == 1 &&
        b_->store->text == L"other|" && b_->store->imeWrites == 0 && EmptyEngineResponse(clear));
    BOOL shown = TRUE;
    Require(service_->_cand->IsShown(&shown), "latest empty response candidate visibility");
    SettleNormalDelivery("assert:V15-latest-empty-E-clears-candidate-data-after-grant-refusal");
    Check(rejectGrant ? "V15-latest-empty-E-clears-candidate-data-after-grant-refusal" :
        rejectLatest ? "V12-latest-empty-E-clears-candidate-data-after-request-refusal" :
        "V11-latest-empty-E-clears-candidate-data-after-normal-drain", CandidateCount() == 0 && !shown);
    NoHostOrCookieErrors("no-cross-owner-write-or-artificial-host-write");
  }
  void RejectedOldEmptyKeepsNewOwner() {
    Type(a_, "abc");
    SettleNormalDelivery("assert:V15-old-empty-precondition-A-shows-real-cn01");
    Check("V15-old-empty-precondition-A-shows-real-cn01", CandidateCount() > 0 &&
        FirstCandidate() == L"cn01" && service_->_IsComposing());
    bool reentered = false;
    std::shared_ptr<Packet> capturedA;
    a_->store->beforeRequest = [&] {
      reentered = true;
      capturedA = service_->_lastResponse;
      Type(b_, "abcd");
      a_->failNextRequest = E_FAIL;
    };
    // Escape is a genuine product producer/IPC response. Reenter B only after
    // A's empty response was copied, before its own edit request is rejected.
    Produce(a_, 0xff1b);
    auto latest = service_->_lastResponse;
    SettleNormalDelivery("assert:V15-old-empty-A-request-fails-after-real-B-reentry");
    Check("V15-old-empty-A-request-fails-after-real-B-reentry", reentered && capturedA &&
        capturedA != latest && EmptyEngineResponse(capturedA) &&
        capturedA->stage == Stage::Failed && FAILED(capturedA->writeResult));
    SettleNormalDelivery("assert:V15-old-empty-A-failure-never-retires-new-B-candidate-data");
    Check("V15-old-empty-A-failure-never-retires-new-B-candidate-data", latest &&
        latest->source && latest->source->owner.p == b_.p &&
        latest->response->status.composing && HasPreedit(latest, L"abcd") &&
        HasFirst(latest, L"cn02") && FirstCandidate() == L"cn02" && CandidateCount() > 0 &&
        service_->_status.composing && service_->_IsComposing() &&
        service_->_pEditSessionContext.p == b_.p);
    SettleNormalDelivery("assert:V15-old-empty-reentry-never-writes-either-host");
    Check("V15-old-empty-reentry-never-writes-either-host", a_->store->text == L"prefix|" &&
        b_->store->text == L"other|" && a_->store->writes == 0 && b_->store->writes == 0 &&
        a_->pending.empty() && b_->pending.empty());
    TracePacket(capturedA); TracePacket(latest);
    NoHostOrCookieErrors("V15-old-empty-reentry-keeps-owner-and-cookie-boundaries");
  }
  void RejectedComposingKeepsPreviousUi() {
    Type(a_, "abc");
    SettleNormalDelivery("assert:V15-composing-refusal-precondition-old-cn01-is-visible-data");
    Check("V15-composing-refusal-precondition-old-cn01-is-visible-data", CandidateCount() > 0 &&
        FirstCandidate() == L"cn01" && service_->_status.composing);
    a_->failNextRequest = E_FAIL;
    auto latest = Produce(a_, 'd');
    SettleNormalDelivery("assert:V15-refused-latest-composing-packet-is-not-delivered-or-empty");
    Check("V15-refused-latest-composing-packet-is-not-delivered-or-empty", latest->stage == Stage::Failed &&
        FAILED(latest->writeResult) && !latest->deliveryStarted && !latest->textWritten &&
        latest->response->status.composing && HasPreedit(latest, L"abcd") &&
        HasFirst(latest, L"cn02") && !EmptyEngineResponse(latest));
    SettleNormalDelivery("assert:V15-refused-composing-response-does-not-clear-ui-or-write-text");
    Check("V15-refused-composing-response-does-not-clear-ui-or-write-text", CandidateCount() > 0 &&
        FirstCandidate() == L"cn01" && service_->_status.composing &&
        a_->store->text == L"prefix|" && b_->store->text == L"other|" &&
        a_->store->writes == 0 && b_->store->writes == 0 && a_->pending.empty());
    TracePacket(latest);
    NoHostOrCookieErrors("V15-refused-composing-response-is-not-empty-ui-success");
  }
  void RejectedCommitCannotWriteWithoutGrant() {
    Type(a_, "abc");
    SettleNormalDelivery("assert:V15-no-grant-precondition-real-A-composition-and-empty-host");
    Check("V15-no-grant-precondition-real-A-composition-and-empty-host", service_->_IsComposing() &&
        FirstCandidate() == L"cn01" && a_->store->text == L"prefix|" && a_->store->writes == 0);
    a_->failNextSession = TF_E_SYNCHRONOUS;
    auto committed = Produce(a_, 0x20);
    SettleNormalDelivery("assert:V15-S_OK-request-with-refused-commit-grant-never-writes");
    Check("V15-S_OK-request-with-refused-commit-grant-never-writes", committed->response->commit == L"cn01" &&
        committed->stage == Stage::Failed && committed->writeResult == TF_E_SYNCHRONOUS &&
        !committed->textWritten && committed->writeAttempts == 0 &&
        a_->store->text == L"prefix|" && a_->store->writes == 0 && a_->pending.empty());
    Replay(committed); a_->Drain(); b_->Drain();
    SettleNormalDelivery("assert:V15-refused-commit-replay-is-finite-and-cannot-use-UI-retirement-as-text-delivery");
    Check("V15-refused-commit-replay-is-finite-and-cannot-use-UI-retirement-as-text-delivery",
        committed->stage == Stage::Failed && !committed->textWritten && committed->writeAttempts == 0 &&
        a_->store->text == L"prefix|" && b_->store->text == L"other|" &&
        a_->store->writes == 0 && b_->store->writes == 0 && a_->pending.empty() && b_->pending.empty());
    TracePacket(committed);
    NoHostOrCookieErrors("V15-refused-commit-never-writes-without-own-edit-cookie");
  }
  void RejectedEmptyKeepsOutstandingComposition() {
    Type(a_, "abc");
    auto composition = service_->_pComposition;
    const auto endAttempts = a_->store->endAttempts;
    const auto attributeClears = a_->store->attributeClears;
    const auto selectionWrites = a_->store->selectionWrites;
    a_->failNextRequest = E_FAIL;
    // Real TestKeyDown plus its matched actual callback, without an Up that
    // could provide a later successful edit grant and conceal this boundary.
    auto rejected = CallbackDown(a_, VK_ESCAPE).packet;
    SettleNormalDelivery("assert:V15-empty-engine-with-outstanding-local-composition-is-not-UI-only-retirement");
    Check("V15-empty-engine-with-outstanding-local-composition-is-not-UI-only-retirement",
        composition && EmptyEngineResponse(rejected) && rejected->stage == Stage::Failed &&
        FAILED(rejected->writeResult) && !rejected->deliveryStarted && !rejected->textWritten &&
        service_->_IsComposing() && service_->_pComposition == composition &&
        CandidateCount() > 0 && FirstCandidate() == L"cn01" &&
        a_->store->text == L"prefix|" && b_->store->text == L"other|" &&
        a_->store->endAttempts == endAttempts && a_->store->attributeClears == attributeClears &&
        a_->store->selectionWrites == selectionWrites && a_->store->writes == 0 && b_->store->writes == 0 &&
        a_->store->hostWrites == 0 && b_->store->hostWrites == 0 &&
        a_->store->ownerErrors == 0 && b_->store->ownerErrors == 0 && a_->pending.empty());
    TracePacket(rejected);
  }
  struct DownResult {
    std::shared_ptr<Packet> packet;
    BOOL tested = FALSE;
    BOOL eaten = FALSE;
    bool actualCalled = false;
  };
  static LPARAM KeyInfoFor(UINT key, bool release) {
    LPARAM info = 1 | (static_cast<LPARAM>(MapVirtualKey(key, MAPVK_VK_TO_VSC)) << 16);
    if (release) info |= (static_cast<LPARAM>(1) << 30) | (static_cast<LPARAM>(1) << 31);
    return info;
  }
  DownResult CallbackDown(Context* owner, UINT key, bool deliverActual = true) {
    DownResult result;
    Require(service_->OnTestKeyDown(owner, key, KeyInfoFor(key, false), &result.tested), "real TestKeyDown");
    if (result.tested && deliverActual) {
      result.actualCalled = true;
      Require(service_->OnKeyDown(owner, key, KeyInfoFor(key, false), &result.eaten), "real KeyDown");
    }
    result.packet = Record(service_->_lastResponse);
    out_ << "KEY_DISPOSITION phase=down-Test owner=" << owner->store->name
         << " key=" << key << " tested=" << result.tested << " eaten=" << result.eaten
         << " actual=" << result.actualCalled << " producerCalls=" << rymcpRetainedKeyCalls
         << " generation=" << service_->m_client.ResponseGeneration() << std::endl;
    return result;
  }
  DownResult ActualDown(Context* owner, UINT key, bool repeat = false) {
    DownResult result;
    result.actualCalled = true;
    const LPARAM info = KeyInfoFor(key, false) |
        (repeat ? (static_cast<LPARAM>(1) << 30) : 0);
    Require(service_->OnKeyDown(owner, key, info, &result.eaten), "real actual-only KeyDown");
    result.packet = Record(service_->_lastResponse);
    out_ << "KEY_DISPOSITION phase=down-Actual owner=" << owner->store->name
         << " key=" << key << " tested=" << result.tested << " eaten=" << result.eaten
         << " actual=" << result.actualCalled << " producerCalls=" << rymcpRetainedKeyCalls
         << " generation=" << service_->m_client.ResponseGeneration() << std::endl;
    return result;
  }
  struct UpResult {
    std::shared_ptr<Packet> packet;
    BOOL tested = FALSE;
    BOOL eaten = FALSE;
    bool actualCalled = false;
  };
  UpResult CallbackRelease(Context* owner, UINT key, bool deliverActual = true) {
    UpResult result;
    Require(service_->OnTestKeyUp(owner, key, KeyInfoFor(key, true), &result.tested), "real TestKeyUp");
    if (result.tested && deliverActual) {
      result.actualCalled = true;
      Require(service_->OnKeyUp(owner, key, KeyInfoFor(key, true), &result.eaten), "real KeyUp");
    }
    result.packet = Record(service_->_lastResponse);
    out_ << "KEY_DISPOSITION phase=up-Test owner=" << owner->store->name
         << " key=" << key << " tested=" << result.tested << " eaten=" << result.eaten
         << " actual=" << result.actualCalled << " producerCalls=" << rymcpRetainedKeyCalls
         << " generation=" << service_->m_client.ResponseGeneration() << std::endl;
    return result;
  }
  UpResult ActualUp(Context* owner, UINT key) {
    UpResult result;
    result.actualCalled = true;
    Require(service_->OnKeyUp(owner, key, KeyInfoFor(key, true), &result.eaten), "real actual-only KeyUp");
    result.packet = Record(service_->_lastResponse);
    out_ << "KEY_DISPOSITION phase=up-Actual owner=" << owner->store->name
         << " key=" << key << " tested=" << result.tested << " eaten=" << result.eaten
         << " actual=" << result.actualCalled << " producerCalls=" << rymcpRetainedKeyCalls
         << " generation=" << service_->m_client.ResponseGeneration() << std::endl;
    return result;
  }
  std::shared_ptr<Packet> CallbackUp(Context* owner, UINT key) {
    return CallbackRelease(owner, key).packet;
  }
  void TypeCallbacks(Context* owner, const char* upper) {
    for (const char* ch = upper; *ch; ++ch) {
      CallbackDown(owner, static_cast<UINT>(*ch));
      CallbackUp(owner, static_cast<UINT>(*ch));
    }
    SettleNormalDelivery("normal-TypeCallbacks-return");
  }
  static bool HasPreedit(const std::shared_ptr<Packet>& packet, const std::wstring& raw) {
    if (!packet || !packet->response) return false;
    const auto& text = packet->response->context.preedit.str;
    // Existing public fixture may include the native U+2038 soft cursor at end.
    return text == raw || text == raw + L"\u2038";
  }
  static bool HasFirst(const std::shared_ptr<Packet>& packet, const wchar_t* text) {
    return packet && packet->response && !packet->response->context.cinfo.candies.empty() &&
        packet->response->context.cinfo.candies.front().str == text;
  }
  std::wstring FirstCandidate() {
    if (CandidateCount() == 0) return L"";
    BSTR text = nullptr;
    Require(service_->_cand->GetString(0, &text), "read genuine UI candidate");
    const std::wstring result = text ? text : L"";
    SysFreeString(text);
    return result;
  }
  void ObserveControl(const char* label, const std::shared_ptr<Packet>& packet) {
    ObserveUI(label);
    auto candidate = service_->_cand->RegisteredIntent();
    out_ << "OBSERVE " << label << " uiFirstUtf16=" << Hex(FirstCandidate())
         << " candidateIntent=" << (candidate ? candidate->token : 0)
         << " currentIntent=" << (service_->_responseIntent ? service_->_responseIntent->token : 0)
         << " latestPacket=" << (service_->_lastResponse == packet)
         << " attributeClears=" << a_->store->attributeClears << std::endl;
    TracePacket(packet);
  }
  void PendingCallbackControl() {
    // Normal Test/actual pairing and independent next strokes retain the
    // original one-engine-send behavior. No product pending state is assigned.
    auto normalA = CallbackDown(a_, 'A');
    SettleNormalDelivery("assert:V13-normal-A-is-one-handled-real-callback");
    Check("V13-normal-A-is-one-handled-real-callback", normalA.tested && normalA.actualCalled &&
        normalA.eaten && HasPreedit(normalA.packet, L"a") && normalA.packet->response->status.composing);
    CallbackUp(a_, 'A');
    auto normalB = CallbackDown(a_, 'B');
    SettleNormalDelivery("assert:V13-normal-next-B-has-new-producer-and-ab");
    Check("V13-normal-next-B-has-new-producer-and-ab", normalB.tested && normalB.actualCalled &&
        normalB.packet != normalA.packet && HasPreedit(normalB.packet, L"ab"));
    CallbackUp(a_, 'B');
    NoHostOrCookieErrors("V13-normal-callbacks-do-not-write-host-text");
    Fresh();

    // Word-style repeated tests must still share the same genuine response.
    auto firstTest = CallbackDown(a_, 'A', false);
    const auto firstGeneration = service_->m_client.ResponseGeneration();
    auto secondTest = CallbackDown(a_, 'A', false);
    SettleNormalDelivery("assert:V13-repeated-same-key-TestDown-does-not-reenter-engine");
    Check("V13-repeated-same-key-TestDown-does-not-reenter-engine", firstTest.tested && secondTest.tested &&
        firstTest.packet == secondTest.packet && service_->m_client.ResponseGeneration() == firstGeneration &&
        HasPreedit(secondTest.packet, L"a"));
    auto pairedActual = ActualDown(a_, 'A');
    SettleNormalDelivery("assert:V13-actual-after-repeated-TestDown-consumes-once");
    Check("V13-actual-after-repeated-TestDown-consumes-once", pairedActual.eaten &&
        pairedActual.packet == firstTest.packet && service_->m_client.ResponseGeneration() == firstGeneration);
    CallbackUp(a_, 'A');
    NoHostOrCookieErrors("V13-repeated-Test-controls-do-not-write-host-text");
    Fresh();

    // Some hosts issue only actual callbacks. A complete earlier stroke must
    // not suppress a second same-key repeat, including its previous-state bit.
    auto onlyActual = ActualDown(a_, 'A');
    SettleNormalDelivery("assert:V13-actual-only-down-enters-engine");
    Check("V13-actual-only-down-enters-engine", onlyActual.eaten && HasPreedit(onlyActual.packet, L"a"));
    auto repeatedActual = ActualDown(a_, 'A', true);
    SettleNormalDelivery("assert:V13-actual-only-autorepeat-is-a-new-engine-event");
    Check("V13-actual-only-autorepeat-is-a-new-engine-event", repeatedActual.eaten &&
        repeatedActual.packet != onlyActual.packet && HasPreedit(repeatedActual.packet, L"aa"));
    auto onlyUp = ActualUp(a_, 'A');
    SettleNormalDelivery("assert:V13-actual-only-up-enters-engine");
    Check("V13-actual-only-up-enters-engine", onlyUp.packet != repeatedActual.packet &&
        HasPreedit(onlyUp.packet, L"aa"));
    auto twiceUp = ActualUp(a_, 'A');
    SettleNormalDelivery("assert:V13-second-actual-only-up-retains-existing-pass-through");
    Check("V13-second-actual-only-up-retains-existing-pass-through", twiceUp.packet != onlyUp.packet &&
        HasPreedit(twiceUp.packet, L"aa"));
    NoHostOrCookieErrors("V13-actual-only-controls-do-not-write-host-text");
    Fresh();

    // Deliberately omit A's actual callback and its release. The repaired B
    // path must enter the engine, unlike the saved 61021 failure control.
    auto missingA = CallbackDown(a_, 'A', false);
    const auto generation = service_->m_client.ResponseGeneration();
    SettleNormalDelivery("assert:V13-missing-actual-A-has-one-genuine-response");
    Check("V13-missing-actual-A-has-one-genuine-response", missingA.tested && !missingA.actualCalled &&
        HasPreedit(missingA.packet, L"a") && generation != 0);
    auto nextB = CallbackDown(a_, 'B');
    SettleNormalDelivery("assert:V13-next-different-B-is-processed-exactly-once");
    Check("V13-next-different-B-is-processed-exactly-once", nextB.tested && nextB.actualCalled &&
        nextB.eaten && nextB.packet != missingA.packet &&
        service_->m_client.ResponseGeneration() != generation && HasPreedit(nextB.packet, L"ab"));
    ObserveControl("V13-repaired-omitted-A-then-B", nextB.packet);
    CallbackUp(a_, 'A'); CallbackUp(a_, 'B');
    auto recoveryB = CallbackDown(a_, 'B');
    SettleNormalDelivery("assert:V13-next-complete-stroke-and-autorepeat-remain-independent");
    Check("V13-next-complete-stroke-and-autorepeat-remain-independent", recoveryB.packet != nextB.packet &&
        HasPreedit(recoveryB.packet, L"abb") && recoveryB.packet->response->status.composing);
    CallbackUp(a_, 'B');
    NoHostOrCookieErrors("V13-fault-and-recovery-have-no-host-write-or-wrong-cookie");
    Fresh();

    // Two test-only keys can both still receive their actual callbacks. A
    // single replaceable pending slot would turn these into duplicate input.
    CallbackDown(a_, 'A', false);
    auto testOnlyB = CallbackDown(a_, 'B', false);
    const auto afterTwoTests = service_->m_client.ResponseGeneration();
    SettleNormalDelivery("assert:V13-overlapping-TestDown-A-B-process-two-keys");
    Check("V13-overlapping-TestDown-A-B-process-two-keys", HasPreedit(testOnlyB.packet, L"ab"));
    auto delayedActualA = ActualDown(a_, 'A');
    SettleNormalDelivery("assert:V13-late-actual-A-does-not-resend-after-Test-B");
    Check("V13-late-actual-A-does-not-resend-after-Test-B", delayedActualA.eaten &&
        delayedActualA.packet == testOnlyB.packet && service_->m_client.ResponseGeneration() == afterTwoTests &&
        HasPreedit(delayedActualA.packet, L"ab"));
    auto delayedActualB = ActualDown(a_, 'B');
    SettleNormalDelivery("assert:V13-late-actual-B-also-does-not-resend");
    Check("V13-late-actual-B-also-does-not-resend", delayedActualB.eaten &&
        delayedActualB.packet == testOnlyB.packet && service_->m_client.ResponseGeneration() == afterTwoTests &&
        HasPreedit(delayedActualB.packet, L"ab"));
    NoHostOrCookieErrors("V13-overlapping-actual-callbacks-keep-host-unchanged");
    CallbackUp(a_, 'A'); CallbackUp(a_, 'B');
    auto rawCommit = ActualDown(a_, VK_RETURN);
    SettleNormalDelivery("assert:V13-overlapping-Test-actual-sequence-commits-only-raw-ab");
    Check("V13-overlapping-Test-actual-sequence-commits-only-raw-ab", rawCommit.packet->response->commit == L"ab" &&
        a_->store->text == L"prefix|ab" && a_->store->imeWrites == 1 &&
        b_->store->text == L"other|" && b_->store->imeWrites == 0 &&
        a_->store->ownerErrors == 0 && b_->store->ownerErrors == 0);
    Fresh();

    auto missingActualA = CallbackDown(a_, 'A', false);
    auto actualOnlyB = ActualDown(a_, 'B');
    SettleNormalDelivery("assert:V13-different-actual-only-B-does-not-consume-A");
    Check("V13-different-actual-only-B-does-not-consume-A", actualOnlyB.eaten &&
        actualOnlyB.packet != missingActualA.packet && HasPreedit(actualOnlyB.packet, L"ab"));
    NoHostOrCookieErrors("V13-missing-A-actual-only-B-keeps-host-unchanged");
    Fresh();

    CallbackDown(a_, 'A', false);
    auto pendingB = CallbackDown(a_, 'B', false);
    SettleNormalDelivery("assert:V13-B-TestDown-replaces-different-A-with-real-ab");
    Check("V13-B-TestDown-replaces-different-A-with-real-ab", pendingB.tested && HasPreedit(pendingB.packet, L"ab"));
    auto lateUpA = CallbackUp(a_, 'A');
    const auto afterLateUp = service_->m_client.ResponseGeneration();
    auto actualAfterLateUp = ActualDown(a_, 'B');
    SettleNormalDelivery("assert:V13-A-release-between-B-Test-and-actual-does-not-resend-B");
    Check("V13-A-release-between-B-Test-and-actual-does-not-resend-B", actualAfterLateUp.eaten &&
        actualAfterLateUp.packet == lateUpA && service_->m_client.ResponseGeneration() == afterLateUp &&
        HasPreedit(actualAfterLateUp.packet, L"ab"));
    CallbackUp(a_, 'B');
    NoHostOrCookieErrors("V13-interleaved-release-keeps-host-unchanged");
    Fresh();

    auto contextA = CallbackDown(a_, 'A', false);
    auto contextB = CallbackDown(b_, 'A', false);
    SettleNormalDelivery("assert:V13-same-key-in-different-context-enters-new-owner");
    Check("V13-same-key-in-different-context-enters-new-owner", contextB.tested &&
        contextB.packet != contextA.packet && contextB.packet->source &&
        contextB.packet->source->owner.p == b_.p && HasPreedit(contextA.packet, L"a") &&
        HasPreedit(contextB.packet, L"a"));
    const auto contextGeneration = service_->m_client.ResponseGeneration();
    const auto contextKeyCalls = rymcpRetainedKeyCalls;
    auto contextActualB = ActualDown(b_, 'A');
    SettleNormalDelivery("assert:V13-new-context-actual-consumes-only-its-own-Test");
    Check("V13-new-context-actual-consumes-only-its-own-Test", contextActualB.eaten &&
        contextActualB.packet == contextB.packet && service_->m_client.ResponseGeneration() == contextGeneration &&
        rymcpRetainedKeyCalls == contextKeyCalls);
    NoHostOrCookieErrors("V13-context-identity-never-writes-other-owner-text");
    Fresh();
    PendingReleaseControl();
  }
  void PendingReleaseControl() {
    // These two public, non-text key_binder actions make Rime genuinely
    // accept F13/F14 release events. Ordinary alphabet releases remain intact.
    TypeCallbacks(a_, "A");
    auto upTestA = CallbackRelease(a_, VK_F13, false);
    const auto firstUpGeneration = service_->m_client.ResponseGeneration();
    SettleNormalDelivery("assert:V13-release-binding-produces-real-handled-TestUp");
    Check("V13-release-binding-produces-real-handled-TestUp", upTestA.tested &&
        !upTestA.actualCalled && HasPreedit(upTestA.packet, L"a"));
    auto duplicateTestA = CallbackRelease(a_, VK_F13, false);
    SettleNormalDelivery("assert:V13-repeated-same-key-TestUp-does-not-reenter-engine");
    Check("V13-repeated-same-key-TestUp-does-not-reenter-engine", duplicateTestA.tested &&
        duplicateTestA.packet == upTestA.packet && service_->m_client.ResponseGeneration() == firstUpGeneration);
    auto actualUpA = ActualUp(a_, VK_F13);
    SettleNormalDelivery("assert:V13-actual-after-repeated-TestUp-consumes-once");
    Check("V13-actual-after-repeated-TestUp-consumes-once", actualUpA.eaten &&
        actualUpA.packet == upTestA.packet && service_->m_client.ResponseGeneration() == firstUpGeneration);
    auto onlyActualUp = ActualUp(a_, VK_F13);
    SettleNormalDelivery("assert:V13-handled-actual-only-Up-still-enters-engine");
    Check("V13-handled-actual-only-Up-still-enters-engine", onlyActualUp.eaten &&
        onlyActualUp.packet != actualUpA.packet && HasPreedit(onlyActualUp.packet, L"a"));
    NoHostOrCookieErrors("V13-real-release-binding-never-commits-host-text");
    Fresh(); TypeCallbacks(a_, "A");

    auto omittedUpA = CallbackRelease(a_, VK_F13, false);
    auto nextUpB = CallbackRelease(a_, VK_F14);
    SettleNormalDelivery("assert:V13-different-B-TestUp-and-actual-do-not-consume-A-Up");
    Check("V13-different-B-TestUp-and-actual-do-not-consume-A-Up", nextUpB.tested && nextUpB.actualCalled &&
        nextUpB.eaten && nextUpB.packet != omittedUpA.packet && HasPreedit(nextUpB.packet, L"a"));
    auto omittedAgainA = CallbackRelease(a_, VK_F13, false);
    auto onlyB = ActualUp(a_, VK_F14);
    SettleNormalDelivery("assert:V13-different-actual-only-B-Up-enters-engine");
    Check("V13-different-actual-only-B-Up-enters-engine", onlyB.eaten &&
        onlyB.packet != omittedAgainA.packet && HasPreedit(onlyB.packet, L"a"));
    NoHostOrCookieErrors("V13-different-release-controls-keep-host-unchanged");
    Fresh(); TypeCallbacks(a_, "A");

    CallbackRelease(a_, VK_F13, false);
    auto overlappingUpB = CallbackRelease(a_, VK_F14, false);
    const auto twoUpGeneration = service_->m_client.ResponseGeneration();
    auto delayedActualUpA = ActualUp(a_, VK_F13);
    SettleNormalDelivery("assert:V13-overlapping-release-late-A-actual-does-not-resend");
    Check("V13-overlapping-release-late-A-actual-does-not-resend", delayedActualUpA.eaten &&
        delayedActualUpA.packet == overlappingUpB.packet &&
        service_->m_client.ResponseGeneration() == twoUpGeneration);
    auto delayedActualUpB = ActualUp(a_, VK_F14);
    SettleNormalDelivery("assert:V13-overlapping-release-late-B-actual-does-not-resend");
    Check("V13-overlapping-release-late-B-actual-does-not-resend", delayedActualUpB.eaten &&
        delayedActualUpB.packet == overlappingUpB.packet &&
        service_->m_client.ResponseGeneration() == twoUpGeneration && HasPreedit(delayedActualUpB.packet, L"a"));
    NoHostOrCookieErrors("V13-overlapping-release-controls-keep-host-unchanged");
    Fresh(); TypeCallbacks(a_, "A");

    CallbackRelease(a_, VK_F13, false);
    auto pendingUpB = CallbackRelease(a_, VK_F14, false);
    SettleNormalDelivery("assert:V13-B-TestUp-is-a-genuine-distinct-event");
    Check("V13-B-TestUp-is-a-genuine-distinct-event", pendingUpB.tested && HasPreedit(pendingUpB.packet, L"a"));
    auto interveningDown = CallbackDown(a_, 'A');
    const auto afterDown = service_->m_client.ResponseGeneration();
    auto actualAfterDown = ActualUp(a_, VK_F14);
    SettleNormalDelivery("assert:V13-unrelated-down-between-B-TestUp-and-actual-does-not-resend");
    Check("V13-unrelated-down-between-B-TestUp-and-actual-does-not-resend", actualAfterDown.eaten &&
        actualAfterDown.packet == interveningDown.packet && service_->m_client.ResponseGeneration() == afterDown &&
        HasPreedit(actualAfterDown.packet, L"aa"));
    NoHostOrCookieErrors("V13-interleaved-down-and-release-keep-host-unchanged");
    Fresh(); TypeCallbacks(a_, "A");

    auto ownerA = CallbackRelease(a_, VK_F13, false);
    auto ownerB = CallbackRelease(b_, VK_F13, false);
    SettleNormalDelivery("assert:V13-same-release-key-in-other-context-enters-new-owner");
    Check("V13-same-release-key-in-other-context-enters-new-owner", ownerB.tested &&
        ownerB.packet != ownerA.packet && ownerB.packet->source && ownerB.packet->source->owner.p == b_.p &&
        HasPreedit(ownerA.packet, L"a") && EmptyEngineResponse(ownerB.packet));
    const auto ownerBGeneration = service_->m_client.ResponseGeneration();
    const auto ownerBKeyCalls = rymcpRetainedKeyCalls;
    auto actualOwnerB = ActualUp(b_, VK_F13);
    SettleNormalDelivery("assert:V13-new-context-Up-actual-consumes-only-its-own-Test");
    Check("V13-new-context-Up-actual-consumes-only-its-own-Test", actualOwnerB.eaten &&
        actualOwnerB.packet == ownerB.packet && service_->m_client.ResponseGeneration() == ownerBGeneration &&
        EmptyEngineResponse(actualOwnerB.packet) && rymcpRetainedKeyCalls == ownerBKeyCalls);
    NoHostOrCookieErrors("V13-release-context-identity-never-writes-other-owner-text");
  }
  void TerminationNextDraft(bool refuseLatest) {
    TypeCallbacks(a_, "ABC");
    // These are post-delivery snapshots. Never snapshot null before the
    // asynchronous Start, settle, then dereference the stale local pointer.
    SettleNormalDelivery("V14-before-composition-snapshots");
    auto initial = service_->_lastResponse;
    auto composition = service_->_pComposition;
    auto intent = service_->_responseIntent;
    const auto attributesBefore = a_->store->attributeClears;
    SettleNormalDelivery("assert:V14-real-abc-preedit-and-cn01-own-a-composition");
    Check("V14-real-abc-preedit-and-cn01-own-a-composition", composition && intent &&
        HasPreedit(initial, L"abc") && initial->response->status.composing &&
        HasFirst(initial, L"cn01") && FirstCandidate() == L"cn01");
    out_ << "MODEL_V14_SNAPSHOT composition=" << static_cast<bool>(composition)
         << " current=" << service_->_IsComposing() << " intent=" << static_cast<bool>(intent)
         << " queued=" << a_->pending.size() << std::endl;
    if (!composition || !intent) {
      out_ << "UNREACHED V14-followup-native-termination missing-composition-or-intent" << std::endl;
      throw std::runtime_error("V14 native termination precondition failed after normal grant boundary");
    }
    // This real host composition object calls production OnCompositionTerminated.
    // It retains the strict existing GetRange/End lifecycle, with no model patch.
    Require(composition->EndComposition(a_->store->cookie), "host termination of actual current composition");
    SettleNormalDelivery("assert:V14-termination-retires-TSF-and-attempts-attribute-clear");
    Check("V14-termination-retires-TSF-and-attempts-attribute-clear", !service_->_IsComposing() &&
        intent->terminated && a_->store->attributeClears == attributesBefore + 1 &&
        a_->store->text == L"prefix|" && a_->store->imeWrites == 0);
    a_->synchronous = false;
    auto status = Produce(a_, 0); // genuine IPC snapshot, held before TSF reattach
    SettleNormalDelivery("assert:V14-engine-reports-abc-after-termination-before-new-grant");
    Check("V14-engine-reports-abc-after-termination-before-new-grant", status->response->commit.empty() &&
        status->response->status.composing && HasPreedit(status, L"abc") &&
        HasFirst(status, L"cn01") && !service_->_IsComposing() && a_->pending.size() == 1);
    auto down = CallbackDown(a_, 'D');
    // Admit D-down, refuse only D-up's latest draft response. Old packets
    // must not fabricate a fresh UI/TSF success after that refusal.
    if (refuseLatest) a_->failNextRequest = E_FAIL;
    auto latest = CallbackUp(a_, 'D');
    SettleNormalDelivery("assert:V14-real-next-D-stroke-reports-abcd-cn02-as-latest");
    Check("V14-real-next-D-stroke-reports-abcd-cn02-as-latest", down.packet != latest &&
        service_->_lastResponse == latest && latest->response->commit.empty() &&
        latest->response->status.composing && HasPreedit(latest, L"abcd") && HasFirst(latest, L"cn02"));
    ObserveControl(refuseLatest ? "V14-refused-before-drain" : "V14-normal-before-drain", latest);
    a_->Drain();
    if (refuseLatest) {
      SettleNormalDelivery("assert:V14-refused-latest-draft-is-finite-and-not-reported-delivered");
      Check("V14-refused-latest-draft-is-finite-and-not-reported-delivered", latest->stage == Stage::Failed &&
          FAILED(latest->writeResult) && a_->pending.empty() && service_->_lastResponse == latest &&
          latest->response->status.composing && HasPreedit(latest, L"abcd"));
    } else {
      SettleNormalDelivery("assert:V14-normal-grant-reattaches-and-shows-current-cn02");
      Check("V14-normal-grant-reattaches-and-shows-current-cn02", latest->stage == Stage::NoCommit &&
          latest->deliveryStarted && a_->pending.empty() && service_->_IsComposing() &&
          FirstCandidate() == L"cn02");
    }
    ObserveControl(refuseLatest ? "V14-refused-after-drain" : "V14-normal-after-drain", latest);
    SettleNormalDelivery("assert:V14-neither-termination-nor-next-draft-commits-host-text");
    Check("V14-neither-termination-nor-next-draft-commits-host-text", a_->store->text == L"prefix|" &&
        b_->store->text == L"other|" && a_->store->writes == 0 && b_->store->writes == 0 &&
        a_->store->hostWrites == 0 && b_->store->hostWrites == 0 &&
        a_->store->ownerErrors == 0 && b_->store->ownerErrors == 0);
  }
// Paste these methods inside ResponseOwnerProductFixture. They exercise the
// real product methods with the existing Store/Range, real IPC and TSF manager.
// Register each through Group(...) in RunAll and update only its group count.

void SelectionCompareFocusReentry() {
  Type(a_, "abc");
  auto committed = Produce(a_, 0x20);
  SettleNormalDelivery("assert:response-selection-reentry-precondition-real-written-selection");
  Check("response-selection-reentry-precondition-real-written-selection",
      committed->stage == Stage::Done && committed->textWritten &&
      committed->source && committed->source->ownSelection &&
      a_->store->text == L"prefix|cn01" && a_->store->imeWrites == 1);
  if (!committed->source || !committed->source->ownSelection)
    throw std::runtime_error("missing product expected selection");

  bool reentered = false;
  a_->store->beforeRangeCompareReturn = [&] {
    out_ << "PROBE selection compare-reentry reached" << std::endl;
    reentered = true;
    Require(service_->OnKillThreadFocus(), "real focus cancellation inside range comparison");
    out_ << "PROBE selection focus-cancel returned ownSelection="
         << (committed->source->ownSelection ? 1 : 0) << std::endl;
  };
  const bool own = service_->_ObserveResponseSelection(a_, a_->store->cookie);
  SettleNormalDelivery("assert:response-selection-CompareStart-focus-reentry-returns-not-own");
  Check("response-selection-CompareStart-focus-reentry-returns-not-own",
      reentered && !own && committed->source->cancelled &&
      !committed->source->ownSelection && a_->store->text == L"prefix|cn01" &&
      a_->store->imeWrites == 1 && !service_->_IsComposing());
  Type(b_, "x");
  auto laterB = Produce(b_, 0xff0d);
  SettleNormalDelivery("assert:response-selection-after-reentry-B-is-still-writable-once");
  Check("response-selection-after-reentry-B-is-still-writable-once",
      laterB->stage == Stage::Done && laterB->response->commit == L"x" &&
      b_->store->text == L"other|x" && b_->store->imeWrites == 1 &&
      a_->store->text == L"prefix|cn01" && a_->store->imeWrites == 1);
  TracePacket(committed);
  NoHostOrCookieErrors("response-selection-reentry-owner-and-cookie-boundaries");
}

void CommitSelectionCleanupFailure() {
  Type(a_, "abc");
  BOOL shown = FALSE;
  Require(service_->_cand->IsShown(&shown), "visible candidates before failed selection cleanup");
  SettleNormalDelivery("assert:response-cleanup-precondition-real-candidate-and-composition");
  Check("response-cleanup-precondition-real-candidate-and-composition",
      shown && CandidateCount() > 0 && service_->_IsComposing());
  a_->store->selectionAvailable = false;
  auto committed = Produce(a_, 0x20);
  Require(service_->_cand->IsShown(&shown), "UI after actual commit selection failure");
  SettleNormalDelivery("assert:response-cleanup-written-error-preserved-with-no-repeat");
  Check("response-cleanup-written-error-preserved-with-no-repeat",
      committed->stage == Stage::Written && committed->textWritten &&
      committed->writeAttempts == 1 && FAILED(committed->cleanupResult) &&
      committed->compositionClosed && a_->store->text == L"prefix|cn01" &&
      a_->store->imeWrites == 1 && a_->store->ends == 1);
  SettleNormalDelivery("assert:response-cleanup-closed-empty-commit-retires-candidates");
  Check("response-cleanup-closed-empty-commit-retires-candidates",
      !committed->response->status.composing &&
      committed->response->context.preedit.str.empty() &&
      committed->response->context.cinfo.candies.empty() &&
      !service_->_IsComposing() && CandidateCount() == 0 && !shown);
  Replay(committed);
  SettleNormalDelivery("assert:response-cleanup-replay-still-never-resends-written-text");
  Check("response-cleanup-replay-still-never-resends-written-text",
      committed->stage == Stage::Written && committed->writeAttempts == 1 &&
      a_->store->text == L"prefix|cn01" && a_->store->imeWrites == 1);
  a_->store->selectionAvailable = true;
  TracePacket(committed);
  NoHostOrCookieErrors("response-cleanup-owner-and-cookie-boundaries");
}

  void NestedTestDownPublication(bool actualAFirst) {
    bool reentered = false;
    std::shared_ptr<Packet> capturedA;
    DownResult innerB;
    a_->store->beforeRequest = [&] {
      reentered = true;
      capturedA = Record(service_->_lastResponse);
      innerB = CallbackDown(b_, 'A', false);
    };
    auto outerA = CallbackDown(a_, 'A', false);
    const auto afterNestedTests = service_->m_client.ResponseGeneration();
    const auto callsAfterNestedTests = rymcpRetainedKeyCalls;
    SettleNormalDelivery("assert:keys-nested-Down-A-then-B-use-two-real-handled-Test-responses");
    Check("keys-nested-Down-A-then-B-use-two-real-handled-Test-responses", reentered &&
        outerA.tested && !outerA.actualCalled && innerB.tested && !innerB.actualCalled &&
        capturedA && innerB.packet != capturedA && HasPreedit(capturedA, L"a") &&
        HasPreedit(innerB.packet, L"a") && innerB.packet->source &&
        innerB.packet->source->owner.p == b_.p && service_->_lastResponse == innerB.packet);
    out_ << "KEYS_ORDER Down actual=" << (actualAFirst ? "A-B" : "B-A") << std::endl;
    auto firstActual = ActualDown(actualAFirst ? a_.p : b_.p, 'A');
    SettleNormalDelivery("assert:keys-nested-Down-A-first-first-actual-does-not-resend");
    Check(actualAFirst ? "keys-nested-Down-A-first-first-actual-does-not-resend" :
        "keys-nested-Down-B-first-first-actual-does-not-resend", firstActual.eaten &&
        firstActual.packet == innerB.packet && service_->m_client.ResponseGeneration() == afterNestedTests &&
        rymcpRetainedKeyCalls == callsAfterNestedTests &&
        HasPreedit(firstActual.packet, L"a"));
    TracePacket(firstActual.packet);
    auto secondActual = ActualDown(actualAFirst ? b_.p : a_.p, 'A');
    SettleNormalDelivery("assert:keys-nested-Down-A-first-second-actual-does-not-resend");
    Check(actualAFirst ? "keys-nested-Down-A-first-second-actual-does-not-resend" :
        "keys-nested-Down-B-first-second-actual-does-not-resend", secondActual.eaten &&
        secondActual.packet == innerB.packet && service_->m_client.ResponseGeneration() == afterNestedTests &&
        rymcpRetainedKeyCalls == callsAfterNestedTests &&
        HasPreedit(secondActual.packet, L"a"));
    SettleNormalDelivery("assert:keys-nested-Down-never-writes-or-clears-either-host");
    Check("keys-nested-Down-never-writes-or-clears-either-host", a_->store->text == L"prefix|" &&
        b_->store->text == L"other|" && a_->store->writes == 0 && b_->store->writes == 0 &&
        a_->store->hostWrites == 0 && b_->store->hostWrites == 0 &&
        a_->store->ownerErrors == 0 && b_->store->ownerErrors == 0);
    TracePacket(capturedA); TracePacket(innerB.packet); TracePacket(secondActual.packet);
  }

  void NestedTestUpPublication(bool actualAFirst) {
    TypeCallbacks(a_, "A");
    bool reentered = false;
    std::shared_ptr<Packet> capturedA;
    UpResult innerB;
    a_->store->beforeRequest = [&] {
      reentered = true;
      capturedA = Record(service_->_lastResponse);
      innerB = CallbackRelease(b_, VK_F13, false);
    };
    // The existing public Release+F13 binding is genuinely handled, with no
    // generated text. No hand-filled Packet, pending record or new host API.
    auto outerA = CallbackRelease(a_, VK_F13, false);
    const auto afterNestedTests = service_->m_client.ResponseGeneration();
    const auto callsAfterNestedTests = rymcpRetainedKeyCalls;
    SettleNormalDelivery("assert:keys-nested-Up-A-then-B-use-two-real-handled-release-responses");
    Check("keys-nested-Up-A-then-B-use-two-real-handled-release-responses", reentered &&
        outerA.tested && !outerA.actualCalled && innerB.tested && !innerB.actualCalled &&
        capturedA && innerB.packet != capturedA && HasPreedit(capturedA, L"a") &&
        EmptyEngineResponse(innerB.packet) && innerB.packet->source &&
        innerB.packet->source->owner.p == b_.p && service_->_lastResponse == innerB.packet);
    out_ << "KEYS_ORDER Up actual=" << (actualAFirst ? "A-B" : "B-A") << std::endl;
    auto firstActual = ActualUp(actualAFirst ? a_.p : b_.p, VK_F13);
    SettleNormalDelivery("assert:keys-nested-Up-A-first-first-actual-does-not-resend");
    Check(actualAFirst ? "keys-nested-Up-A-first-first-actual-does-not-resend" :
        "keys-nested-Up-B-first-first-actual-does-not-resend", firstActual.eaten &&
        firstActual.packet == innerB.packet && service_->m_client.ResponseGeneration() == afterNestedTests &&
        rymcpRetainedKeyCalls == callsAfterNestedTests &&
        EmptyEngineResponse(firstActual.packet));
    TracePacket(firstActual.packet);
    auto secondActual = ActualUp(actualAFirst ? b_.p : a_.p, VK_F13);
    SettleNormalDelivery("assert:keys-nested-Up-A-first-second-actual-does-not-resend");
    Check(actualAFirst ? "keys-nested-Up-A-first-second-actual-does-not-resend" :
        "keys-nested-Up-B-first-second-actual-does-not-resend", secondActual.eaten &&
        secondActual.packet == innerB.packet && service_->m_client.ResponseGeneration() == afterNestedTests &&
        rymcpRetainedKeyCalls == callsAfterNestedTests &&
        EmptyEngineResponse(secondActual.packet));
    SettleNormalDelivery("assert:keys-nested-Up-never-writes-or-clears-either-host");
    Check("keys-nested-Up-never-writes-or-clears-either-host", a_->store->text == L"prefix|" &&
        b_->store->text == L"other|" && a_->store->writes == 0 && b_->store->writes == 0 &&
        a_->store->hostWrites == 0 && b_->store->hostWrites == 0 &&
        a_->store->ownerErrors == 0 && b_->store->ownerErrors == 0);
    TracePacket(capturedA); TracePacket(innerB.packet); TracePacket(secondActual.packet);
  }

// Limited adoption tests derived from the saved real-manager diagnostic.
// No forced native visibility or callback-time rebuild; no product state fill.
// Uses NormalUiSinkScope and the existing real TSF/IPC/owner fixture.
struct UiRetirementSnapshot {
  HRESULT enumHr = E_PENDING;
  HRESULT nextHr = E_PENDING;
  bool complete = false;
  unsigned sameCandidateCount = 0;
  HRESULT getHr = E_PENDING;
  bool queriedIdIsCandidate = false;
};

UiRetirementSnapshot ReadUiRetirement(DWORD id, const char* phase, unsigned mode) {
  UiRetirementSnapshot result;
  com_ptr<ITfUIElementMgr> manager;
  Require(manager_->QueryInterface(IID_ITfUIElementMgr,
      reinterpret_cast<void**>(&manager)), "retirement real UI manager");
  com_ptr<IUnknown> expected;
  Require(service_->_cand->QueryInterface(IID_IUnknown,
      reinterpret_cast<void**>(&expected)), "retirement canonical candidate identity");
  auto sameCandidate = [&](ITfUIElement* element) {
    if (!element) return false;
    com_ptr<IUnknown> canonical;
    return element->QueryInterface(IID_IUnknown,
        reinterpret_cast<void**>(&canonical)) == S_OK && canonical.p == expected.p;
  };
  com_ptr<IEnumTfUIElements> items;
  result.enumHr = manager->EnumUIElements(&items);
  if (SUCCEEDED(result.enumHr) && items) {
    for (unsigned ordinal = 0; ordinal < 16; ++ordinal) {
      com_ptr<ITfUIElement> element;
      ULONG fetched = 0;
      result.nextHr = items->Next(1, &element, &fetched);
      if (result.nextHr == S_FALSE && fetched == 0) {
        result.complete = true;
        break;
      }
      if (result.nextHr != S_OK || fetched != 1 || !element) break;
      if (sameCandidate(element)) ++result.sameCandidateCount;
    }
  }
  com_ptr<ITfUIElement> element;
  result.getHr = manager->GetUIElement(id, &element);
  if (SUCCEEDED(result.getHr)) result.queriedIdIsCandidate = sameCandidate(element);
  out_ << "UIRETIRE mode=" << mode << " phase=" << phase << " queriedId=" << id
       << " enumHr=" << static_cast<LONG>(result.enumHr)
       << " complete=" << result.complete << " own=" << result.sameCandidateCount
       << " getHr=" << static_cast<LONG>(result.getHr)
       << " queriedIsOwn=" << result.queriedIdIsCandidate << std::endl;
  return result;
}

// mode 0: ordinary A blur then B; mode 1: A commit Update reentry to B draft;
// mode 2: composing A Update reentry to B draft then real B Space selection.
// Each mode has 4 original ownership/text checks + 3 registration checks.
void UiRetirementLifecycle(unsigned mode) {
  if (mode > 2) throw std::runtime_error("invalid finite UI retirement mode");
  NormalUiSinkScope host;
  Require(host.Advise(manager_), "retirement real UI sink registration");
  Type(a_, mode == 2 ? "ab" : "abc");
  if (host.sink->beginIds.size() != 1 || host.sink->beginChoices.front())
    throw std::runtime_error("retirement requires genuine integrated A Begin");
  const DWORD oldId = host.sink->beginIds.front();
  bool entered = false;
  std::shared_ptr<Packet> capturedA, bDraft, bCommit;
  auto enterB = [&] {
    entered = true;
    Require(service_->OnKillThreadFocus(), "retirement real product blur");
    Require(manager_->SetFocus(docB_), "retirement real manager B focus");
    bDraft = Produce(b_, 'x');
    if (mode == 2) bCommit = Produce(b_, 0x20);
  };
  if (mode == 0) {
    capturedA = Record(service_->_lastResponse);
    enterB();
  } else {
    host.sink->onUpdate = [&](DWORD) {
      capturedA = Record(service_->_lastResponse);
      enterB();
    };
    Produce(a_, mode == 1 ? 0x20 : 'c');
    if (host.sink->failure) std::rethrow_exception(host.sink->failure);
  }
  SettleNormalDelivery("ui-retirement-before-native-registration-snapshots");
  // Observe after the complete old Update tail. A real B draft now resumes
  // immediately; a B draft that already committed still leaves no UI.
  // Msctf may reuse oldId, so lookup alone cannot prove A was not retired.
  const DWORD returnedId = mode == 0 ? host.sink->beginIds.back() : oldId;
  const auto returned = ReadUiRetirement(returnedId, "after-return", mode);
  if (mode == 0) {
    SettleNormalDelivery("assert:ui-retirement-control-transition-has-one-current-registration");
    Check("ui-retirement-control-transition-has-one-current-registration",
        returned.complete && returned.sameCandidateCount == 1 && returned.getHr == S_OK &&
        returned.queriedIdIsCandidate);
  } else {
    const auto oldEnd = std::find(host.sink->endIds.begin(), host.sink->endIds.end(), oldId);
    const bool endedOnce = std::count(host.sink->endIds.begin(), host.sink->endIds.end(), oldId) == 1;
    const bool gone = returned.getHr == E_INVALIDARG && !returned.queriedIdIsCandidate;
    const bool reused = mode == 1 && host.sink->beginIds.size() == 2 &&
        host.sink->beginIds.back() == oldId && returned.getHr == S_OK &&
        returned.queriedIdIsCandidate && oldEnd != host.sink->endIds.end() &&
        host.sink->beginOrdinals.back() > host.sink->endOrdinals[
            static_cast<size_t>(oldEnd - host.sink->endIds.begin())];
    const bool oldRetired = endedOnce && (gone || reused);
    const auto current = mode == 1 ?
        ReadUiRetirement(host.sink->beginIds.back(), "after-return-current-B", mode) : returned;
    const bool expectedCurrent = mode == 1 ?
        (host.sink->beginIds.size() == 2 && current.complete &&
         current.sameCandidateCount == 1 && current.getHr == S_OK && current.queriedIdIsCandidate) :
        (returned.sameCandidateCount == 0 && gone);
    out_ << "UIRETIRE_OWNERSHIP mode=" << mode << " oldEndOnce=" << endedOnce
         << " oldIdGone=" << gone << " genuineIdReuse=" << reused
         << " beginCallbacks=" << host.sink->beginIds.size()
         << " currentCount=" << current.sameCandidateCount << std::endl;
    SettleNormalDelivery("assert:ui-retirement-commit-reentry-releases-old-registration-after-return");
    Check(mode == 1 ? "ui-retirement-commit-reentry-releases-old-registration-after-return" :
                     "ui-retirement-composing-reentry-releases-old-registration-after-return",
        returned.complete && oldRetired && expectedCurrent);
  }

  auto candidateOwner = service_->_cand->RegisteredIntent();
  auto currentB = mode == 2 ? bCommit : bDraft;
  SettleNormalDelivery("assert:ui-retirement-real-packets-and-candidate-intent-keep-original-owners");
  Check("ui-retirement-real-packets-and-candidate-intent-keep-original-owners", entered &&
      capturedA && capturedA->source && capturedA->source->owner.p == a_.p &&
      (mode == 1 ? capturedA->response->commit == L"cn01" :
                   capturedA->response->commit.empty() && capturedA->response->status.composing) &&
      bDraft && bDraft->source && bDraft->source->owner.p == b_.p && HasPreedit(bDraft, L"x") &&
      currentB && currentB == service_->_lastResponse && currentB->source->owner.p == b_.p &&
      candidateOwner && candidateOwner->owner.p == b_.p);
  const std::wstring expectedA = mode == 1 ? L"prefix|cn01" : L"prefix|";
  const std::wstring expectedB = mode == 2 ? L"other|cx01" : L"other|";
  const unsigned writesA = mode == 1 ? 1 : 0;
  const unsigned writesB = mode == 2 ? 1 : 0;
  SettleNormalDelivery("assert:ui-retirement-before-next-key-text-is-only-original-selection");
  Check("ui-retirement-before-next-key-text-is-only-original-selection", a_->store->text == expectedA &&
      a_->store->imeWrites == writesA && b_->store->text == expectedB && b_->store->imeWrites == writesB &&
      (mode != 2 || (bCommit && bCommit->response->commit == L"cx01" &&
                     bCommit->stage == Stage::Done && bCommit->writeAttempts == 1)));

  auto nextB = Produce(b_, 'x');
  const auto next = ReadUiRetirement(host.sink->beginIds.back(), "after-next-B-key", mode);
  SettleNormalDelivery("assert:ui-retirement-control-next-B-has-one-current-registration");
  Check(mode == 0 ? "ui-retirement-control-next-B-has-one-current-registration" :
        mode == 1 ? "ui-retirement-commit-reentry-next-B-has-one-current-registration" :
                    "ui-retirement-composing-reentry-next-B-has-one-current-registration",
      next.complete && next.sameCandidateCount == 1 && next.getHr == S_OK && next.queriedIdIsCandidate);
  const std::wstring raw = mode == 2 ? L"x" : L"xx";
  candidateOwner = service_->_cand->RegisteredIntent();
  SettleNormalDelivery("assert:ui-retirement-next-B-draft-is-genuine-and-owned-by-B");
  Check("ui-retirement-next-B-draft-is-genuine-and-owned-by-B", nextB && nextB->source &&
      nextB->source->owner.p == b_.p && HasPreedit(nextB, raw) && nextB->response->commit.empty() &&
      candidateOwner && candidateOwner->owner.p == b_.p && a_->store->text == expectedA &&
      b_->store->text == expectedB && b_->store->imeWrites == writesB);
  auto rawCommit = Produce(b_, 0xff0d);
  const DWORD finalId = host.sink->beginIds.back();
  Require(service_->OnKillThreadFocus(), "retirement final ordinary product blur");
  const auto final = ReadUiRetirement(finalId, "after-final-ordinary-blur", mode);
  SettleNormalDelivery("assert:ui-retirement-control-final-blur-has-no-registration");
  Check(mode == 0 ? "ui-retirement-control-final-blur-has-no-registration" :
        mode == 1 ? "ui-retirement-commit-reentry-final-blur-has-no-registration" :
                    "ui-retirement-composing-reentry-final-blur-has-no-registration",
      final.complete && final.sameCandidateCount == 0 && final.getHr == E_INVALIDARG &&
      !final.queriedIdIsCandidate);
  SettleNormalDelivery("assert:ui-retirement-final-blur-preserves-once-only-B-Return-and-A-text");
  Check("ui-retirement-final-blur-preserves-once-only-B-Return-and-A-text",
      rawCommit->response->commit == raw && rawCommit->stage == Stage::Done && rawCommit->writeAttempts == 1 &&
      a_->store->text == expectedA && a_->store->imeWrites == writesA &&
      b_->store->text == expectedB + raw && b_->store->imeWrites == writesB + 1 &&
      a_->store->hostWrites == 0 && b_->store->hostWrites == 0 &&
      a_->store->ownerErrors == 0 && b_->store->ownerErrors == 0);
}

// Group("V20", [&] {
//   UiRetirementLifecycle(0);          // 7 checks, ordinary control
//   Fresh(); UiRetirementLifecycle(1); // 7 checks
//   Fresh(); UiRetirementLifecycle(2); // 7 checks
// });
// New V20 replaces only the unadopted 88 tests, not the retained V1-V19.
// Full product expectation: 220+21=241 checks / 20 groups.
// Baseline V20 expected: 15 PASS, exactly 6 FAIL (the distinct reentry
// after-return/next-B/final-blur registration labels), control all PASS.

// New finite schedules only. The real OnEndEdit implementation is unchanged.
// Host hooks run after the selected range is populated and before GetSelection
// returns, or at the existing real range-comparison return boundary.
void SelectionQueryBlur() {
  Type(a_, "abc");
  SettleNormalDelivery("assert:selection-blur-starts-with-real-A-draft-and-composition");
  Check("selection-blur-starts-with-real-A-draft-and-composition",
      service_->_IsComposing() && service_->_status.composing &&
      HasPreedit(service_->_lastResponse, L"abc") && CandidateCount() > 0);
  bool reentered = false;
  a_->store->afterSelectionQuery = [&] {
    // _ObserveResponseSelection performs the first GetSelection. Reenter
    // during the following GetSelection in OnEndEdit's coverage check.
    a_->store->afterSelectionQuery = [&] {
      reentered = true;
      Require(service_->OnKillThreadFocus(), "real blur before second selection query returns");
      out_ << "SELECTION_BLUR before-return composing=" << service_->_IsComposing()
           << " Atext=" << Hex(a_->store->text) << std::endl;
    };
  };
  com_ptr<SelectionRecord> edit; edit.Attach(new SelectionRecord());
  out_ << "SELECTION_BLUR invoke real OnEndEdit" << std::endl;
  Require(service_->OnEndEdit(a_, a_->store->cookie, edit), "real OnEndEdit after query-time blur");
  out_ << "SELECTION_BLUR OnEndEdit returned" << std::endl;
  SettleNormalDelivery("assert:selection-blur-returns-after-real-cancellation-without-new-text");
  Check("selection-blur-returns-after-real-cancellation-without-new-text", reentered &&
      !service_->_IsComposing() && a_->store->text == L"prefix|" && a_->store->imeWrites == 0);
  Require(service_->OnSetFocus(TRUE), "real key-focus return to A after selection blur");
  auto first = CallbackDown(a_, 'N');
  SettleNormalDelivery("assert:selection-blur-next-real-first-key-enters-new-draft");
  Check("selection-blur-next-real-first-key-enters-new-draft", first.tested && first.eaten &&
      first.actualCalled && HasPreedit(first.packet, L"n") && service_->_IsComposing());
  auto committed = Produce(a_, 0xff0d);
  SettleNormalDelivery("assert:selection-blur-next-Return-writes-only-new-n-once");
  Check("selection-blur-next-Return-writes-only-new-n-once", committed->response->commit == L"n" &&
      committed->stage == Stage::Done && committed->writeAttempts == 1 &&
      a_->store->text == L"prefix|n" && a_->store->imeWrites == 1);
  SettleNormalDelivery("assert:selection-blur-has-no-cross-owner-or-host-write");
  Check("selection-blur-has-no-cross-owner-or-host-write", b_->store->text == L"other|" &&
      b_->store->imeWrites == 0 && a_->store->hostWrites == 0 && b_->store->hostWrites == 0 &&
      a_->store->ownerErrors == 0 && b_->store->ownerErrors == 0);
}

void SelectionCompareReplacement() {
  Type(a_, "abc");
  auto original = service_->_lastResponse;
  SettleNormalDelivery("assert:selection-replace-starts-with-real-A-draft");
  Check("selection-replace-starts-with-real-A-draft", service_->_IsComposing() &&
      HasPreedit(original, L"abc") && original->source && !original->source->cancelled);
  // A host caret change outside A's empty non-inline range.
  a_->store->selectionStart = a_->store->selectionEnd = 0;
  bool reentered = false;
  std::shared_ptr<Packet> replacement;
  a_->store->beforeRangeCompareReturn = [&] {
    reentered = true;
    Require(service_->OnKillThreadFocus(), "real blur during A range comparison");
    Require(service_->OnSetFocus(TRUE), "real key-focus return before comparison returns");
    replacement = Produce(a_, 'x');
    out_ << "SELECTION_REPLACE new-A draft captured before old compare returns"
         << " composing=" << service_->_IsComposing() << std::endl;
  };
  com_ptr<SelectionRecord> edit; edit.Attach(new SelectionRecord());
  Require(service_->OnEndEdit(a_, a_->store->cookie, edit), "real OnEndEdit with replacement composition");
  SettleNormalDelivery("assert:selection-replace-really-published-distinct-A-intent");
  Check("selection-replace-really-published-distinct-A-intent", reentered && replacement &&
      replacement != original && replacement->source != original->source &&
      HasPreedit(replacement, L"x") && replacement->source->owner.p == a_.p);
  SettleNormalDelivery("assert:selection-replace-old-edit-does-not-cancel-new-A-draft");
  Check("selection-replace-old-edit-does-not-cancel-new-A-draft", replacement &&
      service_->_lastResponse == replacement && !replacement->source->cancelled &&
      replacement->source->valid && service_->_IsComposing() && service_->_status.composing &&
      FirstCandidate() == L"cx01");
  auto committed = Produce(a_, 0xff0d);
  SettleNormalDelivery("assert:selection-replace-new-Return-still-writes-x-once");
  Check("selection-replace-new-Return-still-writes-x-once", committed->response->commit == L"x" &&
      committed->stage == Stage::Done && committed->writeAttempts == 1 &&
      a_->store->text == L"xprefix|" && a_->store->imeWrites == 1);
  SettleNormalDelivery("assert:selection-replace-old-abc-never-commits-or-writes-other-owner");
  Check("selection-replace-old-abc-never-commits-or-writes-other-owner",
      b_->store->text == L"other|" && b_->store->imeWrites == 0 &&
      a_->store->hostWrites == 0 && b_->store->hostWrites == 0 &&
      a_->store->ownerErrors == 0 && b_->store->ownerErrors == 0);
}

// Paste inside ResponseOwnerProductFixture. Invoke each after Fresh().
// These are two normal coverage controls, not another full regression group:
//   Fresh(); SelectionCoverageControl(false);  // one Check, inside preserved
//   Fresh(); SelectionCoverageControl(true);   // one Check, outside cancelled
// Existing V6 checks an unanchored deferred commit, not an active composition's
// normal inside/outside range coverage. No product state/anchor is filled here.
void SelectionCoverageControl(bool outside) {
  Type(a_, "abc");
  auto intent = service_->_responseIntent;
  com_ptr<ITfComposition> composition = service_->_pComposition;
  if (!intent || !composition || !service_->_status.composing ||
      !HasPreedit(service_->_lastResponse, L"abc"))
    throw std::runtime_error("selection coverage control requires a real A draft");
  const unsigned comparisons = a_->store->comparisonCalls;
  if (outside)
    a_->store->selectionStart = a_->store->selectionEnd = 0;
  com_ptr<SelectionRecord> edit; edit.Attach(new SelectionRecord());
  Require(service_->OnEndEdit(a_, a_->store->cookie, edit),
      "normal active-composition selection coverage");
  BOOL shown = FALSE;
  Require(service_->_cand->IsShown(&shown), "normal selection candidate visibility");
  const bool originalText = a_->store->text == L"prefix|" &&
      b_->store->text == L"other|" && a_->store->imeWrites == 0 &&
      b_->store->imeWrites == 0 && a_->store->hostWrites == 0 &&
      b_->store->hostWrites == 0 && a_->store->ownerErrors == 0 &&
      b_->store->ownerErrors == 0;
  if (outside) {
    SettleNormalDelivery("assert:selection-control-normal-outside-caret-still-cancels-original-draft");
    Check("selection-control-normal-outside-caret-still-cancels-original-draft",
        originalText && a_->store->comparisonCalls > comparisons &&
        intent->cancelled && !service_->_IsComposing() &&
        !service_->_status.composing && !shown &&
        !service_->_cand->RegisteredIntent());
  } else {
    SettleNormalDelivery("assert:selection-control-normal-inside-caret-retains-original-draft");
    Check("selection-control-normal-inside-caret-retains-original-draft",
        originalText && a_->store->comparisonCalls >= comparisons + 2 &&
        service_->_responseIntent == intent && intent->valid && !intent->cancelled &&
        service_->_pComposition.p == composition.p && service_->_status.composing &&
        service_->_cand->RegisteredIntent() == intent &&
        FirstCandidate() == L"cn01");
  }
}

void ObserveOwnerReturnRange(const char* label, const std::shared_ptr<Packet>& packet) {
  auto source = packet ? packet->source : nullptr;
  com_ptr<ITfRange> range = source ? source->range : nullptr;
  TfGravity startGravity = TF_GRAVITY_BACKWARD, endGravity = TF_GRAVITY_BACKWARD;
  const HRESULT gravityHr = range ? range->GetGravity(&startGravity, &endGravity) : E_POINTER;
  com_ptr<ITfContext> owner;
  const HRESULT ownerHr = range ? range->GetContext(&owner) : E_POINTER;
  // All ranges in this public host are Range objects. RTTI is observation
  // only: read model bounds without constructing or assigning a new anchor.
  auto fixtureRange = range ? dynamic_cast<response_owner_product_fixture::Range*>(range.p) : nullptr;
  auto candidate = service_->_cand->RegisteredIntent();
  out_ << "OWNER_RANGE label=" << label
       << " token=" << (source ? source->token : 0)
       << " stage=" << (packet ? StageName(packet->stage) : "none")
       << " range=" << static_cast<bool>(range)
       << " fixtureRange=" << (fixtureRange != nullptr)
       << " start=" << (fixtureRange ? fixtureRange->start() : -1)
       << " end=" << (fixtureRange ? fixtureRange->end() : -1)
       << " gravityHr=" << static_cast<LONG>(gravityHr)
       << " startGravity=" << static_cast<unsigned>(startGravity)
       << " endGravity=" << static_cast<unsigned>(endGravity)
       << " ownerHr=" << static_cast<LONG>(ownerHr)
       << " rangeOwnerA=" << (owner.p == a_.p)
       << " followsCommit=" << (source && source->followsCommit)
       << " predecessorAlive=" << (source && static_cast<bool>(source->predecessor))
       << " sourceValid=" << (source && source->valid)
       << " sourceCancelled=" << (source && source->cancelled)
       << " localComposition=" << service_->_IsComposing()
       << " candidateToken=" << (candidate ? candidate->token : 0)
       << " candidateCount=" << CandidateCount() << std::endl;
}


void SameOwnerFailedRequestProbe() {
  TypeCallbacks(a_, "ABC");
  a_->failNextRequest = E_FAIL;
  auto selected = CallbackDown(a_, VK_SPACE);
  auto p = selected.packet;
  SettleNormalDelivery("assert:same-owner-failed-request-P-failure-is-real-and-never-writes");
  Check("same-owner-failed-request-P-failure-is-real-and-never-writes",
      selected.tested && selected.eaten && p && p->source && p->source->owner.p == a_.p &&
      p->response->commit == L"cn01" && p->stage == Stage::Failed && FAILED(p->writeResult) &&
      !p->textWritten && p->writeAttempts == 0 && a_->store->text == L"prefix|" &&
      a_->store->imeWrites == 0);
  ObserveOwnerReturnRange("failed-P-before-next-key", p);
  // The injected host failure is one-shot. No reconnect, service reload,
  // hand-filled endpoint or new input field is used to repair the product.
  auto entered = CallbackDown(a_, 'X');
  auto q = entered.packet;
  ObserveOwnerReturnRange("new-Q-after-one-shot-host-failure", q);
  SettleNormalDelivery("assert:same-owner-failed-request-next-X-is-genuinely-handled-by-engine");
  Check("same-owner-failed-request-next-X-is-genuinely-handled-by-engine",
      entered.tested && entered.eaten && q && q->source && q->source->owner.p == a_.p &&
      q->response->commit.empty() && HasPreedit(q, L"x"));
  auto candidate = service_->_cand->RegisteredIntent();
  SettleNormalDelivery("assert:same-owner-failed-request-new-draft-gets-own-endpoint-and-candidates");
  Check("same-owner-failed-request-new-draft-gets-own-endpoint-and-candidates",
      q->source->range && q->stage == Stage::NoCommit && service_->_IsComposing() &&
      candidate == q->source && CandidateCount() > 0 && a_->store->imeWrites == 0);
  auto returned = CallbackDown(a_, VK_RETURN);
  auto r = returned.packet;
  ObserveOwnerReturnRange("failed-P-after-new-Return", p);
  ObserveOwnerReturnRange("new-Q-after-new-Return", q);
  ObserveOwnerReturnRange("new-R-after-new-Return", r);
  SettleNormalDelivery("assert:same-owner-failed-request-new-Return-produces-genuine-raw-x");
  Check("same-owner-failed-request-new-Return-produces-genuine-raw-x",
      returned.tested && returned.eaten && r && r->source && r->source->owner.p == a_.p &&
      r->response->commit == L"x");
  // P could not be delivered: this probe does not invent/retry its cn01.
  // Only the later, otherwise healthy same-owner x must be able to commit.
  SettleNormalDelivery("assert:same-owner-failed-request-next-word-can-write-after-host-recovers");
  Check("same-owner-failed-request-next-word-can-write-after-host-recovers",
      r->stage == Stage::Done && r->textWritten && r->writeAttempts == 1 &&
      a_->store->text == L"prefix|x" && a_->store->imeWrites == 1);
  SettleNormalDelivery("assert:same-owner-failed-request-never-writes-B-or-uses-wrong-cookie");
  Check("same-owner-failed-request-never-writes-B-or-uses-wrong-cookie",
      b_->store->text == L"other|" && b_->store->imeWrites == 0 &&
      a_->store->hostWrites == 0 && b_->store->hostWrites == 0 &&
      a_->store->ownerErrors == 0 && b_->store->ownerErrors == 0);
  TracePacket(p); TracePacket(q); TracePacket(r);
}

// Standalone research entries, one fresh Group per process/probe:
// "same-owner-return" -> Group("OWNER-RETURN", [&] { SameOwnerReturnProbe(); });
// "same-owner-failed-request" -> Group("OWNER-FAILED", [&] { SameOwnerFailedRequestProbe(); });
// Each has 6 Checks. Do not set expected failure counts before actual evidence.
// The model fixes anchor gravity to backward/forward; report observed bounds
// alongside the result, rather than claiming Chromium/Qt gravity was measured.

  #include "SelectionControlledModes.inc"

  void RunProbe(const char* probe) {
    if (std::strcmp(probe, "truthful-key-pairing") == 0) {
      Group("V13", [&] { PendingCallbackControl(); });
      return;
    }
    if (std::strcmp(probe, "truthful-key-nested") == 0) {
      Group("V18", [&] {
        NestedTestDownPublication(true); Fresh(); NestedTestDownPublication(false);
        Fresh(); NestedTestUpPublication(true); Fresh(); NestedTestUpPublication(false);
      });
      return;
    }
    if (std::strcmp(probe, "truthful-key-repeat-space") == 0) {
      Group("V19", [&] {
        NestedRepeatPublication(false, true); Fresh(); NestedRepeatPublication(false, false);
        Fresh(); NestedRepeatPublication(true, true); Fresh(); NestedRepeatPublication(true, false);
        Fresh(); NestedSpaceSelection(true); Fresh(); NestedSpaceSelection(false);
      });
      return;
    }
    if (std::strncmp(probe, "selection-endpoint-", 19) == 0) {
      Group("SELECTION-ENDPOINT", [&] { SelectionEndpointControlled(probe); });
      return;
    }
    if (std::strcmp(probe, "selection-blur") == 0)
      Group("V21", [&] { SelectionQueryBlur(); });
    else if (std::strcmp(probe, "selection-replace") == 0)
      Group("V21", [&] { SelectionCompareReplacement(); });
    else if (std::strcmp(probe, "same-owner-failed-request") == 0)
      Group("V22", [&] { SameOwnerFailedRequestProbe(); });
    else throw std::runtime_error("unknown finite focus/commit repair probe");
  }

// Methods for the existing ResponseOwnerProductFixture only. Register after
// the original V18 four schedules (16 checks); no new pending/Packet fixture.

void NestedRepeatPublication(bool release, bool actualAFirst) {
  if (release) TypeCallbacks(a_, "A");
  const UINT key = release ? VK_F13 : 'A';
  // Entering B clears A's engine draft under the existing owner policy.
  const auto expectedB = [&](const std::shared_ptr<Packet>& packet) {
    return release ? EmptyEngineResponse(packet) : HasPreedit(packet, L"a");
  };
  auto testOnly = [&](Context* owner) -> BOOL {
    if (release) return CallbackRelease(owner, key, false).tested;
    return CallbackDown(owner, key, false).tested;
  };
  auto actual = [&](Context* owner) -> BOOL {
    if (release) return ActualUp(owner, key).eaten;
    return ActualDown(owner, key).eaten;
  };
  bool reentered = false;
  BOOL innerTested = FALSE;
  std::shared_ptr<Packet> capturedA, innerB;
  a_->store->beforeRequest = [&] {
    reentered = true;
    capturedA = Record(service_->_lastResponse);
    innerTested = testOnly(b_);
    innerB = Record(service_->_lastResponse);
  };
  const BOOL outerTested = testOnly(a_);
  const auto generation = service_->m_client.ResponseGeneration();
  const auto callsAfterNestedTests = rymcpRetainedKeyCalls;
  out_ << "KEYS_REPEAT " << (release ? "Up" : "Down")
       << " actual=" << (actualAFirst ? "A-B" : "B-A") << std::endl;
  SettleNormalDelivery("assert:keys-repeat-nested-both-Test-responses-are-genuine");
  Check("keys-repeat-nested-both-Test-responses-are-genuine", reentered &&
      outerTested && innerTested && capturedA && innerB && capturedA != innerB &&
      capturedA->source && capturedA->source->owner.p == a_.p && HasPreedit(capturedA, L"a") &&
      innerB->source && innerB->source->owner.p == b_.p && expectedB(innerB));
  const BOOL repeatedA = testOnly(a_);
  SettleNormalDelivery("assert:keys-repeat-same-context-A-Test-reuses-pending-result");
  Check("keys-repeat-same-context-A-Test-reuses-pending-result", repeatedA &&
      innerB && service_->_lastResponse == innerB && service_->m_client.ResponseGeneration() == generation && rymcpRetainedKeyCalls == callsAfterNestedTests);
  const BOOL repeatedB = testOnly(b_);
  SettleNormalDelivery("assert:keys-repeat-same-context-B-Test-reuses-pending-result");
  Check("keys-repeat-same-context-B-Test-reuses-pending-result", repeatedB &&
      innerB && service_->_lastResponse == innerB && service_->m_client.ResponseGeneration() == generation && rymcpRetainedKeyCalls == callsAfterNestedTests);
  const BOOL first = actual(actualAFirst ? a_.p : b_.p);
  SettleNormalDelivery("assert:keys-repeat-first-Actual-consumes-only-own-Test");
  Check("keys-repeat-first-Actual-consumes-only-own-Test", first &&
      service_->_lastResponse == innerB && service_->m_client.ResponseGeneration() == generation && rymcpRetainedKeyCalls == callsAfterNestedTests &&
      expectedB(innerB));
  const BOOL second = actual(actualAFirst ? b_.p : a_.p);
  SettleNormalDelivery("assert:keys-repeat-second-Actual-consumes-only-own-Test");
  Check("keys-repeat-second-Actual-consumes-only-own-Test", second &&
      service_->_lastResponse == innerB && service_->m_client.ResponseGeneration() == generation && rymcpRetainedKeyCalls == callsAfterNestedTests &&
      expectedB(innerB));
  SettleNormalDelivery("assert:keys-repeat-no-document-write-or-owner-cookie-error");
  Check("keys-repeat-no-document-write-or-owner-cookie-error",
      a_->store->text == L"prefix|" && b_->store->text == L"other|" &&
      a_->store->writes == 0 && b_->store->writes == 0 &&
      a_->store->ownerErrors == 0 && b_->store->ownerErrors == 0);
  TracePacket(capturedA); TracePacket(innerB);
}

void NestedSpaceSelection(bool actualAFirst) {
  TypeCallbacks(a_, "ABC");
  bool reentered = false;
  DownResult innerB;
  std::shared_ptr<Packet> capturedA;
  a_->store->beforeRequest = [&] {
    reentered = true;
    capturedA = Record(service_->_lastResponse);
    // A's real Space has already emptied the engine. B builds a fresh word
    // through ordinary callbacks, then selects it with its own real Space.
    TypeCallbacks(b_, "ABC");
    innerB = CallbackDown(b_, VK_SPACE, false);
  };
  auto outerA = CallbackDown(a_, VK_SPACE, false);
  const auto generation = service_->m_client.ResponseGeneration();
  out_ << "KEYS_SPACE actual=" << (actualAFirst ? "A-B" : "B-A") << std::endl;
  SettleNormalDelivery("assert:keys-Space-nested-two-genuine-selection-commits");
  Check("keys-Space-nested-two-genuine-selection-commits", reentered &&
      outerA.tested && !outerA.actualCalled && innerB.tested && !innerB.actualCalled &&
       capturedA && innerB.packet && capturedA != innerB.packet && capturedA->response->commit == L"cn01" &&
      innerB.packet->response->commit == L"cn01" &&
      capturedA->source->owner.p == a_.p && innerB.packet->source->owner.p == b_.p);
  SettleNormalDelivery("assert:keys-Space-Test-stage-delivers-each-original-owner-once");
  Check("keys-Space-Test-stage-delivers-each-original-owner-once",
       capturedA && innerB.packet && capturedA->stage == Stage::Done && innerB.packet->stage == Stage::Done &&
      capturedA->writeAttempts == 1 && innerB.packet->writeAttempts == 1 &&
      a_->store->text == L"prefix|cn01" && b_->store->text == L"other|cn01" &&
      a_->store->imeWrites == 1 && b_->store->imeWrites == 1);
  auto first = ActualDown(actualAFirst ? a_.p : b_.p, VK_SPACE);
  SettleNormalDelivery("assert:keys-Space-first-Actual-does-not-send-or-write-again");
  Check("keys-Space-first-Actual-does-not-send-or-write-again", first.eaten &&
      first.packet == innerB.packet && service_->m_client.ResponseGeneration() == generation &&
      a_->store->imeWrites == 1 && b_->store->imeWrites == 1);
  auto second = ActualDown(actualAFirst ? b_.p : a_.p, VK_SPACE);
  SettleNormalDelivery("assert:keys-Space-second-Actual-does-not-send-or-write-again");
  Check("keys-Space-second-Actual-does-not-send-or-write-again", second.eaten &&
      second.packet == innerB.packet && service_->m_client.ResponseGeneration() == generation &&
      a_->store->text == L"prefix|cn01" && b_->store->text == L"other|cn01" &&
      a_->store->imeWrites == 1 && b_->store->imeWrites == 1);
  SettleNormalDelivery("assert:keys-Space-selection-has-no-artificial-or-wrong-owner-write");
  Check("keys-Space-selection-has-no-artificial-or-wrong-owner-write",
      a_->store->hostWrites == 0 && b_->store->hostWrites == 0 &&
      a_->store->ownerErrors == 0 && b_->store->ownerErrors == 0);
  TracePacket(capturedA); TracePacket(innerB.packet);
}


  void RunAll() {
    Group("V1", [&] {
      Type(a_, "abc"); a_->synchronous = false;
      bool sawCapturedBeforeCom = false;
      a_->store->beforeRequest = [&] {
        auto current = service_->_lastResponse;
        sawCapturedBeforeCom = current && current->response && current->response->commit == L"cn01";
        SettleNormalDelivery("assert:V1-capture-before-first-COM-request");
        Check("V1-capture-before-first-COM-request", sawCapturedBeforeCom);
        SettleNormalDelivery("assert:V1-real-Echo-invalidates-shared-body");
        Check("V1-real-Echo-invalidates-shared-body", service_->m_client.Echo() && service_->m_client.ResponseGeneration() == 0);
      };
      auto packet = Produce(a_, 0x20);
      SettleNormalDelivery("assert:V1-real-commit-waits-for-grant");
      Check("V1-real-commit-waits-for-grant", packet->response->commit == L"cn01" && !a_->pending.empty());
      a_->Drain();
      SettleNormalDelivery("assert:V1-captured-body-survives-Echo");
      Check("V1-captured-body-survives-Echo", sawCapturedBeforeCom && a_->store->text == L"prefix|cn01" &&
          b_->store->text == L"other|" && a_->store->imeWrites == 1 && packet->stage == Stage::Done);
      TracePacket(packet); NoHostOrCookieErrors("V1-public-body-and-owner-only");
    });
    Group("V2", [&] {
      Type(a_, "abc"); a_->synchronous = false;
      auto packet = Produce(a_, 0x20); Replay(packet); Replay(packet); a_->Drain();
      SettleNormalDelivery("assert:V2-same-real-packet-replayed-once");
      Check("V2-same-real-packet-replayed-once", packet->stage == Stage::Done && packet->writeAttempts == 1 &&
          packet->textWritten && a_->store->imeWrites == 1 && a_->store->text == L"prefix|cn01");
      TracePacket(packet); NoHostOrCookieErrors("V2-no-host-write-or-cookie-error");
    });
    Group("V3", [&] {
      Type(a_, "abc"); a_->synchronous = false;
      auto first = Produce(a_, 0x20);
      Type(a_, "abc"); auto second = Produce(a_, 0x20);
      SettleNormalDelivery("assert:V3-distinct-true-generations-same-cn01-before-grant");
      Check("V3-distinct-true-generations-same-cn01-before-grant", first != second &&
          first->response->generation != second->response->generation && first->response->commit == L"cn01" &&
          second->response->commit == L"cn01" && a_->store->imeWrites == 0);
      a_->Drain();
      SettleNormalDelivery("assert:V3-successor-appends-at-predecessor-end");
      Check("V3-successor-appends-at-predecessor-end", a_->store->text == L"prefix|cn01cn01" &&
          a_->store->imeWrites == 2 && first->stage == Stage::Done && second->stage == Stage::Done &&
          first->writeAttempts == 1 && second->writeAttempts == 1);
      TracePacket(first); TracePacket(second); NoHostOrCookieErrors("V3-no-text-dedup-or-wrong-cookie");
    });
    Group("V4", [&] {
      Type(a_, "abc"); a_->synchronous = false;
      service_->_SelectCandidateOnCurrentPage(0);
      auto selected = Record(service_->_lastResponse);
      SettleNormalDelivery("assert:V4-product-Select-immediately-captures-A-cn01");
      Check("V4-product-Select-immediately-captures-A-cn01", selected->response->commit == L"cn01" &&
          selected->source && selected->source->owner.p == a_.p && !a_->pending.empty());
      Require(service_->OnSetFocus(FALSE), "A focus cancel");
      Type(b_, "x"); auto bDraft = service_->_lastResponse;
      SettleNormalDelivery("assert:V4-B-first-body-has-no-A-commit");
      Check("V4-B-first-body-has-no-A-commit", bDraft->response->commit.empty() && bDraft->response->status.composing);
      a_->Drain(); b_->Drain();
      SettleNormalDelivery("assert:V4-Select-focus-B-never-misroutes");
      Check("V4-Select-focus-B-never-misroutes", a_->store->text == L"prefix|cn01" && a_->store->imeWrites == 1 &&
          b_->store->text == L"other|" && b_->store->imeWrites == 0);
      auto probe = Produce(b_, 0xff0d);
      SettleNormalDelivery("assert:V4-B-keeps-its-own-real-x");
      Check("V4-B-keeps-its-own-real-x", probe->response->commit == L"x" && b_->store->text == L"other|x");
      TracePacket(selected); NoHostOrCookieErrors("V4-real-product-Select-cancel-delivery-owners");
      out_ << "UNCOVERED V4 actual OS mouse/SendInput and in-flight IPC thread-focus callback timing" << std::endl;
    });
    Group("V5", [&] {
      a_->synchronous = false;
      CallbackKey(a_, 'A'); CallbackKey(a_, 'B'); CallbackKey(a_, 'C');
      SettleNormalDelivery("assert:V5-no-composition-before-first-commit");
      Check("V5-no-composition-before-first-commit", !service_->_pComposition);
      auto packet = CallbackKey(a_, VK_RETURN);
      SettleNormalDelivery("assert:V5-real-raw-Return-abc-has-initial-A-intent");
      Check("V5-real-raw-Return-abc-has-initial-A-intent", packet->response->commit == L"abc" &&
          packet->source && packet->source->initialSelection && packet->source->owner.p == a_.p);
      a_->Drain();
      SettleNormalDelivery("assert:V5-initial-legal-A-grant-writes-abc-once");
      Check("V5-initial-legal-A-grant-writes-abc-once", packet->stage == Stage::Done &&
          packet->writeAttempts == 1 && a_->store->text == L"prefix|abc" && a_->store->imeWrites == 1 &&
          a_->store->insertionQueries > 0);
      TracePacket(packet); NoHostOrCookieErrors("V5-no-helper-created-endpoint");
    });
    Group("V6", [&] {
      a_->synchronous = false; Type(a_, "abc"); auto packet = Produce(a_, 0xff0d);
      SettleNormalDelivery("assert:V6-awaiting-initial-A-endpoint");
      Check("V6-awaiting-initial-A-endpoint", packet->source && !packet->source->range && !service_->_pComposition);
      a_->store->selectionStart = a_->store->selectionEnd = 0;
      com_ptr<SelectionRecord> record; record.Attach(new SelectionRecord());
      Require(service_->OnEndEdit(a_, a_->store->cookie, record), "real external-selection OnEndEdit");
      a_->Drain();
      SettleNormalDelivery("assert:V6-external-selection-invalidates-unanchored-intent");
      Check("V6-external-selection-invalidates-unanchored-intent", !packet->source->valid &&
          packet->stage == Stage::UnsupportedEndpoint && !packet->textWritten && a_->store->imeWrites == 0 &&
          a_->store->text == L"prefix|" && b_->store->text == L"other|");
      TracePacket(packet); NoHostOrCookieErrors("V6-no-new-selection-fallback");
      Fresh(); a_->synchronous = false; Type(a_, "abc"); auto queryPacket = Produce(a_, 0xff0d);
      bool queryReentered = false;
      a_->store->afterInsertionQuery = [&] {
        queryReentered = true;
        SettleNormalDelivery("assert:V6-query-out-is-not-published-before-revalidation");
        Check("V6-query-out-is-not-published-before-revalidation", !queryPacket->source->range);
        a_->store->selectionStart = a_->store->selectionEnd = 0;
        com_ptr<SelectionRecord> changed; changed.Attach(new SelectionRecord());
        Require(service_->OnEndEdit(a_, a_->store->cookie, changed), "selection reentry inside query-only");
      };
      a_->Drain();
      SettleNormalDelivery("assert:V6-query-reentry-invalidates-before-anchor-publication");
      Check("V6-query-reentry-invalidates-before-anchor-publication", queryReentered &&
          !queryPacket->source->valid && queryPacket->stage == Stage::UnsupportedEndpoint &&
          !queryPacket->textWritten && a_->store->imeWrites == 0 && a_->store->text == L"prefix|");
      TracePacket(queryPacket); NoHostOrCookieErrors("V6-query-reentry-does-not-use-later-selection");
      Fresh(); a_->synchronous = false; Type(a_, "abc"); auto focusPacket = Produce(a_, 0xff0d);
      SettleNormalDelivery("assert:V6-no-local-composition-context-before-grant");
      Check("V6-no-local-composition-context-before-grant", !service_->_pComposition && !service_->_pEditSessionContext);
      Require(service_->OnKillThreadFocus(), "real thread-focus cancellation before initial grant");
      a_->Drain();
      SettleNormalDelivery("assert:V6-thread-blur-invalidates-initial-intent-without-local-context");
      Check("V6-thread-blur-invalidates-initial-intent-without-local-context", !focusPacket->source->valid &&
          focusPacket->stage == Stage::UnsupportedEndpoint && !focusPacket->textWritten &&
          a_->store->imeWrites == 0 && a_->store->text == L"prefix|");
      TracePacket(focusPacket); NoHostOrCookieErrors("V6-thread-blur-does-not-use-delayed-selection");
    });
    Group("V7", [&] {
      Reentry(false); Fresh(); Reentry(true); Fresh();
      Type(a_, "abc"); a_->store->failNextEnd = E_UNEXPECTED;
      auto packet = Produce(a_, 0x20); Replay(packet); a_->Drain();
      SettleNormalDelivery("assert:V7-unmatched-End-error-remains-Written-without-resend");
      Check("V7-unmatched-End-error-remains-Written-without-resend", packet->stage == Stage::Written &&
          packet->textWritten && packet->writeAttempts == 1 && FAILED(packet->cleanupResult) &&
          a_->store->text == L"prefix|cn01" && a_->store->imeWrites == 1 && a_->store->ends == 0);
      TracePacket(packet); NoHostOrCookieErrors("V7-unmatched-error-is-not-Done");
    });
    Group("V8", [&] {
      Type(a_, "abc"); a_->synchronous = false; auto packet = Produce(a_, 0x20);
      Require(service_->OnSetFocus(FALSE), "A pending commit focus cancel");
      Type(b_, "x"); Require(service_->OnSetFocus(FALSE), "B ordinary focus cancel");
      auto probe = Produce(b_, 0xff0d); a_->Drain(); b_->Drain();
      SettleNormalDelivery("assert:V8-A-commit-protected-without-global-B-protection");
      Check("V8-A-commit-protected-without-global-B-protection", packet->stage == Stage::Done &&
          a_->store->text == L"prefix|cn01" && a_->store->imeWrites == 1 &&
          probe->response->commit.empty() && b_->store->text == L"other|" && b_->store->imeWrites == 0);
      TracePacket(packet); NoHostOrCookieErrors("V8-A-clear-End-does-not-revive-or-affect-B");
      Fresh();
      bool cancelledInsideStart = false;
      a_->store->afterStart = [&] {
        cancelledInsideStart = true;
        SettleNormalDelivery("assert:V8-Start-out-contains-new-A-before-focus-cancel");
        Check("V8-Start-out-contains-new-A-before-focus-cancel", a_->store->starts == 1 &&
            a_->store->compositions.size() == 1 && !a_->store->compositions.front().ended);
        Require(service_->OnKillThreadFocus(), "host thread blur inside real StartComposition");
        // Do not start B inside this callback: the original native Start has
        // not returned, and a nested native Start may legitimately fail.
      };
      auto started = Produce(a_, 'x'); a_->Drain();
      const auto activeA = std::count_if(a_->store->compositions.begin(), a_->store->compositions.end(),
          [](const response_owner_product_fixture::CompositionState& state) { return !state.ended; });
      SettleNormalDelivery("assert:V8-focus-cancel-inside-Start-ends-new-A-exactly-once");
      Check("V8-focus-cancel-inside-Start-ends-new-A-exactly-once", cancelledInsideStart &&
          started->response->commit.empty() && a_->store->starts == 1 && a_->store->endAttempts == 1 &&
          a_->store->ends == 1 && activeA == 0 && !service_->_IsComposing() && a_->pending.empty() &&
          a_->store->text == L"prefix|" && a_->store->imeWrites == 0);
      Type(b_, "x"); auto laterB = Produce(b_, 0xff0d);
      SettleNormalDelivery("assert:V8-after-cancelled-Start-B-remains-normal");
      Check("V8-after-cancelled-Start-B-remains-normal", laterB->stage == Stage::Done &&
          laterB->response->commit == L"x" && b_->store->text == L"other|x" && b_->store->imeWrites == 1 &&
          a_->store->text == L"prefix|" && a_->store->endAttempts == 1 && a_->store->imeWrites == 0);
      TracePacket(started); TracePacket(laterB);
      NoHostOrCookieErrors("V8-Start-cancel-has-no-orphan-or-cross-owner-write");
    });
    Group("V9", [&] {
      const auto beforeFocusPacket = service_->_lastResponse;
      Require(service_->OnSetThreadFocus(), "real focus metadata query");
      SettleNormalDelivery("assert:V9-focus-metadata-never-creates-content");
      Check("V9-focus-metadata-never-creates-content", service_->_lastResponse == beforeFocusPacket);
      Type(a_, "abc"); auto noCommit = service_->_lastResponse;
      SettleNormalDelivery("assert:V9-preedit-has-no-commit-protection");
      Check("V9-preedit-has-no-commit-protection", noCommit->response->commit.empty() && noCommit->source &&
          !noCommit->source->preparing && !noCommit->source->hasCommit);
      Require(service_->OnSetFocus(FALSE), "cancel after NoCommit");
      auto empty = Produce(a_, 0xff0d);
      SettleNormalDelivery("assert:V9-NoCommit-releases-normal-cancel");
      Check("V9-NoCommit-releases-normal-cancel", empty->response->commit.empty() && a_->store->imeWrites == 0);
      Type(a_, "abc"); auto committed = Produce(a_, 0x20);
      SettleNormalDelivery("assert:V9-next-ordinary-commit-delivers-once");
      Check("V9-next-ordinary-commit-delivers-once", committed->stage == Stage::Done &&
          a_->store->text == L"prefix|cn01" && a_->store->imeWrites == 1);
      TracePacket(noCommit); TracePacket(committed); NoHostOrCookieErrors("V9-no-hanging-intent-protection");
    });
    Group("V10", [&] {
      Type(a_, "abc"); a_->synchronous = false; auto packet = Produce(a_, 0x20);
      a_->store->connected = false; Require(manager_->SetFocus(docB_), "real focus B"); Type(b_, "x");
      a_->Drain(); b_->Drain();
      SettleNormalDelivery("assert:V10-disconnected-A-is-not-delivered-to-B");
      Check("V10-disconnected-A-is-not-delivered-to-B", (packet->stage == Stage::Failed || packet->stage == Stage::UnsupportedEndpoint) &&
          !packet->textWritten && packet->response->commit == L"cn01" && a_->store->imeWrites == 0 &&
          b_->store->imeWrites == 0 && a_->store->text == L"prefix|" && b_->store->text == L"other|");
      SettleNormalDelivery("assert:V10-failure-is-finite-with-no-success-claim");
      Check("V10-failure-is-finite-with-no-success-claim", a_->pending.empty() && b_->pending.empty() &&
          packet->stage != Stage::Done && !packet->source->preparing && a_->pending.empty() &&
          !service_->_producerResponse && (FAILED(packet->writeResult) || FAILED(packet->captureResult)));
      TracePacket(packet); NoHostOrCookieErrors("V10-no-cross-owner-fallback-or-personal-data");
      Fresh(); Type(a_, "abc"); a_->failNextRequest = E_FAIL;
      auto rejected = Produce(a_, 0x20);
      SettleNormalDelivery("assert:V10-request-failure-releases-producer-with-no-queued-resend");
      Check("V10-request-failure-releases-producer-with-no-queued-resend", rejected->stage == Stage::Failed &&
          !rejected->source->preparing && !service_->_producerResponse && a_->pending.empty() &&
          FAILED(rejected->writeResult) && !rejected->textWritten && a_->store->imeWrites == 0);
      Type(b_, "x");
      SettleNormalDelivery("assert:V10-request-failure-does-not-block-next-B-producer");
      Check("V10-request-failure-does-not-block-next-B-producer", service_->_lastResponse->source &&
          service_->_lastResponse->source->owner.p == b_.p && !service_->_lastResponse->source->preparing &&
          service_->_lastResponse->response->commit.empty() && b_->store->imeWrites == 0);
      TracePacket(rejected); NoHostOrCookieErrors("V10-request-failure-is-finite-and-source-bound");
    });
    Group("V11", [&] { CommitThenEscape(false); });
    Group("V12", [&] { CommitThenEscape(true); });
    Group("V13", [&] { PendingCallbackControl(); });
    Group("V14", [&] { TerminationNextDraft(false); Fresh(); TerminationNextDraft(true); });
    Group("V15", [&] {
      CommitThenEscape(true, true);
      Fresh(); RejectedOldEmptyKeepsNewOwner();
      Fresh(); RejectedComposingKeepsPreviousUi();
      Fresh(); RejectedCommitCannotWriteWithoutGrant();
      Fresh(); RejectedEmptyKeepsOutstandingComposition();
    });
    Group("V16", [&] { SelectionCompareFocusReentry(); });
    Group("V17", [&] { CommitSelectionCleanupFailure(); });
    Group("V18", [&] {
      NestedTestDownPublication(true);
      Fresh(); NestedTestDownPublication(false);
      Fresh(); NestedTestUpPublication(true);
      Fresh(); NestedTestUpPublication(false);
    });
    Group("V19", [&] {
      NestedRepeatPublication(false, true);
      Fresh(); NestedRepeatPublication(false, false);
      Fresh(); NestedRepeatPublication(true, true);
      Fresh(); NestedRepeatPublication(true, false);
      Fresh(); NestedSpaceSelection(true);
      Fresh(); NestedSpaceSelection(false);
    });
    Group("V20", [&] { UiRetirementLifecycle(0); Fresh(); UiRetirementLifecycle(1);
        Fresh(); UiRetirementLifecycle(2); });
    Group("V21", [&] { SelectionQueryBlur(); Fresh(); SelectionCompareReplacement();
        Fresh(); SelectionCoverageControl(false); Fresh(); SelectionCoverageControl(true); });
    Group("V22", [&] { SameOwnerFailedRequestProbe(); });
  }

  std::ofstream& out_;
  unsigned passed_ = 0, failed_ = 0, groups_ = 0, realCommits_ = 0;
  std::vector<std::uint64_t> observed_;
  TfClientId clientId_ = TF_CLIENTID_NULL;
  BYTE originalKeys_[256] = {};
  bool savedKeys_ = false, savedOpen_ = false;
  BOOL originalOpen_ = FALSE;
  com_ptr<ITfThreadMgr> manager_;
  com_ptr<ITfDocumentMgr> docA_, docB_;
  com_ptr<WeaselTSF> service_;
  com_ptr<Context> a_, b_;
};

extern "C" __declspec(dllexport) int __cdecl RunResponseOwnerProductTests(const wchar_t* path) {
  // Test-child boundary only; never compiled into a frozen product.
  const DWORD previous = SetErrorMode(SEM_FAILCRITICALERRORS | SEM_NOGPFAULTERRORBOX);
  int result = 1;
  __try { result = ResponseOwnerProductFixture::Run(path); }
  __except (GetExceptionCode() == EXCEPTION_ACCESS_VIOLATION ?
            EXCEPTION_EXECUTE_HANDLER : EXCEPTION_CONTINUE_SEARCH) {
    result = static_cast<int>(0xC0000005u);
  }
  SetErrorMode(previous);
  return result;
}
