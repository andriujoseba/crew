/* gif.js — animated GIF89a from a list of PNGs. No dependencies.
 *
 *   node gif.js <out.gif> <w> <delay-cs> <label:png> [label:png ...]
 *
 * Written by hand because there is nothing here to do it with: playwright's
 * bundled ffmpeg is compiled without a gif muxer or encoder (it ships png,
 * image2 and libvpx only), there is no PIL, and no pip to get one. So: decode
 * and scale the frames in a headless canvas, median-cut a single global
 * palette across every frame, and LZW them into a GIF by hand.
 *
 * One global palette rather than one per frame, because the whole point of
 * these is comparing frame N against frame N-1 — a per-frame palette would let
 * the quantiser shift colours between loops and invent differences the code
 * never made.
 */
const { chromium } = require('playwright-core');
const fs = require('fs');
const path = require('path');
const CHROME = process.env.PW_CHROME
  || process.env.HOME + '/.cache/ms-playwright/chromium-1234/chrome-linux64/chrome';

const [, , OUT, WARG, DARG, ...PAIRS] = process.argv;
if (!OUT || !PAIRS.length) { console.error('usage: gif.js <out.gif> <w> <delay-cs> <label:png>...'); process.exit(2); }
const W = Number(WARG) || 560, DELAY = Number(DARG) || 90;

/* ---------- median cut over a 5-bit histogram ---------- */
function quantize(frames, n) {
  const hist = new Map();
  for (const f of frames)
    for (let i = 0; i < f.length; i += 4) {
      const k = ((f[i] >> 3) << 10) | ((f[i + 1] >> 3) << 5) | (f[i + 2] >> 3);
      hist.set(k, (hist.get(k) || 0) + 1);
    }
  let boxes = [[...hist.keys()]];
  const spread = (box) => {
    let lo = [255, 255, 255], hi = [0, 0, 0];
    for (const k of box) {
      const c = [(k >> 10) & 31, (k >> 5) & 31, k & 31];
      for (let j = 0; j < 3; j++) { if (c[j] < lo[j]) lo[j] = c[j]; if (c[j] > hi[j]) hi[j] = c[j]; }
    }
    return [hi[0] - lo[0], hi[1] - lo[1], hi[2] - lo[2]];
  };
  while (boxes.length < n) {
    // split the box with the largest weighted spread; stop when none can split
    let bi = -1, best = -1;
    for (let i = 0; i < boxes.length; i++) {
      if (boxes[i].length < 2) continue;
      const s = spread(boxes[i]), m = Math.max(s[0], s[1], s[2]);
      let w = 0; for (const k of boxes[i]) w += hist.get(k);
      const score = m * Math.log(1 + w);
      if (score > best) { best = score; bi = i; }
    }
    if (bi < 0) break;
    const box = boxes[bi], s = spread(box);
    const ch = s[0] >= s[1] && s[0] >= s[2] ? 10 : s[1] >= s[2] ? 5 : 0;
    box.sort((a, b) => ((a >> ch) & 31) - ((b >> ch) & 31));
    // split at the weighted median, so a big flat area cannot take the whole box
    let total = 0; for (const k of box) total += hist.get(k);
    let acc = 0, cut = 1;
    for (let i = 0; i < box.length; i++) { acc += hist.get(box[i]); if (acc >= total / 2) { cut = Math.max(1, Math.min(i, box.length - 1)); break; } }
    boxes.splice(bi, 1, box.slice(0, cut), box.slice(cut));
  }
  const pal = boxes.map(box => {
    let r = 0, g = 0, b = 0, w = 0;
    for (const k of box) {
      const c = hist.get(k);
      r += (((k >> 10) & 31) * 8 + 4) * c; g += (((k >> 5) & 31) * 8 + 4) * c; b += ((k & 31) * 8 + 4) * c; w += c;
    }
    return w ? [Math.round(r / w), Math.round(g / w), Math.round(b / w)] : [0, 0, 0];
  });
  while (pal.length < n) pal.push([0, 0, 0]);
  // exact lookup for every 15-bit bucket -> nearest palette entry
  const lut = new Uint8Array(32768);
  for (let k = 0; k < 32768; k++) {
    const r = ((k >> 10) & 31) * 8 + 4, g = ((k >> 5) & 31) * 8 + 4, b = (k & 31) * 8 + 4;
    let bd = 1e9, bidx = 0;
    for (let p = 0; p < pal.length; p++) {
      const dr = r - pal[p][0], dg = g - pal[p][1], db = b - pal[p][2];
      const d = dr * dr * 3 + dg * dg * 6 + db * db;   // luma-ish weighting
      if (d < bd) { bd = d; bidx = p; }
    }
    lut[k] = bidx;
  }
  return { pal, lut };
}

