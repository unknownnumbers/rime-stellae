// Include inside the retained ResponseOwnerProductFixture, before RunProbe.
// These are separate controlled public-host cases, never real-MSCTF evidence.
// They use public keys / genuine IPC to create every product-owned endpoint.
bool SelectionControlPrecondition(const char* label, bool condition) {
  out_ << "PRECONDITION " << label << " reached=" << condition << std::endl;
  if (!condition) out_ << "UNREACHED " << label << std::endl;
  return condition;
}

void SelectionEndpointControlled(const char* mode) {
  const bool noAnchor = std::strcmp(mode, "selection-endpoint-no-anchor") == 0;
  const bool outside = std::strcmp(mode, "selection-endpoint-initial-outside") == 0;
  const bool reentry = std::strcmp(mode, "selection-endpoint-reentry") == 0;
  // Opt-in host READ capability below is a controlled stationary-point model.
  // The original host still defaults to sync-read=0; no original oracle changes.
  a_->selectionProbeRead = !noAnchor;
  a_->synchronous = false;
  TypeCallbacks(a_, "ABC");
  const auto draft = service_->_lastResponse;
  const auto source = service_->_responseIntent;
  if (!SelectionControlPrecondition("controlled-public-ABC-created-expected-initial-endpoint",
      source && draft && draft->source == source && HasPreedit(draft, L"abc") &&
      source->valid && !source->cancelled && !service_->_pComposition && !source->range &&
      bool(source->initialPoint) == !noAnchor && !a_->pending.empty())) return;
  const auto revision = source->selection->revision;
  const unsigned comparisons = a_->store->comparisonCalls;
  std::shared_ptr<Packet> replacement;
  bool replaced = false;
  if (reentry) {
    a_->store->beforeRangeCompareReturn = [&] {
      replaced = true;
      Require(service_->OnSetFocus(FALSE), "controlled old draft focus cancellation");
      Require(service_->OnSetFocus(TRUE), "controlled same-context focus return");
      replacement = CallbackDown(a_, 'X').packet;
    };
  }
  a_->store->selectionStart = a_->store->selectionEnd = outside ? 0 : 7;
  com_ptr<SelectionRecord> record;
  record.Attach(new SelectionRecord());
  Require(service_->OnEndEdit(a_, a_->store->cookie, record),
      "controlled selection notification with model cookie");
  out_ << "CONTROLLED_SELECTION mode=" << mode << " realMSCTF=0 realIPC=1"
       << " notificationSynthetic=1 endpointInjected=0" << std::endl;
  if (!noAnchor)
    Check("controlled-logical-endpoint-compared", a_->store->comparisonCalls > comparisons);
  if (reentry && !SelectionControlPrecondition("controlled-original-endpoint-compare-reentered",
      replaced && replacement && replacement->source != source)) return;
  out_ << "SELECTION_CONTROL_REACHED " << mode << std::endl;
  Check("controlled-every-notification-revokes-old-selection-revision",
      source->selection->revision > revision);
  if (noAnchor || outside) {
    Check("controlled-unanchored-or-outside-cancels-original-draft",
        source->cancelled && !source->valid && service_->_responseIntent != source &&
        a_->store->text == L"prefix|" && a_->store->imeWrites == 0);
  } else if (reentry) {
    Check("controlled-old-compare-does-not-cancel-replacement",
        replacement && service_->_responseIntent == replacement->source &&
        replacement->source->valid && !replacement->source->cancelled);
  } else {
    Check("controlled-initial-point-same-location-retains-original-draft",
        service_->_responseIntent == source && source->valid && !source->cancelled);
  }
  a_->synchronous = true;
  a_->Drain();
  if (noAnchor || outside) CallbackDown(a_, 'X');
  const auto selected = CallbackDown(a_, VK_SPACE).packet;
  SettleNormalDelivery("controlled-selection-endpoint-final-selection");
  const std::wstring word = noAnchor || outside || reentry ? L"cx01" : L"cn01";
  const std::wstring expected = outside ? L"cx01prefix|" : L"prefix|" + word;
  Check("controlled-fixed-word-written-once-at-authorized-owner", selected && selected->response &&
      selected->response->commit == word && selected->textWritten &&
      selected->writeAttempts == 1 && a_->store->text == expected &&
      a_->store->imeWrites == 1 && b_->store->text == L"other|" &&
      b_->store->imeWrites == 0);
  NoHostOrCookieErrors("controlled-selection-endpoint-owner-and-cookie-boundaries");
}
