// hint.as — the root timeline of stream/core_hint.gfx (DESIGN §6.7, CONTRACT "the movie").
//
// One frame, no tween, no timeline: the whole hint is laid out from script whenever the renderer
// calls SET_HINT, and an idle movie runs NO code at all (the focus-in animation deletes its own
// onEnterFrame when it is done). Everything is measured in stage pixels with the origin at the
// CENTRE of the key cap, which is where client/interactions.lua puts the world point.
//
// API (argument order and types are binding):
//   SET_HINT(key:String, label:String, disabled:Boolean, left:Boolean, restart:Boolean)
//   HIDE()
// Both reachable as TIMELINE.<NAME> (what the game invokes) and _root.<NAME>.
//
// Compiled by scripts/hint-to-gfx.java with FFDec's ActionScript2Parser — plain AS2, no classes,
// no #include, nothing GFx-only, so a stock Flash 8 player can run the preview build. There is
// deliberately no TextFormat anywhere in here: the kit's letter-spacing is baked into the embedded
// fonts' advance widths by the builder (see SET_TEXT), because Scaleform ignores a format object
// that was fetched from an empty field and re-applied after every .text assignment.

TIMELINE = this;

// ---- tuning ---------------------------------------------------------------------------------
// A Flash text line starts GUTTER px below the field's top and its baseline sits one font ascent
// lower; Barlow Condensed is a 1.0 em ascent with a 0.70 em cap height, so 15 px uppercase is
// optically centred on y = 0 at -(2 + 15) + 15 * 0.70 / 2 = -11.75. These two are THE knobs for
// the in-game baseline tuning — nothing else needs touching if the text sits a pixel high or low.
var KEY_DY = -11.75;   // key_tf._y
var LABEL_DY = -11.75; // label_tf._y

// ---- kit geometry, size md (ui/src/kit/css/actions.css .core-key, game.css .core-interaction-dot)
var GUTTER = 2;        // Flash's own 2 px text-field gutter
var CAP_H = 26;        // .core-key height
var CAP_MIN_W = 26;    // .core-key min-width
var CAP_PAD = 14;      // .core-key padding 0 7px
var CAP_R = 3;         // --radius-ui-xs
var CAP_LIP = 2;       // box-shadow: 0 2px 0 rgba(0,0,0,.45)
var CAP_BG = 0xFBFBFB; // --color-key
var TINT = 0xFFFFFF;   // --color-fg, near enough for the 6 % / 28 % outline cap
var GAP = 8;           // --core-idot-gap
var BAND_MIN = 200;    // --core-idot-band-min
var BAND_TAIL = 84;    // --core-idot-tail
var BAND_PAD = 14;     // the band's left padding
var FILL_W = 1200;     // the generator-built gradient shape's own width
var LABEL_DIM = 65;    // .is-disabled .core-interaction-dot__label
var ANIM_MS = 180;     // the kit's focus-in transition
var SLIDE = 8;         // .core-interaction-dot__band translate(-8px)

// ---- helpers --------------------------------------------------------------------------------

// A rounded rectangle through the AS2 drawing API (solid fills only — no bitmap, no gradient).
function ROUND_RECT(g, x, y, w, h, r) {
    if (r > w / 2) { r = w / 2; }
    if (r > h / 2) { r = h / 2; }
    g.moveTo(x + r, y);
    g.lineTo(x + w - r, y);
    g.curveTo(x + w, y, x + w, y + r);
    g.lineTo(x + w, y + h - r);
    g.curveTo(x + w, y + h, x + w - r, y + h);
    g.lineTo(x + r, y + h);
    g.curveTo(x, y + h, x, y + h - r);
    g.lineTo(x, y + r);
    g.curveTo(x, y, x + r, y);
}

// The cap tile. Its width follows the key text, so it is drawn instead of being a static shape:
// solid = the kit's white cap over its 2 px black lip, disabled = the outline cap (no lip).
function DRAW_CAP(g, w, disabled) {
    var x = -w / 2;
    var y = -CAP_H / 2;
    g.clear();
    if (disabled) {
        g.lineStyle(1, TINT, 28);
        g.beginFill(TINT, 6);
        ROUND_RECT(g, x + 0.5, y + 0.5, w - 1, CAP_H - 1, CAP_R);
        g.endFill();
    } else {
        g.beginFill(0x000000, 45);
        ROUND_RECT(g, x, y + CAP_LIP, w, CAP_H, CAP_R);
        g.endFill();
        g.beginFill(CAP_BG, 100);
        ROUND_RECT(g, x, y, w, CAP_H, CAP_R);
        g.endFill();
    }
}

