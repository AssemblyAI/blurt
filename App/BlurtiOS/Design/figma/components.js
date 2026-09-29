/* global figma, getPage, variableMap, ensureTokens, loadFonts, FONT, metric, token, autoLayout, textNode, paint, bind, bindRadius, gradientPaint, symbolChar, DEVICE_WIDTH, VARS */
// ---------------------------------------------------------------------------
// Components (02 Components). Every fill, stroke, radius and gap is bound to a
// variable; the orb's disc is the one image fill (see buildOrbDisc).

const SIZES = { Bar: "orb/bar", Panel: "orb/panel", Home: "orb/home" };
const WAVES = {
  Bar: ["wave/bar-width", "wave/bar-height"],
  Panel: ["wave/panel-width", "wave/panel-height"],
  Home: ["wave/home-width", "wave/home-height"],
};

async function findComponentSet(page, name) {
  return page.findOne((n) => n.type === "COMPONENT_SET" && n.name === name);
}

async function findComponent(page, name) {
  return page.findOne((n) => n.type === "COMPONENT" && n.name === name && n.parent.type !== "COMPONENT_SET");
}

async function textStyleId(name) {
  const s = (await figma.getLocalTextStylesAsync()).find((x) => x.name === name);
  if (!s) throw new Error(`text style ${name} missing — run buildFoundations first`);
  return s.id;
}

async function effectStyleId(name) {
  const s = (await figma.getLocalEffectStylesAsync()).find((x) => x.name === name);
  if (!s) throw new Error(`effect style ${name} missing — run buildFoundations first`);
  return s.id;
}

/** Replaces a component set (or lone component) of this name, keeping its position. */
function replaceNamed(page, name, node) {
  const old = page.findOne((n) => (n.type === "COMPONENT_SET" || n.type === "COMPONENT") && n.name === name);
  if (old) {
    node.x = old.x;
    node.y = old.y;
    old.remove();
  }
}

/** Lays the variants of a set out in a row and names the set. */
function finishSet(page, name, variants, x, y) {
  const set = figma.combineAsVariants(variants, page);
  set.name = name;
  set.layoutMode = "HORIZONTAL";
  set.itemSpacing = 24;
  set.paddingLeft = set.paddingRight = set.paddingTop = set.paddingBottom = 24;
  set.primaryAxisSizingMode = "AUTO";
  set.counterAxisSizingMode = "AUTO";
  set.counterAxisAlignItems = "MIN";
  set.x = x;
  set.y = y;
  return set;
}

async function keyCap(props) {
  // props: tone "Key"|"Modifier"|"Bare", pressed, label, width (fixed) or null (min width + pad)
  const c = figma.createComponent();
  c.name = `Tone=${props.tone}, State=${props.pressed ? "Pressed" : "Up"}`;
  c.layoutMode = "HORIZONTAL";
  c.primaryAxisAlignItems = "CENTER";
  c.counterAxisAlignItems = "CENTER";
  c.primaryAxisSizingMode = props.width ? "FIXED" : "AUTO";
  c.counterAxisSizingMode = "FIXED";
  c.resize(props.width || metric("key/min-width"), metric("key/height"));
  await bind(c, "height", "Metrics:key/height");
  if (props.width) await bind(c, "width", `Metrics:${props.widthRef}`);
  else {
    await bind(c, "minWidth", "Metrics:key/min-width");
    await bind(c, "paddingLeft", "Metrics:key/pad");
    await bind(c, "paddingRight", "Metrics:key/pad");
  }
  c.fills = props.tone === "Bare" ? [] : [await paint(props.tone === "Modifier" ? "Keyboard:kb/key-modifier" : "Keyboard:kb/key")];
  await bindRadius(c, "Metrics:key/radius");
  const label = await textNode(props.label, {
    styleId: await textStyleId(props.letter ? "Key/Letter" : "Key/Legend"),
    fillRef: props.tint || "Keyboard:kb/legend",
  });
  label.name = "Label";
  c.appendChild(label);
  if (props.pressed) {
    const shine = figma.createRectangle();
    shine.name = "Pressed";
    shine.fills = [{ type: "SOLID", color: { r: 1, g: 1, b: 1 } }];
    await bind(shine, "opacity", "Metrics:opacity/press-brighten");
    c.appendChild(shine);
    shine.layoutPositioning = "ABSOLUTE";
    shine.x = 0;
    shine.y = 0;
    shine.resize(c.width, c.height);
    shine.constraints = { horizontal: "STRETCH", vertical: "STRETCH" };
    await bindRadius(shine, "Metrics:key/radius");
  }
  return c;
}

