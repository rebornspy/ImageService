# ImageService

A lightweight image utility for Drawing API image objects.

ImageService reads image dimensions from in-memory binary data, downloads images, decodes GIF animations, converts GIF frames to PNG, and displays them through a Drawing image object. It does not need to write image files to disk.

## Supported Formats

### Static image dimension detection

- PNG
- JPEG / JPG
- WebP
  - VP8
  - VP8L
  - VP8X

### GIF animation

- GIF87a and GIF89a
- Global and local color tables
- LZW decompression
- Transparency
- Interlaced frames
- Frame delays
- Disposal methods 0–3
- NETSCAPE / ANIMEXTS loop metadata
- Composited RGBA frames

The GIF decoder returns RGBA frame data. `PrepareGIF()` converts those frames to PNG before playback, because the Drawing image in this implementation displays encoded image data rather than the decoder's raw RGBA strings.

---

# Features

- Fetch images and GIFs from URLs
- Detect PNG, JPEG, and WebP dimensions from binary data
- Decode GIF animations in memory
- Optionally downscale decoded GIF frames
- Encode RGBA frames as PNG
- Prepare all GIF frames before playback to avoid PNG encoding during playback
- Release source RGBA frame data after preparation to reduce retained memory
- Play, stop, and clear prepared GIF animations
- Preserve original aspect ratios when calculating sizes or displaying GIFs
- Scale or resize Drawing images without stretching them
- Calculate centered screen positions
- Create Drawing API image objects from image URLs
- Print GIF progress reports using the `[ImageService-GIF]:` prefix

---

# Functions

## Static image retrieval and display

### GetImage(url)

Downloads an image and returns its encoded bytes, dimensions, and HTTP status code.

**Parameters**

```lua
url: string
```

**Returns**

```lua
{
    Data: string,
    Width: number?,
    Height: number?,
    StatusCode: number
}
```

**Example**

```lua
local imageInfo = ImageService:GetImage(url)

print(imageInfo.Width)
print(imageInfo.Height)
print(imageInfo.StatusCode)
```

### Create(url)

Downloads a static image and creates a visible `Drawing.new("Image")` object. The image is displayed at its original dimensions and centered on the screen.

**Parameters**

```lua
url: string
```

**Returns**

```lua
image: DrawingImage
```

**Example**

```lua
local image = ImageService:Create(
    "https://static.wikia.nocookie.net/charlie-the-steak/images/c/c9/Charlie.png"
)
```

### GetCenteredPosition(size)

Calculates the top-left position required to center an image in the current camera viewport.

**Parameters**

```lua
size: Vector2
```

**Returns**

```lua
position: Vector2
```

**Example**

```lua
local position = ImageService:GetCenteredPosition(
    Vector2.new(500, 281.25)
)
```

---

## Aspect ratios and sizing

### CalculateNewSize(width, height, targetWidth)

Calculates a new `Vector2` size using a target width while preserving the input aspect ratio. The returned height is not rounded.

**Parameters**

```lua
width: number
height: number
targetWidth: number
```

**Returns**

```lua
size: Vector2
```

**Example**

```lua
local size = ImageService:CalculateNewSize(1920, 1080, 500)
print(size) -- Vector2.new(500, 281.25)
```

### CalculateNewSizeFromHeight(width, height, targetHeight)

Calculates a new `Vector2` size using a target height while preserving the input aspect ratio.

**Example**

```lua
local size = ImageService:CalculateNewSizeFromHeight(1920, 1080, 300)
print(size) -- Vector2.new(533.333..., 300)
```

### GetGIFProportions(animation)

Returns the GIF's original width, original height, and its width-to-height ratio. It accepts either a decoded animation or a prepared animation.

**Returns**

```lua
width: number
height: number
ratio: number -- width / height
```

**Example**

```lua
local width, height, ratio = ImageService:GetGIFProportions(animation)

print("Original width:", width)
print("Original height:", height)
print("Aspect ratio:", ratio)
```

When `GetGIF()` uses `Scale`, the original dimensions are retained in `OriginalWidth` and `OriginalHeight`.

### GetGIFSize(animation, targetWidth)

Returns the GIF's original dimensions as a `Vector2`. When `targetWidth` is supplied, it returns the proportional dimensions at that width.

**Example**

