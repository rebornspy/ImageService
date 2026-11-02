# ImageService

A lightweight image utility for Drawing API image objects.

Supports reading image dimensions directly from binary image data without writing files to disk.

## Supported Formats

- PNG
- JPEG / JPG
- WebP
  - VP8
  - VP8L
  - VP8X

---

# Features

- Fetch images from URLs
- Detect image format automatically
- Read dimensions directly from binary data
- Preserve aspect ratios
- Calculate centered screen positions
- Create Drawing API image objects from URLs

---

# Functions

## ReadPNGSize(data)

Gets the dimensions of a PNG image from its binary data.

### Parameters

```lua
data: string
```

### Returns

```lua
width: number
height: number
```

### Example

```lua
local width, height = ImageService.ReadPNGSize(imageData)
```

---

## ReadJPEGSize(data)

Gets the dimensions of a JPEG image from its binary data.

### Parameters

```lua
data: string
```

### Returns

```lua
width: number?
height: number?
error: string?
```

### Example

```lua
local width, height = ImageService.ReadJPEGSize(imageData)
```

---

## ReadWebPSize(data)

Gets the dimensions of a WebP image from its binary data.

Automatically supports:

- VP8
- VP8L
- VP8X

### Parameters

```lua
data: string
```

### Returns

```lua
width: number?
height: number?
error: string?
```

### Example

```lua
local width, height = ImageService.ReadWebPSize(imageData)
```

---

## GetSizeFromBytes(bytes)

Automatically determines image type and retrieves its dimensions.

Supported formats:

- PNG
- JPEG
- WebP

If an error occurs, it is warned internally.

### Parameters

```lua
bytes: string
```

### Returns

```lua
width: number?
height: number?
```

### Example

```lua
local width, height = ImageService:GetSizeFromBytes(imageData)
```

---

## GetImage(url)

Requests an image URL and returns the binary data along with image information.

### Parameters

```lua
url: string
```

### Returns

```lua
{
    Data: string,
    Width: number,
    Height: number,
    StatusCode: number
}
```

### Example

```lua
local imageInfo = ImageService:GetImage(url)

print(imageInfo.Width)
print(imageInfo.Height)
```

---

## CalculateNewSize(width, height, targetWidth)

Calculates a new size while preserving the original aspect ratio.

### Parameters

```lua
width: number
height: number
targetWidth: number
```

### Returns

```lua
size: Vector2
```

### Example

```lua
local newSize =
    ImageService:CalculateNewSize(
        1920,
        1080,
        500
    )

print(newSize)
```

Result:

```lua
Vector2.new(500, 281.25) -- Rounded down to 281
```

---

## GetCenteredPosition(size)

Calculates the screen position required to center an image.

### Parameters

```lua
size: Vector2
```

### Returns

```lua
position: Vector2
```

### Example

```lua
local position =
    ImageService:GetCenteredPosition(
        Vector2.new(500, 281)
    )
```

---

## Create(url)

Creates a Drawing API image object at its original size and centers it on the screen.

### Parameters

```lua
url: string
```

### Returns

```lua
image: DrawingImage
```

### Example

```lua
local image = ImageService:Create(url)
```

Equivalent to:

```lua
local imageInfo = ImageService:GetImage(url)

local image = Drawing.new("Image")

image.Data = imageInfo.Data
image.Size = Vector2.new(
    imageInfo.Width,
    imageInfo.Height
)

image.Position =
    ImageService:GetCenteredPosition(
        image.Size
    )

image.Visible = true
```

---

# Types

## imageData

```lua
type imageData = {
    Data: string,
    Width: number,
    Height: number,
    StatusCode: number
}
```

---

# Usage

## Loading the library

```lua
local ImageService = loadstring(game:HttpGet(
    "https://raw.githubusercontent.com/rebornspy/ImageService/refs/heads/main/ImageService.lua?cachebust=" .. tick(),
    true
))()
```

---

## Creating an Image

```lua
local image = ImageService:Create(
    "https://static.wikia.nocookie.net/charlie-the-steak/images/c/c9/Charlie.png" -- Creates an image of Charlie the Steak, because who wouldn't want him on their screen?
)
```

---

## Accessing Image Information

```lua
local imageInfo = ImageService:GetImage(
    "https://static.wikia.nocookie.net/charlie-the-steak/images/c/c9/Charlie.png"
)

print(`Width: {imageInfo.Width}`)
print(`Height: {imageInfo.Height}`)
print(`Status: {imageInfo.StatusCode}`)
```

---

## Resizing While Preserving Aspect Ratio

```lua
local image = ImageService:Create(url)

local imageInfo = ImageService:GetImage(url)

local size = ImageService:CalculateNewSize(
    imageInfo.Width, -- can also use image.Size.X
    imageInfo.Height, -- can also use image.Size.Y
    500
)

image.Size = size
image.Position = ImageService:GetCenteredPosition(size)
```

---

# Notes

- Does not require `writefile()`
- Works entirely from in-memory binary image data
- Intended for executors whose Drawing API accepts image bytes through:

```lua
image.Data = bytes
```

- Currently supports PNG, JPEG, and WebP images
- Some websites may return WebP images even when the URL ends with `.png`
