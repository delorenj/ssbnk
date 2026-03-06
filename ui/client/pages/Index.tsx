import { useState, useEffect, useCallback } from "react";
import {
  AssetMetadata,
  AssetQuery,
  AssetFilter,
  AssetSort,
  BulkActionRequest,
  AssetResponse,
} from "@shared/api";
import { AssetInfoModal } from "@/components/AssetInfoModal";
import { Button } from "@/components/ui/button";
import { Card, CardContent } from "@/components/ui/card";
import { Input } from "@/components/ui/input";
import { Badge } from "@/components/ui/badge";
import { Checkbox } from "@/components/ui/checkbox";
import { Switch } from "@/components/ui/switch";
import {
  Select,
  SelectContent,
  SelectItem,
  SelectTrigger,
  SelectValue,
} from "@/components/ui/select";
import {
  Dialog,
  DialogContent,
  DialogHeader,
  DialogTitle,
  DialogTrigger,
} from "@/components/ui/dialog";
import { Tabs, TabsContent, TabsList, TabsTrigger } from "@/components/ui/tabs";
import { Progress } from "@/components/ui/progress";
import { Skeleton } from "@/components/ui/skeleton";
import { useToast } from "@/hooks/use-toast";
import {
  Search,
  Upload,
  Grid3X3,
  Grid2X2,
  List,
  Star,
  StarOff,
  Trash2,
  Download,
  Copy,
  Filter,
  SortAsc,
  SortDesc,
  Image,
  FileVideo,
  Calendar,
  Clock,
  HardDrive,
  Eye,
  Edit3,
  MoreHorizontal,
  Loader2,
  AlertTriangle,
  CheckCircle2,
  XCircle,
} from "lucide-react";
import { cn } from "@/lib/utils";

type ViewMode = "small" | "medium" | "large" | "list";

interface AssetGridProps {
  assets: AssetMetadata[];
  viewMode: ViewMode;
  selectedAssets: Set<string>;
  onSelectAsset: (id: string, selected: boolean) => void;
  onSelectAll: (selected: boolean) => void;
  onToggleFlag: (id: string) => void;
  onDeleteAsset: (id: string) => void;
  onEditAsset: (asset: AssetMetadata) => void;
  isAllSelected: boolean;
}

