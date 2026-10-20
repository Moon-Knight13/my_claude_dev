#!/usr/bin/env node

import { createInterface } from "node:readline";
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

// --- Allowlist resolution ---

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
      console.error(`Warning: collection "${name}" not found — skipping`);
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

// --- Formatters ---

function formatDocSummary(doc) {
  return [
    `Title: ${doc.title}`,
    `ID: ${doc.id}`,
    `Collection: ${doc.collectionId}`,
    doc.parentDocumentId ? `Parent: ${doc.parentDocumentId}` : null,
    `Updated: ${doc.updatedAt}`,
    `Created: ${doc.createdAt}`,
    doc.archivedAt ? `ARCHIVED: ${doc.archivedAt}` : null,
  ].filter(Boolean).join("\n");
}

function formatDocFull(doc) {
  return formatDocSummary(doc) + "\n---\n" + doc.text;
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

// --- Tool definitions ---

const TOOLS = [
  {
    name: "outline_list_collections",
    description: "List all accessible collections (folders) in Outline. If an allowlist is configured, only those are shown.",
    inputSchema: { type: "object", properties: {}, required: [] },
  },
  {
    name: "outline_collection_structure",
    description: "Show the document tree structure of a collection — titles and IDs, nested by parent/child.",
    inputSchema: {
      type: "object",
      properties: {
        collectionId: { type: "string", description: "Collection UUID" },
      },
      required: ["collectionId"],
    },
  },
  {
    name: "outline_list_documents",
    description: "List documents in a collection, optionally under a specific parent document. Returns summaries (no body text).",
    inputSchema: {
      type: "object",
      properties: {
        collectionId: { type: "string", description: "Collection UUID" },
        parentDocumentId: { type: "string", description: "Parent document UUID to list children of" },
        limit: { type: "number", description: "Max results (default 25)" },
        offset: { type: "number", description: "Pagination offset (default 0)" },
      },
      required: ["collectionId"],
    },
  },
  {
    name: "outline_read_document",
    description: "Read the full content (Markdown) of a single document by its ID.",
    inputSchema: {
      type: "object",
      properties: {
        documentId: { type: "string", description: "Document UUID" },
      },
      required: ["documentId"],
    },
  },
  {
    name: "outline_search",
    description: "Search documents by text query. Scoped to allowlisted collections if configured.",
    inputSchema: {
      type: "object",
      properties: {
        query: { type: "string", description: "Search query text" },
        collectionId: { type: "string", description: "Limit search to a specific collection UUID" },
        limit: { type: "number", description: "Max results (default 10)" },
      },
      required: ["query"],
    },
  },
];

// --- Tool handlers ---

async function handleToolCall(name, args) {
  switch (name) {
    case "outline_list_collections": {
      const collections = await client.listCollections();
      const filtered = collectionAllowlist
        ? collections.filter((c) => collectionAllowlist.has(c.id))
        : collections;
      const text = filtered
        .map((c) => `${c.name} [${c.id}] — ${c.documents?.length || "?"} docs`)
        .join("\n");
      return text || "No collections found.";
    }

    case "outline_collection_structure": {
      enforceCollection(args.collectionId);
      const collection = await client.getCollection(args.collectionId);
      const allDocs = [];
      let offset = 0;
      while (true) {
        const batch = await client.listDocuments(args.collectionId, null, { limit: 100, offset });
        allDocs.push(...batch.data);
        if (batch.data.length < 100) break;
        offset += 100;
      }
      return buildCollectionTree(allDocs, collection);
    }

    case "outline_list_documents": {
      enforceCollection(args.collectionId);
      const limit = args.limit || 25;
      const offset = args.offset || 0;
      const result = await client.listDocuments(args.collectionId, args.parentDocumentId, { limit, offset });
      const text = result.data.map(formatDocSummary).join("\n\n");
      const pagination = result.pagination
        ? `\n\n--- Page offset:${offset} limit:${limit} total:${result.pagination.total || "?"} ---`
        : "";
      return (text || "No documents found.") + pagination;
    }

    case "outline_read_document": {
      const doc = await client.getDocument(args.documentId);
      if (collectionAllowlist) enforceCollection(doc.collectionId);
      return formatDocFull(doc);
    }

    case "outline_search": {
      const limit = args.limit || 10;
      if (args.collectionId) enforceCollection(args.collectionId);

      let results;
      if (collectionAllowlist && !args.collectionId) {
        results = [];
        for (const [cid] of collectionAllowlist) {
          const batch = await client.searchDocuments(args.query, cid, { limit });
          results.push(...(batch.data || []));
        }
        results.sort((a, b) => (b.ranking || 0) - (a.ranking || 0));
        results = results.slice(0, limit);
      } else {
        const result = await client.searchDocuments(args.query, args.collectionId, { limit });
        results = result.data || [];
      }

      const text = results
        .map((r) => {
          const doc = r.document;
          return `${formatDocSummary(doc)}\nContext: ${r.context || "(no snippet)"}`;
        })
        .join("\n\n---\n\n");
      return text || "No results.";
    }

    default:
      throw new Error(`Unknown tool: ${name}`);
  }
}

// --- JSON-RPC over stdio ---

function send(msg) {
  const json = JSON.stringify(msg);
  process.stdout.write(json + "\n");
}

function rpcResult(id, result) {
  send({ jsonrpc: "2.0", id, result });
}

function rpcError(id, code, message) {
  send({ jsonrpc: "2.0", id, error: { code, message } });
}

async function handleMessage(msg) {
  const { id, method, params } = msg;

  switch (method) {
    case "initialize":
      rpcResult(id, {
        protocolVersion: "2024-11-05",
        capabilities: { tools: {} },
        serverInfo: { name: "outline-readonly", version: "1.0.0" },
      });
      break;

    case "notifications/initialized":
      break;

    case "tools/list":
      rpcResult(id, { tools: TOOLS });
      break;

    case "tools/call": {
      const toolName = params?.name;
      const toolArgs = params?.arguments || {};
      try {
        const text = await handleToolCall(toolName, toolArgs);
        rpcResult(id, { content: [{ type: "text", text }] });
      } catch (err) {
        rpcResult(id, {
          content: [{ type: "text", text: `Error: ${err.message}` }],
          isError: true,
        });
      }
      break;
    }

    default:
      if (id !== undefined) {
        rpcError(id, -32601, `Method not found: ${method}`);
      }
  }
}

// --- Main ---

async function main() {
  collectionAllowlist = await resolveAllowlist();

  if (collectionAllowlist) {
    console.error(
      `Outline MCP (read-only): scoped to ${collectionAllowlist.size} collection(s): ${[...collectionAllowlist.values()].join(", ")}`
    );
  } else {
    console.error("Outline MCP (read-only): all collections accessible (no allowlist set)");
  }

  const rl = createInterface({ input: process.stdin });
  rl.on("line", async (line) => {
    if (!line.trim()) return;
    try {
      const msg = JSON.parse(line);
      await handleMessage(msg);
    } catch (err) {
      rpcError(null, -32700, `Parse error: ${err.message}`);
    }
  });

  console.error("Outline MCP (read-only): stdio transport ready");
}

main().catch((err) => {
  console.error("Fatal:", err);
  process.exit(1);
});
