/**
 * Integration test: spawn the real sui-prover binary against the
 * `tiny` fixture and assert the wrapper returns the expected JSON
 * shape and a successful proof. Skipped when the binary is not available
 * so CI without sui-prover does not fail.
 *
 * Requires a compatible prover/framework, Boogie, and Z3. Environment
 * failures must fail this test rather than masquerade as a successful
 * proof with zero failed specs. The mock suite covers error responses.
 * SUI_PROVER_FRAMEWORK_PATH can select framework sources matching the
 * installed binary when upstream's moving branches have diverged.
 */

import { describe, it, expect } from 'vitest';
import { join, dirname } from 'path';
import { fileURLToPath } from 'url';
import { cpSync, mkdtempSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { discoverBinary } from '../../src/binary.js';
import { prove } from '../../src/prove.js';
import { listSpecs } from '../../src/list-specs.js';
import { capabilities } from '../../src/capabilities.js';

const __dirname = dirname(fileURLToPath(import.meta.url));
const FIXTURE = join(__dirname, '..', 'fixtures', 'tiny');

const hasBinary = discoverBinary() !== null;

describe('integration: sui-prover MCP wrapper', () => {
  it('list_specs finds the colocated spec in the fixture', () => {
    const result = listSpecs(FIXTURE);
    expect(result.files_scanned).toBeGreaterThan(0);
    expect(result.specs).toHaveLength(1);
    expect(result.specs[0]!.function_name).toBe('safe_increment_spec');
    expect(result.specs[0]!.attrs).toContain('prove');
  });

  it('prover_capabilities reports binary state and Move.toml setup', () => {
    const caps = capabilities({ move_toml_path: FIXTURE });
    expect(caps.binary.found).toBe(hasBinary);
    expect(caps.setup_warnings.find((w) => w.kind === 'missing_movetoml')).toBeUndefined();
    // Tiny fixture has no explicit Sui/MoveStdlib deps.
    expect(caps.setup_warnings.find((w) => w.kind === 'explicit_framework_dep')).toBeUndefined();
  });

  // Round-trip the wrapper's prove() against the tiny fixture. Skipped
  // when the binary is missing OR when SKIP_PROVER_NETWORK=1 is set --
  // the first invocation on a fresh checkout clones the sui-prover Move
  // dep into ~/.move and downloads framework crates (a one-off ~30-60s
  // cost). CI without network or with a stricter time budget should
  // export SKIP_PROVER_NETWORK=1.
  const itIfWarm =
    hasBinary && process.env['SKIP_PROVER_NETWORK'] !== '1' ? it : it.skip;

  itIfWarm(
    'prove() returns the structured response shape /specify consumes',
    async () => {
      // Never reuse generated Move.lock/build state: the lock can retain
      // old git dependencies even after SUI_PROVER_FRAMEWORK_PATH changes.
      const project = mkdtempSync(join(tmpdir(), 'sui-prover-live-'));
      try {
        cpSync(join(FIXTURE, 'Move.toml'), join(project, 'Move.toml'));
        cpSync(join(FIXTURE, 'sources'), join(project, 'sources'), { recursive: true });
        const result = await prove({ path: project, timeout_seconds: 90 });
        expect(result.binary.path).toMatch(/sui-prover$/);
        expect(result.binary.version).toMatch(/^\d+\.\d+\.\d+/);
        expect(result.package.name).toBe('tiny');
        expect(result.package.edition).toMatch(/^2024/);
        expect(result.invocation.args).toContain('--path');
        expect(result.invocation.args).toContain('--timeout');
        expect(typeof result.invocation.duration_ms).toBe('number');
        expect(result.invocation.duration_ms).toBeGreaterThan(0);
        expect(Array.isArray(result.findings)).toBe(true);
        expect(typeof result.raw_stdout).toBe('string');
        expect(typeof result.raw_stderr).toBe('string');
        expect(result.invocation.exit_code, result.raw_stderr || result.raw_stdout).toBe(0);
        expect(result.summary.overall).toBe('verified_all');
        expect(result.summary.verified).toBeGreaterThan(0);
        expect(result.summary.failed).toBe(0);
      } finally {
        rmSync(project, { recursive: true, force: true });
      }
    },
    180_000
  );
});
