import SwiftUI

if await CLIHandler.handleIfNeeded() {
    exit(0)
} else {
    SoftEtherFethVPNApp.main()
}
