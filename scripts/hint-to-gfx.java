// Builds stream/core_hint.gfx — the Scaleform movie of the world prompt's key hint (DESIGN §6.7).
//
// Same machinery as font-to-gfx.java (JPEXS FFDec's library, GFX signature via saveTo(fos, true,
// false)), plus three static shapes, two embedded DefineFont3 fonts, two dynamic text fields, the
// sprite tree the script addresses by instance name, and scripts/hint.as compiled with FFDec's
// ActionScript2Parser. The kit's letter-spacing is baked into the two fonts' advance widths here
// (TRACK_LABEL_EM / TRACK_KEY_EM below) because Scaleform does not honour the TextFormat dance the
// script used to do — the fonts are private to this movie, so widening their advances is safe.
//
// The shapes are built from FFDec's own shape records instead of SvgImporter: in FFDec 26.3.0
// SvgImporter.importSvg() returns a structurally valid but geometrically EMPTY shape when it is
// driven from the library (every edge delta 0), so the SVG source of truth lives here as Java2D
// geometry — the lock is Material Design Icons' `lock` glyph, rebuilt from the primitives its path
// is drawn with (body rounded rect, half-annulus shackle with two legs, round keyhole).
//
// Usage: java -cp "$FFDEC:$(dirname $FFDEC)/lib/*" hint-to-gfx.java \
//            <hint.as> <label-600.ttf> <key-700.ttf> <out.gfx> [preview.swf] [preview call]
// The preview is the same tags with the plain SWF signature and one extra trailing script line, so
// a stock Flash 8 player (or Ruffle) shows one hint — scripts/build-hint-gfx.sh drives both.
import com.jpexs.decompiler.flash.SWF;
import com.jpexs.decompiler.flash.action.Action;
import com.jpexs.decompiler.flash.action.parser.script.ActionScript2Parser;
import com.jpexs.decompiler.flash.tags.DefineEditTextTag;
import com.jpexs.decompiler.flash.tags.DefineFont3Tag;
import com.jpexs.decompiler.flash.tags.DefineShape3Tag;
import com.jpexs.decompiler.flash.tags.DefineSpriteTag;
import com.jpexs.decompiler.flash.tags.DoActionTag;
import com.jpexs.decompiler.flash.tags.EndTag;
import com.jpexs.decompiler.flash.tags.FileAttributesTag;
import com.jpexs.decompiler.flash.tags.PlaceObject2Tag;
import com.jpexs.decompiler.flash.tags.ShowFrameTag;
import com.jpexs.decompiler.flash.tags.base.FontTag;
import com.jpexs.decompiler.flash.tags.gfx.ExporterInfo;
import com.jpexs.decompiler.flash.types.FILLSTYLE;
import com.jpexs.decompiler.flash.types.FILLSTYLEARRAY;
import com.jpexs.decompiler.flash.types.GRADIENT;
import com.jpexs.decompiler.flash.types.GRADRECORD;
import com.jpexs.decompiler.flash.types.LINESTYLE;
import com.jpexs.decompiler.flash.types.LINESTYLEARRAY;
import com.jpexs.decompiler.flash.types.MATRIX;
import com.jpexs.decompiler.flash.types.RECT;
import com.jpexs.decompiler.flash.types.RGBA;
import com.jpexs.decompiler.flash.types.SHAPEWITHSTYLE;
import com.jpexs.decompiler.flash.types.shaperecords.EndShapeRecord;
import com.jpexs.decompiler.flash.types.shaperecords.SHAPERECORD;
import com.jpexs.decompiler.flash.types.shaperecords.StraightEdgeRecord;
import com.jpexs.decompiler.flash.types.shaperecords.StyleChangeRecord;

import java.awt.Font;
import java.awt.Shape;
import java.awt.font.FontRenderContext;
import java.awt.font.LineMetrics;
import java.awt.geom.AffineTransform;
import java.awt.geom.Area;
import java.awt.geom.Ellipse2D;
import java.awt.geom.PathIterator;
import java.awt.geom.Rectangle2D;
import java.awt.geom.RoundRectangle2D;
import java.io.File;
import java.io.FileOutputStream;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.util.ArrayList;
import java.util.List;
import java.util.Set;
import java.util.TreeSet;

public class HintToGfx {
    // stage (CONTRACT): 1400 x 64 px, the cap centre — the world point — at the stage centre
    static final int STAGE_W = 1400, STAGE_H = 64;