// The kit's letter-spacing (0.08em on the label, 0.02em on the key) is NOT applied here: it is
// BAKED into the advance width of every glyph of the two embedded fonts by scripts/hint-to-gfx.java.
// Scaleform ignores a TextFormat that was fetched from an empty field and re-applied after .text,
// which is what this used to do, so the tracking simply vanished in game while Ruffle showed it.
// Baked advances need no format at all and textWidth already carries the tracking — including the
// one after the last glyph, exactly like CSS letter-spacing in the kit.
function SET_TEXT(tf, s) {
    tf.text = s.toUpperCase();
    return tf.textWidth;
}

// One step of the focus-in; `this` is the hint clip and t is 0..1. Ease-out cubic stands in for
// the kit's cubic-bezier(.22,.61,.36,1).
function ANIM_STEP(t) {
    var u = 1 - t;
    var e = 1 - u * u * u;
    var s = this.aDir * SLIDE * (1 - e);
    this.cap._xscale = 70 + 30 * e;
    this.cap._yscale = 70 + 30 * e;
    this.cap._alpha = 100 * e;
    this.band._x = -s;
    this.band._alpha = 100 * e;
    this.label_tf._x = this.aLx - s;
    this.label_tf._alpha = this.aLa * e;
}

// ---- API ------------------------------------------------------------------------------------

// key    cap text as registered ('E', 'SPACE')      label    the RAW label, uppercased here
// disabled  out of reach or locked                  left     the band opens to the left
// restart   replay the focus-in animation
function SET_HINT(key, label, disabled, left, restart) {
    if (key == undefined) { key = ''; }
    if (label == undefined) { label = ''; }
    var h = hint;

    // the cap: width follows the key text, the lock replaces the letter when disabled
    var kw = SET_TEXT(h.cap.key_tf, key);
    var capW = CAP_MIN_W;
    if (!disabled && Math.ceil(kw) + CAP_PAD > capW) { capW = Math.ceil(kw) + CAP_PAD; }
    h.cap.key_tf._x = -kw / 2 - GUTTER;
    h.cap.key_tf._y = KEY_DY;
    h.cap.key_tf._visible = !disabled;
    h.cap.lock._visible = disabled == true;
    DRAW_CAP(h.cap.bg, capW, disabled);

    // the band: one gradient shape, moved so its faded end is the band's end, through a mask
    // that is the band's own box. x0 is the band's start, measured from the cap's edge.
    var lw = SET_TEXT(h.label_tf, label);
    var x0 = capW / 2 + GAP;
    var bw = BAND_MIN;
    if (BAND_PAD + Math.ceil(lw) + BAND_TAIL > bw) { bw = BAND_PAD + Math.ceil(lw) + BAND_TAIL; }
    h.band.fill._x = x0 + bw - FILL_W;
    h.band.clip._x = x0;
    h.band.clip._width = bw;
    h.band._xscale = left ? -100 : 100;

    // the label is a sibling of the mirrored band, so it is placed by hand on either side
    var lx = x0 + BAND_PAD - GUTTER;
    if (left) { lx = -(x0 + BAND_PAD) - lw - GUTTER; }
    h.label_tf._y = LABEL_DY;

    h.aDir = left ? -1 : 1;
    h.aLx = lx;
    h.aLa = disabled ? LABEL_DIM : 100;
    delete h.onEnterFrame;
    if (restart) {
        h.aT0 = getTimer();
        h.step(0);
        h.onEnterFrame = function () {
            var t = (getTimer() - this.aT0) / ANIM_MS;
            if (t >= 1) {
                t = 1;
                delete this.onEnterFrame;
            }
            this.step(t);
        };
    } else {
        h.step(1);
    }
    h._visible = true;
}

// Blanks the movie. Sent once when focus is lost, so a SET_HINT that lands late can never flash
// the previous hint's content.
function HIDE() {
    delete hint.onEnterFrame;
    hint._visible = false;
}

// ---- init -----------------------------------------------------------------------------------
// AS2 creates functions as the frame runs, so this has to be last.

stop();
hint._visible = false;
hint.step = ANIM_STEP;
hint.band.fill.setMask(hint.band.clip);
hint.cap.lock._visible = false;
