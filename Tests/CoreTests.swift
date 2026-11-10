// The 28 groups preserve the original layout, detector and tracker scenarios.
func runCoreTests() throws -> Int {
  let groups: [() throws -> Void] = [
    testOppositeLayoutIsInvolutive,
    testConvertsWordsInBothDirectionsPreservingCase,
    testConvertsEveryPunctuationLetterKeyWithShift,
    testMatchesCompleteKeyboardRows,
    testEveryTableScalarRoundtripsWithoutDuplicateKeys,
    testRejectsEmptyForeignMixedAndUnmappedInputWithoutNormalizing,
    testLimitsUnicodeScalarsNotBytes,
    testSupportedLettersAreExactlyASCIIAndRussianLetters,
    testCorrectsObviousWordsInBothDirectionsWithCase,
    testLeavesAllKnownSourceWordsUnchangedInAnyCase,
    testPreservesAmbiguousWordsValidInBothLanguages,
    testSkipsShortWordsEvenWhenConvertedWordIsKnown,
    testSkipsUnknownTargetsAndIncorrectSourceLayouts,
    testSkipsIdentifiersAddressesURLsPathsAndSeparatedWords,
    testSkipsPunctuationLetterKeysEvenIfManualConversionIsKnown,
    testRejectsMixedAlphabetsUnsupportedUnicodeAndExcessiveLength,
    testSuccessfulCorrectionsDoNotTriggerReverseCorrection,
    testManualDoesNotRequireSeparator,
    testAutomaticHandlesWordSeparatorsWithoutChangingThem,
    testActionBoundaryCorrectsBeforeInsertingEnterOrTab,
    testActionBoundaryKeepsDetectionAndExistingSuffixRules,
    testOnlyLatestWordIsRetained,
    testBackspaceUpdatesOnlyKnownText,
    testIdentifiersAndMixedInputAreNotCandidates,
    testCompositionAndFormatMarksDoNotTriggerCorrection,
    testContextAndLayoutChangesDiscardPreviousWord,
    testOversizedInputIsNotTruncatedIntoCandidate,
    testUnknownPrefixAfterBackspaceRemainsBlocked,
  ]
  for group in groups { try group() }
  return groups.count
}

private let englishKeyboardFixture =
  "\\qwertyuiop[]asdfghjkl;'zxcvbnm,.|QWERTYUIOP{}ASDFGHJKL:\"ZXCVBNM<>"
private let russianKeyboardFixture =
  "ёйцукенгшщзхъфывапролджэячсмитьбюЁЙЦУКЕНГШЩЗХЪФЫВАПРОЛДЖЭЯЧСМИТЬБЮ"
private let knownEnglishFixture = [
  "about", "after", "again", "before", "better", "could", "first", "friend", "from", "good",
  "hello", "help", "here", "home", "house", "just", "know", "like", "little", "look", "make",
  "many", "more", "morning", "much", "name", "need", "never", "next", "nice", "night", "only",
  "other", "please", "really", "right", "same", "should", "some", "sorry", "take", "test",
  "text", "thank", "thanks", "that", "the", "their", "them", "then", "there", "these", "they",
  "thing", "think", "this", "time", "today", "very", "want", "well", "what", "when", "where",
  "which", "will", "with", "word", "work", "world", "would", "your",
]
private let knownRussianFixture = [
  "было", "будет", "время", "всего", "всегда", "говорить", "даже", "делать", "день", "добрый",
  "друг", "если", "есть", "ещё", "здесь", "знать", "каждый", "как", "когда", "конечно",
  "люди", "меня", "может", "можно", "надо", "наше", "него", "нет", "новый", "нужно",
  "очень", "первый", "пока", "после", "потом", "почему", "привет", "просто", "работа", "руку",
  "самый", "себя", "сегодня", "сейчас", "сказать", "слово", "снова", "спасибо", "тебя", "текст",
  "теперь", "тогда", "только", "тоже", "уже", "хорошо", "хотеть", "человек", "через", "чтобы",
  "этот",
]

private func requireCoreReplacement(
  _ candidate: Replacement?, original: String, replacement: String,
  target: Layout = .russian, _ name: String
) throws {
  // Compare scalars so Swift canonical equivalence cannot hide normalization.
  try requireTest(
    candidate.map { Array($0.original.unicodeScalars) } == Array(original.unicodeScalars),
    name + ": original"
  )
  try requireTest(
    candidate.map { Array($0.replacement.unicodeScalars) } == Array(replacement.unicodeScalars),
    name + ": replacement"
  )
  try requireTest(candidate?.target == target, name + ": target")
}

