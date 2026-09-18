// Builds a Scaleform GFx font library from a TTF, using JPEXS FFDec's font machinery.
//
// The layout mirrors a gfxexport-produced FiveM font exactly (verified against a working
// community .gfx): ExporterInfo, FileAttributes, DefineFont3, ExportAssets (the font exported
// under its name — that is the symbol RegisterFontId resolves), ShowFrame, End. DefineFont2 and
// DefineCompactedFont were both tried first and render as fallback boxes in game.
//
// Usage: java -cp ffdec.jar FontToGfx.java <font.ttf> "<Font Name>" <out.gfx>
import com.jpexs.decompiler.flash.SWF;
import com.jpexs.decompiler.flash.tags.DefineFont3Tag;
import com.jpexs.decompiler.flash.tags.EndTag;
import com.jpexs.decompiler.flash.tags.ExportAssetsTag;
import com.jpexs.decompiler.flash.tags.FileAttributesTag;
import com.jpexs.decompiler.flash.tags.ShowFrameTag;
import com.jpexs.decompiler.flash.tags.base.FontTag;
import com.jpexs.decompiler.flash.tags.gfx.ExporterInfo;
import com.jpexs.decompiler.flash.types.RECT;

import java.awt.Font;
import java.awt.font.FontRenderContext;
import java.awt.font.LineMetrics;
import java.io.File;
import java.io.FileOutputStream;
import java.util.ArrayList;
import java.util.Set;
import java.util.TreeSet;

public class FontToGfx {
    public static void main(String[] args) throws Exception {
        File ttf = new File(args[0]);
        String fontName = args[1];
        File out = new File(args[2]);
        String stem = out.getName().replaceAll("\\.gfx$", "");

        Font font = Font.createFont(Font.TRUETYPE_FONT, ttf);
        FontTag.addCustomFont(font, ttf);
        font = font.deriveFont(1024f);

        SWF swf = new SWF();
        swf.version = 8;
        swf.frameRate = 24.0f;
        swf.displayRect = new RECT(0, 11000, 0, 8000);
        swf.frameCount = 1;

        ExporterInfo info = new ExporterInfo(swf);
        info.version = 0x0401;
        info.flags = 0;
        info.bitmapFormat = 13;
        info.prefix = "";
        info.swfName = stem;
        swf.setExporterInfo(info);
        swf.addTag(info);

        swf.addTag(new FileAttributesTag(swf));

        DefineFont3Tag tag = new DefineFont3Tag(swf);
        tag.fontID = 1;
        tag.fontName = fontName;
        tag.fontFlagsHasLayout = true;
        tag.fontFlagsANSI = true;
        tag.fontFlagsWideOffsets = true;
        tag.fontFlagsWideCodes = true;
        tag.fontBoundsTable = new ArrayList<>();
        tag.fontAdvanceTable = new ArrayList<>();
        tag.fontKerningTable = new ArrayList<>();

        // DefineFont3 stores everything at 20x the 1024-unit em
        LineMetrics lm = font.getLineMetrics("Hxpg", new FontRenderContext(null, true, true));
        tag.fontAscent = Math.round(lm.getAscent()) * 20;
        tag.fontDescent = -Math.round(lm.getDescent()) * 20;
        tag.fontLeading = Math.round(lm.getLeading()) * 20;

        Set<Character> chars = new TreeSet<>();
        for (char c = 0x20; c < Character.MAX_VALUE; c++) {
            if (c == 0x7F) continue;
            if (!font.canDisplay(c)) continue;
            chars.add(c);
        }
        System.out.println("glyphs: " + chars.size());
        for (char c : chars) {
            if (!tag.addCharacter(c, font)) {
                throw new IllegalStateException("addCharacter failed at U+" + Integer.toHexString(c));
            }
        }
        tag.setAdvanceValues(font);
        swf.addTag(tag);

        ExportAssetsTag exports = new ExportAssetsTag(swf);
        exports.tags = new ArrayList<>();
        exports.tags.add(tag.fontID);
        exports.names = new ArrayList<>();
        exports.names.add(fontName);
        swf.addTag(exports);

        swf.addTag(new ShowFrameTag(swf));
        swf.addTag(new EndTag(swf));

        try (FileOutputStream fos = new FileOutputStream(out)) {
            swf.saveTo(fos, true, false);
        }
        System.out.println("ascent=" + tag.fontAscent + " descent=" + tag.fontDescent
                + " leading=" + tag.fontLeading + " glyphs=" + chars.size());
        System.out.println("wrote " + out);
    }
}
