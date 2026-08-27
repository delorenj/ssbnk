import { useState, useEffect } from "react";
import { ToggleGroup, ToggleGroupItem } from "@/components/ui/toggle-group";

interface Screenshot {
  id?: string;
  filename: string;
  url: string;
  timestamp: string;
  size: number;
  original_name?: string;
}

interface APIResponse {
  screenshots: Screenshot[];
  total: number;
  offset: number;
  limit: number;
}

const API_BASE = (import.meta.env.PUBLIC_API_URL || "").replace(/\/$/, "");

function formatSize(bytes: number): string {
  if (!bytes) return "";
  if (bytes < 1024) return `${bytes} B`;
  if (bytes < 1024 * 1024) return `${(bytes / 1024).toFixed(0)} KB`;
  return `${(bytes / (1024 * 1024)).toFixed(1)} MB`;
}

function formatDate(ts: string): string {
  const d = new Date(ts);
  return d.toLocaleDateString("en-US", {
    month: "short",
    day: "numeric",
    hour: "2-digit",
    minute: "2-digit",
  });
}

export default function ScreenshotGallery() {
  const [screenshots, setScreenshots] = useState<Screenshot[]>([]);
  const [total, setTotal] = useState(0);
  const [view, setView] = useState<string>("grid");
  const [loading, setLoading] = useState(true);
  const [offset, setOffset] = useState(0);
  const limit = 48;

  useEffect(() => {
    setLoading(true);
    fetch(`${API_BASE}/api/screenshots?limit=${limit}&offset=${offset}`)
      .then((r) => r.json())
      .then((data: APIResponse) => {
        setScreenshots(data.screenshots || []);
        setTotal(data.total);
      })
      .catch(console.error)
      .finally(() => setLoading(false));
  }, [offset]);

  const hasMore = offset + limit < total;

  return (
    <div className="mx-auto max-w-7xl px-4 py-8">
      <header className="mb-8 flex items-center justify-between">
        <div>
          <h1 className="text-2xl font-bold tracking-tight">ssbnk</h1>
          <p className="text-sm text-muted-foreground">
            {total} screenshots
          </p>
        </div>
        <ToggleGroup
          type="single"
          value={view}
          onValueChange={(v) => v && setView(v)}
        >
          <ToggleGroupItem value="grid" aria-label="Grid view">
            <GridIcon />
          </ToggleGroupItem>
          <ToggleGroupItem value="list" aria-label="List view">
            <ListIcon />
          </ToggleGroupItem>
        </ToggleGroup>
      </header>

      {loading ? (
        <div className="flex justify-center py-20 text-muted-foreground">
          Loading...
        </div>
      ) : view === "grid" ? (
        <div className="grid grid-cols-2 gap-3 sm:grid-cols-3 md:grid-cols-4 lg:grid-cols-6">
          {screenshots.map((s) => (
            <a
              key={s.filename}
              href={s.url}
              target="_blank"
              rel="noopener"
              className="group relative overflow-hidden rounded-lg border bg-card transition-colors hover:border-foreground/20"
            >
              <div className="aspect-video w-full overflow-hidden bg-muted">
                <img
                  src={s.url}
                  alt={s.filename}
                  loading="lazy"
                  className="h-full w-full object-cover transition-transform group-hover:scale-105"
                />
              </div>
              <div className="px-2 py-1.5">
                <p className="truncate text-xs font-medium">{s.filename}</p>
                <p className="text-xs text-muted-foreground">
                  {formatDate(s.timestamp)}
                  {s.size ? ` · ${formatSize(s.size)}` : ""}
                </p>
              </div>
            </a>
          ))}
        </div>
      ) : (
        <div className="divide-y rounded-lg border">
          {screenshots.map((s) => (
            <a
              key={s.filename}
              href={s.url}
              target="_blank"
              rel="noopener"
              className="flex items-center gap-4 px-4 py-3 transition-colors hover:bg-muted/50"
            >
              <div className="h-12 w-20 shrink-0 overflow-hidden rounded bg-muted">
                <img
                  src={s.url}
                  alt={s.filename}
                  loading="lazy"
                  className="h-full w-full object-cover"
                />
              </div>
              <div className="min-w-0 flex-1">
                <p className="truncate text-sm font-medium">{s.filename}</p>
                {s.original_name && s.original_name !== s.filename && (
                  <p className="truncate text-xs text-muted-foreground">
                    {s.original_name}
                  </p>
                )}
              </div>
              <div className="text-right text-xs text-muted-foreground">
                <p>{formatDate(s.timestamp)}</p>
                {s.size ? <p>{formatSize(s.size)}</p> : null}
              </div>
            </a>
          ))}
        </div>
      )}

      {(offset > 0 || hasMore) && (
        <div className="mt-8 flex justify-center gap-4">
          <button
            onClick={() => setOffset(Math.max(0, offset - limit))}
            disabled={offset === 0}
            className="rounded-md border px-4 py-2 text-sm transition-colors hover:bg-muted disabled:opacity-40"
          >
            Previous
          </button>
          <span className="flex items-center text-sm text-muted-foreground">
            {offset + 1}–{Math.min(offset + limit, total)} of {total}
          </span>
          <button
            onClick={() => setOffset(offset + limit)}
            disabled={!hasMore}
            className="rounded-md border px-4 py-2 text-sm transition-colors hover:bg-muted disabled:opacity-40"
          >
            Next
          </button>
        </div>
      )}
    </div>
  );
}

function GridIcon() {
  return (
    <svg width="16" height="16" viewBox="0 0 16 16" fill="none">
      <rect x="1" y="1" width="6" height="6" rx="1" fill="currentColor" />
      <rect x="9" y="1" width="6" height="6" rx="1" fill="currentColor" />
      <rect x="1" y="9" width="6" height="6" rx="1" fill="currentColor" />
      <rect x="9" y="9" width="6" height="6" rx="1" fill="currentColor" />
    </svg>
  );
}

function ListIcon() {
  return (
    <svg width="16" height="16" viewBox="0 0 16 16" fill="none">
      <rect x="1" y="2" width="14" height="3" rx="1" fill="currentColor" />
      <rect x="1" y="7" width="14" height="3" rx="1" fill="currentColor" />
      <rect x="1" y="12" width="14" height="3" rx="1" fill="currentColor" />
    </svg>
  );
}
