import Foundation
import Network

/// Represents a discovered peer device on the local network
struct Peer: Identifiable, Hashable {
    let id: UUID
    let name: String
    let endpoint: NWEndpoint

    init(id: UUID = UUID(), name: String, endpoint: NWEndpoint) {
        self.id = id
        self.name = name
        self.endpoint = endpoint
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }

    static func == (lhs: Peer, rhs: Peer) -> Bool {
        lhs.id == rhs.id
    }
}
