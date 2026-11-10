import Carbon
import CoreGraphics
import Foundation

// UCKeyTranslate has no input-length argument. Own an aligned snapshot and
// validate every offset/count in the selected resource before giving it to C.
// Byte reads deliberately do not assume alignment of the caller's Data.
final class ValidatedKeyboardLayout {
  private let storage: UnsafeMutableRawPointer
  private let length: Int
  private let keyboardType: UInt32
  private var selectedKeyboard = 0

  init(data: Data, keyboardType: UInt32) throws {
    guard data.count >= 40 else { throw KeyboardPlanError.invalid }
    length = data.count
    self.keyboardType = keyboardType
    storage = .allocate(byteCount: length, alignment: MemoryLayout<UCKeyboardLayout>.alignment)
    data.withUnsafeBytes { bytes in
      // SAFETY: nonempty Data supplies length readable bytes; storage owns
      // the same number of writable bytes for this object's lifetime.
      if let base = bytes.baseAddress { storage.copyMemory(from: base, byteCount: length) }
    }
    // All stored properties are initialized: deinit owns cleanup on every
    // throw below as well as successful construction; never free twice.
    guard word(0) == UInt16(kUCKeyLayoutHeaderFormat), word(2) & 0xff00 == 0x0100,
      integer(8) > 0, contains(12, integer(8), 28)
    else { throw KeyboardPlanError.invalid }
    let features = integer(4)
    guard
      features == 0
        || (features % 2 == 0 && contains(features, 1, 8)
          && word(features) == UInt16(kUCKeyLayoutFeatureInfoFormat))
    else { throw KeyboardPlanError.invalid }
    selectedKeyboard = 12
    for index in 0..<integer(8) {
      let keyboard = 12 + index * 28
      try validateKeyboard(at: keyboard)
      if index > 0 && selectedKeyboard == 12 && keyboardType >= UInt32(integer(keyboard))
        && keyboardType <= UInt32(integer(keyboard + 4))
      {
        selectedKeyboard = keyboard
      }
    }
  }

  deinit { storage.deallocate() }

  private func contains(_ offset: Int, _ count: Int, _ size: Int = 1) -> Bool {
    offset >= 0 && offset <= length && count >= 0 && count <= (length - offset) / size
  }

  private func byte(_ offset: Int) -> UInt8 { storage.load(fromByteOffset: offset, as: UInt8.self) }
  private func word(_ offset: Int) -> UInt16 {
    UInt16(byte(offset)) | UInt16(byte(offset + 1)) << 8
  }
  private func integer(_ offset: Int) -> Int {
    Int(word(offset)) | Int(word(offset + 2)) << 16
  }

  private func validateKeyboard(at keyboard: Int) throws {
    let modifiers = integer(keyboard + 8)
    let tables = integer(keyboard + 12)
    guard modifiers % 2 == 0, tables % 2 == 0,
      contains(modifiers, 8), contains(tables, 8),
      word(modifiers) == UInt16(kUCKeyModifiersToTableNumFormat),
      word(tables) == UInt16(kUCKeyToCharTableIndexFormat)
    else { throw KeyboardPlanError.invalid }
    let modifierCount = integer(modifiers + 4)
    let tableCount = integer(tables + 4)
    let tableSize = Int(word(tables + 2))
    guard tableCount > 0, tableSize > 0, contains(modifiers + 8, modifierCount),
      contains(tables + 8, tableCount, 4), Int(word(modifiers + 2)) < tableCount
    else {
      throw KeyboardPlanError.invalid
    }
    for index in 0..<modifierCount {
      guard Int(byte(modifiers + 8 + index)) < tableCount else { throw KeyboardPlanError.invalid }
    }
    for index in 0..<tableCount {
      let offset = integer(tables + 8 + index * 4)
      guard offset % 2 == 0, contains(offset, tableSize, 2) else { throw KeyboardPlanError.invalid }
    }
    let states = integer(keyboard + 16)
    if states != 0 {
      guard states % 2 == 0, contains(states, 4),
        word(states) == UInt16(kUCKeyStateRecordsIndexFormat),
        contains(states + 4, Int(word(states + 2)), 4)
      else { throw KeyboardPlanError.invalid }
      for index in 0..<Int(word(states + 2)) {
        let record = integer(states + 4 + index * 4)
        guard record % 2 == 0, contains(record, 8) else { throw KeyboardPlanError.invalid }
        let count = Int(word(record + 4))
        let format = word(record + 6)
        let entrySize =
          format == UInt16(kUCKeyStateEntryTerminalFormat)
          ? 4 : (format == UInt16(kUCKeyStateEntryRangeFormat) ? 8 : 0)
        guard count == 0 || (entrySize != 0 && contains(record + 8, count, entrySize)) else {
          throw KeyboardPlanError.invalid
        }
      }
    }
    let terminators = integer(keyboard + 20)
    if terminators != 0 {
      guard terminators % 2 == 0, contains(terminators, 4),
        word(terminators) == UInt16(kUCKeyStateTerminatorsFormat),
        contains(terminators + 4, Int(word(terminators + 2)), 2)
      else { throw KeyboardPlanError.invalid }
    }
    let sequences = integer(keyboard + 24)
    if sequences != 0 {
      guard sequences % 2 == 0, contains(sequences, 4),
        word(sequences) == UInt16(kUCKeySequenceDataIndexFormat)
      else { throw KeyboardPlanError.invalid }
      let count = Int(word(sequences + 2))
      guard contains(sequences + 4, count + 1, 2) else { throw KeyboardPlanError.invalid }
      var previous = 4 + (count + 1) * 2
      for index in 0...count {
        let offset = Int(word(sequences + 4 + index * 2))
        guard offset % 2 == 0, offset >= previous, contains(sequences, offset) else {
          throw KeyboardPlanError.invalid
        }
        previous = offset
      }
    }
  }