```lua
local originalSize = ImageService:GetGIFSize(animation)
local resizedSize = ImageService:GetGIFSize(animation, 400)
```

### ScaleGIF(image, scale, keepCenter)

Scales the current Drawing image size by a multiplier. The visual center remains fixed by default.

- `scale = 2` doubles the current size.
- `scale = 0.5` halves the current size.
- Pass `false` for `keepCenter` to keep the top-left position unchanged.

**Example**

```lua
ImageService:ScaleGIF(image, 1.5) -- enlarge by 50%
ImageService:ScaleGIF(image, 0.5) -- halve its current size
```

### ResizeGIF(image, animation, targetWidth, keepCenter)

Sets a Drawing image to a specific width and calculates its height using the GIF's original aspect ratio. The visual center remains fixed by default. Pass `false` for `keepCenter` to keep the top-left position unchanged.

**Example**

```lua
ImageService:ResizeGIF(image, prepared, 400)
```

### FitGIF(image, animation, boundsSize)

Fits a GIF inside a bounding box without stretching it. The current `image.Size` is used as the bounding box when `boundsSize` is omitted. The image is centered within the box.

**Example**

```lua
image.Size = Vector2.new(300, 300)
ImageService:FitGIF(image, prepared)
```

For a 360 × 240 GIF, a 300 × 300 bounding box produces a displayed size of 300 × 200.

---

## GIF decoding

### DecodeGIF(data, limits)

Decodes GIF binary data already held in memory.

**Parameters**

```lua
data: string
limits: table? -- optional settings table
```

Supported `limits` options:

| Option | Default | Description |
|---|---:|---|
| `Scale` | `1` | Output scale from greater than 0 through 1. For example, `0.5` produces half-width and half-height frames. |
| `MaxPixels` | `4000000` | Pixel-count warning threshold for the GIF canvas and individual frames. |
| `MaxFrames` | `500` | Frame-count warning threshold. |
| `ProgressEveryFrames` | `10` | How often decoder frame progress is printed. |
| `Progress` | `true` | Set to `false` to silence GIF progress reports for this operation. |

**Important:** In the current implementation, `MaxPixels` and `MaxFrames` produce warnings when exceeded; they do not truncate or reject the GIF. `Scale` reduces the stored output-frame dimensions, but the decoder still composites frames on the original-size canvas during decoding.

**Returns**

On success, an animation table similar to:

```lua
{
    Width = number,          -- decoded/output frame width
    Height = number,         -- decoded/output frame height
    OriginalWidth = number,  -- source GIF canvas width
    OriginalHeight = number, -- source GIF canvas height
    Scale = number,
    Frames = {
        {
            Data = string,   -- raw RGBA bytes, four bytes per pixel
            Width = number,
            Height = number,
            Delay = number,  -- seconds
            Disposal = number,
            Left = number,
            Top = number
        }
    },
    FrameCount = number,
    LoopCount = number?,     -- nil if no recognized loop extension was present
    Format = "RGBA8"
}
```

On failure, it returns `nil, errorMessage`.

**Example**

```lua
local animation, err = ImageService:DecodeGIF(gifBytes, {
    Scale = 0.5,
    MaxFrames = 300,
    MaxPixels = 4000000
})

if not animation then
    warn("GIF decode failed:", err)
    return
end

print(animation.Width, animation.Height, animation.FrameCount)
```

### GetGIF(url, limits)

Downloads a GIF and passes its response body to `DecodeGIF()`. It returns the decoded animation and adds `StatusCode` to the animation table.

It accepts the same `limits` options as `DecodeGIF()`.

**Example**

```lua
local animation, err = ImageService:GetGIF(
    "https://media1.tenor.com/m/VMst9ENctbQAAAAd/speed-is-how-speed.gif",
    {
        Scale = 0.5,
        MaxFrames = 300,
        MaxPixels = 4000000
    }
)

if not animation then
    warn("GIF download/decode failed:", err)
    return
end

print("Dimensions:", animation.Width, animation.Height)
print("Frames:", animation.FrameCount)
print("HTTP status:", animation.StatusCode)
```

---

## GIF preparation, playback, and cleanup

### PrepareGIF(animation, options)

