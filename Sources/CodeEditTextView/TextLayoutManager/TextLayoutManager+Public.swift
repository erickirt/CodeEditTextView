//
//  TextLayoutManager+Public.swift
//  CodeEditTextView
//
//  Created by Khan Winter on 9/13/23.
//

import AppKit

extension TextLayoutManager {
    public func estimatedHeight() -> CGFloat {
        max(lineStorage.height, estimateLineHeight())
    }

    public func estimatedWidth() -> CGFloat {
        maxLineWidth + edgeInsets.horizontal
    }

    /// Finds a text line for the given y position relative to the text view.
    ///
    /// Y values begin at the top of the view and extend down. Eg, a `0` y value would  return the first line in
    /// the text view if it exists. Though, for that operation the user should instead use
    /// ``TextLayoutManager/textLineForIndex(_:)`` for reliability.
    ///
    /// - Parameter posY: The y position to find a line for.
    /// - Returns: A text line position, if a line could be found at the given y position.
    public func textLineForPosition(_ posY: CGFloat) -> TextLineStorage<TextLine>.TextLinePosition? {
        lineStorage.getLine(atPosition: posY)
    }

    /// Finds a text line for a given text offset.
    ///
    /// This method will not do any checking for document bounds, and will simply return `nil` if the offset if negative
    /// or outside the range of the document.
    ///
    /// However, if the offset is equal to the length of the text storage (one index past the end of the document) this
    /// method will return the last line in the document if it exists.
    ///
    /// - Parameter offset: The offset in the document to fetch a line for.
    /// - Returns: A text line position, if a line could be found at the given offset.
    public func textLineForOffset(_ offset: Int) -> TextLineStorage<TextLine>.TextLinePosition? {
        if offset == lineStorage.length {
            return lineStorage.last
        } else {
            return lineStorage.getLine(atOffset: offset)
        }
    }

    /// Finds text line and returns it if found.
    /// Lines are 0 indexed.
    /// - Parameter index: The line to find.
    /// - Returns: The text line position if any, `nil` if the index is out of bounds.
    public func textLineForIndex(_ index: Int) -> TextLineStorage<TextLine>.TextLinePosition? {
        guard index >= 0 && index < lineStorage.count else { return nil }
        return lineStorage.getLine(atIndex: index)
    }

    /// Calculates the text position at the given point in the view.
    /// - Parameter point: The point to translate to text position.
    /// - Returns: The text offset in the document where the given point is laid out.
    /// - Warning: If the requested point has not been laid out or it's layout has since been invalidated by edits or
    ///            other changes, this method will return the invalid data. For best results, ensure the text around the
    ///            point has been laid out or is visible before calling this method.
    public func textOffsetAtPoint(_ point: CGPoint) -> Int? {
        guard point.y <= estimatedHeight() else { // End position is a special case.
            return textStorage?.length
        }
        guard let position = lineStorage.getLine(atPosition: point.y),
              let fragmentPosition = position.data.typesetter.lineFragments.getLine(
                atPosition: point.y - position.yPos
              ) else {
            return nil
        }
        let fragment = fragmentPosition.data

        if fragment.width == 0 {
            return position.range.location + fragmentPosition.range.location
        } else if fragment.width < point.x - edgeInsets.left {
            let fragmentRange = CTLineGetStringRange(fragment.ctLine)
            let globalFragmentRange = NSRange(
                location: position.range.location + fragmentRange.location,
                length: fragmentRange.length
            )
            let endPosition = position.range.location + fragmentRange.location + fragmentRange.length

            // If the endPosition is at the end of the line, and the line ends with a line ending character
            // return the index before the eol.
            if endPosition == position.range.max,
               let lineEnding = LineEnding(line: textStorage?.substring(from: globalFragmentRange) ?? "") {
                return endPosition - lineEnding.length
            } else {
                return endPosition
            }
        } else {
            // Somewhere in the fragment
            let fragmentIndex = CTLineGetStringIndexForPosition(
                fragment.ctLine,
                CGPoint(x: point.x - edgeInsets.left, y: fragment.height/2)
            )
            return position.range.location + fragmentIndex
        }
    }