    // kit values, size md; the band's gradient shape is longer than any band and slid into place
    static final int BAND_H = 36, FILL_W = 1200, FADE = 76, CLIP_W = 100;
    static final double TEXT_PX = 15, LOCK_PX = 15;

    // The kit's letter-spacing, BAKED into the fonts' advance widths instead of applied from
    // ActionScript. Scaleform ignores a TextFormat that was fetched from an empty field and
    // re-applied after each `.text` assignment (Rockstar's own movies always re-fetch the format
    // AFTER setting the text), so the tracking hint.as used to set never reached the game.
    // Unit: a DefineFont3 advance lives in the glyph coordinate system, a 1024-unit em stored at
    // 20x — EM_UNITS = 20480 per em. Measured on the built tag: fontAscent 20480 for Barlow
    // Condensed's 1.0 em ascent and the space advance 4100 = its 0.2002 em, both exact. At the
    // hint's 15 px text size 0.08 em = 1638 units = 1.1997 px and 0.02 em = 410 units = 0.3003 px,
    // i.e. exactly the 1.2 px / 0.3 px the removed TextFormat.letterSpacing added.
    static final int EM_UNITS = 1024 * 20;
    static final double TRACK_LABEL_EM = 0.08;   // .core-interaction-dot__label letter-spacing
    static final double TRACK_KEY_EM = 0.02;     // .core-key letter-spacing

    // character ids
    static final int SH_FILL = 1, SH_CLIP = 2, SH_LOCK = 3, FONT_LABEL = 4, FONT_KEY = 5,
            TF_KEY = 6, TF_LABEL = 7, MC_FILL = 8, MC_CLIP = 9, MC_LOCK = 10, MC_BG = 11,
            MC_BAND = 12, MC_CAP = 13, MC_HINT = 14;

    static int tw(double px) {
        return (int) Math.round(px * 20);
    }

    static MATRIX at(double xPx, double yPx) {
        MATRIX m = new MATRIX();
        m.translateX = tw(xPx);
        m.translateY = tw(yPx);
        return m;
    }

    static FILLSTYLE solid(int r, int g, int b, int a) {
        FILLSTYLE f = new FILLSTYLE();
        f.fillStyleType = FILLSTYLE.SOLID;
        f.inShape3 = true;
        f.color = new RGBA(r, g, b, a);
        return f;
    }

    static GRADRECORD stop(double offset, int r, int g, int b, int a) {
        GRADRECORD s = new GRADRECORD();
        s.inShape3 = true;
        s.ratio = (int) Math.round(offset * 255);
        s.color = new RGBA(r, g, b, a);
        return s;
    }

    // The band's `linear-gradient(90deg, hud 0, hud calc(100% - 76px), transparent 100%)`. A SWF
    // gradient is defined over a 32768-twip square centred on the origin, so the matrix maps that
    // square onto the shape's own box.
    static FILLSTYLE bandGradient() {
        FILLSTYLE f = new FILLSTYLE();
        f.fillStyleType = FILLSTYLE.LINEAR_GRADIENT;
        f.inShape3 = true;
        f.gradient = new GRADIENT();
        f.gradient.spreadMode = GRADIENT.SPREAD_PAD_MODE;
        f.gradient.interpolationMode = GRADIENT.INTERPOLATION_RGB_MODE;
        f.gradient.gradientRecords = new GRADRECORD[] {
            stop(0, 8, 12, 16, 173),                                       // --color-hud, 0.68
            stop((double) (FILL_W - FADE) / FILL_W, 8, 12, 16, 173),
            stop(1, 6, 11, 15, 0),                                         // --core-ink-rgb / 0
        };
        f.gradientMatrix = new MATRIX();
        f.gradientMatrix.hasScale = true;
        f.gradientMatrix.scaleX = (float) (tw(FILL_W) / 32768.0);
        f.gradientMatrix.scaleY = (float) (tw(BAND_H) / 32768.0);
        f.gradientMatrix.translateX = tw(FILL_W) / 2;
        f.gradientMatrix.translateY = tw(BAND_H) / 2;
        return f;
    }

