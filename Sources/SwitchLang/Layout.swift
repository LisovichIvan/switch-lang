// Pure conversion of ABC/U.S. QWERTY and macOS Russian ЙЦУКЕН.
// macOS Russian puts ё/Ё on the backslash key, unlike Russian — PC.
enum Layout: UInt32 {
  case english = 1
  case russian = 2

  var opposite: Layout {
    switch self {
    case .english: return .russian
    case .russian: return .english
    }
  }
}

private let maximumWordScalars = 64
private let englishKeyScalars = Array(
  "\\qwertyuiop[]asdfghjkl;'zxcvbnm,.|QWERTYUIOP{}ASDFGHJKL:\"ZXCVBNM<>".unicodeScalars
)
private let russianKeyScalars = Array(
  "ёйцукенгшщзхъфывапролджэячсмитьбюЁЙЦУКЕНГШЩЗХЪФЫВАПРОЛДЖЭЯЧСМИТЬБЮ".unicodeScalars
)

// No trimming, normalization or case folding. Reject empty, mixed, unmapped
// input and words longer than 64 Unicode scalars, not Swift Characters.
func convertWord(_ word: String, source: Layout) -> String? {
  let sourceKeys = source == .english ? englishKeyScalars : russianKeyScalars
  let destinationKeys = source == .english ? russianKeyScalars : englishKeyScalars
  var converted = String.UnicodeScalarView()
  var scalarCount = 0
  for scalar in word.unicodeScalars {
    guard scalarCount < maximumWordScalars,
      let keyIndex = sourceKeys.firstIndex(of: scalar)
    else {
      return nil
    }
    converted.append(destinationKeys[keyIndex])
    scalarCount += 1
  }
  return scalarCount == 0 ? nil : String(converted)
}

func isSupportedLetter(_ scalar: Unicode.Scalar) -> Bool {
  switch scalar.value {
  case 0x41...0x5A, 0x61...0x7A, 0x410...0x44F, 0x401, 0x451:
    return true
  default:
    return false
  }
}
