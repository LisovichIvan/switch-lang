#!/usr/bin/env python3
"""Enforce the production AX metadata-only boundary without running the GUI."""

from pathlib import Path
import re
import sys
import unittest

METADATA_FILE = 'SwitchLang/AXMetadata.swift'
ALLOWED_ATTRIBUTES = {
    'kAXRoleAttribute', 'kAXSubroleAttribute', 'kAXFocusedAttribute',
    'kAXEnabledAttribute', 'kAXSelectedTextRangesAttribute',
    'kAXSelectedTextRangeAttribute', 'kAXFocusedUIElementAttribute',
    'kAXNumberOfCharactersAttribute', 'kAXInsertionPointLineNumberAttribute',
    'kAXRangeForLineParameterizedAttribute',
}
COPY_CALL = re.compile(r'\b(AXUIElementCopy\w+)\s*\(')
SETTABLE_QUERY = re.compile(
    r'AXUIElementIsAttributeSettable\(\s*\w+\s*,\s*'
    r'kAX(?:Value|SelectedText)Attribute\s+as\s+CFString\s*,\s*&\w+\s*\)')
CONTENT_ATTRIBUTE = re.compile(
    r'\bkAX(?:Value|SelectedText|StringForRange|AttributedStringForRange|RTFForRange)'
    r'(?:Attribute|ParameterizedAttribute)\b|'
    r'"AX(?:Value|ValueDescription|SelectedText|StringForRange|AttributedStringForRange|RTFForRange)"|'
    r'\baccessibility(?:Value|SelectedText|AttributedStringForRange)\b')
ALLOWED_COPY = {
    'AXUIElementCopyAttributeValue': re.compile(
        r'AXUIElementCopyAttributeValue\(\s*element\s*,\s*'
        r'attribute\.name\s+as\s+CFString\s*,\s*&value\s*\)'),
    'AXUIElementCopyParameterizedAttributeValue': re.compile(
        r'AXUIElementCopyParameterizedAttributeValue\(\s*element\s*,\s*'
        r'kAXRangeForLineParameterizedAttribute\s+as\s+CFString\s*,\s*'
        r'NSNumber\(value:\s*line\)\s*,\s*&value\s*\)'),
}


def violations(sources):
    errors = []
    for name, source in sources.items():
        without_settable_queries = SETTABLE_QUERY.sub('', source)
        if CONTENT_ATTRIBUTE.search(without_settable_queries):
            errors.append(name + ': application-content accessor is forbidden')
        calls = COPY_CALL.findall(source)
        if name != METADATA_FILE:
            if calls:
                errors.append(name + ': AX reads must use the typed metadata boundary')
            continue
        attributes = set(re.findall(r'\bkAX\w+Attribute\b', source))
        if not attributes <= ALLOWED_ATTRIBUTES:
            errors.append(name + ': non-metadata attribute in the AX boundary')
        for call in set(calls):
            allowed = ALLOWED_COPY.get(call)
            if allowed is None or len(allowed.findall(source)) != calls.count(call):
                errors.append(name + ': unapproved AX copy invocation: ' + call)
    return errors


class MetadataPolicyTests(unittest.TestCase):
    def test_current_text_reader_is_rejected(self):
        source = 'AXUIElementCopyParameterizedAttributeValue(element, kAXStringForRangeParameterizedAttribute as CFString, parameter, &value)'
        self.assertTrue(violations({'SwitchLang/AXContext.swift': source}))

    def test_value_getters_and_raw_names_are_rejected(self):
        for attribute in ['kAXValueAttribute', 'kAXSelectedTextAttribute', '"AXValue"']:
            source = 'AXUIElementCopyAttributeValue(element, ' + attribute + ', &value)'
            self.assertTrue(violations({METADATA_FILE: source}))

    def test_settable_capability_is_not_a_content_read(self):
        for attribute in ['kAXValueAttribute', 'kAXSelectedTextAttribute']:
            source = 'AXUIElementIsAttributeSettable(\n target, ' + attribute + ' as CFString, &editable)'
            self.assertEqual(violations({'SwitchLang/AXContext.swift': source}), [])

    def test_only_typed_metadata_and_numeric_line_ranges_are_allowed(self):
        source = ('AXUIElementCopyAttributeValue(element, attribute.name as CFString, &value)\n'
                  'AXUIElementCopyParameterizedAttributeValue(element, kAXRangeForLineParameterizedAttribute as CFString, NSNumber(value: line), &value)')
        self.assertEqual(violations({METADATA_FILE: source}), [])
        self.assertTrue(violations({'SwitchLang/Other.swift': source}))
        self.assertTrue(violations({METADATA_FILE: source.replace('attribute.name', 'untrustedName')}))

    def test_unlisted_copy_functions_and_metadata_attributes_are_rejected(self):
        self.assertTrue(violations({METADATA_FILE: 'AXUIElementCopyMultipleAttributeValues(element, attributes, [], &value)'}))
        self.assertTrue(violations({METADATA_FILE: 'let attribute = kAXValueDescriptionAttribute'}))


def main():
    if sys.argv[1:] == ['--self-test']:
        unittest.main(argv=[sys.argv[0]])
        return
    if sys.argv[1:]:
        raise SystemExit('Expected --self-test or no arguments')
    directory = Path(__file__).resolve().parents[1] / 'Sources'
    sources = {str(path.relative_to(directory)): path.read_text()
               for path in sorted(directory.rglob('*'))
               if path.is_file() and path.suffix in ['.swift', '.c', '.h']}
    errors = violations(sources)
    if errors:
        raise SystemExit('\n'.join(errors))
    print('Production AX reads: metadata only; application-content accessors absent.')


if __name__ == '__main__':
    main()
