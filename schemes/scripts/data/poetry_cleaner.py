"""Conservative extraction of verse clauses from immutable public poem records.

SPDX-License-Identifier: GPL-3.0-only
"""
from collections import Counter
from itertools import product
import re

HAN = re.compile(r'^[\u3400-\u4dbf\u4e00-\u9fff\uf900-\ufaff\U00020000-\U000323af\u3007]$')
BARE_VARIANT = re.compile(r'一作|又作|或作|一云')
EDITORIAL_PREFIX = re.compile(r'^\s*(?:詩題|诗题|題名|题名|首句|原注|自注|校注|按語|按语|編按|编按|說明|说明|校勘|出處|出处|一作|又作|或作|一云)\s*[：:]')
ONE_VARIANT = re.compile(r'''^(?:一作|又作|或作|一云)[\s:：\u300c\u300e"']*([\u3400-\u4dbf\u4e00-\u9fff\uf900-\ufaff\U00020000-\U000323af\u3007])[\s\u300d\u300f"']*$''')
OPEN = {'(': 'round', '（': 'round', '[': 'square', '{': 'curly'}
CLOSE = {')': 'round', '）': 'round', ']': 'square', '}': 'curly'}
SEPARATORS = set('，。！？；：,.!?;:\n\r\t \u3000「」『』《》〈〉“”‘’"\'—–…')
UNKNOWN = '\x00'


def clean_poem(paragraphs, *, min_chars=2, bare_variant_policy='retain', max_variants=16):
    """Return clauses, numeric decisions and unresolved source locations.

    Parenthetical notes may span paragraph boundaries. Unknown components and
    missing-character markers invalidate their clause instead of joining the
    surviving fragments. Bare variant words receive review flags, not rewriting
    instructions. Structured editorial headers and
    known annotation containers are excluded independently of verse wording.
    """
    if bare_variant_policy not in ('quarantine', 'retain'):
        raise ValueError('Unknown bare variant policy')
    if not all(isinstance(paragraph, str) for paragraph in paragraphs):
        raise ValueError('Flatten source-defined poem groups before clause extraction')
    source = [(char, paragraph_index) for paragraph_index, paragraph in enumerate(paragraphs)
              for char in paragraph + '\n']
    output, alternatives, decisions, unresolved = [], {}, Counter(), []
    i = 0
    while i < len(source):
        char, paragraph_index = source[i]
        if (i == 0 or source[i - 1][1] != paragraph_index) and EDITORIAL_PREFIX.match(paragraphs[paragraph_index]):
            decisions['structured_editorial_paragraph_quarantined'] += 1
            unresolved.append({'reason': 'structured_editorial_header', 'paragraph_index': paragraph_index})
            while i < len(source) and source[i][1] == paragraph_index:
                i += 1
            output.append(('\n', paragraph_index))
            continue
        if char in OPEN:
            kind = OPEN[char]
            depth, end = 1, i + 1
            while end < len(source) and depth:
                other = source[end][0]
                if OPEN.get(other) == kind:
                    depth += 1
                elif CLOSE.get(other) == kind:
                    depth -= 1
                end += 1
            if depth:
                decisions['unclosed_annotation_tail'] += 1
                unresolved.append({'reason': 'unclosed_annotation_tail', 'paragraph_index': paragraph_index})
                output.append((UNKNOWN, paragraph_index))
                break
            inner = ''.join(value for value, _ in source[i + 1:end - 1])
            variant = ONE_VARIANT.fullmatch(inner.strip())
            if variant and output and HAN.fullmatch(output[-1][0]):
                position = len(output) - 1
                alternatives.setdefault(position, set()).add(variant.group(1))
                decisions['explicit_single_character_variant'] += 1
            elif kind == 'round':
                decisions['parenthetical_note_removed'] += 1
                if BARE_VARIANT.search(inner):
                    decisions['unresolved_parenthetical_variant'] += 1
                    unresolved.append({'reason': 'unresolved_parenthetical_variant', 'paragraph_index': paragraph_index})
            elif kind == 'square' and len(inner) == 1 and HAN.fullmatch(inner):
                output.append((inner, paragraph_index))
                decisions['single_han_square_wrapper_retained'] += 1
            elif kind == 'square' and inner.strip().isdigit():
                decisions['numeric_reference_removed'] += 1
            else:
                output.append((UNKNOWN, paragraph_index))
                decisions['unknown_bracket_component'] += 1
                unresolved.append({'reason': 'unknown_bracket_component', 'paragraph_index': paragraph_index})
            i = end
            continue
        if char in CLOSE:
            output.append((UNKNOWN, paragraph_index))
            decisions['unmatched_closing_annotation'] += 1
            unresolved.append({'reason': 'unmatched_closing_annotation', 'paragraph_index': paragraph_index})
        elif char == '、':
            decisions['caesura_joined'] += 1
        elif HAN.fullmatch(char) or char in SEPARATORS:
            output.append((char, paragraph_index))
        else:
            output.append((UNKNOWN, paragraph_index))
            decisions['unsupported_source_marker'] += 1
        i += 1

    clauses, current, positions = [], [], []

    def flush():
        if not current:
            return
        text = ''.join(char for char, _ in current)
        paragraph_index = current[0][1]
        if UNKNOWN in text:
            decisions['clause_quarantined_unknown_marker'] += 1
        elif len(text) < min_chars:
            decisions['clause_shorter_than_minimum'] += 1
        elif BARE_VARIANT.search(text) and bare_variant_policy == 'quarantine':
            decisions['clause_quarantined_bare_variant_word'] += 1
            unresolved.append({'reason': 'bare_variant_word', 'paragraph_index': paragraph_index})
        else:
            choices = [sorted({char} | alternatives.get(position, set()))
                       for position, (char, _) in zip(positions, current)]
            combinations = 1
            for choice in choices:
                combinations *= len(choice)
            clauses.append({'text': text, 'paragraph_index': paragraph_index, 'variant': False})
            if 1 < combinations <= max_variants:
                for item in product(*choices):
                    value = ''.join(item)
                    if value != text:
                        clauses.append({'text': value, 'paragraph_index': paragraph_index, 'variant': True})
                        decisions['explicit_variant_clause_emitted'] += 1
            elif combinations > max_variants:
                decisions['variant_combination_limit'] += 1
            if BARE_VARIANT.search(text):
                decisions['bare_variant_word_retained_for_review'] += 1
                unresolved.append({'reason': 'bare_variant_word_review', 'paragraph_index': paragraph_index})
        current.clear()
        positions.clear()

    for position, pair in enumerate(output):
        if pair[0] in SEPARATORS:
            flush()
        else:
            current.append(pair)
            positions.append(position)
    flush()
    decisions['clauses_emitted'] = len(clauses)
    return clauses, dict(decisions), unresolved


def anthology_works(value, inherited=None):
    """Flatten source-defined anthology sections, ignoring prose fields."""
    if isinstance(value, dict):
        if isinstance(value.get('paragraphs'), list):
            if all(isinstance(item, str) for item in value['paragraphs']):
                yield {**(inherited or {}), **value}
            else:
                metadata = {key: value[key] for key in ('author', 'title', 'chapter') if key in value}
                yield from anthology_works(value['paragraphs'], {**(inherited or {}), **metadata})
        elif isinstance(value.get('content'), list):
            yield from anthology_works(value['content'], inherited)
    elif isinstance(value, list):
        for item in value:
            yield from anthology_works(item, inherited)
