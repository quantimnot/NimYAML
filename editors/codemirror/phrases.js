// The words yamllsp.js shows, in the languages <code-editor> speaks.
//
// CodeMirror asks for every word it shows through EditorState.phrase, keyed by
// the English phrase, and an editor's phrases come from every
// EditorState.phrases in its configuration. <code-editor> fills that facet
// from its own catalogs, which hold CodeMirror's words and lsp-client's; the
// path panel's words are this module's, so they are translated here and added
// beside the editor's by yamlLanguageServer, which picks the table of the
// page's locale with phrasesFor.
//
// The languages are the component's: English, French, Arabic, Simplified
// Chinese, Japanese and Hindi. A locale outside them gets English, which is
// what an untranslated phrase shows anyway.
//
// Rejected: these words in the component's catalogs, which would make a
// general editor carry one language server's vocabulary; messages.json files
// read at runtime, which would make the plugin fetch before it can draw a
// panel.

export const PHRASES = {
  fr: {
    "Path format": "Format du chemin",
    "JSON Pointer": "Pointeur JSON",
    "JSON Path": "Chemin JSON",
    "URL Fragment": "Fragment d’URL",
    "Absolute URL Fragment": "Fragment d’URL absolue",
    "Click to copy": "Cliquer pour copier",
    "(root)": "(racine)",
  },
  ar: {
    "Path format": "صيغة المسار",
    "JSON Pointer": "مؤشر JSON",
    "JSON Path": "مسار JSON",
    "URL Fragment": "جزء عنوان URL",
    "Absolute URL Fragment": "جزء عنوان URL مطلق",
    "Click to copy": "انقر للنسخ",
    "(root)": "(الجذر)",
  },
  "zh-Hans": {
    "Path format": "路径格式",
    "JSON Pointer": "JSON 指针",
    "JSON Path": "JSON 路径",
    "URL Fragment": "URL 片段",
    "Absolute URL Fragment": "绝对 URL 片段",
    "Click to copy": "点击复制",
    "(root)": "（根）",
  },
  ja: {
    "Path format": "パスの形式",
    "JSON Pointer": "JSON ポインター",
    "JSON Path": "JSON パス",
    "URL Fragment": "URL フラグメント",
    "Absolute URL Fragment": "絶対 URL フラグメント",
    "Click to copy": "クリックしてコピー",
    "(root)": "（ルート）",
  },
  hi: {
    "Path format": "पाथ का प्रारूप",
    "JSON Pointer": "JSON पॉइंटर",
    "JSON Path": "JSON पाथ",
    "URL Fragment": "URL फ़्रैगमेंट",
    "Absolute URL Fragment": "निरपेक्ष URL फ़्रैगमेंट",
    "Click to copy": "कॉपी करने के लिए क्लिक करें",
    "(root)": "(रूट)",
  },
};

// Chinese written in simplified characters, however the locale says so.
const SIMPLIFIED = /^zh(-(hans|cn|sg|my))?(-|$)/i;

/**
 * The phrases of the first of `locales` (a BCP 47 tag or a list of them, best
 * first) that has a table, each tried in full and then shortened tag by tag
 * (fr-CA → fr); {} for English or none of them.
 */
export function phrasesFor(locales) {
  for (const locale of [locales ?? []].flat()) {
    if (SIMPLIFIED.test(locale) && !/-hant/i.test(locale)) return PHRASES["zh-Hans"];
    const parts = locale.split("-");
    for (let n = parts.length; n > 0; n--) {
      const tag = parts.slice(0, n).join("-");
      if (/^en$/i.test(tag)) return {};
      const table = Object.keys(PHRASES).find((key) => key.toLowerCase() === tag.toLowerCase());
      if (table) return PHRASES[table];
    }
  }
  return {};
}
