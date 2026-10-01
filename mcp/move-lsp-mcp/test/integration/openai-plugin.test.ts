/**
 * Exercise the shipped OpenAI package, not the development source server.
 * A marketplace installation has no node_modules and need not share a cwd
 * with the user's Move project. Missing toolchains must not prevent discovery.
 */
import { afterAll, beforeAll, describe, expect, it } from 'vitest';
import { cpSync, existsSync, mkdirSync, mkdtempSync, readFileSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { Client } from '@modelcontextprotocol/sdk/client/index.js';
import { StdioClientTransport } from '@modelcontextprotocol/sdk/client/stdio.js';

const repository = resolve(dirname(fileURLToPath(import.meta.url)), '../../../..');
const manifestPath = '.codex-plugin/plugin.json';
const manifest = JSON.parse(readFileSync(join(repository, manifestPath), 'utf8'));

describe('OpenAI plugin with local MCP servers', () => {
  let temporaryRoot: string;
  let installedRoot: string;
  let projectRoot: string;

  beforeAll(() => {
    temporaryRoot = mkdtempSync(join(tmpdir(), 'sui-pilot install '));
    installedRoot = join(temporaryRoot, 'plugin cache', 'sui-pilot');
    projectRoot = join(temporaryRoot, 'user project');
    mkdirSync(join(installedRoot, '.codex-plugin'), { recursive: true });
    cpSync(join(repository, manifestPath), join(installedRoot, manifestPath));
    for (const server of ['move-lsp-mcp', 'sui-prover-mcp']) {
      const relativeRoot = join('mcp', server);
      mkdirSync(join(installedRoot, relativeRoot), { recursive: true });
      cpSync(join(repository, relativeRoot, 'package.json'), join(installedRoot, relativeRoot, 'package.json'));
      cpSync(join(repository, relativeRoot, 'dist'), join(installedRoot, relativeRoot, 'dist'), { recursive: true });
    }
    cpSync(join(repository, 'mcp/sui-prover-mcp/test/fixtures/tiny'), projectRoot, { recursive: true });
  });

  afterAll(() => {
    if (temporaryRoot) rmSync(temporaryRoot, { recursive: true, force: true });
  });

  async function withServer(name: string, run: (client: Client) => Promise<void>) {
    const config = manifest.mcpServers[name];
    // Codex resolves a relative plugin MCP cwd against the installed root.
    // Use the manifest's entrypoint verbatim so broken paths fail at startup.
    expect(config.command).toBe('node');
    expect(config.url).toBeUndefined();
    expect(config.cwd).toBeDefined();
    expect(existsSync(join(installedRoot, 'node_modules'))).toBe(false);
    expect(existsSync(join(installedRoot, 'mcp', `${name}-mcp`, 'node_modules'))).toBe(false);
    const client = new Client({ name: 'sui-pilot-package-test', version: '1.0.0' });
    const transport = new StdioClientTransport({
      // Use this test runner's Node binary; no global package launcher needed.
      command: process.execPath,
      args: config.args,
      cwd: resolve(installedRoot, config.cwd),
      // No Claude variables or external toolchain binaries. Startup and
      // local file tools should remain usable on a fresh machine.
      env: { PATH: temporaryRoot },
      stderr: 'pipe',
    });
    let stderr = '';
    transport.stderr?.on('data', (chunk) => { stderr += chunk.toString(); });
    try {
      await client.connect(transport);
      await run(client);
    } catch (error) {
      throw new Error(`${name}: ${String(error)}\n${stderr}`);
    } finally {
      await client.close();
    }
  }

  it('discovers all local LSP tools from the relocated, prebuilt package', async () => {
    await withServer('move-lsp', async (client) => {
      const { tools } = await client.listTools();
      expect(tools.map((tool) => tool.name).sort()).toEqual([
        'move_code_actions', 'move_completions', 'move_diagnostics',
        'move_document_symbols', 'move_find_references', 'move_goto_definition',
        'move_hover', 'move_inlay_hints', 'move_rename', 'move_type_definition',
      ]);
      const result = await client.callTool({
        name: 'move_diagnostics',
        arguments: { filePath: join(projectRoot, 'sources/tiny.move') },
      });
      // An unavailable analyzer is a tool failure, never fake diagnostics.
      expect(result.isError).toBe(true);
      expect(JSON.stringify(result.content)).toMatch(/BINARY_NOT_FOUND|move-analyzer/i);
    });
  }, 15000);

  it('rejects project-relative paths for every LSP tool before touching the plugin cwd', async () => {
    await withServer('move-lsp', async (client) => {
      const { tools } = await client.listTools();
      for (const tool of tools) {
        expect(tool.inputSchema.properties?.filePath).toMatchObject({
          description: expect.stringContaining('Absolute path'),
        });
        for (const content of [undefined, 'module tiny::tiny {}']) {
          const result = await client.callTool({
            name: tool.name,
            arguments: {
              filePath: 'sources/tiny.move', content,
              line: 0, character: 0, startLine: 0, startCharacter: 0,
              endLine: 1, endCharacter: 0, newName: 'renamed',
            },
          });
          expect(result.isError).toBe(true);
          const parsed = JSON.parse((result.content as Array<{ text: string }>)[0].text);
          expect(parsed.error.code).toBe('INVALID_FILE_PATH');
          expect(parsed.error.message).toContain('user project');
          expect(parsed.workspaceRoot).toBeNull();
        }
      }
    });
  }, 15000);

  it('discovers prover tools and reads a separate local project without a prover binary', async () => {
    await withServer('sui-prover', async (client) => {
      const { tools } = await client.listTools();
      expect(tools.map((tool) => tool.name).sort()).toEqual([
        'list_specs', 'prove_package', 'prover_capabilities',
      ]);
      const result = await client.callTool({ name: 'list_specs', arguments: { path: projectRoot } });
      expect(result.isError).not.toBe(true);
      const content = result.content as Array<{ type: string; text: string }>;
      const parsed = JSON.parse(content.find((item) => item.type === 'text')!.text);
      expect(parsed.package_path).toBe(projectRoot);
      expect(parsed.files_scanned).toBe(1);
      expect(parsed.specs.length).toBeGreaterThan(0);
      for (const spec of parsed.specs) {
        expect(spec.file).toBe(join(projectRoot, 'sources/tiny.move'));
      }
    });
  }, 15000);
});
