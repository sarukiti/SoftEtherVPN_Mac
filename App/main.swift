import SwiftUI

if await CLIHandler.handleIfNeeded() {
    exit(0)
} else {
    SoftEtherVPNForMacApp.main()
}
