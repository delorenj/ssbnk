import { useState } from "react";
import { AssetMetadata } from "@shared/api";
import {
  Dialog,
  DialogContent,
  DialogHeader,
  DialogTitle,
} from "@/components/ui/dialog";
import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";
import { Label } from "@/components/ui/label";
import { Badge } from "@/components/ui/badge";
import { Separator } from "@/components/ui/separator";
import { useToast } from "@/hooks/use-toast";
import {
  Copy,
  Download,
  Edit3,
  Save,
  X,
  Calendar,
  HardDrive,
  Image,
  FileVideo,
  Star,
  StarOff,
  ExternalLink,
} from "lucide-react";
import { cn } from "@/lib/utils";

interface AssetInfoModalProps {
  asset: AssetMetadata | null;
  isOpen: boolean;
  onClose: () => void;
  onUpdateAsset: (asset: AssetMetadata) => void;
  onToggleFlag: (id: string) => void;
}

export function AssetInfoModal({
  asset,
  isOpen,
  onClose,
  onUpdateAsset,
  onToggleFlag,
}: AssetInfoModalProps) {
  const [isEditing, setIsEditing] = useState(false);
  const [editedFilename, setEditedFilename] = useState("");
  const { toast } = useToast();

  if (!asset) return null;

  const handleEdit = () => {
    setEditedFilename(asset.filename);
    setIsEditing(true);
  };

  const handleSave = async () => {
    if (!editedFilename.trim()) {
      toast({
        title: "Error",
        description: "Filename cannot be empty",
        variant: "destructive",
      });
      return;
    }

    try {
      const response = await fetch(`/api/assets/${asset.id}`, {
        method: "PUT",
        headers: {
          "Content-Type": "application/json",
        },
        body: JSON.stringify({
          filename: editedFilename,
        }),
      });

      if (response.ok) {
        const updatedAsset = { ...asset, filename: editedFilename };
        onUpdateAsset(updatedAsset);
        setIsEditing(false);
        toast({
          title: "Success",
          description: "Filename updated successfully",
        });
      } else {
        throw new Error("Failed to update asset");
      }
    } catch (error) {
      toast({
        title: "Error",
        description: "Failed to update filename",
        variant: "destructive",
      });
    }
  };

  const handleCancel = () => {
    setEditedFilename("");
    setIsEditing(false);
  };

  const copyToClipboard = (text: string, label: string) => {
    navigator.clipboard.writeText(text);
    toast({
      title: "Copied",
      description: `${label} copied to clipboard`,
    });
  };

  const formatFileSize = (bytes: number) => {
    const sizes = ["B", "KB", "MB", "GB"];
    if (bytes === 0) return "0 B";
    const i = Math.floor(Math.log(bytes) / Math.log(1024));
    return Math.round((bytes / Math.pow(1024, i)) * 100) / 100 + " " + sizes[i];
  };

  const formatDate = (dateString: string) => {
    return new Date(dateString).toLocaleString("en-US", {
      year: "numeric",
      month: "long",
      day: "numeric",
      hour: "2-digit",
      minute: "2-digit",
      second: "2-digit",
    });
  };

  return (
    <Dialog open={isOpen} onOpenChange={onClose}>
      <DialogContent className="max-w-2xl max-h-[90vh] overflow-y-auto">
        <DialogHeader>
          <DialogTitle className="flex items-center gap-2">
            {asset.type === "gif" ? (
              <FileVideo className="w-5 h-5 text-gallery-500" />
            ) : (
              <Image className="w-5 h-5 text-gallery-500" />
            )}
            Asset Information
          </DialogTitle>
        </DialogHeader>

        <div className="space-y-6">
          {/* Asset Preview */}
          <div className="space-y-4">
            <div className="relative rounded-lg overflow-hidden bg-muted border">
              <img
                src={asset.url}
                alt={asset.filename}
                className="w-full max-h-80 object-contain"
              />
              <div className="absolute top-2 right-2 flex gap-2">
                <Button
                  variant="secondary"
                  size="sm"
                  onClick={() => onToggleFlag(asset.id)}
                  className="bg-white/90 hover:bg-white"
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
                  className="bg-white/90 hover:bg-white"
                  onClick={() => window.open(asset.url, "_blank")}
                >
                  <ExternalLink className="w-4 h-4" />
                </Button>
              </div>
            </div>

            {/* Quick Actions */}
            <div className="flex gap-2">
              <Button
                variant="outline"
                onClick={() => copyToClipboard(asset.url, "Asset URL")}
                className="flex-1"
              >
                <Copy className="w-4 h-4 mr-2" />
                Copy URL
              </Button>
              <Button
                variant="outline"
                onClick={() => {
                  const link = document.createElement("a");
                  link.href = asset.url;
                  link.download = asset.filename;
                  document.body.appendChild(link);
                  link.click();
                  document.body.removeChild(link);
                }}
                className="flex-1"
              >
                <Download className="w-4 h-4 mr-2" />
                Download
              </Button>
            </div>
          </div>

          <Separator />

          {/* File Information */}
          <div className="space-y-4">
            <h3 className="text-lg font-semibold">File Information</h3>

            {/* Filename */}
            <div className="space-y-2">
              <Label htmlFor="filename">Filename</Label>
              <div className="flex gap-2">
                {isEditing ? (
                  <>
                    <Input
                      id="filename"
                      value={editedFilename}
                      onChange={(e) => setEditedFilename(e.target.value)}
                      className="flex-1"
                    />
                    <Button onClick={handleSave} size="sm" variant="default">
                      <Save className="w-4 h-4" />
                    </Button>
                    <Button onClick={handleCancel} size="sm" variant="outline">
                      <X className="w-4 h-4" />
                    </Button>
                  </>
                ) : (
                  <>
                    <Input
                      id="filename"
                      value={asset.filename}
                      readOnly
                      className="flex-1"
                    />
                    <Button onClick={handleEdit} size="sm" variant="outline">
                      <Edit3 className="w-4 h-4" />
                    </Button>
                  </>
                )}
              </div>
            </div>

            {/* Original Name */}
            <div className="space-y-2">
              <Label>Original Name</Label>
              <div className="flex gap-2">
                <Input value={asset.originalName} readOnly className="flex-1" />
                <Button
                  onClick={() =>
                    copyToClipboard(asset.originalName, "Original name")
                  }
                  size="sm"
                  variant="outline"
                >
                  <Copy className="w-4 h-4" />
                </Button>
              </div>
            </div>

            {/* File Path */}
            <div className="space-y-2">
              <Label>File Path</Label>
              <div className="flex gap-2">
                <Input value={asset.path} readOnly className="flex-1" />
                <Button
                  onClick={() => copyToClipboard(asset.path, "File path")}
                  size="sm"
                  variant="outline"
                >
                  <Copy className="w-4 h-4" />
                </Button>
              </div>
            </div>

            {/* File URL */}
            <div className="space-y-2">
              <Label>Public URL</Label>
              <div className="flex gap-2">
                <Input value={asset.url} readOnly className="flex-1" />
                <Button
                  onClick={() => copyToClipboard(asset.url, "Asset URL")}
                  size="sm"
                  variant="outline"
                >
                  <Copy className="w-4 h-4" />
                </Button>
              </div>
            </div>
          </div>

          <Separator />

          {/* Metadata */}
          <div className="space-y-4">
            <h3 className="text-lg font-semibold">Metadata</h3>

            <div className="grid grid-cols-2 gap-4">
              {/* File Type */}
              <div className="space-y-1">
                <Label className="text-sm text-muted-foreground">Type</Label>
                <div className="flex items-center gap-2">
                  <Badge
                    variant={asset.type === "gif" ? "default" : "secondary"}
                    className={cn(
                      asset.type === "gif" &&
                        "bg-gallery-500 hover:bg-gallery-600",
                    )}
                  >
                    {asset.type === "gif" ? (
                      <FileVideo className="w-3 h-3 mr-1" />
                    ) : (
                      <Image className="w-3 h-3 mr-1" />
                    )}
                    {asset.type.toUpperCase()}
                  </Badge>
                  <span className="text-sm text-muted-foreground">
                    {asset.mimeType}
                  </span>
                </div>
              </div>

              {/* File Size */}
              <div className="space-y-1">
                <Label className="text-sm text-muted-foreground">Size</Label>
                <div className="flex items-center gap-2">
                  <HardDrive className="w-4 h-4 text-muted-foreground" />
                  <span className="text-sm">{formatFileSize(asset.size)}</span>
                </div>
              </div>

              {/* Dimensions */}
              {asset.width && asset.height && (
                <div className="space-y-1">
                  <Label className="text-sm text-muted-foreground">
                    Dimensions
                  </Label>
                  <div className="flex items-center gap-2">
                    <Image className="w-4 h-4 text-muted-foreground" />
                    <span className="text-sm">
                      {asset.width} × {asset.height} pixels
                    </span>
                  </div>
                </div>
              )}

              {/* Status */}
              <div className="space-y-1">
                <Label className="text-sm text-muted-foreground">Status</Label>
                <div className="flex items-center gap-2">
                  {asset.isFlagged && (
                    <Badge variant="secondary" className="text-yellow-600">
                      <Star className="w-3 h-3 mr-1 fill-current" />
                      Flagged
                    </Badge>
                  )}
                  {asset.isArchived && (
                    <Badge variant="outline">Archived</Badge>
                  )}
                  {!asset.isFlagged && !asset.isArchived && (
                    <Badge variant="outline">Active</Badge>
                  )}
                </div>
              </div>
            </div>
          </div>

          <Separator />

          {/* Timestamps */}
          <div className="space-y-4">
            <h3 className="text-lg font-semibold">Timestamps</h3>

            <div className="space-y-3">
              <div className="flex items-center gap-3">
                <Calendar className="w-4 h-4 text-muted-foreground" />
                <div className="flex-1">
                  <div className="text-sm font-medium">Created</div>
                  <div className="text-sm text-muted-foreground">
                    {formatDate(asset.createdAt)}
                  </div>
                </div>
                <Button
                  onClick={() =>
                    copyToClipboard(asset.createdAt, "Created date")
                  }
                  size="sm"
                  variant="ghost"
                >
                  <Copy className="w-4 h-4" />
                </Button>
              </div>

              <div className="flex items-center gap-3">
                <Calendar className="w-4 h-4 text-muted-foreground" />
                <div className="flex-1">
                  <div className="text-sm font-medium">Modified</div>
                  <div className="text-sm text-muted-foreground">
                    {formatDate(asset.modifiedAt)}
                  </div>
                </div>
                <Button
                  onClick={() =>
                    copyToClipboard(asset.modifiedAt, "Modified date")
                  }
                  size="sm"
                  variant="ghost"
                >
                  <Copy className="w-4 h-4" />
                </Button>
              </div>
            </div>
          </div>
        </div>
      </DialogContent>
    </Dialog>
  );
}
