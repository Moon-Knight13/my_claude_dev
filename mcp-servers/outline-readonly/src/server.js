#!/usr/bin/env node

import { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { StdioServerTransport } from "@modelcontextprotocol/sdk/server/stdio.js";
import { z } from "zod";
import { OutlineClient } from "./outline-client.js";

const API_URL = process.env.OUTLINE_API_URL;
const API_KEY = process.env.OUTLINE_API_KEY;
const ALLOWED_COLLECTIONS = process.env.OUTLINE_COLLECTIONS
  ? process.env.OUTLINE_COLLECTIONS.split(",").map((s) => s.trim()).filter(Boolean)
  : [];

if (!API_URL || !API_KEY) {
  console.error("Required: OUTLINE_API_URL and OUTLINE_API_KEY environment variables");
  process.exit(1);
}

const client = new OutlineClient(API_URL, API_KEY);

let collectionAllowlist = null;

async function resolveAllowlist() {
  if (ALLOWED_COLLECTIONS.length === 0) return null;

  const allCollections = await client.listCollections();
  const allowed = new Map();

  for (const name of ALLOWED_COLLECTIONS) {
    const match = allCollections.find(
      (c) => c.name.toLowerCase() === name.toLowerCase() || c.id === name
    );
    if (match) {
      allowed.set(match.id, match.name);
    } else {
      console.error(`Warning: collection "${name}" not found in Outline — skipping`);
    }
  }

  return allowed.size > 0 ? allowed : null;
}

function enforceCollection(collectionId) {
  if (!collectionAllowlist) return;
  if (!collectionAllowlist.has(collectionId)) {
    throw new Error(
      `Collection ${collectionId} not in allowlist. Allowed: ${[...collectionAllowlist.values()].join(", ")}`
    );
  }
}

function formatDocSummary(doc) {
  return [
    `Title: ${doc.title}`,
    `ID: ${doc.id}`,
    `Collection: ${doc.collectionId}`,
    doc.parentDocumentId ? `Parent: ${doc.parentDocumentId}` : null,
    `Updated: ${doc.updatedAt}`,
    `Created: ${doc.createdAt}`,
    doc.archivedAt ? `ARCHIVED: ${doc.archivedAt}` : null,
  ]
    .filter(Boolean)
    .join("\n");
}

function formatDocFull(doc) {
  return [
    formatDocSummary(doc),
    "---",
    doc.text,
  ].join("\n");
}

function buildCollectionTree(documents, collection) {
  const byParent = new Map();
  for (const doc of documents) {
    const parent = doc.parentDocumentId || "root";
    if (!byParent.has(parent)) byParent.set(parent, []);
    byParent.get(parent).push(doc);
  }

  function renderLevel(parentId, indent) {
    const children = byParent.get(parentId) || [];
    let output = "";
    for (const child of children) {
      output += `${indent}- ${child.title} [${child.id}]\n`;
      output += renderLevel(child.id, indent + "  ");
    }
    return output;
  }

  return `Collection: ${collection.name} [${collection.id}]\n` + renderLevel("root", "  ");
}

const server = new McpServer({
  name: "outline-readonly",
  version: "1.0.0",
});

server.tool(
  "outline_list_collections",
  "List all accessible collections (folders) in Outline. If an allowlist is configured, only those are shown.",
  {},
  async () => {
    const collections = await client.listCollections();
    const filtered = collectionAllowlist
      ? collections.filter((c) => collectionAllowlist.has(c.id))
      : collections;

    const text = filtered
      .map((c) => `${c.name} [${c.id}] — ${c.documents?.length || "?"} docs`)
      .join("\n");

    return { content: [{ type: "text", text: text || "No collections found." }] };
  }
);

server.tool(
  "outline_collection_structure",
  "Show the document tree structure of a collection — titles and IDs, nested by parent/child.",
  { collectionId: z.string().describe("Collection UUID") },
  async ({ collectionId }) => {
    enforceCollection(collectionId);
    const collection = await client.getCollectionStructure(collectionId);

    const allDocs = [];
    let offset = 0;
    while (true) {
      const batch = await client.listDocuments(collectionId, null, { limit: 100, offset });
      allDocs.push(...batch.data);
      if (batch.data.length < 100) break;
      offset += 100;
    }

    const tree = buildCollectionTree(allDocs, collection);
    return { content: [{ type: "text", text: tree }] };
  }
);

server.tool(
  "outline_list_documents",
  "List documents in a collection, optionally under a specific parent document. Returns summaries (no body text).",
  {
    collectionId: z.string().describe("Collection UUID"),
    parentDocumentId: z.string().optional().describe("Parent document UUID to list children of"),
    limit: z.number().optional().default(25).describe("Max results (default 25)"),
    offset: z.number().optional().default(0).describe("Pagination offset"),
  },
  async ({ collectionId, parentDocumentId, limit, offset }) => {
    enforceCollection(collectionId);
    const result = await client.listDocuments(collectionId, parentDocumentId, { limit, offset });
    const text = result.data.map(formatDocSummary).join("\n\n");
    const pagination = result.pagination
      ? `\n\n--- Page offset:${offset} limit:${limit} total:${result.pagination.total || "?"} ---`
      : "";
    return { content: [{ type: "text", text: (text || "No documents found.") + pagination }] };
  }
);

server.tool(
  "outline_read_document",
  "Read the full content (Markdown) of a single document by its ID.",
  { documentId: z.string().describe("Document UUID") },
  async ({ documentId }) => {
    const doc = await client.getDocument(documentId);
    if (collectionAllowlist) enforceCollection(doc.collectionId);
    return { content: [{ type: "text", text: formatDocFull(doc) }] };
  }
);

server.tool(
  "outline_search",
  "Search documents by text query. Scoped to allowlisted collections if configured.",
  {
    query: z.string().describe("Search query text"),
    collectionId: z.string().optional().describe("Limit search to a specific collection UUID"),
    limit: z.number().optional().default(10).describe("Max results (default 10)"),
  },
  async ({ query, collectionId, limit }) => {
    if (collectionId) enforceCollection(collectionId);

    if (collectionAllowlist && !collectionId) {
      const results = [];
      for (const [cid] of collectionAllowlist) {
        const batch = await client.searchDocuments(query, cid, { limit });
        results.push(...(batch.data || []));
      }
      results.sort((a, b) => (b.ranking || 0) - (a.ranking || 0));
      const text = results
        .slice(0, limit)
        .map((r) => {
          const doc = r.document;
          return `${formatDocSummary(doc)}\nContext: ${r.context || "(no snippet)"}`;
        })
        .join("\n\n---\n\n");
      return { content: [{ type: "text", text: text || "No results." }] };
    }

    const result = await client.searchDocuments(query, collectionId, { limit });
    const text = (result.data || [])
      .map((r) => {
        const doc = r.document;
        return `${formatDocSummary(doc)}\nContext: ${r.context || "(no snippet)"}`;
      })
      .join("\n\n---\n\n");
    return { content: [{ type: "text", text: text || "No results." }] };
  }
);

async function main() {
  collectionAllowlist = await resolveAllowlist();

  if (collectionAllowlist) {
    console.error(
      `Outline MCP (read-only): scoped to ${collectionAllowlist.size} collection(s): ${[...collectionAllowlist.values()].join(", ")}`
    );
  } else {
    console.error("Outline MCP (read-only): all collections accessible (no allowlist set)");
  }

  const transport = new StdioServerTransport();
  await server.connect(transport);
}

main().catch((err) => {
  console.error("Fatal:", err);
  process.exit(1);
});
