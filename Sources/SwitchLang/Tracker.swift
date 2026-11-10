private let maximumTrackedWordScalars = 64
private let maximumTrailingSeparatorScalars = 16

private func isCombiningOrFormat(_ scalar: Unicode.Scalar) -> Bool {
  switch scalar.value {
  case 0x0300...0x036F, 0x0483...0x0489,
    0x1AB0...0x1AFF, 0x1DC0...0x1DFF,
    0x200B...0x200F, 0x202A...0x202E,
    0x2060...0x206F, 0x20D0...0x20FF,
    0xFE00...0xFE0F, 0xFE20...0xFE2F,
    0xFEFF, 0xE0100...0xE01EF:
    return true
  default:
    return false
  }
}

struct Replacement {
  let original: String
  let replacement: String
  let target: Layout
}

struct Tracker {
  // Scalars preserve Rust char counting and pop semantics, including CRLF.
  private var word: [Unicode.Scalar] = []
  private var trailing: [Unicode.Scalar] = []
  private var source: Layout?
  private var focus: UInt64 = 0
  private var blocked = false

  mutating func clear() {
    word.removeAll(keepingCapacity: true)
    trailing.removeAll(keepingCapacity: true)
    source = nil
    focus = 0
    blocked = false
  }

  mutating func observe(_ text: String, source: Layout, focus: UInt64) {
    if self.source != source || self.focus != focus {
      clear()
      self.source = source
      self.focus = focus
    }
    for scalar in text.unicodeScalars {
      let properties = scalar.properties
      // Apple marks some private-use scalars Alphabetic, unlike Rust;
      // exclude private-use scalars from the Alphabetic check below.
      if properties.isWhitespace && blocked {
        word.removeAll(keepingCapacity: true)
        trailing.removeAll(keepingCapacity: true)
        blocked = false
        continue
      }
      // Identifier and URL markers are not natural-language boundaries.
      if properties.numericType != nil || "@/\\_=".unicodeScalars.contains(scalar) {
        word.removeAll(keepingCapacity: true)
        trailing.removeAll(keepingCapacity: true)
        blocked = true
        continue
      }
      if blocked { continue }
      if isSupportedLetter(scalar) {
        if !trailing.isEmpty {
          word.removeAll(keepingCapacity: true)
          trailing.removeAll(keepingCapacity: true)
        }
        if word.count == maximumTrackedWordScalars {
          word.removeAll(keepingCapacity: true)
          blocked = true
        } else {
          word.append(scalar)
        }
      } else if (properties.generalCategory != .privateUse && properties.isAlphabetic)
        || properties.numericType != nil
        || isCombiningOrFormat(scalar)
        || properties.generalCategory == .control && !properties.isWhitespace
      {
        word.removeAll(keepingCapacity: true)
        trailing.removeAll(keepingCapacity: true)
        blocked = true
      } else if !word.isEmpty {
        if trailing.count == maximumTrailingSeparatorScalars {
          clear()
          break
        }
        trailing.append(scalar)
      }
    }
  }

  mutating func backspace() {
    // An unknown prefix still exists after deleting a single character.
    if blocked { return }
    if trailing.popLast() == nil {
      _ = word.popLast()
    }
  }

  func candidate(automatic: Bool) -> Replacement? {
    if automatic && trailing.isEmpty { return nil }
    return replacement(automatic: automatic)
  }

  // The action has not reached the editor. Do not invent Enter or Tab in the
  // suffix: the caller performs the action only after correction is complete.
  func candidateBeforeAction() -> Replacement? {
    replacement(automatic: true)
  }

  private func replacement(automatic: Bool) -> Replacement? {
    guard !blocked, !word.isEmpty, let source = source else { return nil }
    let originalWord = String(String.UnicodeScalarView(word))
    let converted =
      automatic
      ? automaticCorrection(originalWord, source: source)
      : convertWord(originalWord, source: source)
    guard let converted = converted else { return nil }
    let suffix = String(String.UnicodeScalarView(trailing))
    return Replacement(
      original: originalWord + suffix,
      replacement: converted + suffix,
      target: source.opposite
    )
  }
}