async function buildKeySet(page, x, y) {
  const variants = [];
  for (const tone of ["Key", "Modifier", "Bare"]) {
    for (const pressed of [false, true]) {
      variants.push(await keyCap({ tone, pressed, label: tone === "Bare" ? "×" : "space" }));
    }
  }
  replaceNamed(page, "Key", variants[0]);
  const set = finishSet(page, "Key", variants, x, y);
  set.description = "One ordinary key: a legend on a cap in the current palette; Modifier a step darker; Bare a glyph with no cap. Flat: no drop, no edge, no gloss.";
  const labelProp = set.addComponentProperty("Label", "TEXT", "space");
  for (const v of variants) {
    const t = v.findOne((n) => n.type === "TEXT" && n.name === "Label");
    t.componentPropertyReferences = { characters: labelProp };
  }
  return set;
}

async function buildLetterKeySet(page, x, y) {
  const variants = [];
  for (const pressed of [false, true]) {
    const c = await keyCap({
      tone: "Key",
      pressed,
      label: "q",
      letter: true,
      width: metric("key/letter-width-402"),
      widthRef: "key/letter-width-402",
    });
    c.name = `State=${pressed ? "Pressed" : "Up"}`;
    if (pressed) {
      const popup = figma.createFrame();
      popup.name = "LetterPopup";
      popup.layoutMode = "HORIZONTAL";
      popup.primaryAxisAlignItems = "CENTER";
      popup.counterAxisAlignItems = "CENTER";
      popup.primaryAxisSizingMode = "FIXED";
      popup.counterAxisSizingMode = "FIXED";
      popup.resize(metric("key/letter-width-402") + metric("popup/extra-width"), metric("popup/height"));
      await bind(popup, "height", "Metrics:popup/height");
      popup.fills = [await paint("Keyboard:kb/popup")];
      await bindRadius(popup, "Metrics:popup/radius");
      popup.effectStyleId = await effectStyleId("Shadow/Popup");
      const big = await textNode("q", { styleId: await textStyleId("Key/Popup"), fillRef: "Keyboard:kb/legend" });
      big.name = "Popup label";
      popup.appendChild(big);
      c.appendChild(popup);
      popup.layoutPositioning = "ABSOLUTE";
      popup.x = -metric("popup/extra-width") / 2;
      popup.y = -metric("popup/offset");
    }
    variants.push(c);
  }
  replaceNamed(page, "LetterKey", variants[0]);
  const set = finishSet(page, "LetterKey", variants, x, y);
  set.description = "A letter key with the system keyboard's 22 pt legend and its pop-up while pressed: a 32 pt copy above the key, the one thing that floats.";
  const labelProp = set.addComponentProperty("Label", "TEXT", "q");
  for (const v of variants) {
    for (const t of v.findAll((n) => n.type === "TEXT")) t.componentPropertyReferences = { characters: labelProp };
  }
  return set;
}

async function glyphButton(name, symbol, fallback, fillRef, opacityRef) {
  const c = figma.createComponent();
  c.name = name;
  c.layoutMode = "HORIZONTAL";
  c.primaryAxisAlignItems = "CENTER";
  c.counterAxisAlignItems = "CENTER";
  c.primaryAxisSizingMode = "FIXED";
  c.counterAxisSizingMode = "FIXED";
  c.resize(metric("glyph/hit"), metric("glyph/hit"));
  await bind(c, "width", "Metrics:glyph/hit");
  await bind(c, "height", "Metrics:glyph/hit");
  const t = await textNode(symbolChar(symbol, fallback), { styleId: await textStyleId("Glyph"), fillRef });
  t.name = "Glyph";
  if (opacityRef) await bind(t, "opacity", opacityRef);
  c.appendChild(t);
  return c;
}