function AssetCard({
  asset,
  viewMode,
  isSelected,
  onSelect,
  onToggleFlag,
  onDelete,
  onEdit,
}: {
  asset: AssetMetadata;
  viewMode: ViewMode;
  isSelected: boolean;
  onSelect: (selected: boolean) => void;
  onToggleFlag: () => void;
  onDelete: () => void;
  onEdit: () => void;
}) {
  const { toast } = useToast();

  const copyUrl = useCallback(() => {
    navigator.clipboard.writeText(asset.url);
    toast({
      title: "URL copied",
      description: "Asset URL copied to clipboard",
    });
  }, [asset.url, toast]);

  const formatFileSize = (bytes: number) => {
    const sizes = ["B", "KB", "MB", "GB"];
    if (bytes === 0) return "0 B";
    const i = Math.floor(Math.log(bytes) / Math.log(1024));
    return Math.round((bytes / Math.pow(1024, i)) * 100) / 100 + " " + sizes[i];
  };

  const formatDate = (dateString: string) => {
    return new Date(dateString).toLocaleDateString("en-US", {
      month: "short",
      day: "numeric",
      year: "numeric",
    });
  };

  if (viewMode === "list") {
    return (
      <Card className="hover:shadow-md transition-shadow">
        <CardContent className="p-4">
          <div className="flex items-center gap-4">
            <Checkbox
              checked={isSelected}
              onCheckedChange={onSelect}
              className="flex-shrink-0"
            />
            <div className="w-16 h-16 rounded-lg overflow-hidden bg-muted flex-shrink-0">
              <img
                src={asset.thumbnailUrl || asset.url}
                alt={asset.filename}
                className="w-full h-full object-cover"
                loading="lazy"
              />
            </div>
            <div className="flex-1 min-w-0">
              <div className="flex items-center gap-2 mb-1">
                <h3 className="font-medium truncate">{asset.filename}</h3>
                {asset.isFlagged && (
                  <Star className="w-4 h-4 text-yellow-500 fill-current" />
                )}
                {asset.type === "gif" && (
                  <Badge variant="secondary" className="text-xs">
                    GIF
                  </Badge>
                )}
              </div>
              <div className="flex items-center gap-4 text-sm text-muted-foreground">
                <span>{formatFileSize(asset.size)}</span>
                {asset.width && asset.height && (
                  <span>
                    {asset.width} × {asset.height}
                  </span>
                )}
                <span>{formatDate(asset.createdAt)}</span>
              </div>
            </div>
            <div className="flex items-center gap-2 flex-shrink-0">
              <Button
                variant="ghost"
                size="sm"
                onClick={onToggleFlag}
                className="p-2"
              >
                {asset.isFlagged ? (
                  <Star className="w-4 h-4 text-yellow-500 fill-current" />
                ) : (
                  <StarOff className="w-4 h-4" />
                )}
              </Button>
              <Button
                variant="ghost"
                size="sm"
                onClick={copyUrl}
                className="p-2"
              >
                <Copy className="w-4 h-4" />
              </Button>
              <Button
                variant="ghost"
                size="sm"
                onClick={onEdit}
                className="p-2"
              >
                <Edit3 className="w-4 h-4" />
              </Button>
              <Button
                variant="ghost"
                size="sm"
                onClick={onDelete}
                className="p-2 text-destructive hover:text-destructive"
              >
                <Trash2 className="w-4 h-4" />
              </Button>
            </div>
          </div>
        </CardContent>
      </Card>
    );
  }

  const cardSizes = {
    small: "w-full aspect-square",
    medium: "w-full aspect-square",
    large: "w-full aspect-square",
  };

  return (
    <Card className="group hover:shadow-lg transition-all duration-200 overflow-hidden">
      <CardContent className="p-0 relative">
        <div
          className={cn(
            "relative overflow-hidden bg-muted",
            cardSizes[viewMode],
          )}
        >
          <img
            src={asset.thumbnailUrl || asset.url}
            alt={asset.filename}
            className="w-full h-full object-cover transition-transform group-hover:scale-105"
            loading="lazy"
          />

          {/* Selection overlay */}
          <div className="absolute inset-0 bg-black/20 opacity-0 group-hover:opacity-100 transition-opacity">
            <div className="absolute top-2 left-2">
              <Checkbox
                checked={isSelected}
                onCheckedChange={onSelect}
                className="bg-white border-white data-[state=checked]:bg-gallery-500 data-[state=checked]:border-gallery-500"
              />
            </div>

            {/* Action buttons */}
            <div className="absolute top-2 right-2 flex gap-1">
              <Button
                variant="secondary"
                size="sm"
                onClick={onToggleFlag}
                className="p-2 h-8 w-8 bg-white/90 hover:bg-white"
              >
                {asset.isFlagged ? (
                  <Star className="w-4 h-4 text-yellow-500 fill-current" />
                ) : (
                  <StarOff className="w-4 h-4" />
                )}
              </Button>
              <Button
                variant="secondary"
                size="sm"
                onClick={copyUrl}
                className="p-2 h-8 w-8 bg-white/90 hover:bg-white"
              >
                <Copy className="w-4 h-4" />
              </Button>
            </div>

            {/* File type indicator */}
            {asset.type === "gif" && (
              <div className="absolute bottom-2 left-2">
                <Badge variant="secondary" className="text-xs bg-white/90">
                  <FileVideo className="w-3 h-3 mr-1" />
                  GIF
                </Badge>
              </div>
            )}
          </div>
        </div>

        {/* Asset info */}
        <div className="p-3">
          <div className="flex items-center justify-between mb-1">
            <h3 className="font-medium text-sm truncate pr-2">
              {asset.filename}
            </h3>
            {asset.isFlagged && (
              <Star className="w-4 h-4 text-yellow-500 fill-current flex-shrink-0" />
            )}
          </div>
          <div className="flex items-center justify-between text-xs text-muted-foreground">
            <span>{formatFileSize(asset.size)}</span>
            <span>{formatDate(asset.createdAt)}</span>
          </div>
          {asset.width && asset.height && (
            <div className="text-xs text-muted-foreground mt-1">
              {asset.width} × {asset.height}
            </div>
          )}
        </div>
      </CardContent>
    </Card>
  );
}

