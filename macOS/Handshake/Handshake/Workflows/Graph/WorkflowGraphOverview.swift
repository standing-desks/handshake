import SwiftUI

/// A centered preview of the same agent cards used on the work mat.
struct WorkflowGraphOverview: View {
    static let height: CGFloat = 170
    let definition: CoreWorkflowType.Definition

    init(definition: CoreWorkflowType.Definition) {
        self.definition = WorkflowGraphAgents.expanded(definition)
    }

    private func point(_ id: String) -> CGPoint {
        let position =
            definition.graph?.positions[id]
            ?? WorkflowEditorLayout.defaultPosition(for: id, roles: definition.roles)
        return CGPoint(x: position.x, y: position.y)
    }

    private func nodeSize(_ id: String) -> CGSize { WorkflowEditorLayout.nodeSize(for: id, in: definition) }

    private func returnLane(_ edge: CoreWorkflowType.Edge) -> CGFloat? {
        WorkflowEditorLayout.returnLane(
            for: edge, edges: definition.graph?.agentEdges ?? [], point: point, size: nodeSize)
    }

    private var bounds: CGRect {
        var bounds = definition.roles.reduce(CGRect.null) { bounds, role in
            let center = point(role.id)
            let size = WorkflowEditorLayout.nodeSize(for: role.id, in: definition)
            return bounds.union(
                CGRect(
                    x: center.x - size.width / 2 - 16, y: center.y - size.height / 2 - 16,
                    width: size.width + 32, height: size.height + 32))
        }
        let edges = definition.graph?.agentEdges ?? []
        for edge in edges {
            let path = WorkflowConnectionShape(
                from: point(edge.from), destination: point(edge.to), feedback: edge.event == .feedback,
                lane: returnLane(edge), sourceSize: nodeSize(edge.from), destinationSize: nodeSize(edge.to)
            ).path(in: .zero)
            bounds = bounds.union(path.boundingRect.insetBy(dx: -16, dy: -16))
        }
        return bounds
    }

    var accessibilitySummary: String {
        guard !definition.roles.isEmpty else { return "No agents" }
        let graph = definition.graph
        let agents = definition.roles.map { role in
            var states: [String] = []
            if graph?.startsAgent(role.id) == true { states.append("Starts here") }
            if graph?.returnsResult(role.id) == true {
                states.append(graph?.reviewsWork(role.id) == true ? "Result on approval" : "Returns result")
            }
            if graph?.reviewsWork(role.id) == true { states.append("Reviews work") }
            return ([role.name] + states).joined(separator: ", ")
        }
        func name(_ id: String) -> String { definition.roles.first { $0.id == id }?.name ?? "Agent" }
        let links = (graph?.agentEdges ?? []).map { edge in
            let output = WorkflowDecisionLabels.outputTitle(edge, definition: definition)
            return "\(name(edge.from)) to \(name(edge.to)): \(output)"
        }
        return (agents + links).joined(separator: "; ")
    }

    var body: some View {
        GeometryReader { geometry in
            let bounds = bounds.isNull ? CGRect(x: 0, y: 0, width: 400, height: 180) : bounds
            let scale = min(1, geometry.size.width / bounds.width, geometry.size.height / bounds.height)
            let display: (String) -> CGPoint = { id in
                let center = point(id)
                return CGPoint(
                    x: geometry.size.width / 2 + (center.x - bounds.midX) * scale,
                    y: geometry.size.height / 2 + (center.y - bounds.midY) * scale)
            }
            ZStack(alignment: .topLeading) {
                Canvas { context, _ in
                    for edge in definition.graph?.agentEdges ?? [] {
                        let path = WorkflowConnectionShape(
                            from: point(edge.from), destination: point(edge.to),
                            feedback: edge.event == .feedback,
                            lane: returnLane(edge), sourceSize: nodeSize(edge.from), destinationSize: nodeSize(edge.to)
                        ).path(in: bounds)
                        var transform = CGAffineTransform(
                            translationX: geometry.size.width / 2, y: geometry.size.height / 2)
                        transform = transform.scaledBy(x: scale, y: scale)
                            .translatedBy(x: -bounds.midX, y: -bounds.midY)
                        context.stroke(
                            path.applying(transform),
                            with: .color(
                                (definition.roles.first { $0.id == edge.from }?.color?.tint ?? .secondary).opacity(0.65)
                            ),
                            style: .init(lineWidth: 1.5, dash: edge.event == .feedback ? [5, 4] : []))
                    }
                }.accessibilityHidden(true)
                ForEach(definition.roles) { role in
                    WorkflowGraphCard(
                        title: role.name, decision: definition.graph?.decisions[role.id],
                        passthrough: definition.graph?.decisions[role.id] != nil
                            && definition.graph?.agentEdges.filter { $0.from == role.id }.count == 1,
                        tint: role.color?.tint,
                        startsHere: definition.graph?.startsAgent(role.id) == true,
                        returnsResult: definition.graph?.returnsResult(role.id) == true,
                        reviewsWork: definition.graph?.reviewsWork(role.id) == true
                    )
                    .scaleEffect(scale).position(display(role.id))
                }
            }
        }.frame(height: Self.height)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(accessibilitySummary)
    }
}