async function buildAddTermKey(page, x, y) {
  const off = await glyphButton("Saved=False", "plus", "+", "Keyboard:kb/legend", "Metrics:opacity/legend-muted");
  const on = await glyphButton("Saved=True", "checkmark", "✓", "Keyboard:kb/signal", null);
  replaceNamed(page, "AddTermKey", off);
  const set = finishSet(page, "AddTermKey", [off, on], x, y);
  set.description = "The small + beside the orb: a new key term. A bare glyph, quiet until needed; a check for a moment after one was saved.";
  return set;
}

async function buildCancelKey(page, x, y) {
  const c = await keyCap({ tone: "Bare", pressed: false, label: symbolChar("xmark", "×"), tint: "Keyboard:kb/cancel" });
  c.name = "CancelKey";
  c.description = "Cancel, in the panel's top-right corner while something is in flight: the orange × on no cap.";
  replaceNamed(page, "CancelKey", c);
  page.appendChild(c);
  c.x = x;
  c.y = y;
  return c;
}

async function buildTermField(page, x, y) {
  const c = figma.createComponent();
  c.name = "TermField";
  c.description = "The voice bar as a field: × to leave, what has been typed with a caret, ✓ to save.";
  c.layoutMode = "HORIZONTAL";
  c.counterAxisAlignItems = "CENTER";
  c.primaryAxisSizingMode = "FIXED";
  c.counterAxisSizingMode = "FIXED";
  c.resize(DEVICE_WIDTH - 2 * metric("margin/side"), metric("voicebar/height"));
  await bind(c, "height", "Metrics:voicebar/height");
  await bind(c, "itemSpacing", "Metrics:term/gap");
  await bind(c, "paddingLeft", "Metrics:term/inset");
  await bind(c, "paddingRight", "Metrics:term/inset");
  const cancel = await glyphButton("Cancel", "xmark", "×", "Keyboard:kb/legend", "Metrics:opacity/term-cancel");
  cancel.name = "Cancel";
  const cancelInstance = cancel.createInstance();
  cancel.remove();
  c.appendChild(cancelInstance);
  const field = figma.createFrame();
  field.name = "Field";
  field.layoutMode = "HORIZONTAL";
  field.counterAxisAlignItems = "CENTER";
  field.primaryAxisSizingMode = "FIXED";
  field.counterAxisSizingMode = "FIXED";
  field.resize(100, metric("term/height"));
  await bind(field, "height", "Metrics:term/height");
  await bind(field, "paddingLeft", "Metrics:term/pad");
  await bind(field, "paddingRight", "Metrics:term/pad");
  field.fills = [await paint("Keyboard:kb/key-modifier")];
  field.cornerRadius = metric("term/height") / 2; // a capsule: half the height
  const draft = await textNode("Rizz", { styleId: await textStyleId("Term/Text"), fillRef: "Keyboard:kb/legend" });
  draft.name = "Draft";
  field.appendChild(draft);
  const caret = figma.createRectangle();
  caret.name = "Caret";
  caret.resize(metric("caret/width"), metric("caret/height"));
  await bind(caret, "width", "Metrics:caret/width");
  await bind(caret, "height", "Metrics:caret/height");
  await bindRadius(caret, "Metrics:caret/radius");
  caret.fills = [await paint("Keyboard:kb/signal")];
  field.appendChild(caret);
  c.appendChild(field);
  field.layoutSizingHorizontal = "FILL";
  const save = await glyphButton("Save", "checkmark", "✓", "Keyboard:kb/signal", null);
  const saveInstance = save.createInstance();
  save.remove();
  c.appendChild(saveInstance);
  const draftProp = c.addComponentProperty("Draft", "TEXT", "Rizz");
  draft.componentPropertyReferences = { characters: draftProp };
  replaceNamed(page, "TermField", c);
  page.appendChild(c);
  c.x = x;
  c.y = y;
  return c;
}