  func translate(keycode: UInt16, modifiers: UInt32, capacity: Int = 8) -> [UInt16]? {
    guard capacity > 0, capacity <= 255 else { return nil }
    let modifiersOffset = integer(selectedKeyboard + 8)
    let tables = integer(selectedKeyboard + 12)
    guard Int(keycode) < Int(word(tables + 2)) else { return nil }
    let tableNumber =
      Int(modifiers) < integer(modifiersOffset + 4)
      ? Int(byte(modifiersOffset + 8 + Int(modifiers))) : Int(word(modifiersOffset + 2))
    let table = integer(tables + 8 + tableNumber * 4)
    let output = word(table + Int(keycode) * 2)
    if output & 0xc000 == 0x4000 {
      let states = integer(selectedKeyboard + 16)
      // An absent/out-of-range state index is not a physical mapping.
      // Never rely on UCKeyTranslate to bounds-check that reference.
      guard states != 0, Int(output & 0x3fff) < Int(word(states + 2)) else { return nil }
    }
    var deadState: UInt32 = 0
    var count = 0
    var text = [UInt16](repeating: 0, count: capacity)
    // SAFETY: all resource headers, selected tables, state records and
    // sequence extents were checked in the immutable aligned snapshot.
    // Bind the aligned resource header explicitly before passing a typed C
    // pointer. Initial dead state is zero; NoDeadKeys prevents composition.
    let status = UCKeyTranslate(
      storage.bindMemory(to: UCKeyboardLayout.self, capacity: 1), keycode,
      UInt16(kUCKeyActionDown), modifiers, keyboardType, OptionBits(kUCKeyTranslateNoDeadKeysMask),
      &deadState, capacity, &count, &text)
    guard status == noErr, deadState == 0, count >= 0, count <= capacity else { return nil }
    return Array(text.prefix(count))
  }
}

enum KeyboardLayouts {
  static func sourceLayout(_ source: TISInputSource?) -> Layout? {
    guard Thread.isMainThread, let source,
      let pointer = TISGetInputSourceProperty(source, kTISPropertyInputSourceID)
    else { return nil }
    // SAFETY: TIS returns a borrowed CF object while source is retained.
    let value = Unmanaged<CFTypeRef>.fromOpaque(pointer).takeUnretainedValue()
    guard CFGetTypeID(value) == CFStringGetTypeID() else { return nil }
    switch value as? String {
    case "com.apple.keylayout.ABC", "com.apple.keylayout.US": return .english
    case "com.apple.keylayout.Russian": return .russian
    default: return nil
    }
  }

  static func copyTargetSource(_ layout: Layout) -> TISInputSource? {
    guard Thread.isMainThread,
      let sources = TISCreateInputSourceList(nil, false)?.takeRetainedValue()
    else { return nil }
    for index in 0..<CFArrayGetCount(sources) {
      guard let pointer = CFArrayGetValueAtIndex(sources, index) else { continue }
      // SAFETY: this CFArray is documented to contain TISInputSource
      // objects. ARC retains the returned source beyond the array.
      let source = Unmanaged<TISInputSource>.fromOpaque(pointer).takeUnretainedValue()
      guard sourceLayout(source) == layout,
        booleanProperty(source, kTISPropertyInputSourceIsEnabled),
        booleanProperty(source, kTISPropertyInputSourceIsSelectCapable)
      else { continue }
      return source
    }
    return nil
  }