function AssetGrid({
  assets,
  viewMode,
  selectedAssets,
  onSelectAsset,
  onSelectAll,
  onToggleFlag,
  onDeleteAsset,
  onEditAsset,
  isAllSelected,
}: AssetGridProps) {
  if (viewMode === "list") {
    return (
      <div className="space-y-3">
        {assets.map((asset) => (
          <AssetCard
            key={asset.id}
            asset={asset}
            viewMode={viewMode}
            isSelected={selectedAssets.has(asset.id)}
            onSelect={(selected) => onSelectAsset(asset.id, selected)}
            onToggleFlag={() => onToggleFlag(asset.id)}
            onDelete={() => onDeleteAsset(asset.id)}
            onEdit={() => onEditAsset(asset)}
          />
        ))}
      </div>
    );
  }

  const gridCols = {
    small: "grid-cols-2 sm:grid-cols-4 lg:grid-cols-6 xl:grid-cols-8",
    medium: "grid-cols-2 sm:grid-cols-3 lg:grid-cols-4 xl:grid-cols-6",
    large: "grid-cols-1 sm:grid-cols-2 lg:grid-cols-3 xl:grid-cols-4",
  };

  return (
    <div>
      {/* Bulk select header */}
      {selectedAssets.size > 0 && (
        <div className="flex items-center gap-2 mb-4 p-2 bg-gallery-50 rounded-lg border border-gallery-200">
          <Checkbox checked={isAllSelected} onCheckedChange={onSelectAll} />
          <span className="text-sm font-medium">
            {selectedAssets.size} selected
          </span>
        </div>
      )}

      <div className={cn("grid gap-4", gridCols[viewMode])}>
        {assets.map((asset) => (
          <AssetCard
            key={asset.id}
            asset={asset}
            viewMode={viewMode}
            isSelected={selectedAssets.has(asset.id)}
            onSelect={(selected) => onSelectAsset(asset.id, selected)}
            onToggleFlag={() => onToggleFlag(asset.id)}
            onDelete={() => onDeleteAsset(asset.id)}
            onEdit={() => onEditAsset(asset)}
          />
        ))}
      </div>
    </div>
  );
}