Encodes every decoded RGBA frame into PNG **before playback starts**. This moves PNG encoding work out of the playback loop, so playback only assigns pre-encoded PNG strings to `image.Data`.

**Options**

| Option | Default | Description |
|---|---:|---|
| `ReleaseRGBA` | `true` | Clears the original RGBA frame strings after each frame is successfully encoded, then removes `animation.Frames` after preparation. Set to `false` to retain decoded RGBA frames. |
| `YieldEveryFrames` | `1` | Yields after this many frames are prepared. |
| `ProgressEveryFrames` | About 10 updates | Controls preparation progress frequency. |
| `Progress` | `true` | Set to `false` to silence preparation progress reports. |

**Returns**

A prepared animation containing PNG data:

```lua
{
    Frames = {
        {
            Data = string, -- encoded PNG bytes
            Delay = number -- seconds
        }
    },
    Width = number,
    Height = number,
    OriginalWidth = number,
    OriginalHeight = number,
    LoopCount = number?,
    FrameCount = number,
    Format = "PNG",
    IsPrepared = true
}
```

**Example**

```lua
local prepared = ImageService:PrepareGIF(animation, {
    ReleaseRGBA = true,
    YieldEveryFrames = 1
})
```

When `ReleaseRGBA` is `true`, the original decoded `animation.Frames` array is removed after preparation. Use the returned `prepared` object for playback and proportion calculations.

### PlayGIF(prepared, image, options)

Plays a prepared GIF using an existing Drawing image. It does not decode or encode frames during playback; it assigns the pre-encoded PNG frame data to `image.Data`.

The initial `image.Size` is treated as a bounding box when `PreserveAspect` is enabled.

**Options**

| Option | Default | Description |
|---|---:|---|
| `MaxFPS` | No additional cap | Optional frame-rate cap, such as `24` or `30`. |
| `MinDelay` | `1 / 60` | Minimum time between frame updates, in seconds. |
| `PreserveAspect` | `true` | Fits the GIF proportionally inside the image's initial `Size` bounding box. Set to `false` to use the current image dimensions without fitting. |
| `ProgressEveryFrames` | About 10 updates | Controls playback progress frequency. |
| `Progress` | `true` | Set to `false` to silence playback progress reports. |

**Returns**

A stop function. Call it to stop playback:

```lua
local stopPlayback = ImageService:PlayGIF(prepared, image, {
    MaxFPS = 24,
    MinDelay = 1 / 30,
    PreserveAspect = true
})

-- Later:
stopPlayback()
```

**Loop behavior**

- `LoopCount == nil`: play once when no recognized loop extension is present.
- `LoopCount == 0`: loop indefinitely.
- Positive `LoopCount`: repeat that many times after the initial play.

### ClearPreparedGIF(prepared, options)

Clears the encoded PNG frame strings from a prepared animation. Stop playback before calling this function, and do not call it if you intend to reuse the prepared animation.

**Options**

| Option | Default | Description |
|---|---:|---|
| `Progress` | `true` | Set to `false` to silence cleanup progress reports. |

**Example**

```lua
stopPlayback()
ImageService:ClearPreparedGIF(prepared)
prepared = nil
```

Clearing the prepared animation releases its Lua references to the PNG strings. Actual memory reclamation is handled by Luau's garbage collector and may not happen immediately. The Drawing object may also retain its currently assigned image data; remove the Drawing object when it is no longer needed:

```lua
image:Remove()
image = nil
```

---

## PNG encoding

### EncodePNG(rgba, width, height)

Encodes raw RGBA pixel bytes into an 8-bit RGBA PNG.

- Uses PNG filter type 0 for every scanline.
- Generates PNG chunks and CRC-32 checksums.
- Uses a zlib stream with uncompressed DEFLATE stored blocks.

**Parameters**

```lua
rgba: string -- exactly width * height * 4 bytes
width: number
height: number
```

**Returns**

```lua
pngData: string
```

On encoding failure, it returns `nil, errorMessage`.

**Example**

```lua
local pngData, err = ImageService:EncodePNG(rgbaBytes, 100, 100)

if not pngData then
    warn("PNG encoding failed:", err)
    return
end

image.Data = pngData
```

Because the encoder uses uncompressed DEFLATE blocks, its PNG output can be substantially larger than output from a compressed PNG encoder. Preparing every frame also requires temporary memory while each PNG is being built.

