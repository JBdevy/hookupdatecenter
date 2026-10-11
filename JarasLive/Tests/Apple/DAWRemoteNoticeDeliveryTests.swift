// Application-level receipts are separate from state packet ACKs: a write to
// the network is never enough to claim a notice was accepted by the PC.
let deliveryID = UUID()
let noticeReceipt = DAWRemoteNoticeReceipt(commandID: deliveryID, project: project, accepted: true)
if case .noticeReceipt(let decoded) = try DAWRemoteWire.decode(DAWRemoteWire.noticeReceipt(noticeReceipt)) {
    require(decoded == noticeReceipt, "notice receipt roundtrips its exact command/project/acceptance")
} else { fatalError("missing notice receipt packet") }
var receiptCommand = DAWRemoteCommand(project: project, action: .noticeSend, text: "Receipt requested")
receiptCommand.noticeReceiptRequested = true
require(receiptCommand.valid, "notice sender opts in to application receipts")
var invalidReceiptCommand = DAWRemoteCommand(project: project, action: .play)
invalidReceiptCommand.noticeReceiptRequested = true
require(!invalidReceiptCommand.valid, "other controls cannot request a notice receipt")
let oldNotice = try JSONDecoder().decode(DAWRemoteCommand.self, from: JSONEncoder().encode(DAWRemoteCommand(project: project, action: .noticeSend, text: "Legacy")))
require(oldNotice.noticeReceiptRequested == nil, "legacy clients never receive a packet type they do not support")

extension DAWRemoteSession {
    func testNoticeReceipt(_ receipt: DAWRemoteNoticeReceipt) { received(.noticeReceipt(receipt), from: channel!) }
    func testExpireNotice(_ id: UUID) { pendingNotices[id]?.timeout.perform() }
    func testPendingNoticeCount() -> Int { pendingNotices.count }
}
let deliveryHost = DAWRemoteSession(role: .host, name: "Notice receipt host")
let deliveryClient = DAWRemoteSession(role: .client, name: "Notice receipt remote")
var receivedNotices: [UUID] = []
var deliveredNotices: [UUID: DAWRemoteNoticeDelivery] = [:]
let deliveryEndpoint = try deliveryHost.testListen()
deliveryHost.stateProvider = { fixture }
deliveryHost.noticeSendHandler = { command in
    guard command.project == project, command.text?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false else { return false }
    receivedNotices.append(command.id)
    // Receipt cannot run ahead of this synchronous application acceptance.
    require(deliveredNotices[command.id] == nil, "send callback runs only after the host handler accepts")
    return true
}
deliveryClient.testConnect(deliveryEndpoint)
waitFor("notice peers connected and authorized") { deliveryClient.remoteState != nil }
let firstNotice = DAWRemoteCommand(project: project, action: .noticeSend, text: "Same message")
let secondNotice = DAWRemoteCommand(project: project, action: .noticeSend, text: "Same message")
for command in [firstNotice, secondNotice] {
    deliveryClient.sendNotice(command) { deliveredNotices[command.id] = $0 }
}
require(deliveredNotices.isEmpty, "enqueueing bytes never produces an immediate success")
waitFor("repeated same-text taps get their own application receipts") { deliveredNotices.count == 2 }
require(deliveredNotices.values.allSatisfy { $0 == .accepted } && receivedNotices == [firstNotice.id, secondNotice.id], "each tap restarts the notice once and confirms its own ID")
var dedupResult: DAWRemoteNoticeDelivery?
deliveryClient.sendNotice(firstNotice) { dedupResult = $0 }
waitFor("retransmission reuses cached application receipt") { dedupResult != nil }
require(dedupResult == .accepted && receivedNotices.count == 2, "same command ID cannot display the notice twice")
var rejectResults: [DAWRemoteNoticeDelivery] = []
deliveryClient.sendNotice(.init(project: UUID(), action: .noticeSend, text: "Wrong project")) { rejectResults.append($0) }
deliveryClient.sendNotice(.init(project: project, action: .noticeSend, text: " \n ")) { rejectResults.append($0) }
waitFor("invalid project and empty notice are rejected by application") { rejectResults.count == 2 }
require(rejectResults == [.rejected, .rejected] && receivedNotices.count == 2, "rejected notices never report sent")

