import { mkdir } from "node:fs/promises";
import path from "node:path";
import sharp from "sharp";

const root = path.resolve("public/characters/_placeholder");
const states = {
  idle: [{ y: 0, eye: 1 }, { y: -2, eye: 1 }, { y: 0, eye: 1 }],
  blink: [{ y: 0, eye: 1 }, { y: 0, eye: 0.12 }, { y: 0, eye: 1 }],
  walk: [{ y: 0, lean: -4 }, { y: -4, lean: 4 }, { y: 0, lean: -4 }, { y: -4, lean: 4 }],
  sleep: [{ y: 4, eye: 0.12 }, { y: 6, eye: 0.12 }, { y: 4, eye: 0.12 }],
  click: [{ y: 0 }, { y: 7, squash: 1.1 }, { y: -7, squash: 0.92 }, { y: 0 }],
  drag: [{ y: -8, eye: 0.7 }],
  land: [{ y: -10 }, { y: 9, squash: 1.13 }, { y: 0 }],
  happy: [{ y: 0 }, { y: -10, lean: -7 }, { y: -14, lean: 7 }, { y: -7 }, { y: 0 }],
};

function svg({ y = 0, eye = 1, lean = 0, squash = 1 }) {
  const bodyHeight = 104 / squash;
  const bodyY = 88 + y + (104 - bodyHeight);
  return `<svg xmlns="http://www.w3.org/2000/svg" width="256" height="256" viewBox="0 0 256 256">
    <g transform="rotate(${lean} 128 204)">
      <rect x="54" y="${bodyY}" width="148" height="${bodyHeight}" rx="36" fill="#65708a" stroke="#d9deea" stroke-width="7"/>
      <rect x="76" y="109" width="104" height="48" rx="13" fill="#252c3b"/>
      <ellipse cx="105" cy="132" rx="8" ry="${Math.max(1, 10 * eye)}" fill="#92e7ff"/>
      <ellipse cx="151" cy="132" rx="8" ry="${Math.max(1, 10 * eye)}" fill="#92e7ff"/>
      <path d="M106 172 H150" stroke="#d9deea" stroke-width="6" stroke-linecap="round"/>
      <path d="M78 194 v20 M178 194 v20" stroke="#d9deea" stroke-width="10" stroke-linecap="round"/>
      <circle cx="47" cy="145" r="14" fill="#ffbc58"/><circle cx="209" cy="145" r="14" fill="#ffbc58"/>
      <text x="128" y="78" text-anchor="middle" font-family="Arial,sans-serif" font-weight="700" font-size="20" fill="#ffffff">DEV</text>
    </g>
  </svg>`;
}

for (const [state, frames] of Object.entries(states)) {
  const directory = path.join(root, "animations", state);
  await mkdir(directory, { recursive: true });
  for (let index = 0; index < frames.length; index += 1) {
    const filename = `${state}_${String(index + 1).padStart(4, "0")}.png`;
    await sharp(Buffer.from(svg(frames[index]))).png().toFile(path.join(directory, filename));
  }
}

await sharp(Buffer.from(svg(states.idle[0]))).png().toFile(path.join(root, "preview.png"));
await sharp(Buffer.from(svg(states.idle[0]))).resize(128, 128).png().toFile(path.join(root, "icon.png"));
await mkdir(path.resolve("src-tauri/icons"), { recursive: true });
await sharp(Buffer.from(svg(states.idle[0]))).resize(512, 512).png().toFile(path.resolve("src-tauri/icons/icon.png"));
console.log("Generated neutral geometric placeholder PNG frames.");