export default function Index() {
  const [assets, setAssets] = useState<AssetMetadata[]>([]);
  const [loading, setLoading] = useState(true);
  const [viewMode, setViewMode] = useState<ViewMode>("medium");
  const [selectedAssets, setSelectedAssets] = useState<Set<string>>(new Set());
  const [searchQuery, setSearchQuery] = useState("");
  const [filter, setFilter] = useState<AssetFilter>({});
  const [sort, setSort] = useState<AssetSort>({
    field: "createdAt",
    direction: "desc",
  });
  const [uploadProgress, setUploadProgress] = useState<number | null>(null);
  const [selectedAssetForInfo, setSelectedAssetForInfo] =
    useState<AssetMetadata | null>(null);
  const [isAssetInfoOpen, setIsAssetInfoOpen] = useState(false);
  const { toast } = useToast();

  // Fetch assets from API
  const fetchAssets = useCallback(async () => {
    setLoading(true);
    try {
      const params = new URLSearchParams();
      if (searchQuery) {
        params.append("filter[search]", searchQuery);
      }
      if (filter.type && filter.type !== "all") {
        params.append("filter[type]", filter.type);
      }
      if (filter.flagged !== undefined) {
        params.append("filter[flagged]", filter.flagged.toString());
      }
      params.append("sort[field]", sort.field);
      params.append("sort[direction]", sort.direction);

      const response = await fetch(`/api/assets?${params}`);
      if (response.ok) {
        const data: AssetResponse = await response.json();
        setAssets(data.assets);
      } else {
        throw new Error("Failed to fetch assets");
      }
    } catch (error) {
      console.error("Error fetching assets:", error);
      toast({
        title: "Error",
        description: "Failed to load assets",
        variant: "destructive",
      });
    } finally {
      setLoading(false);
    }
  }, [searchQuery, filter, sort, toast]);

  useEffect(() => {
    fetchAssets();
  }, [fetchAssets]);

  const handleSelectAsset = useCallback((id: string, selected: boolean) => {
    setSelectedAssets((prev) => {
      const newSet = new Set(prev);
      if (selected) {
        newSet.add(id);
      } else {
        newSet.delete(id);
      }
      return newSet;
    });
  }, []);

  const handleSelectAll = useCallback(
    (selected: boolean) => {
      if (selected) {
        setSelectedAssets(new Set(assets.map((asset) => asset.id)));
      } else {
        setSelectedAssets(new Set());
      }
    },
    [assets],
  );

  const handleToggleFlag = useCallback(
    async (id: string) => {
      const asset = assets.find((a) => a.id === id);
      if (!asset) return;

      try {
        const response = await fetch(`/api/assets/${id}`, {
          method: "PUT",
          headers: { "Content-Type": "application/json" },
          body: JSON.stringify({ isFlagged: !asset.isFlagged }),
        });

        if (response.ok) {
          setAssets((prev) =>
            prev.map((a) =>
              a.id === id ? { ...a, isFlagged: !a.isFlagged } : a,
            ),
          );
          toast({
            title: "Asset updated",
            description: "Asset flag status updated successfully",
          });
        } else {
          throw new Error("Failed to update asset");
        }
      } catch (error) {
        toast({
          title: "Error",
          description: "Failed to update asset",
          variant: "destructive",
        });
      }
    },
    [assets, toast],
  );

  const handleDeleteAsset = useCallback(
    async (id: string) => {
      try {
        const response = await fetch(`/api/assets/${id}`, {
          method: "DELETE",
        });

        if (response.ok) {
          setAssets((prev) => prev.filter((asset) => asset.id !== id));
          setSelectedAssets((prev) => {
            const newSet = new Set(prev);
            newSet.delete(id);
            return newSet;
          });
          toast({
            title: "Asset deleted",
            description: "Asset deleted successfully",
          });
        } else {
          throw new Error("Failed to delete asset");
        }
      } catch (error) {
        toast({
          title: "Error",
          description: "Failed to delete asset",
          variant: "destructive",
        });
      }
    },
    [toast],
  );

  const handleEditAsset = useCallback((asset: AssetMetadata) => {
    setSelectedAssetForInfo(asset);
    setIsAssetInfoOpen(true);
  }, []);

  const handleBulkAction = useCallback(
    async (action: BulkActionRequest["action"]) => {
      const assetIds = Array.from(selectedAssets);
      const count = assetIds.length;

      try {
        const response = await fetch("/api/assets/bulk-action", {
          method: "POST",
          headers: { "Content-Type": "application/json" },
          body: JSON.stringify({ assetIds, action }),
        });

        if (response.ok) {
          if (action === "delete") {
            setAssets((prev) =>
              prev.filter((asset) => !selectedAssets.has(asset.id)),
            );
          } else if (action === "flag") {
            setAssets((prev) =>
              prev.map((asset) =>
                selectedAssets.has(asset.id)
                  ? { ...asset, isFlagged: true }
                  : asset,
              ),
            );
          } else if (action === "unflag") {
            setAssets((prev) =>
              prev.map((asset) =>
                selectedAssets.has(asset.id)
                  ? { ...asset, isFlagged: false }
                  : asset,
              ),
            );
          }

          setSelectedAssets(new Set());
          toast({
            title: "Bulk action completed",
            description: `${action} applied to ${count} assets`,
          });
        } else {
          throw new Error("Failed to perform bulk action");
        }
      } catch (error) {
        toast({
          title: "Error",
          description: "Failed to perform bulk action",
          variant: "destructive",
        });
      }
    },
    [selectedAssets, toast],
  );

  const handleFileUpload = useCallback(
    (files: FileList) => {
      setUploadProgress(0);

      // Simulate upload progress
      const interval = setInterval(() => {
        setUploadProgress((prev) => {
          if (prev === null) return null;
          if (prev >= 100) {
            clearInterval(interval);
            setTimeout(() => setUploadProgress(null), 1000);
            return 100;
          }
          return prev + 10;
        });
      }, 200);

      toast({
        title: "Upload started",
        description: `Uploading ${files.length} file(s)`,
      });
    },
    [toast],
  );

  const handleUpdateAsset = useCallback((updatedAsset: AssetMetadata) => {
    setAssets((prev) =>
      prev.map((asset) =>
        asset.id === updatedAsset.id ? updatedAsset : asset,
      ),
    );
    setSelectedAssetForInfo(updatedAsset);
  }, []);

  const handleCloseAssetInfo = useCallback(() => {
    setIsAssetInfoOpen(false);
    setSelectedAssetForInfo(null);
  }, []);

  const filteredAssets = assets.filter((asset) => {
    if (
      searchQuery &&
      !asset.filename.toLowerCase().includes(searchQuery.toLowerCase())
    ) {
      return false;
    }
    if (filter.type && filter.type !== "all" && asset.type !== filter.type) {
      return false;
    }
    if (filter.flagged !== undefined && asset.isFlagged !== filter.flagged) {
      return false;
    }
    return true;
  });

  const sortedAssets = [...filteredAssets].sort((a, b) => {
    const aValue = a[sort.field];
    const bValue = b[sort.field];
    const direction = sort.direction === "asc" ? 1 : -1;

    if (typeof aValue === "string" && typeof bValue === "string") {
      return aValue.localeCompare(bValue) * direction;
    }
    if (typeof aValue === "number" && typeof bValue === "number") {
      return (aValue - bValue) * direction;
    }
    return 0;
  });

  const isAllSelected =
    assets.length > 0 && selectedAssets.size === assets.length;

  if (loading) {
    return (
      <div className="min-h-screen bg-background">
        <div className="container mx-auto px-4 py-8">
          <div className="flex items-center justify-between mb-8">
            <div>
              <Skeleton className="h-8 w-48 mb-2" />
              <Skeleton className="h-4 w-32" />
            </div>
            <Skeleton className="h-10 w-32" />
          </div>

          <div className="flex gap-4 mb-6">
            <Skeleton className="h-10 flex-1" />
            <Skeleton className="h-10 w-32" />
            <Skeleton className="h-10 w-32" />
          </div>

          <div className="grid grid-cols-2 sm:grid-cols-3 lg:grid-cols-4 xl:grid-cols-6 gap-4">
            {Array.from({ length: 12 }).map((_, i) => (
              <Card key={i}>
                <CardContent className="p-0">
                  <Skeleton className="w-full aspect-square" />
                  <div className="p-3">
                    <Skeleton className="h-4 w-3/4 mb-2" />
                    <Skeleton className="h-3 w-1/2" />
                  </div>
                </CardContent>
              </Card>
            ))}
          </div>
        </div>
      </div>
    );
  }

  return (
    <div className="min-h-screen bg-background">
      <div className="container mx-auto px-4 py-8">
        {/* Header */}
        <div className="flex items-center justify-between mb-8">
          <div>
            <h1 className="text-3xl font-bold text-foreground">
              Asset Gallery
            </h1>
            <p className="text-muted-foreground mt-1">
              Manage your screenshots and GIFs
            </p>
          </div>

          <Dialog>
            <DialogTrigger asChild>
              <Button className="bg-gallery-500 hover:bg-gallery-600">
                <Upload className="w-4 h-4 mr-2" />
                Upload Assets
              </Button>
            </DialogTrigger>
            <DialogContent className="sm:max-w-md">
              <DialogHeader>
                <DialogTitle>Upload Assets</DialogTitle>
              </DialogHeader>
              <div className="space-y-4">
                <div
                  className="border-2 border-dashed border-gallery-300 rounded-lg p-8 text-center hover:border-gallery-400 transition-colors cursor-pointer"
                  onDrop={(e) => {
                    e.preventDefault();
                    const files = e.dataTransfer.files;
                    if (files.length > 0) {
                      handleFileUpload(files);
                    }
                  }}
                  onDragOver={(e) => e.preventDefault()}
                >
                  <Upload className="w-8 h-8 mx-auto mb-4 text-gallery-500" />
                  <p className="text-sm text-muted-foreground mb-2">
                    Drag and drop files here, or click to select
                  </p>
                  <p className="text-xs text-muted-foreground">
                    Supports PNG, JPG, and GIF files
                  </p>
                  <input
                    type="file"
                    multiple
                    accept="image/*"
                    className="hidden"
                    onChange={(e) => {
                      if (e.target.files) {
                        handleFileUpload(e.target.files);
                      }
                    }}
                  />
                </div>

                {uploadProgress !== null && (
                  <div className="space-y-2">
                    <div className="flex justify-between text-sm">
                      <span>Uploading...</span>
                      <span>{uploadProgress}%</span>
                    </div>
                    <Progress value={uploadProgress} className="h-2" />
                  </div>
                )}
              </div>
            </DialogContent>
          </Dialog>
        </div>

        {/* Controls */}
        <div className="flex flex-col sm:flex-row gap-4 mb-6">
          <div className="relative flex-1">
            <Search className="absolute left-3 top-1/2 transform -translate-y-1/2 text-muted-foreground w-4 h-4" />
            <Input
              placeholder="Search assets..."
              value={searchQuery}
              onChange={(e) => setSearchQuery(e.target.value)}
              className="pl-10"
            />
          </div>

          <Select
            value={filter.type || "all"}
            onValueChange={(value) =>
              setFilter((prev) => ({
                ...prev,
                type: value === "all" ? undefined : (value as "image" | "gif"),
              }))
            }
          >
            <SelectTrigger className="w-32">
              <SelectValue />
            </SelectTrigger>
            <SelectContent>
              <SelectItem value="all">All Types</SelectItem>
              <SelectItem value="image">Images</SelectItem>
              <SelectItem value="gif">GIFs</SelectItem>
            </SelectContent>
          </Select>

          <Select
            value={filter.flagged?.toString() || "all"}
            onValueChange={(value) =>
              setFilter((prev) => ({
                ...prev,
                flagged: value === "all" ? undefined : value === "true",
              }))
            }
          >
            <SelectTrigger className="w-32">
              <SelectValue />
            </SelectTrigger>
            <SelectContent>
              <SelectItem value="all">All Assets</SelectItem>
              <SelectItem value="true">Flagged</SelectItem>
              <SelectItem value="false">Unflagged</SelectItem>
            </SelectContent>
          </Select>

          <Select
            value={`${sort.field}-${sort.direction}`}
            onValueChange={(value) => {
              const [field, direction] = value.split("-") as [
                AssetSort["field"],
                AssetSort["direction"],
              ];
              setSort({ field, direction });
            }}
          >
            <SelectTrigger className="w-40">
              <SelectValue />
            </SelectTrigger>
            <SelectContent>
              <SelectItem value="createdAt-desc">Newest First</SelectItem>
              <SelectItem value="createdAt-asc">Oldest First</SelectItem>
              <SelectItem value="filename-asc">Name A-Z</SelectItem>
              <SelectItem value="filename-desc">Name Z-A</SelectItem>
              <SelectItem value="size-desc">Largest First</SelectItem>
              <SelectItem value="size-asc">Smallest First</SelectItem>
            </SelectContent>
          </Select>
        </div>

        {/* View Controls */}
        <div className="flex items-center justify-between mb-6">
          <div className="flex items-center gap-2">
            <span className="text-sm text-muted-foreground">
              {sortedAssets.length} assets
            </span>
            {selectedAssets.size > 0 && (
              <div className="flex items-center gap-2 ml-4">
                <Button
                  variant="outline"
                  size="sm"
                  onClick={() => handleBulkAction("flag")}
                >
                  <Star className="w-4 h-4 mr-1" />
                  Flag
                </Button>
                <Button
                  variant="outline"
                  size="sm"
                  onClick={() => handleBulkAction("unflag")}
                >
                  <StarOff className="w-4 h-4 mr-1" />
                  Unflag
                </Button>
                <Button
                  variant="outline"
                  size="sm"
                  onClick={() => handleBulkAction("delete")}
                  className="text-destructive hover:text-destructive"
                >
                  <Trash2 className="w-4 h-4 mr-1" />
                  Delete
                </Button>
              </div>
            )}
          </div>

          <div className="flex items-center gap-2">
            <Button
              variant={viewMode === "small" ? "default" : "outline"}
              size="sm"
              onClick={() => setViewMode("small")}
            >
              <Grid3X3 className="w-4 h-4" />
            </Button>
            <Button
              variant={viewMode === "medium" ? "default" : "outline"}
              size="sm"
              onClick={() => setViewMode("medium")}
            >
              <Grid2X2 className="w-4 h-4" />
            </Button>
            <Button
              variant={viewMode === "large" ? "default" : "outline"}
              size="sm"
              onClick={() => setViewMode("large")}
            >
              <Image className="w-4 h-4" />
            </Button>
            <Button
              variant={viewMode === "list" ? "default" : "outline"}
              size="sm"
              onClick={() => setViewMode("list")}
            >
              <List className="w-4 h-4" />
            </Button>
          </div>
        </div>

        {/* Asset Grid */}
        {sortedAssets.length === 0 ? (
          <div className="text-center py-12">
            <Image className="w-12 h-12 mx-auto text-muted-foreground mb-4" />
            <h3 className="text-lg font-medium mb-2">No assets found</h3>
            <p className="text-muted-foreground mb-4">
              {searchQuery || Object.keys(filter).length > 0
                ? "Try adjusting your search or filters"
                : "Upload your first asset to get started"}
            </p>
            <Dialog>
              <DialogTrigger asChild>
                <Button>
                  <Upload className="w-4 h-4 mr-2" />
                  Upload Assets
                </Button>
              </DialogTrigger>
              <DialogContent className="sm:max-w-md">
                <DialogHeader>
                  <DialogTitle>Upload Assets</DialogTitle>
                </DialogHeader>
                <div className="space-y-4">
                  <div
                    className="border-2 border-dashed border-gallery-300 rounded-lg p-8 text-center hover:border-gallery-400 transition-colors cursor-pointer"
                    onClick={(e) => {
                      const input = e.currentTarget.querySelector(
                        'input[type="file"]',
                      ) as HTMLInputElement;
                      input?.click();
                    }}
                    onDrop={(e) => {
                      e.preventDefault();
                      const files = e.dataTransfer.files;
                      if (files.length > 0) {
                        handleFileUpload(files);
                      }
                    }}
                    onDragOver={(e) => e.preventDefault()}
                  >
                    <Upload className="w-8 h-8 mx-auto mb-4 text-gallery-500" />
                    <p className="text-sm text-muted-foreground mb-2">
                      Drag and drop files here, or click to select
                    </p>
                    <p className="text-xs text-muted-foreground">
                      Supports PNG, JPG, and GIF files
                    </p>
                    <input
                      type="file"
                      multiple
                      accept="image/*"
                      className="hidden"
                      onChange={(e) => {
                        if (e.target.files) {
                          handleFileUpload(e.target.files);
                        }
                      }}
                    />
                  </div>

                  {uploadProgress !== null && (
                    <div className="space-y-2">
                      <div className="flex justify-between text-sm">
                        <span>Uploading...</span>
                        <span>{uploadProgress}%</span>
                      </div>
                      <Progress value={uploadProgress} className="h-2" />
                    </div>
                  )}
                </div>
              </DialogContent>
            </Dialog>
          </div>
        ) : (
          <AssetGrid
            assets={sortedAssets}
            viewMode={viewMode}
            selectedAssets={selectedAssets}
            onSelectAsset={handleSelectAsset}
            onSelectAll={handleSelectAll}
            onToggleFlag={handleToggleFlag}
            onDeleteAsset={handleDeleteAsset}
            onEditAsset={handleEditAsset}
            isAllSelected={isAllSelected}
          />
        )}

        {/* Asset Info Modal */}
        <AssetInfoModal
          asset={selectedAssetForInfo}
          isOpen={isAssetInfoOpen}
          onClose={handleCloseAssetInfo}
          onUpdateAsset={handleUpdateAsset}
          onToggleFlag={handleToggleFlag}
        />
      </div>
    </div>
  );
}