let timeoutNotice = DAWRemoteCommand(project: project, action: .noticeSend, text: "Delayed response")
var timeoutResults: [DAWRemoteNoticeDelivery] = []
deliveryClient.sendNotice(timeoutNotice) { timeoutResults.append($0) }
deliveryClient.testNoticeReceipt(.init(commandID: UUID(), project: project, accepted: true))
deliveryClient.testNoticeReceipt(.init(commandID: timeoutNotice.id, project: UUID(), accepted: true))
require(timeoutResults.isEmpty && deliveryClient.testPendingNoticeCount() == 1, "unrelated IDs or projects cannot confirm a pending notice")
deliveryClient.testExpireNotice(timeoutNotice.id)
require(timeoutResults == [.unconfirmed] && deliveryClient.testPendingNoticeCount() == 0, "deadline reports unknown delivery, never a false success")
waitFor("timed-out notice is eventually received") { receivedNotices.contains(timeoutNotice.id) }
RunLoop.main.run(until: Date().addingTimeInterval(0.15))
require(timeoutResults == [.unconfirmed], "late ACK cannot flip a timed-out attempt to sent")
let interruptedNotice = DAWRemoteCommand(project: project, action: .noticeSend, text: "Disconnected")
var interrupted: [DAWRemoteNoticeDelivery] = []
deliveryClient.sendNotice(interruptedNotice) { interrupted.append($0) }
deliveryClient.stop()
require(interrupted == [.disconnected] && deliveryClient.testPendingNoticeCount() == 0, "disconnect fails pending delivery exactly once")
deliveryClient.sendNotice(.init(project: project, action: .noticeSend, text: "Offline")) { interrupted.append($0) }
require(interrupted == [.disconnected, .disconnected], "offline sends cannot claim delivery")
deliveryHost.stop()
print("REMOTE_NOTICE_APPLICATION_ACK_REPEAT_DEDUP_REJECT_TIMEOUT_STALE_ACK_AND_DISCONNECT_OK")

// Closing a Notices-only screen must drain the withdrawal before stop cancels
// the TCP connection, including an immediate Send -> Close before active state.
let clearHost = DAWRemoteSession(role: .host, name: "Withdraw host")
let clearClient = DAWRemoteSession(role: .client, name: "Withdraw remote")
var clearOrder: [DAWRemoteCommand.Action] = []
var clearCompletionCount = 0
let clearEndpoint = try clearHost.testListen()
clearHost.stateProvider = { fixture }
clearHost.noticeSendHandler = { command in
    guard command.project == project else { return false }
    clearOrder.append(command.action); return true
}
clearHost.commandHandler = { command in
    if command.project == project && command.action == .noticeClear { clearOrder.append(command.action) }
}
clearClient.testConnect(clearEndpoint)
waitFor("withdraw peers connected and authorized") { clearClient.remoteState != nil }
clearClient.requestAccess(.notices)
waitFor("withdraw notices-only access authorized") { clearClient.accessMode == .notices && clearClient.remoteState != nil }
require(clearClient.remoteState?.notices?.active != true, "The close fixture has no active notice snapshot")
var invalidClearCompletions = 0
clearClient.sendNoticeClear(.init(project: UUID(), action: .noticeClear)) { invalidClearCompletions += 1 }
clearClient.sendNoticeClear(.init(project: project, action: .play)) { invalidClearCompletions += 1 }
require(invalidClearCompletions == 2 && clearOrder.isEmpty, "Stale projects and non-withdrawal commands complete locally without sending")
clearClient.send(.init(project: project, action: .noticeSend, text: "Close immediately"))
clearClient.sendNoticeClear(.init(project: project, action: .noticeClear)) {
    clearCompletionCount += 1; clearClient.stop()
}
require(clearCompletionCount == 0, "Explicit close waits for withdrawal socket completion")
waitFor("host receives send then withdrawal before client stops") { clearOrder == [.noticeSend, .noticeClear] && clearCompletionCount == 1 }
RunLoop.main.run(until: Date().addingTimeInterval(1.1))
require(clearCompletionCount == 1, "Write completion and deadline can finish a close only once")
clearClient.sendNoticeClear(.init(project: project, action: .noticeClear)) { clearCompletionCount += 1 }
require(clearCompletionCount == 2 && clearOrder == [.noticeSend, .noticeClear], "Offline close completes locally without queuing a later withdrawal")
clearHost.stop()
print("REMOTE_NOTICE_SEND_THEN_WITHDRAW_THEN_STOP_DRAINS_ONCE_WITHOUT_ACTIVE_SNAPSHOT_OK")