---

## Progress reports

GIF download, decoding, preparation, playback, and cleanup messages use this prefix:

```text
[ImageService-GIF]: message
```

Progress is enabled by default. Set `Progress = false` in the relevant operation's options to silence that operation.

Examples:

```lua
-- Silence download and decoding reports.
local animation = ImageService:GetGIF(url, {
    Progress = false
})

-- Silence preparation reports.
local prepared = ImageService:PrepareGIF(animation, {
    Progress = false
})

-- Silence playback reports.
local stop = ImageService:PlayGIF(prepared, image, {
    Progress = false
})
```

`ProgressEveryFrames` controls how often frame-based progress is reported during decoding, preparation, and playback. The exact default is stage-dependent and is chosen to produce roughly ten updates for the operation.

---

# Internal helpers

The current module contains local helper functions named `ReadPNGSize`, `ReadJPEGSize`, `ReadWebPSize`, and `GetSizeFromBytes`. They are used internally by `GetImage()` but are **not exported methods** on `ImageService` in this version. They cannot currently be called as `ImageService:ReadPNGSize(...)` or `ImageService:GetSizeFromBytes(...)` without changing the module to expose them.

---

# Complete GIF example

```lua
local ImageService = loadstring(game:HttpGet(
    "https://raw.githubusercontent.com/rebornspy/ImageService/refs/heads/main/ImageService.lua?cachebust=" .. tick(),
    true
))()

local url = "https://media1.tenor.com/m/VMst9ENctbQAAAAd/speed-is-how-speed.gif"

-- Download and decode the GIF. Scale reduces the stored RGBA frame dimensions.
local animation, err = ImageService:GetGIF(url, {
    Scale = 0.5,
    MaxFrames = 300,
    MaxPixels = 4000000,
    ProgressEveryFrames = 10
})

if not animation then
    warn("GIF loading failed:", err)
    return
end

local originalWidth, originalHeight, aspectRatio =
    ImageService:GetGIFProportions(animation)

print("Original dimensions:", originalWidth, originalHeight)
print("Aspect ratio:", aspectRatio)

-- Encode all frames before playback. ReleaseRGBA drops the source RGBA frames.
local prepared = ImageService:PrepareGIF(animation, {
    ReleaseRGBA = true,
    YieldEveryFrames = 1
})

local image = Drawing.new("Image")
image.Position = Vector2.new(100, 100)
image.Size = Vector2.new(300, 300) -- bounding box, not a forced 1:1 image
image.Visible = true

local stopPlayback = ImageService:PlayGIF(prepared, image, {
    MaxFPS = 24,
    MinDelay = 1 / 30,
    PreserveAspect = true
})

-- Resize to an exact width later; height is calculated proportionally.
-- ImageService:ResizeGIF(image, prepared, 400)

-- Stop and clean up when finished:
-- stopPlayback()
-- ImageService:ClearPreparedGIF(prepared)
-- image:Remove()
```

---

# Notes and limitations

- Does not require `writefile()`.
- Image data is handled in memory.
- The Drawing implementation must accept encoded image bytes through `image.Data`.
- `GetImage()` supports dimension detection for PNG, JPEG, and WebP. GIFs should be loaded through `GetGIF()`.
- WebP support here is for reading dimensions; animated WebP decoding is not implemented.
- `Scale` in `GetGIF()` downsamples the returned frame data, but decoding/compositing still uses the source GIF canvas dimensions.
- `MaxPixels` and `MaxFrames` currently issue warnings; they are not strict rejection limits.
- `PrepareGIF()` shifts PNG encoding work to the preparation stage. This can cause a temporary startup pause, but keeps PNG encoding out of the playback loop.
- The PNG encoder uses uncompressed DEFLATE, so prepared GIFs can use substantial memory. Lowering `Scale` reduces frame dimensions and prepared PNG size.
- After calling `PrepareGIF()` with the default `ReleaseRGBA = true`, use the prepared object. The source animation's `Frames` array has been cleared.
- Call the returned playback stop function before `ClearPreparedGIF()`.
- Setting references to `nil` makes data eligible for garbage collection; it does not guarantee immediate memory reclamation.
- GIF decoding and playback should be tested with the specific Luau runtime and Drawing implementation in use.
