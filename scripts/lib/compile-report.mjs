#!/usr/bin/env node
/**
 * Compile engagement report from wiki structured pages.
 *
 * Reads an engagement page, follows cross-references to targets/techniques/
 * creds/IOCs/remediation, and produces a compiled report.
 *
 * Outputs: HTML (always), DOCX (when pandoc available), or both (--format all).
 */
import { readFileSync, writeFileSync, mkdirSync, existsSync, readdirSync } from 'fs';
import { join, basename, dirname } from 'path';
import { execSync } from 'child_process';
import { parseArgs } from 'util';

const { values: args } = parseArgs({
  options: {
    vault:      { type: 'string', default: '/home/node/vault' },
    engagement: { type: 'string' },
    format:     { type: 'string', default: 'html' },
    output:     { type: 'string', default: './reports' },
  },
});

if (!args.engagement) {
  console.error('--engagement required');
  process.exit(1);
}

const VAULT = args.vault;
const ENGAGEMENT = args.engagement;
const FORMAT = args.format;
const OUTPUT_DIR = join(args.output, ENGAGEMENT);

// ── Frontmatter parser (minimal, no deps) ────────────────────────────────
function parseFrontmatter(content) {
  const match = content.match(/^---\n([\s\S]*?)\n---\n([\s\S]*)$/);
  if (!match) return { meta: {}, body: content };
  const meta = {};
  for (const line of match[1].split('\n')) {
    const m = line.match(/^(\w[\w_]*):\s*(.*)$/);
    if (m) {
      let val = m[2].trim();
      if (val.startsWith('[') && val.endsWith(']')) {
        val = val.slice(1, -1).split(',').map(s => s.trim());
      } else if (val === 'true') val = true;
      else if (val === 'false') val = false;
      meta[m[1]] = val;
    }
  }
  return { meta, body: match[2] };
}

// ── Read a wiki page ─────────────────────────────────────────────────────
function readPage(relPath) {
  const fullPath = join(VAULT, relPath);
  if (!existsSync(fullPath)) return null;
  const content = readFileSync(fullPath, 'utf8');
  return parseFrontmatter(content);
}

// ── Collect pages from a wiki subdirectory ──────────────────────────────
function collectPages(subdir) {
  const dir = join(VAULT, subdir);
  if (!existsSync(dir)) return [];
  return readdirSync(dir)
    .filter(f => f.endsWith('.md'))
    .map(f => {
      const page = readPage(join(subdir, f));
      return page ? { file: f, name: basename(f, '.md'), ...page } : null;
    })
    .filter(Boolean);
}

