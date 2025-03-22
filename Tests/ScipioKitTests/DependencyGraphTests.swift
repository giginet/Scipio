import Testing
@testable import ScipioKit

struct DependencyGraphTests {
    @Test
    func resolve() throws {
        let graph = try DependencyGraph.resolve(Set(TestValue.allCases), id: \.self, childIDs: { $0.children })

        #expect(Set(graph.rootNodes.map(\.value)) == [.a, .f])

        let aNode = try #require(graph.rootNodes.first { $0.value == .a })
        #expect(aNode.parents.isEmpty)
        #expect(aNode.children.map(\.value) == [.b])

        let bNode = try #require(aNode.children.first { $0.value == .b })
        #expect(bNode.parents.map(\.reference?.value) == [.a])
        #expect(Set(bNode.children.map(\.value)) == [.c, .d])

        let cNode = try #require(bNode.children.first { $0.value == .c })
        #expect(cNode.parents.map(\.reference?.value) == [.b])
        #expect(cNode.children.map(\.value) == [.e])

        let dNode = try #require(bNode.children.first { $0.value == .d })
        #expect(dNode.parents.map(\.reference?.value) == [.b])
        #expect(dNode.children.map(\.value) == [.e])

        let eNode = try #require(dNode.children.first { $0.value == .e })
        #expect(Set(eNode.parents.map(\.reference?.value)) == [.c, .d])
        #expect(eNode.children.isEmpty)

        let fNode = try #require(graph.rootNodes.first { $0.value == .f })
        #expect(fNode.parents.isEmpty)
        #expect(fNode.children.map(\.value) == [.g])

        let gNode = try #require(fNode.children.first { $0.value == .g })
        #expect(gNode.parents.map(\.reference?.value) == [.f])
        #expect(gNode.children.isEmpty)
    }

    @Test
    func map() throws {
        let baseGraph = try DependencyGraph.resolve(Set(TestValue.allCases), id: \.self, childIDs: { $0.children })
        let graph = baseGraph.map { $0.rawValue }

        let aNode = try #require(graph.rootNodes.first { $0.value == "a" })
        #expect(aNode.parents.isEmpty)
        #expect(aNode.children.map(\.value) == ["b"])

        let bNode = try #require(aNode.children.first { $0.value == "b"})
        #expect(bNode.parents.map(\.reference?.value) == ["a"])
        #expect(Set(bNode.children.map(\.value)) == ["c", "d"])

        let cNode = try #require(bNode.children.first { $0.value == "c" })
        #expect(cNode.parents.map(\.reference?.value) == ["b"])
        #expect(cNode.children.map(\.value) == ["e"])

        let dNode = try #require(bNode.children.first { $0.value == "d" })
        #expect(dNode.parents.map(\.reference?.value) == ["b"])
        #expect(dNode.children.map(\.value) == ["e"])

        let eNode = try #require(dNode.children.first { $0.value == "e" })
        #expect(Set(eNode.parents.map(\.reference?.value)) == ["c", "d"])
        #expect(eNode.children.isEmpty)

        let fNode = try #require(graph.rootNodes.first { $0.value == "f" })
        #expect(fNode.parents.isEmpty)
        #expect(fNode.children.map(\.value) == ["g"])

        let gNode = try #require(fNode.children.first { $0.value == "g" })
        #expect(gNode.parents.map(\.reference?.value) == ["f"])
        #expect(gNode.children.isEmpty)
    }

    @Test
    func filter() throws {
        let baseGraph = try DependencyGraph.resolve(Set(TestValue.allCases), id: \.self, childIDs: { $0.children })
        let graph = baseGraph.filter { $0 == .a || $0 == .e }
        // a → e

        #expect(Set(graph.rootNodes.map(\.value)) == [.a])

        let aNode = try #require(graph.rootNodes.first { $0.value == .a })
        #expect(aNode.parents.isEmpty)
        #expect(aNode.children.map(\.value) == [.e])

        let eNode = try #require(aNode.children.first { $0.value == .e })
        #expect(eNode.parents.map(\.reference?.value) == [.a])
        #expect(eNode.children.isEmpty)
    }

    @Test
    func leafs() throws {
        let graph = try DependencyGraph.resolve(Set(TestValue.allCases), id: \.self, childIDs: { $0.children })
        #expect(Set(graph.leafs().map(\.value)) == [.e, .g])
    }

    @Test
    func remove() throws {
        var graph = try DependencyGraph.resolve(Set(TestValue.allCases), id: \.self, childIDs: { $0.children })
        graph.remove([.b, .d, .g])
        // a      f
        // ↓ ↘︎
        // c → e

        #expect(Set(graph.rootNodes.map(\.value)) == [.a, .f])

        let aNode = try #require(graph.rootNodes.first { $0.value == .a })
        #expect(aNode.parents.isEmpty)
        #expect(aNode.children.map(\.value) == [.c, .e])

        let cNode = try #require(aNode.children.first { $0.value == .c })
        #expect(cNode.parents.map(\.reference?.value) == [.a])
        #expect(cNode.children.map(\.value) == [.e])

        let eNode = try #require(aNode.children.first { $0.value == .e })
        #expect(Set(eNode.parents.map(\.reference?.value)) == [.c, .a])
        #expect(eNode.children.isEmpty)

        let fNode = try #require(graph.rootNodes.first { $0.value == .f })
        #expect(fNode.parents.isEmpty)
        #expect(fNode.children.isEmpty)

        #expect(Set(graph.leafs().map(\.value)) == [.e, .f])
    }
}

// a → b → d  f → g
//     ↓   ↓
//     c → e
private enum TestValue: String, Hashable, CaseIterable {
    // swiftlint:disable:next identifier_name
    case a, b, c, d, e, f, g

    var children: [TestValue] {
        switch self {
        case .a: return [.b]
        case .b: return [.c, .d]
        case .c: return [.e]
        case .d: return [.e]
        case .e: return []
        case .f: return [.g]
        case .g: return []
        }
    }
}