async function buildOrbRing(page, x, y) {
  const variants = [];
  for (const [size, ref] of Object.entries(SIZES)) {
    for (const kind of ["Still", "Working", "Ok", "Error"]) {
      const c = figma.createComponent();
      c.name = `Kind=${kind}, Size=${size}`;
      const d = metric(ref);
      c.resize(d, d);
      c.fills = [];
      const ring = figma.createEllipse();
      ring.name = "Ring";
      ring.resize(d, d);
      ring.fills = [];
      ring.strokeAlign = "INSIDE";
      if (kind === "Ok" || kind === "Error") {
        ring.strokes = [await paint(kind === "Ok" ? "Keyboard:kb/notice-ok" : "Keyboard:kb/notice-error")];
      } else {
        ring.strokes = [gradientPaint("orb-ring")];
      }
      await bind(ring, "strokeWeight", kind === "Still" ? "Metrics:ring/still" : "Metrics:ring/active");
      c.appendChild(ring);
      await bind(c, "width", `Metrics:${ref}`);
      await bind(c, "height", `Metrics:${ref}`);
      variants.push(c);
    }
  }
  replaceNamed(page, "Orb/Ring", variants[0]);
  const set = finishSet(page, "Orb/Ring", variants, x, y);
  set.description = "The hairline ring round the orb: green into white, 1 pt at rest and 2 pt while working (it sweeps one turn per 1.6 s); solid green for pasted and copied, orange for an error.";
  return set;
}

/** An orb still the app rendered, if one has been placed in the file. */
function orbStill(page, size, mood) {
  const node = page.findOne((n) => n.name === `orb-still/${size}-${mood}`.toLowerCase());
  if (!node || !("fills" in node)) return null;
  const fill = node.fills.find((f) => f.type === "IMAGE");
  return fill ? fill.imageHash : null;
}

async function buildOrbDisc(page, x, y) {
  const variants = [];
  let images = 0;
  for (const [size, ref] of Object.entries(SIZES)) {
    for (const mood of ["Off", "Idle", "Listening", "Working", "Landed"]) {
      const c = figma.createComponent();
      c.name = `Size=${size}, Mood=${mood}`;
      const d = metric(ref);
      c.resize(d, d);
      c.fills = [];
      const disc = figma.createEllipse();
      disc.name = "Disc";
      disc.resize(d, d);
      const hash = orbStill(page, size, mood === "Off" ? "Idle" : mood);
      if (hash) {
        disc.fills = [{ type: "IMAGE", imageHash: hash, scaleMode: "FILL" }];
        images += 1;
      } else {
        disc.fills = [gradientPaint("orb")];
      }
      if (mood === "Off") {
        await bind(disc, "opacity", "Metrics:opacity/dim");
      }
      c.appendChild(disc);
      await bind(c, "width", `Metrics:${ref}`);
      await bind(c, "height", `Metrics:${ref}`);
      variants.push(c);
    }
  }
  replaceNamed(page, "Orb/Disc", variants[0]);
  const set = finishSet(page, "Orb/Disc", variants, x, y);
  set.description =
    "The orb's fill. A still the app renders (-BlurtOrb <size> <mood>, placed here as orb-still/<size>-<mood>); the brand gradient stands in until one is. Off is Idle dimmed.";
  return { set, images };
}

