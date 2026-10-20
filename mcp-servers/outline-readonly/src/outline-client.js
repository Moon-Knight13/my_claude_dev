import fetch from "node-fetch";

export class OutlineClient {
  constructor(apiUrl, apiKey) {
    this.apiUrl = apiUrl.replace(/\/+$/, "");
    if (!this.apiUrl.endsWith("/api")) {
      this.apiUrl += "/api";
    }
    this.apiKey = apiKey;
  }

  async request(endpoint, body = {}) {
    const url = `${this.apiUrl}/${endpoint}`;
    const response = await fetch(url, {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        Authorization: `Bearer ${this.apiKey}`,
      },
      body: JSON.stringify(body),
    });

    if (!response.ok) {
      const text = await response.text();
      throw new Error(`Outline API ${endpoint}: ${response.status} ${text}`);
    }

    return response.json();
  }

  async listCollections() {
    const result = await this.request("collections.list", { limit: 100 });
    return result.data;
  }

  async getCollection(id) {
    const result = await this.request("collections.info", { id });
    return result.data;
  }

  async getCollectionStructure(id) {
    const result = await this.request("collections.info", { id });
    return result.data;
  }

  async listDocuments(collectionId, parentDocumentId, options = {}) {
    const body = { limit: options.limit || 25, offset: options.offset || 0 };
    if (collectionId) body.collectionId = collectionId;
    if (parentDocumentId) body.parentDocumentId = parentDocumentId;
    const result = await this.request("documents.list", body);
    return result;
  }

  async getDocument(id) {
    const result = await this.request("documents.info", { id });
    return result.data;
  }

  async searchDocuments(query, collectionId, options = {}) {
    const body = { query, limit: options.limit || 25, offset: options.offset || 0 };
    if (collectionId) body.collectionId = collectionId;
    const result = await this.request("documents.search", body);
    return result;
  }
}
