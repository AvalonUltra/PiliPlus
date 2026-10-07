# BabelStone Han (PiliPlus 修改版)

`assets/fonts/BabelStoneHan.ttf` 不是原版 BabelStone Han 16.0.3,而是由
`build.py` 生成的修改版,用于在 Flutter 中正确显示「故障文字」(Zalgo,
即叠满组合附加符号的文本,例如 `秘̢̰͕͙`)。

## 为什么要改

Flutter 按字素簇选字体:基字与其上所有组合附加符号必须来自同一个字体,
否则整簇显示为豆腐块。iOS 上没有同时包含汉字和全部组合附加符号的字体,
所以汉字 + 附加符号只能由打包的 BabelStone Han 承担。

## 改动

1. 删除 PingFang SC 已覆盖的 243 个假名字形(原字体已满 65535 字形上限)。
   回退链里 PingFang SC 排在 BabelStone Han 之前,覆盖范围不变。
2. 删除 GPOS 表(仅含 kern/chws,对末位回退字体无意义),让 HarfBuzz
   启用内置的附加符号回退定位:按组合类别居中于基字并逐层堆叠。
3. 补齐组合附加符号(U+0300–036F 全部 112 个,另含 U+0483–0489、
   U+1DC0–1DFF、U+20D0–20FF、U+FE20–FE2F 中 DejaVu Sans 有的部分),
   共 118 个字形。93 个取自 DejaVu Sans,其余 19 个用 DejaVu Sans 自身
   字形缩放拼合。

其余字形、cmap、GSUB、异体字序列(IVS)与原版逐字节一致。

## 重新生成

```bash
pip install fonttools
python build.py <原版 BabelStoneHan.ttf> <PingFang.ttc> <DejaVuSans.ttf> <输出.ttf>
```

## 许可

- BabelStone Han:Arphic Public License(© Arphic Technology;© Andrew West)。
  本修改版依该许可分发,修改说明即本文件及字体 name 表中的版权附注。
- 组合附加符号字形源自 DejaVu Sans 2.37(Bitstream Vera 许可 + 公有领域
  修改),许可全文见 `DejaVu-LICENSE`。修改版字体名不含 "Bitstream"/"Vera"。
