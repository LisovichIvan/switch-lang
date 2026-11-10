// Deliberately limited, hand-written lists, not a comprehensive dictionary.
// Unknown words remain unchanged; manual conversion does not use these lists.
private let commonEnglishWords = [
  "about", "after", "again", "before", "better", "could", "first", "friend", "from", "good",
  "hello", "help", "here", "home", "house", "just", "know", "like", "little", "look", "make",
  "many", "more", "morning", "much", "name", "need", "never", "next", "nice", "night", "only",
  "other", "please", "really", "right", "same", "should", "some", "sorry", "take", "test",
  "text", "thank", "thanks", "that", "the", "their", "them", "then", "there", "these", "they",
  "thing", "think", "this", "time", "today", "very", "want", "well", "what", "when", "where",
  "which", "will", "with", "word", "work", "world", "would", "your",
]
private let commonRussianWords = [
  "было", "будет", "время", "всего", "всегда", "говорить", "даже", "делать", "день", "добрый",
  "друг", "если", "есть", "ещё", "здесь", "знать", "каждый", "как", "когда", "конечно",
  "люди", "меня", "может", "можно", "надо", "наше", "него", "нет", "новый", "нужно",
  "очень", "первый", "пока", "после", "потом", "почему", "привет", "просто", "работа", "руку",
  "самый", "себя", "сегодня", "сейчас", "сказать", "слово", "снова", "спасибо", "тебя", "текст",
  "теперь", "тогда", "только", "тоже", "уже", "хорошо", "хотеть", "человек", "через", "чтобы",
  "этот",
]

// Suggest only 4–64-letter words unknown in the source list and known after
// conversion. Digits, punctuation, mixed alphabets and foreign Unicode reject.
func automaticCorrection(_ word: String, source: Layout) -> String? {
  var scalarCount = 0
  for scalar in word.unicodeScalars {
    guard scalarCount < 64, isSupportedLetter(scalar) else { return nil }
    scalarCount += 1
  }
  guard scalarCount >= 4, !isCommonWord(word, layout: source),
    let converted = convertWord(word, source: source),
    isCommonWord(converted, layout: source.opposite)
  else {
    return nil
  }
  return converted
}

private func isCommonWord(_ word: String, layout: Layout) -> Bool {
  let words = layout == .english ? commonEnglishWords : commonRussianWords
  return words.contains(word.lowercased())
}
