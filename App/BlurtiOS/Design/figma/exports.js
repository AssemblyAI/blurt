/* global figma, getPage, PAGES */
// ---------------------------------------------------------------------------
// Export: the variables back out as tokens.json's groups

async function exportTokens() {
  const collections = await figma.variables.getLocalVariableCollectionsAsync();
  const byId = new Map(collections.map((c) => [c.id, c]));
  const all = await figma.variables.getLocalVariablesAsync();
  const byVarId = new Map(all.map((v) => [v.id, v]));
  const groupOf = { Brand: "brand", Themes: "themes", Keyboard: "keyboard", Metrics: "metrics", Typography: "type", Motion: "motion" };
  const out = {};
  for (const v of all) {
    const c = byId.get(v.variableCollectionId);
    const group = c && groupOf[c.name];
    if (!group) continue;
    const modeId = c.modes[0].modeId;
    let raw = v.valuesByMode[modeId];
    let value;
    if (raw && typeof raw === "object" && raw.type === "VARIABLE_ALIAS") {
      const target = byVarId.get(raw.id);
      const tc = byId.get(target.variableCollectionId);
      value = `{${groupOf[tc.name]}.${target.name}}`;
    } else if (raw && typeof raw === "object" && "r" in raw) {
      const hex = [raw.r, raw.g, raw.b].map((x) => Math.round(x * 255).toString(16).padStart(2, "0")).join("");
      value = `#${hex.toUpperCase()}`;
    } else {
      value = raw;
    }
    out[group] = out[group] || {};
    out[group][v.name] = v.description ? { value, use: v.description } : { value };
  }
  return { tokens: out, note: "merge into App/BlurtiOS/Design/tokens.json (keep gradients and figma), then scripts/design-sync.sh" };
}

/** The absolute bounds of every named node under the layout frames, in points. */
async function exportBounds() {
  const page = await getPage(PAGES.layouts);
  const frames = page.findAll((n) => n.type === "FRAME" && /^(panel|slimBar|full)\//.test(n.name));
  const bounds = {};
  for (const frame of frames) {
    const origin = frame.absoluteBoundingBox;
    bounds[frame.name] = {};
    for (const node of frame.findAll((n) => n.name && n.absoluteBoundingBox)) {
      const b = node.absoluteBoundingBox;
      bounds[frame.name][node.name] = {
        x: +(b.x - origin.x).toFixed(2),
        y: +(b.y - origin.y).toFixed(2),
        w: +b.width.toFixed(2),
        h: +b.height.toFixed(2),
        type: node.type,
      };
    }
  }
  return { frames: frames.length, bounds };
}