async function buildWaveformMeter(page, x, y) {
  const variants = [];
  for (const [size, [wRef, hRef]] of Object.entries(WAVES)) {
    const c = figma.createComponent();
    c.name = `Size=${size}`;
    const w = metric(wRef);
    const h = metric(hRef);
    c.resize(w, h);
    c.fills = [];
    c.layoutMode = "HORIZONTAL";
    c.primaryAxisAlignItems = "CENTER";
    c.counterAxisAlignItems = "CENTER";
    c.primaryAxisSizingMode = "FIXED";
    c.counterAxisSizingMode = "FIXED";
    await bind(c, "itemSpacing", "Metrics:wave/gap");
    await bind(c, "width", `Metrics:${wRef}`);
    await bind(c, "height", `Metrics:${hRef}`);
    const bar = metric("wave/bar");
    const gap = metric("wave/gap");
    const count = Math.floor((w + gap) / (bar + gap));
    const level = 0.62;
    for (let i = 0; i < count; i += 1) {
      const t = i / Math.max(count - 1, 1);
      // A schematic of the engine's envelope: a soft hump, minimum 12 %, at the gallery's level.
      const envelope = 0.12 + 0.88 * level * Math.pow(Math.sin(Math.PI * t), 0.45);
      const capsule = figma.createRectangle();
      capsule.name = "Bar";
      capsule.resize(bar, Math.max(bar, h * envelope));
      capsule.cornerRadius = bar / 2;
      await bind(capsule, "width", "Metrics:wave/bar");
      capsule.fills = [await paint("Keyboard:kb/signal")];
      c.appendChild(capsule);
    }
    variants.push(c);
  }
  replaceNamed(page, "WaveformMeter", variants[0]);
  const set = finishSet(page, "WaveformMeter", variants, x, y);
  set.description =
    "The thin wave: 2 pt bars 2 pt apart, flat on the surface, no container. Heights are the engine's (MeterBarGeometry); this is the schematic at level 0.62 — fidelity frames use app captures.";
  return set;
}

const MIC_STATES = ["Off", "Idle", "Working", "Recording", "Pasted", "Copied", "Error"];

async function buildMicKey(page, x, y) {
  const disc = await findComponentSet(page, "Orb/Disc");
  const ring = await findComponentSet(page, "Orb/Ring");
  const meter = await findComponentSet(page, "WaveformMeter");
  if (!disc || !ring || !meter) throw new Error("build Orb/Disc, Orb/Ring and WaveformMeter first");
  const pick = (set, props) =>
    set.children.find((c) => Object.entries(props).every(([k, v]) => c.name.includes(`${k}=${v}`)));
  const variants = [];
  for (const [size, ref] of Object.entries(SIZES)) {
    for (const state of MIC_STATES) {
      const c = figma.createComponent();
      c.name = `Size=${size}, State=${state}`;
      const d = metric(ref);
      const [wRef] = WAVES[size];
      c.resize(Math.max(metric(wRef), d), d);
      c.fills = [];
      c.layoutMode = "HORIZONTAL";
      c.primaryAxisAlignItems = "CENTER";
      c.counterAxisAlignItems = "CENTER";
      c.primaryAxisSizingMode = "FIXED";
      c.counterAxisSizingMode = "FIXED";
      await bind(c, "height", `Metrics:${ref}`);
      if (state === "Recording") {
        c.appendChild(pick(meter, { Size: size }).createInstance());
      } else {
        const stack = figma.createFrame();
        stack.name = "Orb";
        stack.resize(d, d);
        stack.fills = [];
        stack.clipsContent = false;
        const mood = { Off: "Off", Idle: "Idle", Working: "Working", Pasted: "Landed", Copied: "Idle", Error: "Idle" }[state];
        const kind = { Off: "Still", Idle: "Still", Working: "Working", Pasted: "Ok", Copied: "Ok", Error: "Error" }[state];
        const discInstance = pick(disc, { Size: size, Mood: mood }).createInstance();
        discInstance.name = "Disc";
        stack.appendChild(discInstance);
        const ringInstance = pick(ring, { Size: size, Kind: kind }).createInstance();
        ringInstance.name = "Ring";
        stack.appendChild(ringInstance);
        if (state === "Copied" || state === "Error") {
          const glyph = await textNode(
            state === "Copied" ? symbolChar("doc.on.clipboard", "⎘") : symbolChar("exclamationmark", "!"),
            { size: d * token("Typography", "ratio/orb-glyph").value, weight: FONT.semibold }
          );
          glyph.name = "Glyph";
          glyph.fills = [{ type: "SOLID", color: { r: 1, g: 1, b: 1 } }];
          stack.appendChild(glyph);
          glyph.x = (d - glyph.width) / 2;
          glyph.y = (d - glyph.height) / 2;
        }
        if (state === "Off") await bind(stack, "opacity", "Metrics:opacity/dim");
        c.appendChild(stack);
      }
      variants.push(c);
    }
  }
  replaceNamed(page, "MicKey", variants[0]);
  const set = finishSet(page, "MicKey", variants, x, y);
  set.description =
    "The mic key is the orb, and it says everything without a word: dimmed when Blurt isn't ready; ring sweeping while connecting and transcribing; dissipated into the wave while recording; a green ring when the words landed (with the drop), a clipboard on green when they went to the clipboard, orange and ! for an error.";
  return set;
}

