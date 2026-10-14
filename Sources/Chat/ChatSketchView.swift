// ToshLLM - run LLMs locally on Intel Macs with AMD GPUs
// Copyright (C) 2026 Engelbert Delgado <engeldlgado@gmail.com>
// SPDX-License-Identifier: GPL-3.0-or-later

import SwiftUI

/// A figure an agent attached to an answer in a plane of its own, such as a tract traced from its deed's calls:
/// drawn without a map, since nothing in it places it on the ground.
struct ChatSketch: Codable, Equatable {
    var title: String?
    /// The unit of the coordinates, such as "ft".
    var unit: String
    /// The path in order, east and north of its first point.
    var points: [[Double]]
    /// The points to mark and number; the path's own points when nil (a tract with curves marks only its corners).
    var corners: [[Double]]?
    /// The figure should end where it began: the gap left between its last point and its first is drawn in red.
    var closed: Bool

    static let maximumPoints = 5000

    init(title: String?, unit: String, points: [[Double]], corners: [[Double]]? = nil, closed: Bool) {
        self.title = title
        self.unit = unit
        self.points = points
        self.corners = corners
        self.closed = closed
    }

    /// From an agent's `tosh.sketch`, or nil when it is not a figure that can be drawn.
    init?(_ object: [String: Any]) {
        func pairs(_ value: Any?) -> [[Double]]? {
            guard let items = value as? [Any], (2...Self.maximumPoints).contains(items.count) else { return nil }
            let read = items.compactMap { item -> [Double]? in
                guard let pair = item as? [Any], pair.count == 2,
                      let x = (pair[0] as? NSNumber)?.doubleValue, let y = (pair[1] as? NSNumber)?.doubleValue,
                      x.isFinite, y.isFinite else { return nil }
                return [x, y]
            }
            return read.count == items.count ? read : nil
        }
        guard let points = pairs(object["points"]) else { return nil }
        let corners = object["corners"] == nil ? nil : pairs(object["corners"])
        if object["corners"] != nil && corners == nil { return nil }
        self.init(title: (object["title"] as? String).map { String($0.prefix(120)) },
                  unit: String((object["unit"] as? String ?? "").prefix(12)), points: points, corners: corners,
                  closed: object["closed"] as? Bool ?? false)
    }

    /// How far the last point ends from the first, in the sketch's unit.
    var gap: Double {
        guard let first = points.first, let last = points.last else { return 0 }
        return hypot(last[0] - first[0], last[1] - first[1])
    }

    /// The width of a figure, for the gap to be read against.
    var span: Double {
        let xs = points.map { $0[0] }, ys = points.map { $0[1] }
        return max((xs.max() ?? 0) - (xs.min() ?? 0), (ys.max() ?? 0) - (ys.min() ?? 0))
    }

    /// A round length near a quarter of the figure, for the scale bar.
    var scaleLength: Double {
        let target = max(span / 4, 1e-9)
        let power = pow(10, floor(log10(target)))
        return [1.0, 2, 5, 10].map { $0 * power }.last { $0 <= target } ?? power
    }
}

extension ChatStore {
    /// Keeps a figure an agent sent with its answer on that answer.
    func attachSketch(_ sketch: ChatSketch, conversation id: UUID) {
        guard let i = conversations.firstIndex(where: { $0.id == id }),
              let j = conversations[i].messages.indices.last, conversations[i].messages[j].role == "assistant" else { return }
        conversations[i].messages[j].sketch = sketch
        save()
    }
}

struct ChatSketchSection: View {
    let sketch: ChatSketch

    @EnvironmentObject var loc: Localizer

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let title = sketch.title, !title.isEmpty {
                Text(title).font(.caption.weight(.medium))
            }
            ChatSketchCanvas(sketch: sketch)
                .frame(height: 280)
                .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 10))
                .help(loc.t("Croquis según los datos de la respuesta: el punto 1 es el inicio y cada tramo va al número siguiente.",
                            "Sketch from the answer's data: point 1 is the start and each leg runs to the next number."))
            Text(caption).font(.caption2).foregroundStyle(.secondary)
        }
    }

    private var caption: String {
        var text = loc.t("Croquis sin ubicar en el mapa", "Sketch, not placed on a map")
        if sketch.closed && sketch.gap > sketch.span * 1e-4 {
            text += " · " + loc.t("en rojo, lo que le falta para cerrar: %@ %@", "in red, what it lacks to close: %@ %@",
                                  ChatSketchCanvas.figure(sketch.gap), sketch.unit)
        }
        return text
    }
}

