"""Pinned phrase-aware syllable readings and dictionary-based text conversion.

SPDX-License-Identifier: GPL-3.0-only
"""
from pathlib import Path
import re
import sys
import unicodedata
import zipfile


class MaxMatchConverter:
    def __init__(self, files):
        self.trie = {}
        for path in files:
            for row in Path(path).read_text('utf-8-sig').splitlines():
                if not row or row.startswith('#'):
                    continue
                source, targets = row.split('\t', 1)
                branch = self.trie
                for char in source:
                    branch = branch.setdefault(char, {})
                branch[''] = targets.split(' ')[0]

    def convert(self, text):
        output, start = [], 0
        while start < len(text):
            branch = self.trie
            end, replacement = start + 1, text[start]
            for index in range(start, len(text)):
                branch = branch.get(text[index])
                if branch is None:
                    break
                if '' in branch:
                    end, replacement = index + 1, branch['']
            output.append(replacement)
            start = end
        return ''.join(output)


# These lexical/context readings affect syllable spelling, rather than tone.
# The complete public corpus is selected independently of these reading rules.
PHRASE_READINGS = {
    '朝辞白帝': 'zhao ci bai di', '渭城朝雨': 'wei cheng zhao yu', '朝如青丝': 'zhao ru qing si',
    '不亦说乎': 'bu yi yue hu', '风吹草低见牛羊': 'feng chui cao di xian niu yang',
    '扁舟': 'pian zhou', '单于': 'chan yu', '参差': 'cen ci',
    '霓裳': 'ni chang', '将进酒': 'qiang jin jiu',
    '乐府': 'yue fu', '礼乐': 'li yue', '弹琴': 'tan qin',
    '弹琵琶': 'tan pi pa', '弹箜篌': 'tan kong hou',
    '回乐烽': 'hui le feng', '燕然': 'yan ran', '燕山': 'yan shan',
    '燕支': 'yan zhi', '长歌': 'chang ge', '长安': 'chang an',
    '长相思': 'chang xiang si', '重阳': 'chong yang', '重九': 'chong jiu',
    '重重': 'chong chong', '欸乃': 'ai nai', '塞上': 'sai shang',
    '塞下': 'sai xia', '塞外': 'sai wai', '似的': 'shi de',
}


class Readings:
    def __init__(self, vendor_root, opencc_root, syllables):
        sys.path.insert(0, str(Path(vendor_root).resolve()))
        import pypinyin
        if pypinyin.__version__ != '0.55.0':
            raise ValueError('Unexpected pinned pinyin implementation')
        pypinyin.load_phrases_dict({word: [[p] for p in code.split()]
                                   for word, code in PHRASE_READINGS.items()})
        self.pypinyin = pypinyin
        root = Path(opencc_root)
        self.to_sc = MaxMatchConverter([root / 'TSCharacters.txt', root / 'TSPhrases.txt'])
        self.to_tc = MaxMatchConverter([root / 'STCharacters.txt', root / 'STPhrases.txt'])
        self.syllables = syllables
        self.unihan = {}
        unihan = root.parent / 'Unihan-17.0.0.zip'
        if unihan.exists():
            fields = {}
            with zipfile.ZipFile(unihan) as archive:
                for row in archive.read('Unihan_Readings.txt').decode('utf-8').splitlines():
                    if not row or row.startswith('#'):
                        continue
                    point, field, value = row.split('\t', 2)
                    if field not in ('kMandarin', 'kHanyuPinlu', 'kHanyuPinyin', 'kXHC1983'):
                        continue
                    fields.setdefault(int(point[2:], 16), {})[field] = value
            for point, values in fields.items():
                for field in ('kMandarin', 'kHanyuPinlu', 'kXHC1983', 'kHanyuPinyin'):
                    raw = values.get(field)
                    if not raw:
                        continue
                    if field in ('kHanyuPinyin', 'kXHC1983'):
                        raw = raw.split()[0].split(':', 1)[-1]
                    tokens = re.split(r'[ ,()]', raw)
                    supported = [self.normalize(value) for value in tokens if value]
                    supported = [value for value in supported if value in syllables]
                    if supported:
                        self.unihan[chr(point)] = supported[0]
                        break

    @staticmethod
    def normalize(value):
        value = unicodedata.normalize('NFD', value.lower()).replace('u\u0308', 'v').replace('u:', 'v')
        value = ''.join(char for char in unicodedata.normalize('NFD', value)
                        if not unicodedata.combining(char))
        return re.sub('[1-5]$', '', value)

    def read(self, text, source_sc=False, poetry=True):
        original = text
        if source_sc:
            text = self.to_tc.convert(text)
        reading_text = self.to_sc.convert(text)
        code = self.pypinyin.lazy_pinyin(reading_text, errors=lambda chars: list(chars),
                                         style=self.pypinyin.Style.NORMAL,
                                         strict=False, v_to_u=False)
        # Clause-final literary 還 is the return verb. Existing dictionary
        # phrases such as 往還 and 生還 already have this same reading.
        final_return = poetry and reading_text.endswith('还') and len(code) == len(text) and code[-1] == 'hai'
        if final_return:
            code[-1] = 'huan'
        normalized = []
        original_fallbacks = unicode_fallbacks = 0
        for char, item in zip(text, code):
            value = self.normalize(item)
            if not re.fullmatch('[a-z]+', value) or value not in self.syllables:
                # Conversion can map an attested source glyph to a newer SC
                # character absent from the phrase library. Consult the
                # original glyph before using the fixed Unicode readings.
                original_code = self.pypinyin.lazy_pinyin(char, errors=lambda chars: list(chars),
                                                          style=self.pypinyin.Style.NORMAL,
                                                          strict=False, v_to_u=False)
                fallback = self.normalize(original_code[0]) if len(original_code) == 1 else ''
                if fallback in self.syllables:
                    value = fallback
                    original_fallbacks += 1
                elif char in self.unihan:
                    value = self.unihan[char]
                    unicode_fallbacks += 1
                else:
                    return None, {'Reason': 'UnsupportedReading', 'Character': char, 'Reading': item}
            normalized.append(value)
        if len(code) != len(text):
            return None, {'Reason': 'ReadingCharacterAlignment'}
        return (text, ' '.join(normalized)), {'NormalizedText': text != original, 'FinalReturnRule': final_return,
                                             'OriginalCharacterFallbacks': original_fallbacks,
                                             'UnicodeCharacterFallbacks': unicode_fallbacks}
