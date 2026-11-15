import UIKit
import Darwin

private final class InputDelegate: TerminalViewDelegate {
    func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {}
    func setTerminalTitle(source: TerminalView, title: String) {}
    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
    func scrolled(source: TerminalView, position: Double) {}
    func requestOpenLink(source: TerminalView, link: String, params: [String: String]) {}
    func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}
    func send(source: TerminalView, data: ArraySlice<UInt8>) {
        typealias Send = @convention(c) (UnsafePointer<UInt8>?, Int) -> Void
        let send = unsafeBitCast(dlsym(UnsafeMutableRawPointer(bitPattern: -2), "test_send_bytes"), to: Send.self)
        Array(data).withUnsafeBufferPointer { send($0.baseAddress, $0.count) }
    }
}

private var view: TerminalView?
private let inputDelegate = InputDelegate()

@_cdecl("test_create_terminal")
public func createTerminal() {
    dispatchPrecondition(condition: .onQueue(.main))
    let terminal = TerminalView(frame: CGRect(x: 0, y: 0, width: 1024, height: 700), font: nil)
    terminal.terminalDelegate = inputDelegate
    view = terminal
}

@_cdecl("test_feed_terminal")
public func feedTerminal(_ bytes: UnsafePointer<UInt8>, _ count: Int) {
    dispatchPrecondition(condition: .onQueue(.main))
    view?.feed(byteArray: Array(UnsafeBufferPointer(start: bytes, count: count))[...])
}

@_cdecl("test_terminal_key")
public func terminalKey(_ bytes: UnsafePointer<UInt8>, _ count: Int) {
    dispatchPrecondition(condition: .onQueue(.main))
    let input = Array(UnsafeBufferPointer(start: bytes, count: count))
    if input == [27, 91, 66] { view?.sendKeyDown() }
    else if input == [27, 91, 65] { view?.sendKeyUp() }
    else { view?.send(data: input[...]) }
}
