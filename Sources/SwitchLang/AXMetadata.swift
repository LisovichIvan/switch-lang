import AppKit
import ApplicationServices

// Deliberately excludes values, selected text and all string-for-range APIs.
// The keyboard tracker, never an accessibility text read, supplies each word.
enum AXMetadataAttribute: CaseIterable {
  case role
  case subrole
  case focused
  case enabled
  case protectedContent
  case selectedTextRanges
  case selectedTextRange
  case focusedElement
  case characterCount
  case insertionPointLine

  var name: String {
    switch self {
    case .role: return kAXRoleAttribute
    case .subrole: return kAXSubroleAttribute
    case .focused: return kAXFocusedAttribute
    case .enabled: return kAXEnabledAttribute
    case .protectedContent:
      return NSAccessibility.Attribute.containsProtectedContent.rawValue
    case .selectedTextRanges: return kAXSelectedTextRangesAttribute
    case .selectedTextRange: return kAXSelectedTextRangeAttribute
    case .focusedElement: return kAXFocusedUIElementAttribute
    case .characterCount: return kAXNumberOfCharactersAttribute
    case .insertionPointLine: return kAXInsertionPointLineNumberAttribute
    }
  }
}

func readAXMetadata(
  _ attribute: AXMetadataAttribute, from element: AXUIElement, value: inout CFTypeRef?
) -> AXError {
  AXUIElementCopyAttributeValue(element, attribute.name as CFString, &value)
}

func readAXLineRange(
  _ line: Int, from element: AXUIElement, value: inout CFTypeRef?
) -> AXError {
  guard line >= 0 else { return .illegalArgument }
  return AXUIElementCopyParameterizedAttributeValue(
    element, kAXRangeForLineParameterizedAttribute as CFString, NSNumber(value: line), &value)
}
