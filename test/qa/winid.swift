// The windows a process shows, for screencapture -l: number, width, height.
import CoreGraphics
import Foundation

let pid = Int32(CommandLine.arguments[1])!
let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
    as! [[String: Any]]
for window in windows where (window[kCGWindowOwnerPID as String] as? Int32) == pid {
    let bounds = window[kCGWindowBounds as String] as! [String: Any]
    let layer = window[kCGWindowLayer as String] as? Int ?? 0
    if layer == 0 {
        print(window[kCGWindowNumber as String]!, bounds["Width"]!, bounds["Height"]!)
    }
}
