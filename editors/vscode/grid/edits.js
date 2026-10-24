// yamllsp answers a grid edit with the whole edited text (`nimyaml/gridEdit`
// in tools/yamllsp.nim), since that is what yaml/edit produces and what it
// verifies. Replacing the whole document with it, as a WorkspaceEdit easily
// could, would move the cursor and selections of every text editor showing
// the file and make an undo step of the entire text. The edit applied is
// therefore only the part that differs: the text between the longest common
// prefix and the longest common suffix.

/**
 * The single replacement that turns `before` into `after`, as UTF-16
 * offsets into `before` (what `TextDocument.positionAt` takes), or null if
 * they are equal. Its ends are never inside a surrogate pair or a CRLF.
 */
function minimalEdit(before, after) {
  if (before === after) return null;
  const limit = Math.min(before.length, after.length);
  let start = 0;
  while (start < limit && before.charCodeAt(start) === after.charCodeAt(start)) start++;
  let suffix = 0;
  while (
    suffix < limit - start &&
    before.charCodeAt(before.length - 1 - suffix) === after.charCodeAt(after.length - 1 - suffix)
  ) suffix++;
  // A boundary between the halves of a pair splits a character in two.
  const splits = (text, i) =>
    i > 0 && i < text.length &&
    ((isHigh(text.charCodeAt(i - 1)) && isLow(text.charCodeAt(i))) ||
     (text[i - 1] === "\r" && text[i] === "\n"));
  while (start > 0 && (splits(before, start) || splits(after, start))) start--;
  while (suffix > 0 && (splits(before, before.length - suffix) || splits(after, after.length - suffix))) suffix--;
  return {
    start,
    end: before.length - suffix,
    text: after.slice(start, after.length - suffix),
  };
}

const isHigh = (c) => c >= 0xd800 && c <= 0xdbff;
const isLow = (c) => c >= 0xdc00 && c <= 0xdfff;

module.exports = { minimalEdit };
