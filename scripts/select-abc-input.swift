import Carbon
import Foundation

let abcID = "com.apple.keylayout.ABC"

func identifier(_ source: TISInputSource) -> String? {
    guard let property = TISGetInputSourceProperty(source, kTISPropertyInputSourceID) else {
        return nil
    }
    return Unmanaged<CFString>.fromOpaque(property).takeUnretainedValue() as String
}

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(EXIT_FAILURE)
}

let current = TISCopyCurrentKeyboardInputSource().takeRetainedValue()
print("Current keyboard input source: \(identifier(current) ?? "unknown")")
if identifier(current) != abcID {
    let filter = [kTISPropertyInputSourceID as String: abcID] as CFDictionary
    let sources = TISCreateInputSourceList(filter, true).takeRetainedValue() as NSArray
    guard let source = sources.firstObject else { fail("ABC keyboard input source is unavailable.") }
    let abc = source as! TISInputSource
    guard TISEnableInputSource(abc) == noErr, TISSelectInputSource(abc) == noErr else {
        fail("Could not select ABC keyboard input source.")
    }
    let selected = TISCopyCurrentKeyboardInputSource().takeRetainedValue()
    guard identifier(selected) == abcID else { fail("ABC keyboard input source was not selected.") }
}
print("Keyboard input source: ABC")
