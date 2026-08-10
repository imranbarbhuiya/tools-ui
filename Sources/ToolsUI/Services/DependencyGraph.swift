import Foundation

enum DependencyGraph {
	/// Transitive dependencies of `id` in the order they must be started
	/// (deepest first). Excludes `id`. Cycles are broken rather than hung on, so
	/// a corrupted config still starts something instead of deadlocking.
	static func startOrder(for id: UUID, in services: [ManagedService]) -> [UUID] {
		let byID = Dictionary(uniqueKeysWithValues: services.map { ($0.id, $0) })
		var order: [UUID] = []
		var visited: Set<UUID> = []
		var onStack: Set<UUID> = []

		func visit(_ current: UUID) {
			guard !visited.contains(current), !onStack.contains(current) else { return }
			onStack.insert(current)
			for dependency in byID[current]?.dependencies ?? [] where byID[dependency] != nil {
				visit(dependency)
			}
			onStack.remove(current)
			visited.insert(current)
			if current != id {
				order.append(current)
			}
		}

		visit(id)
		return order
	}

	/// Services that would break if `id` stopped, nearest first.
	static func dependents(of id: UUID, in services: [ManagedService]) -> [UUID] {
		var result: [UUID] = []
		var queue = [id]
		var seen: Set<UUID> = [id]

		while !queue.isEmpty {
			let current = queue.removeFirst()
			for service in services where service.dependencies.contains(current) {
				guard !seen.contains(service.id) else { continue }
				seen.insert(service.id)
				result.append(service.id)
				queue.append(service.id)
			}
		}
		return result
	}

	/// Guards the editor against a user selecting a dependency that loops back.
	static func wouldCreateCycle(adding dependency: UUID, to id: UUID, in services: [ManagedService]) -> Bool {
		if dependency == id { return true }
		// A cycle appears exactly when `id` is already reachable from `dependency`.
		return reachable(from: dependency, in: services).contains(id)
	}

	static func reachable(from id: UUID, in services: [ManagedService]) -> Set<UUID> {
		let byID = Dictionary(uniqueKeysWithValues: services.map { ($0.id, $0) })
		var seen: Set<UUID> = []
		var queue = [id]

		while !queue.isEmpty {
			let current = queue.removeFirst()
			for dependency in byID[current]?.dependencies ?? [] {
				guard !seen.contains(dependency) else { continue }
				seen.insert(dependency)
				queue.append(dependency)
			}
		}
		return seen
	}

	/// Ids that participate in a dependency cycle, so the UI can flag them.
	static func cyclic(in services: [ManagedService]) -> Set<UUID> {
		var result: Set<UUID> = []
		for service in services where reachable(from: service.id, in: services).contains(service.id) {
			result.insert(service.id)
		}
		return result
	}
}