    // Any Java2D outline as ONE filled DefineShape3. Curves are flattened (the biggest radius here
    // is 5 units of a 15 px glyph, so 0.05 px is well under a twip of error) and every point is
    // rounded to twips before the delta is taken, which keeps the path from drifting.
    static DefineShape3Tag shape(SWF swf, int id, Shape geom, AffineTransform t, FILLSTYLE fill) {
        SHAPEWITHSTYLE sh = new SHAPEWITHSTYLE();
        sh.fillStyles = new FILLSTYLEARRAY();
        sh.fillStyles.fillStyles = new FILLSTYLE[] { fill };
        sh.lineStyles = new LINESTYLEARRAY();
        sh.lineStyles.lineStyles = new LINESTYLE[0];
        sh.shapeRecords = new ArrayList<>();

        double[] c = new double[6];
        int x = 0, y = 0, sx = 0, sy = 0;
        boolean first = true;
        int xMin = Integer.MAX_VALUE, xMax = Integer.MIN_VALUE;
        int yMin = Integer.MAX_VALUE, yMax = Integer.MIN_VALUE;
        for (PathIterator it = geom.getPathIterator(t, 0.05); !it.isDone(); it.next()) {
            int kind = it.currentSegment(c);
            int tx = x, ty = y;
            if (kind == PathIterator.SEG_MOVETO || kind == PathIterator.SEG_LINETO) {
                tx = tw(c[0]);
                ty = tw(c[1]);
            } else if (kind == PathIterator.SEG_CLOSE) {
                tx = sx;
                ty = sy;
            } else {
                throw new IllegalStateException("unflattened segment " + kind);
            }
            if (kind == PathIterator.SEG_MOVETO) {
                StyleChangeRecord m = new StyleChangeRecord();
                m.stateMoveTo = true;
                m.moveDeltaX = tx;
                m.moveDeltaY = ty;
                if (first) {
                    m.stateFillStyle1 = true;
                    m.fillStyle1 = 1;
                    first = false;
                }
                sh.shapeRecords.add(m);
                sx = tx;
                sy = ty;
            } else if (tx != x || ty != y) {
                StraightEdgeRecord e = new StraightEdgeRecord();
                e.deltaX = tx - x;
                e.deltaY = ty - y;
                e.generalLineFlag = e.deltaX != 0 && e.deltaY != 0;
                e.vertLineFlag = e.deltaX == 0;
                sh.shapeRecords.add(e);
            }
            x = tx;
            y = ty;
            xMin = Math.min(xMin, x);
            xMax = Math.max(xMax, x);
            yMin = Math.min(yMin, y);
            yMax = Math.max(yMax, y);
        }
        sh.shapeRecords.add(new EndShapeRecord());
        for (SHAPERECORD r : sh.shapeRecords) {
            r.calculateBits();
        }
        DefineShape3Tag s = new DefineShape3Tag(swf);
        s.shapeId = id;
        s.shapes = sh;
        s.shapeBounds = new RECT(xMin, xMax, yMin, yMax);
        return s;
    }

    // Material Design Icons' `lock`, 24 x 24, rebuilt from the primitives its path draws: the body
    // (rounded rect r 2), the shackle (upper half of an r 5 / r 3 annulus at (12,6) plus the two
    // legs down to the body) and the round keyhole punched out at (12,15) r 2.
    static Shape lockGlyph() {
        Area a = new Area(new RoundRectangle2D.Double(4, 8, 16, 14, 4, 4));
        Area shackle = new Area(new Ellipse2D.Double(7, 1, 10, 10));
        shackle.intersect(new Area(new Rectangle2D.Double(7, 1, 10, 5)));
        shackle.subtract(new Area(new Ellipse2D.Double(9, 3, 6, 6)));
        a.add(shackle);
        a.add(new Area(new Rectangle2D.Double(7, 6, 2, 2)));
        a.add(new Area(new Rectangle2D.Double(15, 6, 2, 2)));
        a.subtract(new Area(new Ellipse2D.Double(10, 13, 4, 4)));
        return a;
    }