private func typedCoreText(_ text: String) -> Tracker {
  var tracker = Tracker()
  tracker.observe(text, source: .english, focus: 1)
  return tracker
}

private func testOppositeLayoutIsInvolutive() throws {
  try requireTest(Layout.english.rawValue == 1 && Layout.russian.rawValue == 2, "layout raw values")
  try requireTest(Layout.english.opposite == .russian, "English opposite")
  try requireTest(Layout.russian.opposite == .english, "Russian opposite")
  for layout in [Layout.english, .russian] {
    try requireTest(layout.opposite.opposite == layout, "opposite is involutive")
  }
}

private func testConvertsWordsInBothDirectionsPreservingCase() throws {
  for (english, russian) in [
    ("ghbdtn", "привет"), ("Ghbdtn", "Привет"), ("GHBDTN", "ПРИВЕТ"),
    ("gHbDtN", "пРиВеТ"), ("hello", "руддщ"), ("Hello", "Руддщ"),
    ("HELLO", "РУДДЩ"), ("\\krf", "ёлка"), ("|KRF", "ЁЛКА"),
  ] {
    try requireTest(convertWord(english, source: .english) == russian, "convert English case")
    try requireTest(convertWord(russian, source: .russian) == english, "convert Russian case")
  }
}

private func testConvertsEveryPunctuationLetterKeyWithShift() throws {
  for (english, russian) in [("\\[];',.", "ёхъжэбю"), ("|{}:\"<>", "ЁХЪЖЭБЮ")] {
    try requireTest(convertWord(english, source: .english) == russian, "punctuation to Russian")
    try requireTest(convertWord(russian, source: .russian) == english, "punctuation to English")
  }
}

private func testMatchesCompleteKeyboardRows() throws {
  for (english, russian) in [
    ("qwertyuiop[]", "йцукенгшщзхъ"), ("asdfghjkl;'", "фывапролджэ"),
    ("zxcvbnm,.", "ячсмитьбю"), ("QWERTYUIOP{}", "ЙЦУКЕНГШЩЗХЪ"),
    ("ASDFGHJKL:\"", "ФЫВАПРОЛДЖЭ"), ("ZXCVBNM<>", "ЯЧСМИТЬБЮ"),
  ] {
    try requireTest(convertWord(english, source: .english) == russian, "English keyboard row")
    try requireTest(convertWord(russian, source: .russian) == english, "Russian keyboard row")
  }
}

private func testEveryTableScalarRoundtripsWithoutDuplicateKeys() throws {
  for (layout, keys) in [
    (Layout.english, englishKeyboardFixture), (.russian, russianKeyboardFixture),
  ] {
    try requireTest(keys.unicodeScalars.count == 66, "keyboard has 66 scalars")
    for scalar in keys.unicodeScalars {
      try requireTest(
        keys.unicodeScalars.filter { $0 == scalar }.count == 1, "keyboard key is unique"
      )
      let original = String(scalar)
      let converted = convertWord(original, source: layout)
      try requireTest(converted != nil, "every key converts")
      if let converted = converted {
        try requireTest(
          convertWord(converted, source: layout.opposite) == original, "key roundtrip"
        )
      }
    }
  }
}

private func testRejectsEmptyForeignMixedAndUnmappedInputWithoutNormalizing() throws {
  for word in [
    "", " ", " ghbdtn", "ghbdtn ", "hello\n", "a\tb", "hello-world", "hello_world",
    "1234", "hello1", "hello/", "hello?", "hello!", "hello@", "hello`", "hello~",
    "приветa", "helloя", "приветHello", "café", "і", "ї", "є", "ґ", "α", "🙂",
    "a\0", "е\u{308}",
  ] {
    for source in [Layout.english, .russian] {
      try requireTest(convertWord(word, source: source) == nil, "reject unmapped word")
    }
  }
  try requireTest(convertWord("привет", source: .english) == nil, "wrong English source")
  try requireTest(convertWord("hello", source: .russian) == nil, "wrong Russian source")
}

private func testLimitsUnicodeScalarsNotBytes() throws {
  for (source, original, expected) in [
    (Layout.english, "f", "а"), (.russian, "я", "z"), (.english, "|", "Ё"),
  ] {
    try requireTest(
      convertWord(String(repeating: original, count: 64), source: source)
        == String(repeating: expected, count: 64), "64 scalars convert"
    )
    try requireTest(
      convertWord(String(repeating: original, count: 65), source: source) == nil,
      "65 scalars reject"
    )
  }
  try requireTest(
    convertWord(String(repeating: "f", count: 100_000), source: .english) == nil,
    "large conversion rejects"
  )
}

