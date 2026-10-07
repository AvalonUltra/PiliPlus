"""Add combining marks to BabelStone Han so "Zalgo" text renders in Flutter.

Flutter (SkParagraph + HarfBuzz) resolves fonts per grapheme cluster: a base
character and every combining mark on it must come from ONE font, otherwise
the whole cluster falls back to tofu. iOS has no font with both CJK and the
full Combining Diacritical Marks block, so text like 秘̢̰͕͙ shows as boxes.
BabelStone Han (our last-resort CJK fallback) gets those marks here.

Steps:
  1. Drop kana glyphs that PingFang SC already covers (it precedes BabelStone
     in the fallback chain) — the font sits at the 65535-glyph limit.
  2. Drop GPOS (only kern/chws, irrelevant for a last-resort fallback) so
     HarfBuzz applies its built-in fallback mark positioning: marks are
     centred on the base by combining class and stacked.
  3. Copy combining marks from DejaVu Sans; synthesize the 19 it lacks
     (U+0350/0354-0356/0359/035B, U+0363-036F) from its own glyphs.

Usage: python build.py <BabelStoneHan.ttf> <PingFang.ttc> <DejaVuSans.ttf> <out.ttf>
Requires fonttools.
"""

import sys

from fontTools import subset
from fontTools.pens.boundsPen import BoundsPen
from fontTools.pens.recordingPen import DecomposingRecordingPen
from fontTools.pens.transformPen import TransformPen
from fontTools.pens.ttGlyphPen import TTGlyphPen
from fontTools.ttLib import TTCollection, TTFont

SRC, PINGFANG, DEJAVU, OUT = sys.argv[1:5]

KANA_RANGES = [
    (0x3040, 0x30A0),
    (0x30A0, 0x3100),
    (0x31F0, 0x3200),
    (0x32D0, 0x3300),
    (0xFF61, 0xFFA0),
]
MARK_RANGES = [
    (0x0300, 0x0370),
    (0x0483, 0x048A),
    (0x1DC0, 0x1E00),
    (0x20D0, 0x2100),
    (0xFE20, 0xFE30),
]

# Synthesized marks: (codepoint, [(source char, scale, dx, dy)], placement)
# Coordinates are in the target font's units (upem 1024) after scaling;
# HarfBuzz's fallback positioning re-centres them, only shape matters.
SUPER = 0.30  # superscript letter size relative to DejaVu outline
SYNTH = {
    0x0350: ([('˃', 0.5, 0, 0)], 'above'),
    0x0354: ([('˂', 0.5, 0, 0)], 'below'),
    0x0355: ([('˃', 0.5, 0, 0)], 'below'),
    0x0356: ([('˃', 0.5, 0, 0), ('˄', 0.5, 150, 0)], 'below'),
    0x0359: ([('*', 0.32, 0, 0)], 'below'),
    0x035B: ([('~', 0.42, 0, 0)], 'above'),
    **{
        cp: ([(ch, SUPER, 0, 0)], 'above')
        for cp, ch in zip(range(0x0363, 0x0370), 'aeioucdhmrtvx')
    },
}
MARK_CENTER_X = -300  # zero-advance marks sit over the previous glyph
ABOVE_BOTTOM = 760
BELOW_TOP = -40

src = TTFont(SRC, recalcBBoxes=False)  # keep the original glyf bounds byte-identical
cmap = src.getBestCmap()

pf = TTCollection(PINGFANG, lazy=True)
pf_sc = next(f for f in pf.fonts if f['name'].getDebugName(4) == 'PingFang SC Regular')
pf_cmap = pf_sc.getBestCmap()
drop = {
    cp
    for a, z in KANA_RANGES
    for cp in range(a, z)
    if cp in cmap and cp in pf_cmap
}

