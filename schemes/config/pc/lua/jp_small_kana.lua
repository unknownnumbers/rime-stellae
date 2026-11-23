-- xX 正文碼 -> 小假名。呼叫端只讀使用；此表不含控制前綴或學習狀態。
-- 大小寫有別：lowercase 只查小平假名，UPPERCASE 只查小片假名。
-- 共 52 個碼、51 種輸出（50 個獨立字元，另有 PU 結合序列）。最長碼為 3 bytes。
return {
  -- 保留原有 x... / X... 的 12 組正文碼。
  a = 'ぁ', A = 'ァ',
  i = 'ぃ', I = 'ィ',
  u = 'ぅ', U = 'ゥ',
  e = 'ぇ', E = 'ェ',
  o = 'ぉ', O = 'ォ',
  ka = 'ゕ', KA = 'ヵ',
  ke = 'ゖ', KE = 'ヶ',
  tsu = 'っ', TSU = 'ッ',
  ya = 'ゃ', YA = 'ャ',
  yu = 'ゅ', YU = 'ュ',
  yo = 'ょ', YO = 'ョ',
  wa = 'ゎ', WA = 'ヮ',

  -- Katakana Phonetic Extensions U+31F0–U+31FF。
  KU = 'ㇰ', SHI = 'ㇱ', SU = 'ㇲ', TO = 'ㇳ', NU = 'ㇴ',
  HA = 'ㇵ', HI = 'ㇶ', FU = 'ㇷ', HE = 'ㇸ', HO = 'ㇹ',
  MU = 'ㇺ', RA = 'ㇻ', RI = 'ㇼ', RU = 'ㇽ', RE = 'ㇾ', RO = 'ㇿ',

  -- Small Kana Extension；Lua Unicode escape 保留完整補充平面字元。
  ko = '\u{1B132}',
  wi = '\u{1B150}', we = '\u{1B151}', wo = '\u{1B152}',
  KO = '\u{1B155}',
  WI = '\u{1B164}', WE = '\u{1B165}', WO = '\u{1B166}',
  N = '\u{1B167}', NN = '\u{1B167}', YE = '\u{1B168}',

  -- 一項候選、兩個碼點：KATAKANA LETTER SMALL HU + COMBINING SEMI-VOICED SOUND MARK。
  PU = '\u{31F7}\u{309A}',
}