async function buildVoiceBar(page, x, y) {
  const mic = await findComponentSet(page, "MicKey");
  const addTerm = await findComponentSet(page, "AddTermKey");
  const termField = await findComponent(page, "TermField");
  if (!mic || !addTerm || !termField) throw new Error("build MicKey, AddTermKey and TermField first");
  const pick = (set, props) =>
    set.children.find((c) => Object.entries(props).every(([k, v]) => c.name.includes(`${k}=${v}`)));
  const variants = [];
  for (const mode of ["Orb", "Wave", "Term", "NoFullAccess"]) {
    const c = figma.createComponent();
    c.name = `Mode=${mode}`;
    c.layoutMode = "HORIZONTAL";
    c.primaryAxisAlignItems = mode === "NoFullAccess" ? "MIN" : "CENTER";
    c.counterAxisAlignItems = "CENTER";
    c.primaryAxisSizingMode = "FIXED";
    c.counterAxisSizingMode = "FIXED";
    c.resize(DEVICE_WIDTH - 2 * metric("margin/side"), metric("voicebar/height"));
    await bind(c, "height", "Metrics:voicebar/height");
    c.fills = [];
    c.clipsContent = false;
    if (mode === "Term") {
      const f = termField.createInstance();
      c.appendChild(f);
      f.layoutSizingHorizontal = "FILL";
    } else if (mode === "NoFullAccess") {
      await bind(c, "itemSpacing", "Metrics:voicebar/note-gap");
      c.appendChild(pick(mic, { Size: "Bar", State: "Off" }).createInstance());
      const note = await textNode("Allow Full Access in Settings → Keyboards", {
        size: 13,
        fillRef: "Keyboard:kb/full-access-note",
      });
      note.name = "Note";
      c.appendChild(note);
    } else {
      c.appendChild(pick(mic, { Size: "Bar", State: mode === "Wave" ? "Recording" : "Idle" }).createInstance());
      const plus = pick(addTerm, { Saved: "False" }).createInstance();
      c.appendChild(plus);
      plus.layoutPositioning = "ABSOLUTE";
      plus.constraints = { horizontal: "MAX", vertical: "CENTER" };
      plus.x = c.width - plus.width;
      plus.y = (c.height - plus.height) / 2;
    }
    variants.push(c);
  }
  replaceNamed(page, "VoiceBar", variants[0]);
  const set = finishSet(page, "VoiceBar", variants, x, y);
  set.description =
    "The keyboard's voice row, and the only place voice lives: the orb (the mic key) dissipating into the wave while recording; the + for a key term; the field the keys type into; the one line of words, without Full Access.";
  return set;
}

async function buildComponents() {
  await ensureTokens();
  const page = await getPage(PAGES.components);
  VARS = await variableMap();
  await loadFonts();
  const built = {};
  let y = 0;
  const step = 360;
  built.key = (await buildKeySet(page, 0, y)).id;
  built.letterKey = (await buildLetterKeySet(page, 0, (y += step))).id;
  built.addTermKey = (await buildAddTermKey(page, 0, (y += step))).id;
  built.cancelKey = (await buildCancelKey(page, 400, y)).id;
  built.termField = (await buildTermField(page, 0, (y += step))).id;
  built.orbRing = (await buildOrbRing(page, 0, (y += step))).id;
  const disc = await buildOrbDisc(page, 0, (y += step));
  built.orbDisc = disc.set.id;
  built.orbStillsUsed = disc.images;
  built.waveformMeter = (await buildWaveformMeter(page, 0, (y += step))).id;
  built.micKey = (await buildMicKey(page, 0, (y += step))).id;
  built.voiceBar = (await buildVoiceBar(page, 0, (y += step))).id;
  return { page: page.id, built };
}
