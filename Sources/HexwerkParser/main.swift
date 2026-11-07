import Foundation
import HexwerkHelper

// The XPC service inside hexwerk.app (#102), assembled by `make app` as
// Contents/XPCServices/de.schreck-thomas.hexwerk.Parser.xpc and run in the
// App Sandbox. All logic lives in HexwerkHelper.
let delegate = HelperListener()
let listener = NSXPCListener.service()
listener.delegate = delegate
listener.resume()  // never returns