    /// Find a position for the character at a given offset.
    /// Returns the rect of the character at the given offset.
    /// The rect may represent more than one unicode unit, for instance if the offset is at the beginning of an
    /// emoji or non-latin glyph.
    /// - Parameter offset: The offset to create the rect for.
    /// - Returns: The found rect for the given offset.
    public func rectForOffset(_ offset: Int) -> CGRect? {
        guard offset != lineStorage.length else {
            return rectForEndOffset()
        }
        guard let linePosition = lineStorage.getLine(atOffset: offset) else {
            return nil
        }
        if linePosition.data.lineFragments.isEmpty {
            let newHeight = ensureLayoutFor(position: linePosition)
            if linePosition.height != newHeight {
                delegate?.layoutManagerHeightDidUpdate(newHeight: lineStorage.height)
            }
        }

        guard let fragmentPosition = linePosition.data.typesetter.lineFragments.getLine(
            atOffset: offset - linePosition.range.location
        ) else {
            return nil
        }

        // Get the *real* length of the character at the offset. If this is a surrogate pair it'll return the correct
        // length of the character at the offset.
        let realRange = textStorage?.length == 0
        ? NSRange(location: offset, length: 0)
        : (textStorage?.string as? NSString)?.rangeOfComposedCharacterSequence(at: offset)
        ?? NSRange(location: offset, length: 0)

        let minXPos = CTLineGetOffsetForStringIndex(
            fragmentPosition.data.ctLine,
            realRange.location - linePosition.range.location, // CTLines have the same relative range as the line
            nil
        )
        let maxXPos = CTLineGetOffsetForStringIndex(
            fragmentPosition.data.ctLine,
            realRange.max - linePosition.range.location,
            nil
        )

        return CGRect(
            x: minXPos + edgeInsets.left,
            y: linePosition.yPos + fragmentPosition.yPos,
            width: maxXPos - minXPos,
            height: fragmentPosition.data.scaledHeight
        )
    }

    // swiftlint:disable function_body_length
    /// Creates a smooth bezier path for the specified range.
    /// If the range exceeds the available text, it uses the maximum available range.
    /// - Parameter range: The range of text offsets to generate the path for.
    /// - Returns: An `NSBezierPath` representing the visual shape for the text range, or `nil` if the range is invalid.
    public func roundedPathForRange(_ range: NSRange) -> NSBezierPath? {
        // Ensure the range is within the bounds of the text storage
        let validRange = NSRange(
            location: range.lowerBound,
            length: min(range.length, lineStorage.length - range.lowerBound)
        )

        guard validRange.length > 0 else { return rectForEndOffset().map { NSBezierPath(rect: $0) } }

        var rightSidePoints: [CGPoint] = [] // Points for Bottom-right → Top-right
        var leftSidePoints: [CGPoint] = []  // Points for Bottom-left → Top-left

        var currentOffset = validRange.lowerBound

        // Process each line fragment within the range
        while currentOffset < validRange.upperBound {
            guard let linePosition = lineStorage.getLine(atOffset: currentOffset) else { return nil }

            if linePosition.data.lineFragments.isEmpty {
                let newHeight = ensureLayoutFor(position: linePosition)
                if linePosition.height != newHeight {
                    delegate?.layoutManagerHeightDidUpdate(newHeight: lineStorage.height)
                }
            }

            guard let fragmentPosition = linePosition.data.typesetter.lineFragments.getLine(
                atOffset: currentOffset - linePosition.range.location
            ) else { break }

            // Calculate the X positions for the range's boundaries within the fragment
            let realRangeStart = (textStorage?.string as? NSString)?
                .rangeOfComposedCharacterSequence(at: validRange.lowerBound)
            ?? NSRange(location: validRange.lowerBound, length: 0)

            let realRangeEnd = (textStorage?.string as? NSString)?
                .rangeOfComposedCharacterSequence(at: validRange.upperBound - 1)
            ?? NSRange(location: validRange.upperBound - 1, length: 0)

            let minXPos = CTLineGetOffsetForStringIndex(
                fragmentPosition.data.ctLine,
                realRangeStart.location - linePosition.range.location,
                nil
            ) + edgeInsets.left

            let maxXPos = CTLineGetOffsetForStringIndex(
                fragmentPosition.data.ctLine,
                realRangeEnd.upperBound - linePosition.range.location,
                nil
            ) + edgeInsets.left

            // Ensure the fragment has a valid width
            guard maxXPos > minXPos else { break }

            // Add the Y positions for the fragment
            let topY = linePosition.yPos + fragmentPosition.yPos + fragmentPosition.data.scaledHeight
            let bottomY = linePosition.yPos + fragmentPosition.yPos

            // Append points in the correct order
            rightSidePoints.append(contentsOf: [
                CGPoint(x: maxXPos, y: bottomY), // Bottom-right
                CGPoint(x: maxXPos, y: topY)    // Top-right
            ])
            leftSidePoints.insert(contentsOf: [
                CGPoint(x: minXPos, y: topY),   // Top-left
                CGPoint(x: minXPos, y: bottomY) // Bottom-left
            ], at: 0)

            // Move to the next fragment
            currentOffset = min(validRange.upperBound, linePosition.range.upperBound)
        }

        // Combine the points in clockwise order
        let points = leftSidePoints + rightSidePoints

        // Close the path
        if let firstPoint = points.first {
            return NSBezierPath.smoothPath(points + [firstPoint], radius: 2)
        }

        return nil
    }
    // swiftlint:enable function_body_length

