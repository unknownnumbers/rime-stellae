# SPDX-License-Identifier: GPL-3.0-only
from pathlib import Path
import sys
sys.path.insert(0, str(Path(__file__).resolve().parents[2] / 'scripts/data'))
"""Fixed public-text and editorial-notation cases; no personal input records."""
from poetry_cleaner import clean_poem, anthology_works


def texts(paragraphs, **kwargs):
    return {row['text'] for row in clean_poem(paragraphs, **kwargs)[0]}


assert texts(['待到秋來九月八，我花開後百花殺。']) == {'待到秋來九月八', '我花開後百花殺'}
assert texts(['（以上劉瑛整理）。']) == set()
assert texts(['詩句甲乙。', '（〖1〗這首詩雖不見舊集，', '整理說明。', '）。', '詩句丙丁。']) == {'詩句甲乙', '詩句丙丁'}
assert texts(['[爽]節在重九，物華新雨餘。']) == {'爽節在重九', '物華新雨餘'}
assert texts(['甲[𡵞]乙，正文丙丁。']) == {'甲𡵞乙', '正文丙丁'}
assert texts(['{虫攵}聲不可讀，子母長相隨。']) == {'子母長相隨'}
assert texts(['能持淨意作□家，解駕牛羊白鹿車。']) == {'解駕牛羊白鹿車'}
assert texts(['三危山內□（賢），正常詩句。']) == {'正常詩句'}
assert texts(['對、長亭晚，驟雨初歇。']) == {'對長亭晚', '驟雨初歇'}
assert texts(['春（一作秋）風花草香，白日依山盡。']) == {'春風花草香', '秋風花草香', '白日依山盡'}
assert texts(['正文甲乙（注中又有（內注）兩層），正文丙丁。']) == {'正文甲乙', '正文丙丁'}
assert texts(['正常詩句。未明（缺少右括號', '續注不應變成詩句。']) == {'正常詩句'}
assert texts(['仲宣一作從軍詠，迴顧儒衣自不平。']) == {'仲宣一作從軍詠', '迴顧儒衣自不平'}
assert texts(['仲宣一作從軍詠，迴顧儒衣自不平。'], bare_variant_policy='retain') == {'仲宣一作從軍詠', '迴顧儒衣自不平'}
assert texts(['天明又作人間別，洞口春深道路荒。']) == {'天明又作人間別', '洞口春深道路荒'}
assert texts(['或作山林遊，正常詩句。']) == {'或作山林遊', '正常詩句'}
assert texts(['又作凝香齋宿，正常詩句。']) == {'又作凝香齋宿', '正常詩句'}
assert texts(['詩題：原無題首句：按徹梁州更六幺一作蜀國佳人號細腰。']) == set()
assert texts(['一作：注釋異文內容。', '正常詩句。']) == {'正常詩句'}
assert texts(['原注：說明中的一作不應進詞表。', '正常詩句。']) == {'正常詩句'}
assert texts(['詩句甲乙[1]，詩句丙丁。']) == {'詩句甲乙', '詩句丙丁'}
grouped = {'author': 'Public fixture', 'chapter': 'Sequence', 'paragraphs': [
    {'subchapter': 'A', 'paragraphs': ['詩句甲乙。']}, {'subchapter': 'B', 'paragraphs': ['詩句丙丁。']}]}
leaves = list(anthology_works(grouped))
assert len(leaves) == 2 and all(row['author'] == 'Public fixture' for row in leaves)
assert {text for row in leaves for text in texts(row['paragraphs'])} == {'詩句甲乙', '詩句丙丁'}
print('23 fixed source-cleaning and grouped-source cases passed.')