opts = subset.Options()
opts.layout_features = ['*']
opts.layout_scripts = ['*']
opts.name_IDs = ['*']
opts.name_languages = ['*']
opts.name_legacy = True
opts.notdef_outline = True
opts.glyph_names = True
opts.legacy_kern = True
opts.hinting = True
opts.drop_tables = []
opts.passthrough_tables = True
opts.prune_unicode_ranges = False
opts.ignore_missing_unicodes = True
subsetter = subset.Subsetter(opts)
subsetter.populate(unicodes=set(cmap) - drop)
subsetter.subset(src)
font = src
print('glyphs after dropping kana:', len(font.getGlyphOrder()))

del font['GPOS']

dv = TTFont(DEJAVU)
dv_set = dv.getGlyphSet()
dv_cmap = dv.getBestCmap()
k = font['head'].unitsPerEm / dv['head'].unitsPerEm


def record(char_or_cp):
    cp = char_or_cp if isinstance(char_or_cp, int) else ord(char_or_cp)
    rec = DecomposingRecordingPen(dv_set)
    dv_set[dv_cmap[cp]].draw(rec)
    return rec


def bounds(rec):
    bp = BoundsPen(None)
    rec.replay(bp)
    return bp.bounds


def build(parts, placement):
    """Scale DejaVu outlines, centre at MARK_CENTER_X, place above/below."""
    recs = []
    for ch, scale, dx, dy in parts:
        rec = record(ch)
        recs.append((rec, scale, dx, dy))
    # bounds of the combined, scaled shape before final translation
    boxes = []
    for rec, scale, dx, dy in recs:
        b = bounds(rec)
        boxes.append((b[0] * scale + dx, b[1] * scale + dy, b[2] * scale + dx, b[3] * scale + dy))
    xmin = min(b[0] for b in boxes)
    ymin = min(b[1] for b in boxes)
    xmax = max(b[2] for b in boxes)
    ymax = max(b[3] for b in boxes)
    tx = MARK_CENTER_X - (xmin + xmax) / 2
    ty = ABOVE_BOTTOM - ymin if placement == 'above' else BELOW_TOP - ymax
    pen = TTGlyphPen(None)
    for rec, scale, dx, dy in recs:
        rec.replay(TransformPen(pen, (scale, 0, 0, scale, dx + tx, dy + ty)))
    return pen.glyph()


def copy_mark(cp):
    pen = TTGlyphPen(None)
    record(cp).replay(TransformPen(pen, (k, 0, 0, k, 0, 0)))
    return pen.glyph()


glyf = font['glyf']
hmtx = font['hmtx']
order = list(font.getGlyphOrder())
existing = set(order)
cmap = font.getBestCmap()
gdef_classes = font['GDEF'].table.GlyphClassDef.classDefs
added = []
for a, z in MARK_RANGES:
    for cp in range(a, z):
        if cp in cmap:
            continue
        if cp in dv_cmap:
            glyph = copy_mark(cp)
        elif cp in SYNTH:
            glyph = build(*SYNTH[cp])
        else:
            continue
        name = f'uni{cp:04X}'
        while name in existing:
            name += '.pili'
        existing.add(name)
        glyph.recalcBounds(glyf)
        glyf.glyphs[name] = glyph
        order.append(name)
        hmtx.metrics[name] = (0, getattr(glyph, 'xMin', 0))
        gdef_classes[name] = 3
        added.append((cp, name))

assert len(order) <= 65535, len(order)
font.setGlyphOrder(order)
glyf.glyphOrder = order
for table in font['cmap'].tables:
    if table.isUnicode():
        for cp, name in added:
            table.cmap[cp] = name

note = 'Modified for PiliPlus: added combining marks (derived from DejaVu Sans, Bitstream Vera license), removed kana covered by PingFang SC, removed GPOS.'
name_table = font['name']
for rec in list(name_table.names):
    if rec.nameID == 5:
        name_table.setName(rec.toUnicode() + '; PiliPlus marks', rec.nameID, rec.platformID, rec.platEncID, rec.langID)
    if rec.nameID == 0:
        name_table.setName(rec.toUnicode() + ' ' + note, rec.nameID, rec.platformID, rec.platEncID, rec.langID)

font.save(OUT)
print('added marks:', len(added), 'total glyphs:', len(order))