    /// Finds a suitable cursor rect for the end position.
    /// - Returns: A CGRect if it could be created.
    private func rectForEndOffset() -> CGRect? {
        if let last = lineStorage.last {
            if last.range.isEmpty {
                // Return a 0-width rect at the end of the last line.
                return CGRect(x: edgeInsets.left, y: last.yPos, width: 0, height: last.height)
            } else if let rect = rectForOffset(last.range.max - 1) {
                return  CGRect(x: rect.maxX, y: rect.minY, width: 0, height: rect.height)
            }
        } else if lineStorage.isEmpty {
            // Text is empty, create a new rect with estimated height at the origin
            return CGRect(
                x: edgeInsets.left,
                y: 0.0,
                width: 0,
                height: estimateLineHeight()
            )
        }
        return nil
    }

    /// Forces layout calculation for all lines up to and including the given offset.
    /// - Parameter offset: The offset to ensure layout until.
    public func ensureLayoutUntil(_ offset: Int) {
        guard let linePosition = lineStorage.getLine(atOffset: offset),
              let visibleRect = delegate?.visibleRect,
              visibleRect.maxY < linePosition.yPos + linePosition.height,
              let startingLinePosition = lineStorage.getLine(atPosition: visibleRect.minY)
        else {
            return
        }
        let originalHeight = lineStorage.height

        for linePosition in lineStorage.linesInRange(
            NSRange(start: startingLinePosition.range.location, end: linePosition.range.max)
        ) {
            let height = ensureLayoutFor(position: linePosition)
            if height != linePosition.height {
                lineStorage.update(
                    atIndex: linePosition.range.location,
                    delta: 0,
                    deltaHeight: height - linePosition.height
                )
            }
        }

        if originalHeight != lineStorage.height || layoutView?.frame.size.height != lineStorage.height {
            delegate?.layoutManagerHeightDidUpdate(newHeight: lineStorage.height)
        }
    }

    /// Forces layout calculation for all lines up to and including the given offset.
    /// - Parameter offset: The offset to ensure layout until.
    private func ensureLayoutFor(position: TextLineStorage<TextLine>.TextLinePosition) -> CGFloat {
        guard let textStorage else { return 0 }
        let displayData = TextLine.DisplayData(
            maxWidth: maxLineLayoutWidth,
            lineHeightMultiplier: lineHeightMultiplier,
            estimatedLineHeight: estimateLineHeight()
        )
        position.data.prepareForDisplay(
            displayData: displayData,
            range: position.range,
            stringRef: textStorage,
            markedRanges: markedTextManager.markedRanges(in: position.range),
            breakStrategy: lineBreakStrategy
        )
        var height: CGFloat = 0
        for fragmentPosition in position.data.lineFragments {
            height += fragmentPosition.data.scaledHeight
        }
        return height
    }
}
