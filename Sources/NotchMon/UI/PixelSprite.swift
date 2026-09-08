import SwiftUI

/// A stepped pixel animation, eleven by eleven.
///
/// Eleven because that is the size of a brand mark in the strip, and the whole
/// point is that this stands **in place of** the mark rather than beside it:
/// nothing is added, nothing moves, and the laid-out size does not change by a
/// point. That last part is not a preference — the strip is measured by SwiftUI
/// and the panel window is sized to the measurement, so an animation that grew
/// would resize a window several times a second and drag the hole off the
/// camera cutout with it.
///
/// Drawn with `Canvas` on a `TimelineView` clock. Not `.animation(_:value:)`
/// with a repeat: an implicit animation on this subtree catches the panel's own
/// movement, which is what once had the refresh glyph bobbing below the header.
/// A clock has nothing to leak.
struct PixelSprite: View {
    let frames: [[String]]
    let color: Color
    var size: CGFloat = 11
    /// Seconds for one pass through every frame.
    var cycle: Double = 0.9

    private var step: Double { max(cycle / Double(frames.count), 1.0 / 30) }

    var body: some View {
        TimelineView(.periodic(from: .now, by: step)) { timeline in
            Canvas(opaque: false, rendersAsynchronously: false) { context, canvas in
                draw(frames[index(at: timeline.date)], in: context, size: canvas)
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }

    private func index(at date: Date) -> Int {
        let ticks = Int(date.timeIntervalSinceReferenceDate / step)
        return ((ticks % frames.count) + frames.count) % frames.count
    }

    private func draw(_ frame: [String], in context: GraphicsContext, size canvas: CGSize) {
        // Rounded up, so a grid at a fractional point size has no seams between
        // neighbouring cells — at eleven points on a 2x display the cell is
        // exactly one device pixel and a gap would be half the mark.
        let cell = canvas.width / 11
        let lit = GraphicsContext.Shading.color(color)
        let dim = GraphicsContext.Shading.color(color.opacity(0.38))
        for (y, row) in frame.enumerated() {
            for (x, mark) in row.enumerated() where mark != "." {
                let rect = CGRect(x: CGFloat(x) * cell, y: CGFloat(y) * cell,
                                  width: cell.rounded(.up), height: cell.rounded(.up))
                context.fill(Path(rect), with: mark == "#" ? lit : dim)
            }
        }
    }
}

/// The two that were chosen, as pictures.
///
/// Written as bitmaps rather than as maths because the entire question is what
/// they look like at eleven pixels, and a formula cannot be squinted at.
/// `#` is the agent's brand colour, `+` the same at 38%, `.` is nothing.
enum Sprites {
    /// The app is called NotchMon. A small thing that lives in the notch and
    /// stirs when work does is the one mascot it can have without borrowing
    /// anyone else's — it is the product's own name, drawn.
    ///
    /// Four frames: up, down, blink, down. The blink is what stops it reading
    /// as a shape being translated and starts it reading as something alive.
    static let notchling: [[String]] = [
        ["...........",
         "...#...#...",
         "....#.#....",
         "..#######..",
         ".#########.",
         ".##.###.##.",
         ".#########.",
         ".#########.",
         "..#######..",
         "..#.....#..",
         "..........."],
        ["...........",
         "...........",
         "...#...#...",
         "....#.#....",
         "..#######..",
         ".#########.",
         ".##.###.##.",
         ".#########.",
         ".#########.",
         "..#######..",
         ".#.......#."],
        ["...........",
         "...#...#...",
         "....#.#....",
         "..#######..",
         ".#########.",
         ".##+###+##.",
         ".#########.",
         ".#########.",
         "..#######..",
         "..#.....#..",
         "..........."],
        ["...........",
         "...........",
         "...#...#...",
         "....#.#....",
         "..#######..",
         ".#########.",
         ".##.###.##.",
         ".#########.",
         ".#########.",
         "..#######..",
         ".#.......#."]
    ]

    /// Fall, squash, spring. Character without a mascot, and the squash frame
    /// is the whole of it: take that one frame out and this is a dot going up
    /// and down.
    static let bounce: [[String]] = build()

    private static func build() -> [[String]] {
        let heights = [0, 2, 5, 8, 5, 2]
        return heights.enumerated().map { index, top in
            var grid = Array(repeating: Array(repeating: Character("."), count: 11), count: 11)
            for x in 2...8 { grid[10][x] = "+" }          // the floor it lands on
            if index == 3 {
                for x in 3...7 { grid[9][x] = "#" }        // squashed wide
                for x in 4...6 { grid[8][x] = "#" }
            } else {
                for dy in 0..<3 where top + dy <= 10 {
                    for dx in 0..<3 { grid[top + dy][4 + dx] = "#" }
                }
            }
            return grid.map { String($0) }
        }
    }
}
