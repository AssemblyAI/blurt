/* global figma, TOKENS, getPage, getSection, variableMap, hexToRGB, loadFonts, FONT, metric, autoLayout, textNode, paint, gradientPaint, VARS */
// ---------------------------------------------------------------------------
// Foundations: variables, styles, specimens

async function buildFoundations() {
  if (!TOKENS) throw new Error("buildFoundations needs tokens.js in the call (scripts/design-figma-call.sh foundations)");
  const page = await getPage(PAGES.foundations);
  const existingCollections = await figma.variables.getLocalVariableCollectionsAsync();
  const created = { collections: 0, variables: 0, aliases: 0, textStyles: 0, effectStyles: 0 };
  const collections = {};
  for (const name of TOKENS.groups) {
    let c = existingCollections.find((x) => x.name === name);
    if (!c) {
      c = figma.variables.createVariableCollection(name);
      created.collections += 1;
    }
    c.renameMode(c.modes[0].modeId, TOKENS.collections[name].mode);
    collections[name] = c;
  }
  VARS = await variableMap();
  // Concrete values first, aliases second, so a target always exists.
  for (const pass of ["values", "aliases"]) {
    for (const name of TOKENS.groups) {
      const c = collections[name];
      const modeId = c.modes[0].modeId;
      for (const spec of TOKENS.collections[name].variables) {
        if ((pass === "aliases") !== Boolean(spec.alias)) continue;
        const key = `${name}:${spec.name}`;
        let v = VARS.get(key);
        if (!v) {
          v = figma.variables.createVariable(spec.name, c, spec.type);
          VARS.set(key, v);
          created.variables += 1;
        }
        if (spec.alias) {
          const target = VARS.get(spec.alias);
          if (!target) throw new Error(`${key} aliases ${spec.alias}, which is missing`);
          v.setValueForMode(modeId, figma.variables.createVariableAlias(target));
          created.aliases += 1;
        } else if (spec.type === "COLOR") {
          v.setValueForMode(modeId, { ...hexToRGB(spec.value), a: 1 });
        } else {
          v.setValueForMode(modeId, spec.value);
        }
        v.scopes = spec.scopes;
        v.description = spec.use || "";
        v.setVariableCodeSyntax("iOS", spec.codeSyntax);
      }
    }
  }

  await loadFonts();
  const sizes = Object.fromEntries(
    TOKENS.collections.Typography.variables.filter((v) => v.name.startsWith("size/")).map((v) => [v.name.slice(5), v.value])
  );
  const weights = Object.fromEntries(
    TOKENS.collections.Typography.variables.filter((v) => v.name.startsWith("weight/")).map((v) => [v.name.slice(7), v.value])
  );
  const weightStyle = { regular: FONT.regular, medium: FONT.medium, semibold: FONT.semibold };
  const textStyleSpecs = [
    ["Key/Letter", sizes.letter, weights.letter],
    ["Key/Legend", sizes.legend, weights.legend],
    ["Key/Popup", sizes.popup, weights.popup],
    ["Term/Text", sizes.term, weights.term],
    ["Glyph", sizes.glyph, weights.glyph],
  ];
  const textStyles = await figma.getLocalTextStylesAsync();
  for (const [name, size, weight] of textStyleSpecs) {
    let s = textStyles.find((x) => x.name === name);
    if (!s) {
      s = figma.createTextStyle();
      s.name = name;
      created.textStyles += 1;
    }
    s.fontName = { family: FONT.family, style: weightStyle[weight] };
    s.fontSize = size;
  }
  // The two gradients as paint styles, so a later call can draw them without
  // carrying the token data (core.js › gradientPaint falls back to these).
  const paintStyles = await figma.getLocalPaintStylesAsync();
  for (const name of Object.keys(TOKENS.gradients)) {
    let ps = paintStyles.find((x) => x.name === `Gradient/${name}`);
    if (!ps) {
      ps = figma.createPaintStyle();
      ps.name = `Gradient/${name}`;
      created.paintStyles = (created.paintStyles || 0) + 1;
    }
    ps.paints = [gradientPaint(name)];
    ps.description = TOKENS.gradients[name].use || "";
  }
  const effectStyles = await figma.getLocalEffectStylesAsync();
  let shadow = effectStyles.find((x) => x.name === "Shadow/Popup");
  if (!shadow) {
    shadow = figma.createEffectStyle();
    shadow.name = "Shadow/Popup";
    created.effectStyles += 1;
  }
  // Figma's blur is about twice SwiftUI's shadow radius; the generator's
  // DESIGN.md note says the same, so the two stay one number apart on purpose.
  shadow.effects = [
    {
      type: "DROP_SHADOW",
      color: { r: 0, g: 0, b: 0, a: metric("opacity/popup-shadow") },
      offset: { x: 0, y: metric("popup/shadow-y") },
      radius: metric("popup/shadow-radius") * 2,
      spread: 0,
      visible: true,
      blendMode: "NORMAL",
    },
  ];

  // Specimens: swatches for every colour, a line per number, all bound.
  const ids = [];
  const colours = getSection(page, "Colour", 0, 0);
  const grid = autoLayout("VERTICAL", { name: "Swatches", itemSpacing: 8 });
  for (const name of ["Brand", "Themes", "Keyboard"]) {
    const row = autoLayout("VERTICAL", { name, itemSpacing: 4 });
    row.appendChild(await textNode(name, { size: 14, weight: FONT.medium, fillRef: "Brand:ink" }));
    const wrap = autoLayout("HORIZONTAL", { name: `${name} swatches`, itemSpacing: 8 });
    wrap.layoutWrap = "WRAP";
    wrap.counterAxisSpacing = 8;
    wrap.resize(1200, 10);
    wrap.primaryAxisSizingMode = "FIXED";
    for (const spec of TOKENS.collections[name].variables) {
      const cell = autoLayout("VERTICAL", { name: spec.name, itemSpacing: 2 });
      const swatch = figma.createRectangle();
      swatch.resize(64, 40);
      swatch.cornerRadius = 4;
      swatch.fills = [await paint(`${name}:${spec.name}`)];
      cell.appendChild(swatch);
      cell.appendChild(await textNode(spec.name, { size: 9, fillRef: "Brand:ink" }));
      cell.appendChild(await textNode(spec.value, { size: 9, fillRef: "Brand:ink" }));
      wrap.appendChild(cell);
    }
    row.appendChild(wrap);
    grid.appendChild(row);
  }
  const oldGrid = colours.children.find((n) => n.name === "Swatches");
  if (oldGrid) oldGrid.remove();
  colours.appendChild(grid);
  colours.resizeWithoutConstraints(grid.width + 80, grid.height + 80);
  grid.x = 40;
  grid.y = 40;
  ids.push(grid.id);

  const numbers = getSection(page, "Numbers", 0, colours.height + 80);
  const list = autoLayout("VERTICAL", { name: "Tokens", itemSpacing: 2 });
  for (const name of ["Metrics", "Typography", "Motion"]) {
    list.appendChild(await textNode(name, { size: 14, weight: FONT.medium, fillRef: "Brand:ink" }));
    for (const spec of TOKENS.collections[name].variables) {
      list.appendChild(
        await textNode(`${spec.name} = ${spec.value}  ·  ${spec.codeSyntax}${spec.use ? "  —  " + spec.use : ""}`, {
          size: 10,
          fillRef: "Brand:ink",
        })
      );
    }
  }
  const oldList = numbers.children.find((n) => n.name === "Tokens");
  if (oldList) oldList.remove();
  numbers.appendChild(list);
  numbers.resizeWithoutConstraints(list.width + 80, list.height + 80);
  list.x = 40;
  list.y = 40;
  ids.push(list.id);

  const recipe = getSection(page, "Orb recipe", colours.width + 80, 0);
  const note = await textNode(
    [
      "The orb is the one thing Figma does not draw. It is a 3 × 3 MeshGradient whose edge midpoints and centre",
      "drift on slow sines (further with the voice), under a soft upper-left light (opacity/orb-light,",
      "orb/light-x, orb/light-y, orb/light-radius) and film grain (opacity/grain; a seeded scatter of 1 pt dots,",
      "one per 26 pt²). The words landing pours cobolt in from the centre (drop, drop-rise, drop-hold) with six",
      "four-point sparkles. Orb/Disc's fills are stills the app renders (-BlurtOrb <size> <mood>); the",
      "parameters above are the variables. Source: App/BlurtiOS/BlurtKeyboard/Sources/PrismOrb.swift.",
    ].join("\n"),
    { size: 11, fillRef: "Brand:ink" }
  );
  note.textAutoResize = "HEIGHT";
  note.resize(720, 10);
  const oldNote = recipe.children.find((n) => n.type === "TEXT");
  if (oldNote) oldNote.remove();
  recipe.appendChild(note);
  recipe.resizeWithoutConstraints(800, note.height + 80);
  note.x = 40;
  note.y = 40;

  return { page: page.id, created, specimenIds: ids, variables: VARS.size };
}
