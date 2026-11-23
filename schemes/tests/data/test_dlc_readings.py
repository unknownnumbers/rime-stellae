"""Fixed syllable and cross-word-boundary checks for public text annotation.

SPDX-License-Identifier: GPL-3.0-only
"""
from pathlib import Path
import sys
import tempfile
import unittest
import zipfile

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / 'scripts'))
from data.dlc_readings import Readings


class ReadingChecks(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.temporary = tempfile.TemporaryDirectory()
        cls.vendor = Path(cls.temporary.name)
        source = ROOT / 'dlc/sources/readings'
        with zipfile.ZipFile(source / 'pypinyin-0.55.0-py2.py3-none-any.whl') as archive:
            archive.extractall(cls.vendor)
        syllables = set((ROOT / 'dlc/sources/allowed-syllables.txt').read_text('ascii').split())
        cls.reader = Readings(cls.vendor, source / 'opencc', syllables)

    @classmethod
    def tearDownClass(cls):
        cls.temporary.cleanup()

    def test_context_and_boundary_readings(self):
        cases = {
            '朝辭白帝彩雲間': 'zhao ci bai di cai yun jian',
            '渭城朝雨浥輕塵': 'wei cheng zhao yu yi qing chen',
            '朝如青絲暮成雪': 'zhao ru qing si mu cheng xue',
            '倉皇得郡免朝辭': 'cang huang de jun mian chao ci',
            '敢向聖朝辭寵祿': 'gan xiang sheng chao ci chong lu',
            '屈狄歸朝辭廟主': 'qu di gui chao ci miao zhu',
            '三朝雨露聖人心': 'san chao yu lu sheng ren xin',
            '兩朝雨露書中得': 'liang chao yu lu shu zhong de',
            '從古市朝如此耳': 'cong gu shi chao ru ci er',
            '風吹草低見牛羊': 'feng chui cao di xian niu yang',
            '隔牆見牛羊': 'ge qiang jian niu yang',
            '一日還應不可無': 'yi ri hai ying bu ke wu',
            '一日還應兩度知': 'yi ri hai ying liang du zhi',
            '等閑一日還過却': 'deng xian yi ri hai guo que',
            '千里江陵一日還': 'qian li jiang ling yi ri huan',
            '明月何時照我還': 'ming yue he shi zhao wo huan',
            '不亦說乎': 'bu yi yue hu',
            '床前明月光': 'chuang qian ming yue guang',
            '牀前看月光': 'chuang qian kan yue guang',
            '舉頭望明月': 'ju tou wang ming yue',
            '舉頭望山月': 'ju tou wang shan yue',
            '綠蟻新醅酒': 'lv yi xin pei jiu',
            '黎曼流形': 'li man liu xing',
        }
        for text, expected in cases.items():
            with self.subTest(text=text):
                result, flags = self.reader.read(text)
                self.assertIsNotNone(result, flags)
                self.assertEqual(result[0], text)
                self.assertEqual(result[1], expected)

    def test_sc_source_has_tc_output_and_aligned_reading(self):
        result, flags = self.reader.read('举头望明月', source_sc=True)
        self.assertEqual(result, ('舉頭望明月', 'ju tou wang ming yue'))
        self.assertTrue(flags['NormalizedText'])

    def test_unknown_characters_are_not_silently_removed(self):
        result, flags = self.reader.read('明月🙂')
        self.assertIsNone(result)
        self.assertIn(flags['Reason'], ('UnsupportedReading', 'ReadingCharacterAlignment'))

    def test_original_glyph_fallback_prevents_conversion_loss(self):
        for text, code in {'斸': 'zhu', '殢': 'ti', '竚': 'zhu', '爇': 'ruo', '艣': 'lu'}.items():
            with self.subTest(text=text):
                result, flags = self.reader.read(text)
                self.assertEqual(result, (text, code))
                self.assertGreater(flags['OriginalCharacterFallbacks'], 0)

    def test_fixed_unicode_source_supplies_missing_character_reading(self):
        result, flags = self.reader.read('\u37e5')
        self.assertEqual(result, ('\u37e5', 'cen'))
        self.assertGreater(flags['UnicodeCharacterFallbacks'], 0)

    def test_diaeresis_is_preserved_when_removing_tones(self):
        for text, expected in {'lǜ': 'lv', 'nǚ': 'nv', 'lü4': 'lv', 'lu:4': 'lv'}.items():
            with self.subTest(text=text):
                self.assertEqual(self.reader.normalize(text), expected)


if __name__ == '__main__':
    unittest.main()
