import Foundation
import HexwerkHelper

// Test-only twin of HexwerkParser (#134): the same service code, signed with
// the same entitlements by `make sandbox-probes`, but its listener also
// exports the sandbox probes (`HelperProbeXPC`). It lives in a test bundle
// below .build and never in hexwerk.app.
let delegate = HelperListener(probes: true)
let listener = NSXPCListener.service()
listener.delegate = delegate
listener.resume()  // never returns