// ── Markdown to HTML (minimal — no external deps) ────────────────────────
function mdToHtml(md) {
  return md
    .replace(/^### (.+)$/gm, '<h3>$1</h3>')
    .replace(/^## (.+)$/gm, '<h2>$1</h2>')
    .replace(/^# (.+)$/gm, '<h1>$1</h1>')
    .replace(/\*\*(.+?)\*\*/g, '<strong>$1</strong>')
    .replace(/\*(.+?)\*/g, '<em>$1</em>')
    .replace(/`(.+?)`/g, '<code>$1</code>')
    .replace(/^\- (.+)$/gm, '<li>$1</li>')
    .replace(/(<li>.*<\/li>\n?)+/g, m => `<ul>${m}</ul>`)
    .replace(/^\|(.+)\|$/gm, (_, row) => {
      const cells = row.split('|').map(c => c.trim()).filter(Boolean);
      return '<tr>' + cells.map(c => `<td>${c}</td>`).join('') + '</tr>';
    })
    .replace(/(<tr>.*<\/tr>\n?)+/g, m => `<table>${m}</table>`)
    .replace(/\[\[(.+?)\]\]/g, '<em>$1</em>')
    .replace(/\n\n/g, '</p><p>')
    .replace(/^(?!<[hultop])(.+)$/gm, '<p>$1</p>')
    .replace(/<p><\/p>/g, '')
    .replace(/<!--.*?-->/g, '');
}

// ── Build report ─────────────────────────────────────────────────────────
const engPage = readPage(`wiki/engagements/${ENGAGEMENT}.md`);
if (!engPage) {
  console.error(`Engagement not found: wiki/engagements/${ENGAGEMENT}.md`);
  process.exit(1);
}

const targets    = collectPages('wiki/targets');
const techniques = collectPages('wiki/techniques');
const creds      = collectPages('wiki/creds');
const iocs       = collectPages('wiki/iocs');
const remediation = collectPages('wiki/remediation');
const purple     = collectPages('wiki/purple');

const date = new Date().toISOString().slice(0, 10);
const title = engPage.meta.name || ENGAGEMENT;

// ── HTML template ────────────────────────────────────────────────────────
const html = `<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>${title} — Engagement Report</title>
<style>
  :root { --fg: #1a1a2e; --bg: #fafafa; --accent: #0f3460; --border: #ddd; }
  @media (prefers-color-scheme: dark) {
    :root { --fg: #e0e0e0; --bg: #1a1a2e; --accent: #4cc9f0; --border: #333; }
  }
  * { box-sizing: border-box; margin: 0; padding: 0; }
  body { font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, sans-serif;
         color: var(--fg); background: var(--bg); max-width: 900px; margin: 0 auto;
         padding: 2rem 1rem; line-height: 1.6; }
  h1 { color: var(--accent); border-bottom: 3px solid var(--accent); padding-bottom: 0.5rem;
       margin-bottom: 1.5rem; font-size: 1.8rem; }
  h2 { color: var(--accent); margin: 2rem 0 0.8rem; font-size: 1.4rem;
       border-bottom: 1px solid var(--border); padding-bottom: 0.3rem; }
  h3 { margin: 1.2rem 0 0.5rem; font-size: 1.1rem; }
  p { margin: 0.5rem 0; }
  table { width: 100%; border-collapse: collapse; margin: 1rem 0; font-size: 0.9rem; }
  td, th { border: 1px solid var(--border); padding: 0.4rem 0.6rem; text-align: left; }
  th { background: var(--accent); color: white; }
  code { background: rgba(0,0,0,0.06); padding: 0.15rem 0.3rem; border-radius: 3px;
         font-size: 0.9em; }
  ul { margin: 0.5rem 0 0.5rem 1.5rem; }
  .meta { color: #666; font-size: 0.9rem; margin-bottom: 2rem; }
  .section-empty { color: #999; font-style: italic; }
  .finding { background: rgba(0,0,0,0.03); border-left: 3px solid var(--accent);
             padding: 0.8rem 1rem; margin: 0.8rem 0; }
  @media print { body { max-width: 100%; } }
</style>
</head>
<body>
<h1>${title} — Engagement Report</h1>
<div class="meta">
  <p><strong>Generated:</strong> ${date}</p>
  ${engPage.meta.team ? `<p><strong>Team:</strong> ${engPage.meta.team}</p>` : ''}
  ${engPage.meta.start_date ? `<p><strong>Period:</strong> ${engPage.meta.start_date} — ${engPage.meta.end_date || 'ongoing'}</p>` : ''}
  ${engPage.meta.status ? `<p><strong>Status:</strong> ${engPage.meta.status}</p>` : ''}
</div>

${mdToHtml(engPage.body)}

<h2>Targets (${targets.length})</h2>
${targets.length === 0 ? '<p class="section-empty">No target pages found.</p>' :
  targets.map(t => `
  <div class="finding">
    <h3>${t.meta.hostname || t.name}</h3>
    <table>
      <tr><td><strong>IP</strong></td><td>${t.meta.ip || '—'}</td>
          <td><strong>OS</strong></td><td>${t.meta.os || '—'}</td></tr>
      <tr><td><strong>Domain</strong></td><td>${t.meta.domain || '—'}</td>
          <td><strong>Role</strong></td><td>${t.meta.role || '—'}</td></tr>
    </table>
    ${mdToHtml(t.body)}
  </div>`).join('\n')}

<h2>Techniques (${techniques.length})</h2>
${techniques.length === 0 ? '<p class="section-empty">No technique pages found.</p>' :
  techniques.map(t => `
  <div class="finding">
    <h3>${t.meta.name || t.name}${t.meta.mitre_id ? ` (${t.meta.mitre_id})` : ''}</h3>
    ${t.meta.mitre_tactic ? `<p><strong>Tactic:</strong> ${t.meta.mitre_tactic}</p>` : ''}
    ${mdToHtml(t.body)}
  </div>`).join('\n')}

<h2>Credentials (${creds.length})</h2>
${creds.length === 0 ? '<p class="section-empty">No credential pages found.</p>' :
  `<table>
    <tr><th>Username</th><th>Domain</th><th>Type</th><th>Source</th><th>Method</th></tr>
    ${creds.map(c => `<tr>
      <td>${c.meta.username || '—'}</td>
      <td>${c.meta.domain || '—'}</td>
      <td>${c.meta.type || '—'}</td>
      <td>${c.meta.source_host || '—'}</td>
      <td>${c.meta.harvest_method || '—'}</td>
    </tr>`).join('\n')}
  </table>`}

<h2>Indicators of Compromise (${iocs.length})</h2>
${iocs.length === 0 ? '<p class="section-empty">No IOC pages found.</p>' :
  `<table>
    <tr><th>Type</th><th>Value</th><th>Context</th><th>First Seen</th></tr>
    ${iocs.map(i => `<tr>
      <td>${i.meta.type || '—'}</td>
      <td><code>${i.meta.value || '—'}</code></td>
      <td>${i.meta.context || '—'}</td>
      <td>${i.meta.first_seen || '—'}</td>
    </tr>`).join('\n')}
  </table>`}

<h2>Remediation (${remediation.length})</h2>
${remediation.length === 0 ? '<p class="section-empty">No remediation pages found.</p>' :
  remediation.map(r => `
  <div class="finding">
    <h3>${r.name}</h3>
    ${mdToHtml(r.body)}
  </div>`).join('\n')}

<h2>Purple Team (${purple.length})</h2>
${purple.length === 0 ? '<p class="section-empty">No purple team pages found.</p>' :
  purple.map(p => `
  <div class="finding">
    <h3>${p.name}</h3>
    ${mdToHtml(p.body)}
  </div>`).join('\n')}

<footer style="margin-top:3rem; border-top:1px solid var(--border); padding-top:1rem; font-size:0.8rem; color:#999;">
  Generated ${date} from LLM Wiki.
</footer>
</body>
</html>`;

// ── Write output ─────────────────────────────────────────────────────────
mkdirSync(OUTPUT_DIR, { recursive: true });

const htmlPath = join(OUTPUT_DIR, `${date}-report.html`);
writeFileSync(htmlPath, html);
console.log(`HTML: ${htmlPath}`);

// DOCX via pandoc if available and requested
if (FORMAT === 'docx' || FORMAT === 'all') {
  try {
    execSync('which pandoc', { stdio: 'ignore' });
    const docxPath = join(OUTPUT_DIR, `${date}-report.docx`);
    execSync(`pandoc "${htmlPath}" -o "${docxPath}" --from html --to docx`);
    console.log(`DOCX: ${docxPath}`);
  } catch {
    console.log('DOCX: pandoc not available — install pandoc for DOCX export');
  }
}

console.log(`\nReport compiled: ${targets.length} targets, ${techniques.length} techniques, ${creds.length} credentials, ${iocs.length} IOCs`);