private func testSupportedLettersAreExactlyASCIIAndRussianLetters() throws {
  for value: UInt32 in 0...127 {
    if let scalar = Unicode.Scalar(value) {
      let expected = (0x41...0x5A).contains(value) || (0x61...0x7A).contains(value)
      try requireTest(isSupportedLetter(scalar) == expected, "ASCII letter classification")
    } else {
      try requireTest(false, "ASCII scalar construction")
    }
  }
  for scalar in russianKeyboardFixture.unicodeScalars {
    try requireTest(isSupportedLetter(scalar), "Russian letter classification")
  }
  for scalar in "ієїґІЇЄҐαéÉ🙂１２３\u{0308}\u{200d}".unicodeScalars {
    try requireTest(!isSupportedLetter(scalar), "unsupported letter classification")
  }
}

private func testCorrectsObviousWordsInBothDirectionsWithCase() throws {
  for (original, source, expected) in [
    ("ghbdtn", Layout.english, "привет"), ("Ghbdtn", .english, "Привет"),
    ("GHBDTN", .english, "ПРИВЕТ"), ("руддщ", .russian, "hello"),
    ("Руддщ", .russian, "Hello"), ("РУДДЩ", .russian, "HELLO"),
    ("gjrf", .english, "пока"), ("цщкдв", .russian, "world"),
  ] {
    try requireTest(automaticCorrection(original, source: source) == expected, "obvious correction")
  }
}

private func testLeavesAllKnownSourceWordsUnchangedInAnyCase() throws {
  for (source, words, oppositeWords) in [
    (Layout.english, knownEnglishFixture, knownRussianFixture),
    (.russian, knownRussianFixture, knownEnglishFixture),
  ] {
    for word in words {
      try requireTest(automaticCorrection(word, source: source) == nil, "known source unchanged")
      try requireTest(
        automaticCorrection(word.uppercased(), source: source) == nil,
        "uppercase known source unchanged"
      )
      // Also check target membership: omitting a dictionary entry must fail.
      if word.unicodeScalars.count >= 4,
        let mistyped = convertWord(word, source: source),
        mistyped.unicodeScalars.allSatisfy(isSupportedLetter),
        !oppositeWords.contains(mistyped.lowercased())
      {
        try requireTest(
          automaticCorrection(mistyped, source: source.opposite) == word,
          "known target recognized"
        )
      }
    }
  }
  try requireTest(
    automaticCorrection("Hello", source: .english) == nil, "titlecase English unchanged")
  try requireTest(
    automaticCorrection("Привет", source: .russian) == nil, "titlecase Russian unchanged")
}

private func testPreservesAmbiguousWordsValidInBothLanguages() throws {
  try requireTest(convertWord("here", source: .english) == "руку", "ambiguous physical conversion")
  for word in ["here", "Here", "HERE"] {
    try requireTest(knownEnglishFixture.contains(word.lowercased()), "ambiguous English is known")
    try requireTest(
      automaticCorrection(word, source: .english) == nil, "ambiguous English unchanged")
  }
  for word in ["руку", "Руку", "РУКУ"] {
    try requireTest(knownRussianFixture.contains(word.lowercased()), "ambiguous Russian is known")
    try requireTest(
      automaticCorrection(word, source: .russian) == nil, "ambiguous Russian unchanged")
  }
}

private func testSkipsShortWordsEvenWhenConvertedWordIsKnown() throws {
  for (word, source, target) in [
    ("rfr", Layout.english, "как"), ("еру", .russian, "the"), ("ytn", .english, "нет"),
  ] {
    let targetWords = source == .english ? knownRussianFixture : knownEnglishFixture
    try requireTest(targetWords.contains(target), "short target is known")
    try requireTest(convertWord(word, source: source) == target, "short manual conversion")
    try requireTest(automaticCorrection(word, source: source) == nil, "short automatic rejects")
  }
  for word in ["", "f", "ab", "abc"] {
    try requireTest(automaticCorrection(word, source: .english) == nil, "short input rejects")
  }
}

private func testSkipsUnknownTargetsAndIncorrectSourceLayouts() throws {
  for (word, source) in [
    ("zzzz", Layout.english), ("ъъъъ", .russian), ("qwerty", .english),
    ("asdfgh", .english), ("привет", .english), ("hello", .russian),
  ] {
    try requireTest(automaticCorrection(word, source: source) == nil, "unknown or incorrect source")
  }
}

