import AppKit

// Ported from upstream 430075438fc763bb291811c607ace790e2a7fb42. The indicator
// sits at the caret anchor only when that anchor is near the mouse.
@main enum IndicatorPlacementTests {
    static func main() {
        let cursor = NSPoint(x: 100, y: 100)

        let near = NSPoint(x: 220, y: 100)
        precondition(FocusUtils.chooseIndicatorPoint(resolvedInputAnchor: near, cursorPosition: cursor, maxDistanceFromCursor: 200) == near)
        print("PASS uses the resolved anchor when it is near the cursor")

        let far = NSPoint(x: 301, y: 100)
        precondition(FocusUtils.chooseIndicatorPoint(resolvedInputAnchor: far, cursorPosition: cursor, maxDistanceFromCursor: 200) == cursor)
        print("PASS falls back to the cursor when the resolved anchor is too far away")

        precondition(FocusUtils.chooseIndicatorPoint(resolvedInputAnchor: nil, cursorPosition: cursor, maxDistanceFromCursor: 200) == cursor)
        print("PASS falls back to the cursor when the anchor is unavailable")

        // The shipped limit is 200 pt, measured as a straight line.
        let edge = NSPoint(x: 220, y: 260)
        precondition(FocusUtils.chooseIndicatorPoint(resolvedInputAnchor: edge, cursorPosition: cursor) == edge)
        let past = NSPoint(x: 221, y: 260)
        precondition(FocusUtils.chooseIndicatorPoint(resolvedInputAnchor: past, cursorPosition: cursor) == cursor)
        print("PASS default limit is 200 pt from the cursor")
    }
}