    // Exactly font-to-gfx.java's DefineFont3: every glyph the TTF can display (so umlauts work),
    // layout at 20 x the 1024-unit em. Not exported as an asset — the text fields reference the
    // font by id inside this movie, and an ExportAssets name would collide with the separate
    // stream/barlow_condensed*.gfx font libraries Scaleform already has registered.
    static DefineFont3Tag font(SWF swf, int id, File ttf, String name, double trackEm)
            throws Exception {
        Font font = Font.createFont(Font.TRUETYPE_FONT, ttf);
        FontTag.addCustomFont(font, ttf);
        font = font.deriveFont(1024f);

        DefineFont3Tag tag = new DefineFont3Tag(swf);
        tag.fontID = id;
        tag.fontName = name;
        tag.fontFlagsHasLayout = true;
        tag.fontFlagsANSI = true;
        tag.fontFlagsWideOffsets = true;
        tag.fontFlagsWideCodes = true;
        tag.fontBoundsTable = new ArrayList<>();
        tag.fontAdvanceTable = new ArrayList<>();
        tag.fontKerningTable = new ArrayList<>();

        LineMetrics lm = font.getLineMetrics("Hxpg", new FontRenderContext(null, true, true));
        tag.fontAscent = Math.round(lm.getAscent()) * 20;
        tag.fontDescent = -Math.round(lm.getDescent()) * 20;
        tag.fontLeading = Math.round(lm.getLeading()) * 20;

        Set<Character> chars = new TreeSet<>();
        for (char c = 0x20; c < Character.MAX_VALUE; c++) {
            if (c == 0x7F || !font.canDisplay(c)) continue;
            chars.add(c);
        }
        for (char c : chars) {
            if (!tag.addCharacter(c, font)) {
                throw new IllegalStateException("addCharacter failed at U+" + Integer.toHexString(c));
            }
        }
        tag.setAdvanceValues(font);

        // The tracking goes on EVERY glyph, spaces included, so textWidth carries it as well —
        // the trailing step after the last glyph included, exactly like CSS letter-spacing in the
        // kit. hint.as therefore keeps measuring the layout straight from textWidth.
        int track = (int) Math.round(trackEm * EM_UNITS);
        int plain = tag.fontAdvanceTable.get(tag.charToGlyph('H'));
        for (int i = 0; i < tag.fontAdvanceTable.size(); i++) {
            tag.fontAdvanceTable.set(i, tag.fontAdvanceTable.get(i) + track);
        }
        System.out.println("font " + name + ": " + chars.size() + " glyphs, ascent="
                + tag.fontAscent + " descent=" + tag.fontDescent + "; advance unit 1/" + EM_UNITS
                + " em ('H' " + plain + " = " + String.format("%.4f", plain / (double) EM_UNITS)
                + " em), tracking +" + trackEm + " em = +" + track + " units = +"
                + String.format("%.4f", track * TEXT_PX / EM_UNITS) + " px at " + TEXT_PX + " px");
        return tag;
    }

    // A dynamic, single-line, embedded-outline text field. The script positions it, so the box
    // only has to be wide enough for the longest text it will ever hold.
    static DefineEditTextTag text(SWF swf, int id, int fontId, double wPx, RGBA colour) {
        DefineEditTextTag t = new DefineEditTextTag(swf);
        t.characterID = id;
        t.bounds = new RECT(0, tw(wPx), 0, tw(TEXT_PX * 2));
        t.readOnly = true;
        t.noSelect = true;
        t.useOutlines = true;
        t.hasFont = true;
        t.fontId = fontId;
        t.fontHeight = tw(TEXT_PX);
        t.hasTextColor = true;
        t.textColor = colour;
        t.hasText = true;
        t.initialText = "";
        t.variableName = "";
        return t;
    }

    static DefineSpriteTag sprite(SWF swf, int id) {
        DefineSpriteTag s = new DefineSpriteTag(swf);
        s.spriteId = id;
        s.frameCount = 1;
        return s;
    }

    static void place(SWF swf, DefineSpriteTag parent, int depth, int charId, MATRIX m, String name) {
        parent.addTag(new PlaceObject2Tag(swf, false, depth, charId, m, null, -1, name, -1, null));
    }

    static DefineSpriteTag seal(SWF swf, DefineSpriteTag s) {
        s.addTag(new ShowFrameTag(swf));
        s.addTag(new EndTag(swf));
        return s;
    }