private func testSkipsIdentifiersAddressesURLsPathsAndSeparatedWords() throws {
  for word in [
    "ghbdtn_id", "ghbdtn2", "2ghbdtn", "hello_world", "getValue", "camelCase",
    "ghbdtn@example.com", "руддщ@example.test", "https://ghbdtn.test", "www.ghbdtn.test",
    "/tmp/ghbdtn", "C:\\ghbdtn", "ghbdtn-hello", "ghbdtn hello", " ghbdtn", "ghbdtn ",
    "ghbdtn\n", "ghbdtn\t", "ghbdtn!", "ghbdtn🙂", "ghbdtn\0",
  ] {
    for source in [Layout.english, .russian] {
      try requireTest(automaticCorrection(word, source: source) == nil, "non-word rejects")
    }
  }
}

private func testSkipsPunctuationLetterKeysEvenIfManualConversionIsKnown() throws {
  for (word, expected) in [("cgfcb,j", "спасибо"), ("[jhjij", "хорошо")] {
    try requireTest(knownRussianFixture.contains(expected), "punctuation target is known")
    try requireTest(convertWord(word, source: .english) == expected, "manual punctuation converts")
    try requireTest(
      automaticCorrection(word, source: .english) == nil, "automatic punctuation rejects")
  }
}

private func testRejectsMixedAlphabetsUnsupportedUnicodeAndExcessiveLength() throws {
  for word in ["ghbdtн", "руddщ", "ghbdté", "руддї", "ghbdtn\u{0301}", "ｈｅｌｌｏ"] {
    for source in [Layout.english, .russian] {
      try requireTest(automaticCorrection(word, source: source) == nil, "mixed Unicode rejects")
    }
  }
  for (word, source) in [
    (String(repeating: "f", count: 64), Layout.english),
    (String(repeating: "f", count: 65), .english),
    (String(repeating: "я", count: 65), .russian),
    (String(repeating: "f", count: 100_000), .english),
  ] {
    try requireTest(
      automaticCorrection(word, source: source) == nil, "unknown or oversized rejects")
  }
}

private func testSuccessfulCorrectionsDoNotTriggerReverseCorrection() throws {
  for (word, source) in [("ghbdtn", Layout.english), ("руддщ", .russian)] {
    let corrected = automaticCorrection(word, source: source)
    try requireTest(corrected != nil, "initial automatic correction")
    if let corrected = corrected {
      try requireTest(
        automaticCorrection(corrected, source: source.opposite) == nil, "no reverse correction"
      )
    }
  }
}

private func testManualDoesNotRequireSeparator() throws {
  try requireCoreReplacement(
    typedCoreText("ghbdtn").candidate(automatic: false),
    original: "ghbdtn", replacement: "привет", "manual without separator"
  )
  try requireTest(
    typedCoreText("ghbdtn").candidate(automatic: true) == nil, "automatic needs separator"
  )
}

private func testAutomaticHandlesWordSeparatorsWithoutChangingThem() throws {
  for separator in [
    " ", "\t", "\n", "\r", ",", ".", "!", "?", ":", ";", "—", "…", ")", "\u{00a0}", "🙂",
    // Apple marks some private-use scalars Alphabetic; Rust does not.
    "\u{F882}", "\u{F89A}", "\u{F8D6}", "\u{F0000}", "\u{100000}",
  ] {
    try requireCoreReplacement(
      typedCoreText("ghbdtn" + separator).candidate(automatic: true),
      original: "ghbdtn" + separator, replacement: "привет" + separator,
      "automatic preserves separator"
    )
  }
}

private func testActionBoundaryCorrectsBeforeInsertingEnterOrTab() throws {
  for (text, source, expected) in [
    ("ghbdtn", Layout.english, "привет"), ("Ghbdtn", .english, "Привет"),
    ("GHBDTN", .english, "ПРИВЕТ"), ("руддщ", .russian, "hello"),
  ] {
    var tracker = Tracker()
    tracker.observe(text, source: source, focus: 1)
    try requireTest(tracker.candidate(automatic: true) == nil, "action not yet inserted")
    try requireCoreReplacement(
      tracker.candidateBeforeAction(), original: text, replacement: expected,
      target: source.opposite, "action candidate excludes new Enter and Tab"
    )
  }
}

