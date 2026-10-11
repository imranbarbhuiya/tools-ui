import { mkdtempSync, mkdirSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { dirname, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { spawnSync } from 'node:child_process';
import { createHash } from 'node:crypto';

const root = resolve(dirname(fileURLToPath(import.meta.url)), '..');
const source = resolve(process.argv[2] ?? resolve(root, '../neural-logline'));
const destination = resolve(root, 'Sources/ToolsUI/Resources');
const temporary = mkdtempSync(resolve(tmpdir(), 'toolsui-log-model-'));
mkdirSync(destination, { recursive: true });
try {
  const entry = resolve(temporary, 'model.ts');
  writeFileSync(entry, `import { parse } from ${JSON.stringify(resolve(source, 'src/index.ts'))};
globalThis.__toolsuiParseLog = (line) => {
  const result = parse(line);
  return {
    message: result.message.text,
    messageConfidence: result.message.confidence,
    level: result.level?.normalized ?? '',
    source: result.source?.text ?? '',
    sourceConfidence: result.source?.confidence ?? 0,
    timestamp: result.timestamp?.text ?? '',
    confidence: result.confidence,
  };
};
`);
  const output = resolve(destination, 'neural-logline.js');
  const build = spawnSync('bun', ['build', entry, '--target=browser', '--format=iife', '--minify', '--outfile', output], { stdio: 'inherit' });
  if (build.status !== 0) throw new Error('Could not bundle neural-logline');
  const metadata = JSON.parse(readFileSync(resolve(source, 'package.json'), 'utf8'));
  const hash = createHash('sha256').update(readFileSync(resolve(source, 'src/weights.ts'))).digest('hex');
  writeFileSync(resolve(destination, 'NOTICE-neural-logline.txt'), `neural-logline ${metadata.version}\nhttps://github.com/imranbarbhuiya/neural-logline\nWeights SHA-256: ${hash}\nBundled for offline JavaScriptCore inference. Training and evaluation use synthetic data; this model is a fallback for unfamiliar single-line log headers.\n\n${readFileSync(resolve(source, 'LICENSE'), 'utf8')}`);
} finally {
  rmSync(temporary, { recursive: true, force: true });
}
