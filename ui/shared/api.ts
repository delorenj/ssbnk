/**
 * Shared code between client and server
 * Asset Gallery API Types
 */

export interface DemoResponse {
  message: string;
}

export interface AssetMetadata {
  id: string;
  filename: string;
  originalName: string;
  size: number;
  width?: number;
  height?: number;
  type: "image" | "gif";
  mimeType: string;
  url: string;
  thumbnailUrl?: string;
  createdAt: string;
  modifiedAt: string;
  path: string;
  isFlagged: boolean;
  isArchived: boolean;
}

export interface AssetResponse {
  assets: AssetMetadata[];
  total: number;
  hasMore: boolean;
}

export interface UploadResponse {
  success: boolean;
  asset?: AssetMetadata;
  error?: string;
}

export interface BulkActionRequest {
  assetIds: string[];
  action: "flag" | "unflag" | "delete" | "archive";
}

export interface BulkActionResponse {
  success: boolean;
  affectedCount: number;
  errors?: string[];
}

export interface AssetFilter {
  type?: "image" | "gif" | "all";
  flagged?: boolean;
  archived?: boolean;
  dateFrom?: string;
  dateTo?: string;
  search?: string;
}

export interface AssetSort {
  field: "createdAt" | "modifiedAt" | "filename" | "size";
  direction: "asc" | "desc";
}

export interface AssetQuery {
  page?: number;
  limit?: number;
  filter?: AssetFilter;
  sort?: AssetSort;
}

export interface UpdateAssetRequest {
  filename?: string;
  isFlagged?: boolean;
}

export interface UpdateAssetResponse {
  success: boolean;
  asset?: AssetMetadata;
  error?: string;
}
