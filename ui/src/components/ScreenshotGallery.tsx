import { useState, useEffect, useRef } from "react";
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
const REQUEST_TIMEOUT_MS = 10_000;

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
  const [error, setError] = useState<string | null>(null);
  const [offset, setOffset] = useState(0);
  const [reloadKey, setReloadKey] = useState(0);
  const [selected, setSelected] = useState<Set<string>>(() => new Set());
  const [copyStatus, setCopyStatus] = useState<{ message: string; error: boolean } | null>(null);
  const [copying, setCopying] = useState(false);
  const copyInFlight = useRef(false);
  const copyGeneration = useRef(0);
  const limit = 48;

  function clearSelection() {
    if (copyInFlight.current) return;
    copyGeneration.current += 1;
    setSelected(new Set());
    setCopyStatus(null);
  }

  function changePage(nextOffset: number) {
    if (copyInFlight.current) return;
    clearSelection();
    setOffset(nextOffset);
  }

  function toggleSelection(filename: string) {
    if (copyInFlight.current) return;
    copyGeneration.current += 1;
    setCopyStatus(null);
    setSelected((current) => {
      const next = new Set(current);
      if (next.has(filename)) next.delete(filename);
      else next.add(filename);
      return next;
    });
  }

  const selectedUrls = Array.from(
    new Set(
      screenshots
        .filter((s) => selected.has(s.filename))
        .map((s) => new URL(s.url, API_BASE || window.location.origin).href),
    ),
  );

  async function copySelection() {
    if (!selectedUrls.length || copyInFlight.current) return;
    copyInFlight.current = true;
    const generation = ++copyGeneration.current;
    setCopying(true);
    setCopyStatus(null);
    try {
      if (!navigator.clipboard?.writeText) throw new Error("Clipboard unavailable");
      await navigator.clipboard.writeText(selectedUrls.join("\n"));
      if (generation === copyGeneration.current) {
        setCopyStatus({ message: `Copied ${selectedUrls.length} link${selectedUrls.length === 1 ? "" : "s"}.`, error: false });
      }
    } catch {
      if (generation === copyGeneration.current) {
        setCopyStatus({ message: "Could not copy links. Check clipboard permission and try again.", error: true });
      }
    } finally {
      copyInFlight.current = false;
      setCopying(false);
    }
  }

  useEffect(() => {
    let active = true;
    const controller = new AbortController();
    const timeout = window.setTimeout(
      () => controller.abort(),
      REQUEST_TIMEOUT_MS,
    );

    setLoading(true);
    setError(null);
    fetch(`${API_BASE}/api/screenshots?limit=${limit}&offset=${offset}`, {
      cache: "no-store",
      signal: controller.signal,
    })
      .then((response) => {
        if (!response.ok) {
          throw new Error(`Gallery request failed with ${response.status}`);
        }
        return response.json();
      })
      .then((data: APIResponse) => {
        if (!active) return;
        setScreenshots(data.screenshots || []);
        setTotal(data.total);
      })
      .catch((requestError: unknown) => {
        if (!active) return;
        console.error(requestError);
        setError(
          controller.signal.aborted
            ? "The gallery request timed out."
            : "The gallery could not be loaded.",
        );
      })
      .finally(() => {
        window.clearTimeout(timeout);
        if (active) setLoading(false);
      });

    return () => {
      active = false;
      window.clearTimeout(timeout);
      controller.abort();
    };
  }, [offset, reloadKey]);

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

      <div className="mb-5 flex flex-wrap items-center gap-3">
        <button
          type="button"
          onClick={copySelection}
          disabled={loading || !!error || !selectedUrls.length || copying}
          className="rounded-md border px-4 py-2 text-sm transition-colors hover:bg-muted disabled:cursor-not-allowed disabled:opacity-40"
        >
          {copying ? "Copying…" : `Copy links (${selectedUrls.length})`}
        </button>
        <span role="status" aria-live="polite" className={`text-sm ${copyStatus?.error ? "text-red-600 dark:text-red-400" : "text-muted-foreground"}`}>
          {copyStatus?.message || (selected.size ? `${selected.size} selected` : "Select screenshots to copy their links")}
        </span>
      </div>

      {loading ? (
        <div
          aria-live="polite"
          className="flex justify-center py-20 text-muted-foreground"
        >
          Loading...
        </div>
      ) : error ? (
        <div
          role="alert"
          className="flex flex-col items-center gap-4 py-20 text-center"
        >
          <p className="text-sm text-muted-foreground">{error}</p>
          <button
            type="button"
            onClick={() => { clearSelection(); setReloadKey((key) => key + 1); }}
            className="rounded-md border px-4 py-2 text-sm transition-colors hover:bg-muted"
          >
            Retry
          </button>
        </div>
      ) : view === "grid" ? (
        <div className="grid grid-cols-2 gap-3 sm:grid-cols-3 md:grid-cols-4 lg:grid-cols-6">
          {screenshots.map((s) => (
            <div
              key={s.filename}
              className={`relative overflow-hidden rounded-lg border bg-card transition-colors ${selected.has(s.filename) ? "border-primary ring-2 ring-primary" : "hover:border-foreground/20"}`}
            >
              <label className="absolute right-2 top-2 z-10 flex cursor-pointer items-center rounded bg-background/95 p-2 shadow-sm">
                <input
                  type="checkbox"
                  aria-label={`Select ${s.filename}`}
                  checked={selected.has(s.filename)}
                  disabled={copying}
                  onChange={() => toggleSelection(s.filename)}
                  className="h-5 w-5 accent-primary"
                />
              </label>
              <a href={s.url} target="_blank" rel="noopener" className="group block" aria-label={`Open ${s.filename}`}>
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
            </div>
          ))}
        </div>
      ) : (
        <div className="divide-y rounded-lg border">
          {screenshots.map((s) => (
            <div
              key={s.filename}
              className={`flex items-center gap-3 px-4 py-3 transition-colors ${selected.has(s.filename) ? "bg-primary/10 ring-2 ring-inset ring-primary" : "hover:bg-muted/50"}`}
            >
              <input
                type="checkbox"
                aria-label={`Select ${s.filename}`}
                checked={selected.has(s.filename)}
                disabled={copying}
                onChange={() => toggleSelection(s.filename)}
                className="h-5 w-5 shrink-0 accent-primary"
              />
              <a href={s.url} target="_blank" rel="noopener" className="flex min-w-0 flex-1 items-center gap-4" aria-label={`Open ${s.filename}`}>
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
            </div>
          ))}
        </div>
      )}

      {(offset > 0 || hasMore) && (
        <div className="mt-8 flex justify-center gap-4">
          <button
            onClick={() => changePage(Math.max(0, offset - limit))}
            disabled={copying || offset === 0}
            className="rounded-md border px-4 py-2 text-sm transition-colors hover:bg-muted disabled:opacity-40"
          >
            Previous
          </button>
          <span className="flex items-center text-sm text-muted-foreground">
            {offset + 1}–{Math.min(offset + limit, total)} of {total}
          </span>
          <button
            onClick={() => changePage(offset + limit)}
            disabled={copying || !hasMore}
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