    // The whole movie. Built from scratch per output so the preview can carry one extra script
    // line without any tag being re-serialised from a cached byte range.
    static SWF build(File as, File labelTtf, File keyTtf, String stem, String extra) throws Exception {
        SWF swf = new SWF();
        swf.version = 8;
        swf.frameRate = 60.0f;
        swf.displayRect = new RECT(0, tw(STAGE_W), 0, tw(STAGE_H));
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

        // static shapes: the band's gradient, the mask that windows it, the lock glyph
        swf.addTag(shape(swf, SH_FILL, new Rectangle2D.Double(0, 0, FILL_W, BAND_H), null,
                bandGradient()));
        swf.addTag(shape(swf, SH_CLIP, new Rectangle2D.Double(0, 0, CLIP_W, BAND_H), null,
                solid(255, 255, 255, 255)));
        AffineTransform lockAt = AffineTransform.getTranslateInstance(-LOCK_PX / 2, -LOCK_PX / 2);
        lockAt.scale(LOCK_PX / 24.0, LOCK_PX / 24.0);
        swf.addTag(shape(swf, SH_LOCK, lockGlyph(), lockAt, solid(243, 245, 247, 255)));

        swf.addTag(font(swf, FONT_LABEL, labelTtf, "Barlow Condensed", TRACK_LABEL_EM));
        swf.addTag(font(swf, FONT_KEY, keyTtf, "Barlow Condensed Bold", TRACK_KEY_EM));
        swf.addTag(text(swf, TF_KEY, FONT_KEY, 120, new RGBA(17, 22, 27, 255)));   // --color-key-fg
        swf.addTag(text(swf, TF_LABEL, FONT_LABEL, 640, new RGBA(243, 245, 247, 255))); // --color-fg

        // a bare shape has no AS2 identity, so every part the script touches is a sprite; the
        // gradient and the mask are hung off their sprite's origin at the band's vertical centre
        DefineSpriteTag fill = sprite(swf, MC_FILL);
        place(swf, fill, 1, SH_FILL, at(0, -BAND_H / 2.0), "shape");
        swf.addTag(seal(swf, fill));
        DefineSpriteTag clip = sprite(swf, MC_CLIP);
        place(swf, clip, 1, SH_CLIP, at(0, -BAND_H / 2.0), "shape");
        swf.addTag(seal(swf, clip));
        DefineSpriteTag lock = sprite(swf, MC_LOCK);
        place(swf, lock, 1, SH_LOCK, at(0, 0), "shape");
        swf.addTag(seal(swf, lock));
        swf.addTag(seal(swf, sprite(swf, MC_BG)));   // empty: the script draws the cap into it

        DefineSpriteTag band = sprite(swf, MC_BAND);
        place(swf, band, 1, MC_FILL, at(0, 0), "fill");
        place(swf, band, 2, MC_CLIP, at(0, 0), "clip");
        swf.addTag(seal(swf, band));

        DefineSpriteTag cap = sprite(swf, MC_CAP);
        place(swf, cap, 1, MC_BG, at(0, 0), "bg");
        place(swf, cap, 2, TF_KEY, at(0, 0), "key_tf");
        place(swf, cap, 3, MC_LOCK, at(0, 0), "lock");
        swf.addTag(seal(swf, cap));

        DefineSpriteTag hint = sprite(swf, MC_HINT);
        place(swf, hint, 1, MC_BAND, at(0, 0), "band");
        place(swf, hint, 2, MC_CAP, at(0, 0), "cap");
        place(swf, hint, 3, TF_LABEL, at(0, 0), "label_tf");
        swf.addTag(seal(swf, hint));

        swf.addTag(new PlaceObject2Tag(swf, false, 1, MC_HINT, at(STAGE_W / 2.0, STAGE_H / 2.0),
                null, -1, "hint", -1, null));

        String src = new String(Files.readAllBytes(as.toPath()), StandardCharsets.UTF_8) + extra;
        DoActionTag script = new DoActionTag(swf);
        List<Action> actions = new ActionScript2Parser(swf, script).actionsFromString(src, "UTF-8");
        script.setActions(actions);
        swf.addTag(script);
        System.out.println(stem + ": " + actions.size() + " actions compiled from " + as.getName());

        swf.addTag(new ShowFrameTag(swf));
        swf.addTag(new EndTag(swf));
        return swf;
    }

    public static void main(String[] args) throws Exception {
        File as = new File(args[0]);
        File labelTtf = new File(args[1]);
        File keyTtf = new File(args[2]);
        File out = new File(args[3]);
        String stem = out.getName().replaceAll("\\.(gfx|swf)$", "");

        try (FileOutputStream fos = new FileOutputStream(out)) {
            build(as, labelTtf, keyTtf, stem, "").saveTo(fos, true, false);   // GFX signature
        }
        System.out.println("wrote " + out + " (" + out.length() + " bytes)");

        if (args.length > 4 && !args[4].isEmpty()) {
            File preview = new File(args[4]);
            String call = args.length > 5 && !args[5].isEmpty() ? args[5]
                    : "SET_HINT('E', 'Pick up Bandage', false, false, false);";
            String stem2 = preview.getName().replaceAll("\\.(gfx|swf)$", "");
            try (FileOutputStream fos = new FileOutputStream(preview)) {
                build(as, labelTtf, keyTtf, stem2, "\n" + call + "\n").saveTo(fos, false, false);
            }
            System.out.println("wrote " + preview + " (" + preview.length() + " bytes): " + call);
        }
    }
}