private func testActionBoundaryKeepsDetectionAndExistingSuffixRules() throws {
  for text in ["", "hello", "zzzzzz", "ghbdtn_", "ghbdtn1", "ghbdtnЖ"] {
    try requireTest(typedCoreText(text).candidateBeforeAction() == nil, "action detection rejects")
  }
  try requireCoreReplacement(
    typedCoreText("ghbdtn, ").candidateBeforeAction(),
    original: "ghbdtn, ", replacement: "привет, ", "action preserves existing suffix"
  )
  var tracker = typedCoreText("ghbdtn")
  tracker.clear()
  try requireTest(tracker.candidateBeforeAction() == nil, "clear invalidates action candidate")
}

private func testOnlyLatestWordIsRetained() throws {
  try requireCoreReplacement(
    typedCoreText("hello ghbdtn, ").candidate(automatic: false),
    original: "ghbdtn, ", replacement: "привет, ", "only latest word retained"
  )
  try requireTest(
    typedCoreText("ghbdtn next").candidate(automatic: true) == nil, "old candidate forgotten"
  )
}

private func testBackspaceUpdatesOnlyKnownText() throws {
  var tracker = typedCoreText("ghbdtn, ")
  tracker.backspace()
  tracker.backspace()
  try requireTest(tracker.candidate(automatic: true) == nil, "backspace removed separators")
  try requireCoreReplacement(
    tracker.candidate(automatic: false), original: "ghbdtn", replacement: "привет",
    "backspace leaves known word"
  )
  tracker.backspace()
  try requireCoreReplacement(
    tracker.candidate(automatic: false), original: "ghbdt", replacement: "приве",
    "backspace removes one letter"
  )
  // CRLF is one Swift Character but two Rust chars / Unicode scalars.
  tracker = typedCoreText("ghbdtn\r\n")
  tracker.backspace()
  try requireCoreReplacement(
    tracker.candidate(automatic: true), original: "ghbdtn\r", replacement: "привет\r",
    "backspace removes only LF"
  )
  tracker.backspace()
  try requireTest(tracker.candidate(automatic: true) == nil, "backspace then removes CR")
  tracker = typedCoreText("ghbdtn🇷🇺")
  tracker.backspace()
  try requireCoreReplacement(
    tracker.candidate(automatic: true), original: "ghbdtn🇷", replacement: "привет🇷",
    "backspace removes one regional-indicator scalar"
  )
  tracker = Tracker()
  tracker.backspace()
  try requireTest(tracker.candidate(automatic: false) == nil, "backspace on empty tracker")
}

private func testIdentifiersAndMixedInputAreNotCandidates() throws {
  for text in [
    "ghbdtn@", "ghbdtn/", "ghbdtn_", "ghbdtn1 ", "ghbdtné ", "ghbdtn=", "ghbdtnЖ ",
    "ghbdtn\\", "ghbdtn²", "ghbdtnⅧ", "ghbdtn١", "ghbdtn\0", "ghbdtn\u{7f}",
  ] {
    try requireTest(typedCoreText(text).candidate(automatic: false) == nil, "unsafe input rejects")
  }
  try requireCoreReplacement(
    typedCoreText("bad_url ghbdtn ").candidate(automatic: true),
    original: "ghbdtn ", replacement: "привет ", "whitespace ends blocked identifier"
  )
  for separator in [" ", "\t", "\n", "\r", "\u{85}", "\u{a0}", "\u{1680}", "\u{2003}", "\u{2028}"] {
    try requireCoreReplacement(
      typedCoreText("bad_url" + separator + "ghbdtn ").candidate(automatic: true),
      original: "ghbdtn ", replacement: "привет ", "Unicode whitespace clears blocked state"
    )
  }
  try requireTest(
    typedCoreText("bad_url.ghbdtn ").candidate(automatic: true) == nil,
    "punctuation does not end blocked identifier"
  )
}

private func testCompositionAndFormatMarksDoNotTriggerCorrection() throws {
  // Original regressions plus every boundary in the explicit Rust ranges.
  let marks: [UInt32] = [
    0x0301, 0x200D, 0x202E, 0xFE0F, 0xE0100,
    0x0300, 0x036F, 0x0483, 0x0489, 0x1AB0, 0x1AFF, 0x1DC0, 0x1DFF,
    0x200B, 0x200F, 0x202A, 0x2060, 0x206F, 0x20D0, 0x20FF,
    0xFE00, 0xFE20, 0xFE2F, 0xFEFF, 0xE01EF,
  ]
  for value in marks {
    if let scalar = Unicode.Scalar(value) {
      let text = "ghbdtn" + String(scalar)
      try requireTest(
        typedCoreText(text + " ").candidate(automatic: true) == nil,
        "composition or format mark blocks automatic correction"
      )
      try requireTest(
        typedCoreText(text).candidate(automatic: false) == nil,
        "composition or format mark blocks manual conversion"
      )
    } else {
      try requireTest(false, "format fixture scalar construction")
    }
  }
}