  private static func booleanProperty(_ source: TISInputSource, _ key: CFString) -> Bool {
    guard let pointer = TISGetInputSourceProperty(source, key) else { return false }
    let value = Unmanaged<CFTypeRef>.fromOpaque(pointer).takeUnretainedValue()
    return CFGetTypeID(value) == CFBooleanGetTypeID() && CFEqual(value, kCFBooleanTrue)
  }

  private static func layoutData(_ source: TISInputSource) -> Data? {
    guard let pointer = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else {
      return nil
    }
    let value = Unmanaged<CFTypeRef>.fromOpaque(pointer).takeUnretainedValue()
    guard CFGetTypeID(value) == CFDataGetTypeID() else { return nil }
    // SAFETY: the dynamic CF type was checked above. Copy the bytes, not a
    // TIS-owned view; listener/worker code receives no borrowed TIS storage.
    let data = unsafeBitCast(value, to: CFData.self)
    let count = CFDataGetLength(data)
    guard count > 0, let bytes = CFDataGetBytePtr(data) else { return nil }
    return Data(bytes: bytes, count: count)
  }

  static func currentSnapshot() -> (layout: Layout?, data: Data?) {
    guard Thread.isMainThread, let source = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue()
    else { return (nil, nil) }
    return (sourceLayout(source), layoutData(source))
  }

  static func translate(data: Data, keycode: UInt16, flags: UInt64, keyboardType: UInt32)
    -> [UInt16]?
  {
    guard
      flags
        & (CGEventFlags.maskCommand.rawValue | CGEventFlags.maskControl.rawValue
          | CGEventFlags.maskAlternate.rawValue) == 0,
      let validated = try? ValidatedKeyboardLayout(data: data, keyboardType: keyboardType)
    else { return nil }
    var modifiers: UInt32 = 0
    if flags & CGEventFlags.maskShift.rawValue != 0 { modifiers |= 2 }
    if flags & CGEventFlags.maskAlphaShift.rawValue != 0 { modifiers |= 4 }
    return validated.translate(keycode: keycode, modifiers: modifiers)
  }

  // Read-only: no selection, input capture, access requests or event posting.
  static func checkLayouts() -> Bool {
    guard Thread.isMainThread, let english = copyTargetSource(.english),
      let russian = copyTargetSource(.russian),
      let englishData = layoutData(english), let russianData = layoutData(russian)
    else { return false }
    let keyboardType = UInt32(LMGetKbdType())
    guard let first = try? ValidatedKeyboardLayout(data: englishData, keyboardType: keyboardType),
      let second = try? ValidatedKeyboardLayout(data: russianData, keyboardType: keyboardType)
    else { return false }
    var checked = 0
    var baseMappings = 0
    do {
      for keycode: UInt16 in 0...50 {
        for modifiers: UInt32 in stride(from: 0, through: 6, by: 2) {
          guard let englishText = first.translate(keycode: keycode, modifiers: modifiers),
            let russianText = second.translate(keycode: keycode, modifiers: modifiers),
            englishText.count == 1, russianText.count == 1
          else { continue }
          let letter = (65...90).contains(englishText[0]) || (97...122).contains(englishText[0])
          if modifiers >= 4 && !letter { continue }
          guard
            let converted = convertWord(
              String(decoding: englishText, as: UTF16.self), source: .english)
          else { continue }
          guard Array(converted.utf16) == russianText else { return false }
          checked += 1
          if modifiers < 4 {
            baseMappings += 1
            _ = try KeyboardEventPlan(
              original: russianText, replacement: englishText,
              layoutData: englishData, keyboardType: keyboardType)
            if letter {
              _ = try KeyboardEventPlan(
                original: englishText, replacement: russianText,
                layoutData: russianData, keyboardType: keyboardType)
            }
          }
        }
      }
      _ = try KeyboardEventPlan(
        original: Array("Ghbdtn, ".utf16), replacement: Array("Привет, ".utf16),
        layoutData: russianData, keyboardType: keyboardType)
      _ = try KeyboardEventPlan(
        original: Array("Руддщ! ".utf16), replacement: Array("Hello! ".utf16),
        layoutData: englishData, keyboardType: keyboardType)
    } catch { return false }
    return checked == 118 && baseMappings == 66
  }
}