struct ChatSketchCanvas: View {
    let sketch: ChatSketch

    static func figure(_ value: Double) -> String {
        value >= 100 ? String(format: "%.0f", value) : value >= 10 ? String(format: "%.1f", value) : String(format: "%.2f", value)
    }

    var body: some View {
        Canvas { context, size in
            let corners = sketch.corners ?? sketch.points
            let all = sketch.points + corners
            let xs = all.map { $0[0] }, ys = all.map { $0[1] }
            let (minX, maxX, minY, maxY) = (xs.min() ?? 0, xs.max() ?? 0, ys.min() ?? 0, ys.max() ?? 0)
            let inset: CGFloat = 34
            let scale = min((size.width - 2 * inset) / max(maxX - minX, 1e-9), (size.height - 2 * inset) / max(maxY - minY, 1e-9))
            let offsetX = (size.width - (maxX - minX) * scale) / 2, offsetY = (size.height - (maxY - minY) * scale) / 2
            func place(_ p: [Double]) -> CGPoint {
                CGPoint(x: offsetX + (p[0] - minX) * scale, y: size.height - offsetY - (p[1] - minY) * scale)
            }

            var path = Path()
            path.addLines(sketch.points.map(place))
            context.stroke(path, with: .color(.accentColor), lineWidth: 2)
            let open = sketch.closed && sketch.gap > sketch.span * 1e-4
            if open, let first = sketch.points.first, let last = sketch.points.last {
                var gap = Path()
                gap.move(to: place(last))
                gap.addLine(to: place(first))
                context.stroke(gap, with: .color(.red), style: StrokeStyle(lineWidth: 2, dash: [5, 4]))
                let end = place(last)
                context.fill(Path(ellipseIn: CGRect(x: end.x - 4.5, y: end.y - 4.5, width: 9, height: 9)), with: .color(.red))
            }
            // the last point of a closed figure is its first one again, or the red end of what it lacks
            let marked = sketch.closed ? Array(corners.dropLast()) : corners
            for (index, corner) in marked.enumerated() {
                let point = place(corner)
                let dot = CGRect(x: point.x - 3.5, y: point.y - 3.5, width: 7, height: 7)
                context.fill(Path(ellipseIn: dot), with: .color(index == 0 ? .green : .accentColor))
                context.draw(Text("\(index + 1)").font(.caption2.weight(.semibold)).foregroundColor(.primary),
                             at: CGPoint(x: point.x + 9, y: point.y - 9))
            }

            // north up, and a scale bar of a round length
            let north = CGPoint(x: size.width - 18, y: 16)
            var arrow = Path()
            arrow.move(to: CGPoint(x: north.x, y: north.y + 18))
            arrow.addLine(to: north)
            arrow.move(to: CGPoint(x: north.x - 4, y: north.y + 6))
            arrow.addLine(to: north)
            arrow.addLine(to: CGPoint(x: north.x + 4, y: north.y + 6))
            context.stroke(arrow, with: .color(.secondary), lineWidth: 1.2)
            context.draw(Text("N").font(.caption2.weight(.bold)).foregroundColor(.secondary), at: CGPoint(x: north.x - 11, y: north.y + 4))
            let length = sketch.scaleLength * scale
            var bar = Path()
            bar.move(to: CGPoint(x: 14, y: size.height - 18))
            bar.addLine(to: CGPoint(x: 14 + length, y: size.height - 18))
            context.stroke(bar, with: .color(.secondary), lineWidth: 2)
            context.draw(Text("\(Self.figure(sketch.scaleLength)) \(sketch.unit)").font(.caption2).foregroundColor(.secondary),
                         at: CGPoint(x: 14 + length / 2, y: size.height - 8))
        }
    }
}
