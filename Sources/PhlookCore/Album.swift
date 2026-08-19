import Foundation

public struct Album: Identifiable, Equatable {
    public let id: Int64
    public let name: String
    public let count: Int
    public init(id: Int64, name: String, count: Int) {
        self.id = id; self.name = name; self.count = count
    }
}
