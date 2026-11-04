// Gemini's interactive renderer segments text using ICU break-iterator data.
// Constructing Intl.Segmenter alone did not expose the missing-data crash.
const assert = require('node:assert/strict');

for (let invocation = 0; invocation < 3; invocation++) {
  const graphemes = new Intl.Segmenter('pl', {granularity: 'grapheme'});
  const text = 'A\u0301\u{1f1f5}\u{1f1f1}\u{1f469}\u200d\u{1f4bb}';
  const segments = [...graphemes.segment(text)];
  assert.deepEqual(segments.map(item => item.segment), [
    'A\u0301', '\u{1f1f5}\u{1f1f1}', '\u{1f469}\u200d\u{1f4bb}'
  ]);
  assert.equal(graphemes.segment(text).containing(1).segment, 'A\u0301');

  const words = new Intl.Segmenter('en', {granularity: 'word'});
  assert.deepEqual([...words.segment('Hello world!')]
    .filter(item => item.isWordLike).map(item => item.segment), ['Hello', 'world']);
  const sentences = new Intl.Segmenter('en', {granularity: 'sentence'});
  assert.equal([...sentences.segment('One. Two!')].length, 2);
}
console.log('PASS Intl.Segmenter graphemes, emoji, words, sentences and repeated use');
