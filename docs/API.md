# API Documentation

ssbnk provides a simple HTTP API for accessing hosted screenshots and metadata.

## Base URL

All API endpoints are relative to your configured domain:
```
https://your-domain.com
```

## Endpoints

### GET /hosted/{filename}

Retrieve a hosted screenshot.

**Parameters**:
- `filename` (string): The screenshot filename (e.g., `20250714-1234.png`)

**Response**:
- `200 OK`: Returns the image file
- `404 Not Found`: File not found or archived
- `403 Forbidden`: Access denied

**Headers**:
- `Content-Type`: `image/png`, `image/jpeg`, etc.
- `Cache-Control`: `max-age=86400, public, immutable`
- `ETag`: File hash for caching

**Example**:
```bash
curl https://your-domain.com/hosted/20250714-1234.png
```

### GET /

Returns the default index page with service information.

**Response**:
- `200 OK`: HTML page with service status

## File Naming Convention

Screenshots are automatically renamed using the following pattern:
```
YYYYMMDD-HHMM.png
```

Where:
- `YYYY`: 4-digit year
- `MM`: 2-digit month
- `DD`: 2-digit day
- `HH`: 2-digit hour (24-hour format)
- `MM`: 2-digit minute

If multiple screenshots are taken in the same minute, a counter is appended:
```
YYYYMMDD-HHMM-1.png
YYYYMMDD-HHMM-2.png
```

## Metadata

Each screenshot has associated metadata stored internally:

```json
{
  "id": "uuid-string",
  "original_name": "Screenshot From 2025-07-14 12-34-56.png",
  "filename": "20250714-1234.png",
  "url": "https://your-domain.com/hosted/20250714-1234.png",
  "timestamp": "2025-07-14T12:34:56Z",
  "size": 12345,
  "preserve": false,
  "description": "",
  "batch_id": "",
  "repo_name": ""
}
```

**Note**: Metadata is not currently exposed via API but is used internally for management and cleanup.

## Caching

Screenshots are served with aggressive caching headers:
- `Cache-Control: max-age=86400, public, immutable`
- `ETag` headers for conditional requests
- `Expires` headers set to 24 hours

This ensures fast loading and reduces server load.

## Rate Limiting

Currently, no rate limiting is implemented. Consider adding rate limiting at the reverse proxy level for production deployments.

## CORS

Cross-Origin Resource Sharing (CORS) is not explicitly configured. Screenshots can be embedded in web pages from any origin.

## Security

### Access Control

- No authentication is required for public screenshots
- Files are served with security headers
- Directory listing is disabled
- Custom error pages prevent information disclosure

### File Types

Only image files are processed and served:
- `.png`
- `.jpg` / `.jpeg`
- `.gif`
- `.webp`

### File Size

No explicit file size limits are enforced at the API level. Consider adding limits at the reverse proxy level if needed.

## Error Responses

### 404 Not Found

```html
<!DOCTYPE html>
<html>
<head>
    <title>404 Not Found</title>
</head>
<body>
    <h1>404 Not Found</h1>
    <p>The requested file was not found.</p>
</body>
</html>
```

### 403 Forbidden

```html
<!DOCTYPE html>
<html>
<head>
    <title>403 Forbidden</title>
</head>
<body>
    <h1>403 Forbidden</h1>
    <p>Access to this resource is forbidden.</p>
</body>
</html>
```

## Integration Examples

### HTML Embedding

```html
<img src="https://your-domain.com/hosted/20250714-1234.png" alt="Screenshot">
```

### Markdown

```markdown
![Screenshot](https://your-domain.com/hosted/20250714-1234.png)
```

### cURL

```bash
# Download a screenshot
curl -O https://your-domain.com/hosted/20250714-1234.png

# Check if a screenshot exists
curl -I https://your-domain.com/hosted/20250714-1234.png
```

### JavaScript

```javascript
// Check if image exists
fetch('https://your-domain.com/hosted/20250714-1234.png', { method: 'HEAD' })
  .then(response => {
    if (response.ok) {
      console.log('Image exists');
    } else {
      console.log('Image not found');
    }
  });
```

## Future API Enhancements

Planned features for future versions:

- **Metadata API**: Retrieve screenshot metadata
- **Search API**: Search screenshots by date, size, etc.
- **Upload API**: Direct upload via HTTP
- **Batch operations**: Multiple file operations
- **Authentication**: Optional access control
- **Webhooks**: Notifications for new screenshots