private func testContextAndLayoutChangesDiscardPreviousWord() throws {
  var tracker = typedCoreText("ghbdtn")
  tracker.observe("x", source: .english, focus: 2)
  try requireCoreReplacement(
    tracker.candidate(automatic: false), original: "x", replacement: "ч", "focus invalidates word"
  )
  tracker.observe("р", source: .russian, focus: 2)
  try requireCoreReplacement(
    tracker.candidate(automatic: false), original: "р", replacement: "h", target: .english,
    "layout invalidates word"
  )
  tracker.clear()
  try requireTest(tracker.candidate(automatic: false) == nil, "clear invalidates word")
  // Unknown prefixes must also be discarded after a genuine context change.
  tracker = typedCoreText("name_")
  tracker.observe("ghbdtn", source: .english, focus: 2)
  try requireCoreReplacement(
    tracker.candidateBeforeAction(), original: "ghbdtn", replacement: "привет",
    "focus invalidates blocked prefix"
  )
}

private func testOversizedInputIsNotTruncatedIntoCandidate() throws {
  var tracker = typedCoreText(String(repeating: "a", count: 65))
  try requireTest(tracker.candidate(automatic: false) == nil, "oversized word rejects")
  tracker.observe(" ghbdtn ", source: .english, focus: 1)
  try requireCoreReplacement(
    tracker.candidate(automatic: true), original: "ghbdtn ", replacement: "привет ",
    "whitespace recovers after oversized word"
  )
  try requireTest(
    typedCoreText("ghbdtn" + String(repeating: " ", count: 17))
      .candidate(automatic: false) == nil, "17 separators clear candidate"
  )
  for (source, original, expected) in [(Layout.english, "a", "ф"), (.russian, "я", "z")] {
    var bounded = Tracker()
    let word = String(repeating: original, count: 64)
    bounded.observe(word, source: source, focus: 1)
    try requireCoreReplacement(
      bounded.candidate(automatic: false), original: word,
      replacement: String(repeating: expected, count: 64), target: source.opposite,
      "exact 64-scalar tracker limit"
    )
    bounded.observe(original, source: source, focus: 1)
    try requireTest(bounded.candidate(automatic: false) == nil, "65th scalar blocks tracker")
  }
  // Eight flags have sixteen scalars, not eight Characters.
  let suffix = String(repeating: "🇷🇺", count: 8)
  try requireCoreReplacement(
    typedCoreText("ghbdtn" + suffix).candidate(automatic: true),
    original: "ghbdtn" + suffix, replacement: "привет" + suffix,
    "exact 16-scalar suffix limit"
  )
  try requireTest(
    typedCoreText("ghbdtn" + suffix + "!").candidate(automatic: false) == nil,
    "17th suffix scalar clears tracker"
  )
  tracker = typedCoreText("ghbdtn" + String(repeating: " ", count: 17) + "ghbdtn ")
  try requireTest(
    tracker.candidate(automatic: false) == nil, "suffix overflow stops the current observation"
  )
  tracker.observe("ghbdtn ", source: .english, focus: 1)
  try requireCoreReplacement(
    tracker.candidate(automatic: true), original: "ghbdtn ", replacement: "привет ",
    "next observation recovers after suffix overflow"
  )
}

private func testUnknownPrefixAfterBackspaceRemainsBlocked() throws {
  var tracker = typedCoreText("name_")
  tracker.backspace()
  tracker.observe("ghbdtn", source: .english, focus: 1)
  try requireTest(tracker.candidate(automatic: false) == nil, "unknown prefix survives backspace")
  for _ in 0..<10 { tracker.backspace() }
  tracker.observe("ghbdtn", source: .english, focus: 1)
  try requireTest(tracker.candidateBeforeAction() == nil, "repeated backspace cannot infer prefix")
  tracker.observe(" ghbdtn", source: .english, focus: 1)
  try requireCoreReplacement(
    tracker.candidateBeforeAction(), original: "ghbdtn", replacement: "привет",
    "whitespace ends unknown prefix after backspace"
  )
}
