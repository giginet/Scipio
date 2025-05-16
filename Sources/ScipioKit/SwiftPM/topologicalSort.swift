//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift open source project
//
// Copyright (c) 2014-2021 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See http://swift.org/LICENSE.txt for license information
// See http://swift.org/CONTRIBUTORS.txt for the list of Swift project authors
//
//===----------------------------------------------------------------------===//

import Foundation
import OrderedCollections

func topologicalSort<T: Identifiable>(
    _ nodes: [T], successors: (T) throws -> [T]
) throws -> [T] {
    // Implements a topological sort via recursion and reverse postorder DFS.
    func visit(_ node: T,
               _ stack: inout OrderedSet<T.ID>, _ visited: inout Set<T.ID>, _ result: inout [T],
               _ successors: (T) throws -> [T]) throws {
        // Mark this node as visited -- we are done if it already was.
        if !visited.insert(node.id).inserted {
            return
        }

        // Otherwise, visit each adjacent node.
        for succ in try successors(node) {
            guard stack.append(succ.id).inserted else {
                // If the successor is already in this current stack, we have found a cycle.
                //
                // FIXME: We could easily include information on the cycle we found here.
                throw GraphError.unexpectedCycle
            }
            try visit(succ, &stack, &visited, &result, successors)
            let popped = stack.removeLast()
            assert(popped == succ.id)
        }

        // Add to the result.
        result.append(node)
    }

    // FIXME: This should use a stack not recursion.
    var visited = Set<T.ID>()
    var result = [T]()
    var stack = OrderedSet<T.ID>()
    for node in nodes {
        precondition(stack.isEmpty)
        stack.append(node.id)
        try visit(node, &stack, &visited, &result, successors)
        let popped = stack.removeLast()
        assert(popped == node.id)
    }

    return result.reversed()
}

enum GraphError: Error {
    /// A cycle was detected in the input.
    case unexpectedCycle
}

