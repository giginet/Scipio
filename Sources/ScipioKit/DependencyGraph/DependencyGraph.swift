import Foundation

/// A graph indicating dependencies between nodes.
/// The graph means that the parent node depends on the child nodes.
struct DependencyGraph<Value: Equatable> {
    /// Root nodes which are not depended on by the other nodes.
    private(set) var rootNodes: [Node]

    /// All nodes in this graph.
    private(set) var allNodes: [Node]

    private init(rootNodes: [Node], allNodes: [Node]) {
        self.rootNodes = rootNodes
        self.allNodes = allNodes
    }

    /// Resolves the graph from the given values.
    /// This function asks id for the given values and child ids to build the graph.
    static func resolve<ID: Hashable & Sendable>(
        _ values: Set<Value>,
        id: KeyPath<Value, ID>,
        childIDs: (Value) -> [ID]
    ) throws -> DependencyGraph<Value> where Value: Hashable {
        let nodes = values.enumerated().map { Node($1, nodeIndex: $0) }
        let nodeMap = Dictionary(uniqueKeysWithValues: nodes.map { ($0.value[keyPath: id], $0) })

        for node in nodes {
            let childNodeIDs = childIDs(node.value)
            let childNodes = try childNodeIDs.map { id in
                guard let node = nodeMap[id] else {
                    throw DependencyGraphError<ID>.failedToResolveChildNode(id)
                }
                return node
            }
            childNodes.forEach { childNode in node.appendToChildren(childNode) }
        }
        let rootNodes = nodes.filter { node in node.parents.isEmpty }
        return DependencyGraph(rootNodes: rootNodes, allNodes: nodes)
    }
}

extension DependencyGraph {
    /// All leaf nodes in this graph.
    var leafs: [Node] {
        allNodes.filter { $0.children.isEmpty }
    }

    /// Transforms values in all nodes to another values.
    /// The returned graph has the same structure with one of this graph.
    func map<T>(_ transform: (Value) -> T) -> DependencyGraph<T> {
        let newAllNodes = self.allNodes.map { node in
            let value = transform(node.value)
            return DependencyGraph<T>.Node(value, nodeIndex: node.nodeIndex)
        }
        let nodeMap = Dictionary(uniqueKeysWithValues: newAllNodes.map { ($0.nodeIndex, $0) })
        allNodes.forEach { previousNode in
            let children = previousNode.children.compactMap { nodeMap[$0.nodeIndex] }
            let newNode = nodeMap[previousNode.nodeIndex]
            children.forEach { newNode?.appendToChildren($0) }
        }
        let newRootNodes = rootNodes.compactMap { nodeMap[$0.nodeIndex] }
        return DependencyGraph<T>(rootNodes: newRootNodes, allNodes: newAllNodes)
    }

    /// Filters nodes which satisfy the given closure.
    /// Note that the parents and children of removed nodes are connects.
    /// For more details, please check documents of `remove`
    func filter(_ predicate: (Value) -> Bool) -> DependencyGraph<Value> {
        var copiedGraph = map { $0 }
        let removedNodes = copiedGraph.allNodes.filter { !predicate($0.value) }
        copiedGraph.remove(removedNodes.map(\.value))
        return copiedGraph
    }

    /// Removes nodes which have the given values.
    ///
    /// When an intermediate node is removed, the parent nodes and the child nodes are connected.
    ///
    /// This is an example.
    /// ```
    /// A → B → D
    ///     ↓   ↓
    ///     C → E
    /// ```
    /// If the node `B` is removed, `A` is connected to `C` and `D`
    /// ```
    /// A → D
    /// ↓   ↓
    /// C → E
    /// ```
    mutating func remove(_ value: Value) {
        remove([value])
    }

    /// Removes nodes which have the given values.
    ///
    /// When an intermediate node is removed, the parent nodes and the child nodes are connected.
    ///
    /// This is an example.
    /// ```
    /// A → B → D
    ///     ↓   ↓
    ///     C → E
    /// ```
    /// If the node `B` is removed, `A` is connected to `C` and `D`
    /// ```
    /// A → D
    /// ↓   ↓
    /// C → E
    /// ```
    mutating func remove(_ values: some Collection<Value>) {
        let copiedGraph = map { $0 }
        let newAllNodes = copiedGraph.allNodes.filter { !values.contains($0.value) }
        let nodeMap = Dictionary(uniqueKeysWithValues: copiedGraph.allNodes.map { ($0.nodeIndex, $0) })

        copiedGraph.allNodes.filter { values.contains($0.value) }
            .forEach { node in
                let parentNodes = node.parents.compactMap(\.reference)
                    .compactMap { nodeMap[$0.nodeIndex] }
                let childrenNodes = node.children

                // Remove relationship of the node.
                parentNodes.forEach { $0.removeFromChildren(node.nodeIndex) }
                childrenNodes.forEach { $0.removeFromParents(node.nodeIndex) }

                // Add relationship between the parents and the children.
                parentNodes.forEach { parentNode in
                    childrenNodes.forEach { child in
                        parentNode.appendToChildren(child)
                    }
                }
            }

        self.allNodes = newAllNodes
        self.rootNodes = newAllNodes.filter(\.parents.isEmpty)
    }
}

extension DependencyGraph {
    final class Node {
        let value: Value
        fileprivate let nodeIndex: NodeIndex
        private(set) var parents: [WeakReference<Node>] = []
        private(set) var children: [Node] = []

        fileprivate init(_ value: Value, nodeIndex: Int) {
            self.value = value
            self.nodeIndex = NodeIndex(value: nodeIndex)
        }

        fileprivate init(_ value: Value, nodeIndex: NodeIndex) {
            self.value = value
            self.nodeIndex = nodeIndex
        }

        fileprivate func appendToChildren(_ node: Node) {
            if !children.contains(where: { $0.nodeIndex == node.nodeIndex }) {
                children.append(node)
            }

            if !node.parents.contains(where: { $0.reference?.nodeIndex == nodeIndex }) {
                node.parents.append(WeakReference(self))
            }
        }

        fileprivate func removeFromChildren(_ nodeIndex: NodeIndex) {
            children = children.filter { $0.nodeIndex != nodeIndex }
        }

        fileprivate func removeFromParents(_ nodeIndex: NodeIndex) {
            parents = parents.filter { $0.reference?.nodeIndex != nodeIndex }
        }
    }
}

struct NodeIndex: Hashable {
    var value: Int
}

enum DependencyGraphError<ID: Hashable & Sendable>: LocalizedError {
    case failedToResolveChildNode(ID)

    var errorDescription: String? {
        switch self {
        case .failedToResolveChildNode(let id): "Failed to resolve child node with ID: \(id)"
        }
    }
}