/* ---------- GIF LZW ---------- */
function lzw(indexed, minCodeSize) {
  const out = [];
  let buf = 0, bits = 0;
  const emit = (code, len) => {
    buf |= code << bits; bits += len;
    while (bits >= 8) { out.push(buf & 0xff); buf >>>= 8; bits -= 8; }
  };
  const clear = 1 << minCodeSize, eoi = clear + 1;
  let size = minCodeSize + 1, next = eoi + 1, table = new Map();
  emit(clear, size);
  let cur = indexed[0];
  for (let i = 1; i < indexed.length; i++) {
    const k = indexed[i], key = cur * 4096 + k;
    const hit = table.get(key);
    if (hit !== undefined) { cur = hit; continue; }
    emit(cur, size);
    if (next === 4096) { emit(clear, size); table = new Map(); next = eoi + 1; size = minCodeSize + 1; }
    else { if (next >= (1 << size)) size++; table.set(key, next++); }
    cur = k;
  }
  emit(cur, size); emit(eoi, size);
  if (bits > 0) out.push(buf & 0xff);
  return out;
}

const bytes = [];
const u8 = b => bytes.push(b & 0xff);
const u16 = v => { bytes.push(v & 0xff); bytes.push((v >> 8) & 0xff); };
const str = s => { for (let i = 0; i < s.length; i++) bytes.push(s.charCodeAt(i)); };

(async () => {
  const browser = await chromium.launch({ executablePath: CHROME });
  const page = await browser.newPage();
  const frames = [];
  let FW = 0, FH = 0;

  for (const pair of PAIRS) {
    const idx = pair.indexOf(':');
    const label = pair.slice(0, idx), file = pair.slice(idx + 1);
    const src = 'data:image/png;base64,' + fs.readFileSync(file).toString('base64');
    const r = await page.evaluate(async ([s, w, lab]) => {
      const img = await new Promise(res => { const i = new Image(); i.onload = () => res(i); i.src = s; });
      const sc = w / img.width, h = Math.round(img.height * sc);
      const c = document.createElement('canvas'); c.width = w; c.height = h;
      const x = c.getContext('2d');
      x.imageSmoothingEnabled = true; x.imageSmoothingQuality = 'high';
      x.drawImage(img, 0, 0, w, h);
      // caption bar, so the progression is readable without a legend
      x.fillStyle = 'rgba(3,6,13,0.82)'; x.fillRect(0, h - 22, w, 22);
      x.font = '600 12px ui-monospace,monospace';
      x.fillStyle = '#9fd2ff'; x.fillText(lab, 8, h - 7);
      return { d: [...x.getImageData(0, 0, w, h).data], w, h };
    }, [src, W, label]);
    FW = r.w; FH = r.h;
    frames.push(Uint8ClampedArray.from(r.d));
  }
  await browser.close();

  const { pal, lut } = quantize(frames, 256);
  const indexed = frames.map(f => {
    const out = new Uint8Array(FW * FH);
    for (let i = 0, p = 0; i < f.length; i += 4, p++)
      out[p] = lut[((f[i] >> 3) << 10) | ((f[i + 1] >> 3) << 5) | (f[i + 2] >> 3)];
    return out;
  });

  str('GIF89a'); u16(FW); u16(FH);
  u8(0xf7);                       // global table, 256 entries, 8bpp
  u8(0); u8(0);
  for (let i = 0; i < 256; i++) { u8(pal[i][0]); u8(pal[i][1]); u8(pal[i][2]); }
  // Netscape looping extension
  u8(0x21); u8(0xff); u8(11); str('NETSCAPE2.0'); u8(3); u8(1); u16(0); u8(0);

  indexed.forEach((frame, fi) => {
    // hold the last frame longer — it is the one worth reading
    const d = fi === indexed.length - 1 ? DELAY * 4 : (fi === 0 ? DELAY * 2 : DELAY);
    u8(0x21); u8(0xf9); u8(4); u8(0); u16(d); u8(0); u8(0);
    u8(0x2c); u16(0); u16(0); u16(FW); u16(FH); u8(0);
    u8(8);
    const data = lzw(frame, 8);
    for (let i = 0; i < data.length; i += 255) {
      const chunk = data.slice(i, i + 255);
      u8(chunk.length); for (const b of chunk) u8(b);
    }
    u8(0);
  });
  u8(0x3b);

  fs.mkdirSync(path.dirname(OUT), { recursive: true });
  fs.writeFileSync(OUT, Buffer.from(bytes));
  console.log(`  ${(fs.statSync(OUT).size / 1024).toFixed(0).padStart(5)}kb  ${OUT}  (${indexed.length} frames, ${FW}x${FH})`);
})();
