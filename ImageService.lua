local ImageService = {}

-- All GIF progress output uses one consistent prefix.
-- Pass Progress = false to GetGIF/DecodeGIF, PrepareGIF, or PlayGIF to silence that stage.
local function GIFProgress(message, enabled)
	if enabled ~= false then
		print("[ImageService-GIF]: " .. tostring(message))
	end
end

-- NORMAL IMAGES (PNG, JPEG, WEBP)

local function ReadPNGSize(data): (number, number)
	local byte = { data:byte(17, 24) }

	local width = byte[1] * 16777216 + byte[2] * 65536 + byte[3] * 256 + byte[4]

	local height = byte[5] * 16777216 + byte[6] * 65536 + byte[7] * 256 + byte[8]

	return width, height
end

local function ReadWebPSize(data): (number?, number?, string?)
	if data:sub(1, 4) ~= "RIFF" or data:sub(9, 12) ~= "WEBP" then
		return nil, nil, "Not a WebP file"
	end

	local VP8Pos = data:find("VP8 ", 1, true)
	if VP8Pos then
		local start = data:find("\x9D\x01\x2A", VP8Pos, true)

		if not start then
			return nil, nil, "VP8 frame header not found"
		end

		local w1, w2, h1, h2 = data:byte(start + 3, start + 6)

		return w1 + bit32.lshift(bit32.band(w2, 0x3F), 8), h1 + bit32.lshift(bit32.band(h2, 0x3F), 8)
	end

	local VP8LPos = data:find("VP8L", 1, true)
	if VP8LPos then
		local signature = data:byte(VP8LPos + 8)

		if signature ~= 0x2F then
			return nil, nil, "Invalid VP8L signature"
		end

		local b1, b2, b3, b4 = data:byte(VP8LPos + 9, VP8LPos + 12)

		local width = 1 + b1 + bit32.lshift(bit32.band(b2, 0x3F), 8)

		local height = 1
			+ bit32.rshift(bit32.band(b2, 0xC0), 6)
			+ bit32.lshift(b3, 2)
			+ bit32.lshift(bit32.band(b4, 0x0F), 10)

		return width, height
	end

	local VP8XPos = data:find("VP8X", 1, true)
	if VP8XPos then
		local w1, w2, w3 = data:byte(VP8XPos + 12, VP8XPos + 14)

		local h1, h2, h3 = data:byte(VP8XPos + 15, VP8XPos + 17)

		local width = 1 + w1 + bit32.lshift(w2, 8) + bit32.lshift(w3, 16)

		local height = 1 + h1 + bit32.lshift(h2, 8) + bit32.lshift(h3, 16)

		return height and width, height
	end

	return nil, nil, "Unsupported WebP variant"
end

local function ReadJPEGSize(data): (number?, number?, string?)
	if data:byte(1) ~= 0xFF or data:byte(2) ~= 0xD8 then
		return nil, nil, "Not a JPEG file"
	end

	local pos = 3

	while pos < #data do
		if data:byte(pos) ~= 0xFF then
			pos += 1
			continue
		end

		local marker = data:byte(pos + 1)

		if
			marker == 0xC0
			or marker == 0xC1
			or marker == 0xC2
			or marker == 0xC3
			or marker == 0xC5
			or marker == 0xC6
			or marker == 0xC7
			or marker == 0xC9
			or marker == 0xCA
			or marker == 0xCB
			or marker == 0xCD
			or marker == 0xCE
			or marker == 0xCF
		then
			local h1, h2 = data:byte(pos + 5, pos + 6)
			local w1, w2 = data:byte(pos + 7, pos + 8)

			return w1 * 256 + w2, h1 * 256 + h2
		end

		if marker == 0xD8 or marker == 0xD9 then
			pos += 2
		else
			local l1, l2 = data:byte(pos + 2, pos + 3)
			local segmentLength = l1 * 256 + l2

			if segmentLength < 2 then
				return nil, nil, "Invalid JPEG segment"
			end

			pos += 2 + segmentLength
		end
	end

	return nil, nil, "SOF marker not found"
end

local function GetSizeFromBytes(bytes): (number?, number?)
	local w, h, err

	if bytes:sub(1, 4) == "RIFF" and bytes:sub(9, 12) == "WEBP" then
		w, h, err = ReadWebPSize(bytes)
	elseif bytes:byte(1) == 0xFF and bytes:byte(2) == 0xD8 then
		w, h, err = ReadJPEGSize(bytes)
	elseif bytes:sub(1, 8) == "\137PNG\r\n\26\n" then
		w, h = ReadPNGSize(bytes)
	end

	if w and h then
		return w, h
	else
		warn(err)
		return nil, nil
	end
end

export type imageData = {
	Data: string,
	Width: number,
	Height: number,
	StatusCode: number,
}

function ImageService:GetImage(url): imageData
    local response = request({
        Url = url,
        Method = "GET",
    })

    assert(response and response.StatusCode == 200,
        "Image download failed")

    local data = response.Body

    assert(type(data) == "string" and #data > 0,
        "Empty image response")

    local isJPEG =
        data:byte(1) == 0xFF
        and data:byte(2) == 0xD8

    if isJPEG then
        print("[ImageService]: Converting JPEG to PNG...")

        local encodedURL = game.HttpService:UrlEncode(url)

        local conversionURL =
            "https://images.weserv.nl/?url="
            .. encodedURL
            .. "&output=png"

        local converted = request({
            Url = conversionURL,
            Method = "GET",
        })

        assert(converted and converted.StatusCode == 200,
            "JPEG conversion failed")

        data = converted.Body

		print("[ImageService] Conversion status:", converted.StatusCode)
		print("[ImageService] Response size:", #data)
		print("[ImageService] Content-Type:",
			converted.Headers and (
				converted.Headers["Content-Type"]
				or converted.Headers["content-type"]
			)
		)
		
		print("[ImageService] First 16 bytes:", data:sub(1, 16):byte(1, 16))
		print("[ImageService] PNG signature:", data:sub(1, 8) == "\137PNG\r\n\26\n")
		print("[ImageService] JPEG signature:",
			data:byte(1) == 0xFF and data:byte(2) == 0xD8
		)

        assert(
            data:sub(1, 8) == "\137PNG\r\n\26\n",
            "Conversion service did not return PNG data"
        )
    end

    local width, height = GetSizeFromBytes(data)

    assert(width and height,
        "Could not determine image dimensions")

    return {
        Data = data,
        Width = width,
        Height = height,
        StatusCode = response.StatusCode,
    }
end

function ImageService:CalculateNewSize(width, height, targetWidth): Vector2
	assert(type(width) == "number" and width > 0, "Invalid image width")
	assert(type(height) == "number" and height > 0, "Invalid image height")

	local targetW = targetWidth or 500
	assert(type(targetW) == "number" and targetW > 0, "Invalid target width")

	local targetHeight = targetW * (height / width)
	return Vector2.new(targetW, targetHeight)
end

-- Calculates a size from a target height while preserving aspect ratio.
function ImageService:CalculateNewSizeFromHeight(width, height, targetHeight): Vector2
	assert(type(width) == "number" and width > 0, "Invalid image width")
	assert(type(height) == "number" and height > 0, "Invalid image height")
	assert(type(targetHeight) == "number" and targetHeight > 0, "Invalid target height")

	local targetWidth = targetHeight * (width / height)
	return Vector2.new(targetWidth, targetHeight)
end

-- Returns original width, original height, and width/height ratio.
-- Original dimensions are used when the decoded GIF was downscaled.
function ImageService:GetGIFProportions(animation)
	assert(type(animation) == "table", "Invalid GIF animation")

	local width = tonumber(animation.OriginalWidth) or tonumber(animation.Width)
	local height = tonumber(animation.OriginalHeight) or tonumber(animation.Height)
	assert(width and width > 0, "GIF has an invalid width")
	assert(height and height > 0, "GIF has an invalid height")

	return width, height, width / height
end

-- Returns the GIF's original size, or its size at the requested width.
function ImageService:GetGIFSize(animation, targetWidth): Vector2
	local width, height = self:GetGIFProportions(animation)

	if targetWidth ~= nil then
		return self:CalculateNewSize(width, height, targetWidth)
	end

	return Vector2.new(width, height)
end

-- Scales the currently displayed Drawing image by a multiplier.
-- Keeps the visual center fixed unless keepCenter is false.
function ImageService:ScaleGIF(image, scale, keepCenter): Vector2
	assert(image and image.Size, "Missing Drawing image")
	assert(type(scale) == "number" and scale > 0, "Scale must be greater than zero")

	local oldSize = image.Size
	local newSize = Vector2.new(oldSize.X * scale, oldSize.Y * scale)

	if keepCenter ~= false then
		image.Position = image.Position + (oldSize - newSize) / 2
	end

	image.Size = newSize
	return newSize
end

-- Sets a Drawing image to a specific width using the GIF's original ratio.
-- Keeps the visual center fixed unless keepCenter is false.
function ImageService:ResizeGIF(image, animation, targetWidth, keepCenter): Vector2
	assert(image and image.Size, "Missing Drawing image")

	local newSize = self:GetGIFSize(animation, targetWidth)
	local oldSize = image.Size

	if keepCenter ~= false then
		image.Position = image.Position + (oldSize - newSize) / 2
	end

	image.Size = newSize
	return newSize
end

-- Fits a GIF inside a bounding box without stretching it.
-- The current image.Size is used when boundsSize is omitted.
function ImageService:FitGIF(image, animation, boundsSize): Vector2
	assert(image and image.Size, "Missing Drawing image")

	local width, height = self:GetGIFProportions(animation)
	local box = boundsSize or image.Size
	assert(box and box.X > 0 and box.Y > 0, "Invalid GIF bounding box")

	local factor = math.min(box.X / width, box.Y / height)
	local fittedSize = Vector2.new(width * factor, height * factor)
	local oldPosition = image.Position

	image.Size = fittedSize
	image.Position = oldPosition + (box - fittedSize) / 2
	return fittedSize
end

function ImageService:GetCenteredPosition(size: Vector2)
	local viewport = workspace.CurrentCamera.ViewportSize

	return (viewport - size) / 2
end

function ImageService:Create(url)
	local imageInfo = ImageService:GetImage(url)

	local size = Vector2.new(imageInfo.Width, imageInfo.Height)

	local image = Drawing.new("Image")
	image.Data = imageInfo.Data
	image.Size = size
	image.Position = self:GetCenteredPosition(size)

	image.Visible = true

	return image
end

-- GIF'S

local function ReadU16(data, pos)
	local a, b = data:byte(pos, pos + 1)

	if not a or not b then
		warn("Unexpected end of GIF data")
	end

	return a + b * 256
end

local function ReadColorTable(data, pos, count)
	local colors = {}

	for i = 1, count do
		local r, g, b = data:byte(pos, pos + 2)

		if not r or not g or not b then
			warn("Incomplete GIF color table")
		end

		colors[i] = { r, g, b }
		pos += 3
	end

	return colors, pos
end

local function ReadSubBlocks(data, pos)
	local blocks = {}
	local blockCount = 0

	while true do
		blockCount += 1
		if blockCount % 64 == 0 then
			task.wait()
		end

		local size = data:byte(pos)
		if size == nil then
			error("Unexpected end of GIF sub-blocks")
		end

		pos += 1
		if size == 0 then
			break
		end

		local block = data:sub(pos, pos + size - 1)
		if #block ~= size then
			error("Incomplete GIF sub-block")
		end

		blocks[#blocks + 1] = block
		pos += size
	end

	return table.concat(blocks), pos
end

--// GIF LZW DECODER

local function DecodeLZW(data, minimumCodeSize, expectedPixels)
	if minimumCodeSize < 2 or minimumCodeSize > 8 then
		error("Invalid GIF LZW minimum code size")
	end

	local clearCode = 2 ^ minimumCodeSize
	local endCode = clearCode + 1
	local nextCode
	local codeSize

	local prefix = {}
	local suffix = {}
	local bitPosition = 0
	local output = table.create(expectedPixels)
	local outputCount = 0

	local function ResetDictionary()
		table.clear(prefix)
		table.clear(suffix)
		codeSize = minimumCodeSize + 1
		nextCode = endCode + 1
	end

	local function ReadCode()
		local bytePosition = math.floor(bitPosition / 8) + 1
		local shift = bitPosition % 8
		local b1 = data:byte(bytePosition) or 0
		local b2 = data:byte(bytePosition + 1) or 0
		local b3 = data:byte(bytePosition + 2) or 0

		if bytePosition + 1 > #data then
			return nil
		end

		local combined = b1 + b2 * 256 + b3 * 65536
		local code = bit32.band(bit32.rshift(combined, shift), (2 ^ codeSize) - 1)

		bitPosition += codeSize
		return code
	end

	local function ExpandCode(code)
		local stack = {}
		local depth = 0

		while code >= clearCode do
			if code >= nextCode then
				error("Invalid GIF LZW dictionary reference")
			end

			depth += 1
			if depth > 4096 then
				error("GIF LZW dictionary cycle detected")
			end

			local index = code + 1
			local previous = prefix[index]
			local value = suffix[index]
			if previous == nil or value == nil then
				error("Invalid GIF LZW dictionary entry")
			end

			stack[#stack + 1] = value
			code = previous
		end

		if code < 0 or code >= clearCode then
			error("Invalid GIF LZW literal")
		end

		stack[#stack + 1] = code
		return stack, code
	end

	local function AppendPixel(value)
		outputCount += 1
		if outputCount > expectedPixels then
			error("GIF frame exceeds expected dimensions")
		end

		output[outputCount] = value
		if outputCount % 8192 == 0 then
			task.wait()
		end
	end

	ResetDictionary()
	local oldCode = nil
	local oldFirst = nil
	local processedCodes = 0

	while true do
		processedCodes += 1
		if processedCodes % 2048 == 0 then
			task.wait()
		end

		local code = ReadCode()
		if code == nil then
			error("GIF LZW stream ended unexpectedly")
		end

		if code == clearCode then
			ResetDictionary()
			oldCode = nil
			oldFirst = nil
			continue
		end

		if code == endCode then
			break
		end

		local stack
		local first

		if code < nextCode then
			stack, first = ExpandCode(code)
		elseif code == nextCode and oldCode ~= nil then
			stack = ExpandCode(oldCode)
			first = oldFirst
		else
			error("Invalid GIF LZW code")
		end

		for i = #stack, 1, -1 do
			AppendPixel(stack[i])
		end

		if code == nextCode and oldCode ~= nil then
			AppendPixel(first)
		end

		if oldCode ~= nil and nextCode < 4096 then
			prefix[nextCode + 1] = oldCode
			suffix[nextCode + 1] = first
			nextCode += 1

			if nextCode == 2 ^ codeSize and codeSize < 12 then
				codeSize += 1
			end
		end

		oldCode = code
		oldFirst = first

		if outputCount == expectedPixels then
			break
		end
	end

	if outputCount ~= expectedPixels then
		error("GIF frame contains an incorrect pixel count")
	end

	return output
end

--// INTERLACE DECODER

local function GetInterlacedRows(height)
	local rows = {}

	local passes = {
		{ 0, 8 },
		{ 4, 8 },
		{ 2, 4 },
		{ 1, 2 },
	}

	for _, pass in ipairs(passes) do
		local start = pass[1]
		local step = pass[2]

		for y = start, height - 1, step do
			rows[#rows + 1] = y
		end
	end

	return rows
end

--// RGBA CANVAS

local function CreateCanvas(width, height)
	local canvas = table.create(width * height * 4, 0)

	return canvas
end

local function FillCanvasRect(canvas, canvasWidth, left, top, width, height, color)
	for y = top, top + height - 1 do
		for x = left, left + width - 1 do
			local index = (y * canvasWidth + x) * 4 + 1

			canvas[index] = color[1]
			canvas[index + 1] = color[2]
			canvas[index + 2] = color[3]
			canvas[index + 3] = color[4]
		end
	end
end

local function DrawGIFFrame(canvas, canvasWidth, canvasHeight, frame, colors, transparentIndex)
	local rows

	if frame.Interlaced then
		rows = GetInterlacedRows(frame.Height)
	else
		rows = {}

		for y = 0, frame.Height - 1 do
			rows[#rows + 1] = y
		end
	end

	local pixelIndex = 1
	local processedPixels = 0

	for _, sourceY in ipairs(rows) do
		local destinationY = frame.Top + sourceY

		for x = 0, frame.Width - 1 do
			local paletteIndex = frame.Pixels[pixelIndex]
			pixelIndex += 1
			processedPixels += 1

			if processedPixels % 16384 == 0 then
				task.wait()
			end

			if paletteIndex == nil then
				warn("Missing GIF frame pixel")
			end

			if paletteIndex ~= transparentIndex then
				local color = colors[paletteIndex + 1]

				if not color then
					warn("GIF references missing palette color")
				end

				local destinationX = frame.Left + x

				if
					destinationX >= 0
					and destinationX < canvasWidth
					and destinationY >= 0
					and destinationY < canvasHeight
				then
					local index = (destinationY * canvasWidth + destinationX) * 4 + 1

					canvas[index] = color[1]
					canvas[index + 1] = color[2]
					canvas[index + 2] = color[3]
					canvas[index + 3] = 255
				end
			end
		end
	end
end

--// CONVERT CANVAS TO RGBA BINARY STRING

local function CanvasToRGBA(canvas, sourceWidth, sourceHeight, outputWidth, outputHeight)
	outputWidth = outputWidth or sourceWidth
	outputHeight = outputHeight or sourceHeight

	local chunks = {}
	local chunk = {}
	local processedPixels = 0
	local scaleX = sourceWidth / outputWidth
	local scaleY = sourceHeight / outputHeight

	for y = 0, outputHeight - 1 do
		local sourceY = math.min(sourceHeight - 1, math.floor(y * scaleY))

		for x = 0, outputWidth - 1 do
			local sourceX = math.min(sourceWidth - 1, math.floor(x * scaleX))
			local sourceIndex = (sourceY * sourceWidth + sourceX) * 4 + 1

			chunk[#chunk + 1] = canvas[sourceIndex]
			chunk[#chunk + 1] = canvas[sourceIndex + 1]
			chunk[#chunk + 1] = canvas[sourceIndex + 2]
			chunk[#chunk + 1] = canvas[sourceIndex + 3]
			processedPixels += 1

			if #chunk >= 4096 then
				chunks[#chunks + 1] = string.char(table.unpack(chunk))
				table.clear(chunk)
			end

			if processedPixels % 8192 == 0 then
				task.wait()
			end
		end
	end

	if #chunk > 0 then
		chunks[#chunks + 1] = string.char(table.unpack(chunk))
	end

	return table.concat(chunks)
end

--// GIF PARSER

function ImageService:DecodeGIF(data, limits)
	limits = limits or {}

	local progressEnabled = limits.Progress ~= false
	local progressEvery = math.max(1, math.floor(tonumber(limits.ProgressEveryFrames) or 10))
	GIFProgress("Starting decoder...", progressEnabled)

	local MAX_PIXELS = limits.MaxPixels or 4000000
	local MAX_FRAMES = limits.MaxFrames or 500
	local outputScale = limits.Scale or 1

	if type(outputScale) ~= "number" or outputScale <= 0 or outputScale > 1 then
		return nil, "Scale must be a number greater than 0 and at most 1"
	end

	local success, result = pcall(function()
		if #data < 13 then
			warn("GIF file is too small")
		end

		local signature = data:sub(1, 6)

		if signature ~= "GIF87a" and signature ~= "GIF89a" then
			warn("Invalid GIF signature")
		end

		local width = ReadU16(data, 7)
		local height = ReadU16(data, 9)

		if width == 0 or height == 0 then
			warn("Invalid GIF dimensions")
		end

		local totalPixels = width * height
		local outputWidth = math.max(1, math.floor(width * outputScale + 0.5))
		local outputHeight = math.max(1, math.floor(height * outputScale + 0.5))
		GIFProgress(
			string.format("Canvas detected: %dx%d; decoded output: %dx%d.", width, height, outputWidth, outputHeight),
			progressEnabled
		)

		if totalPixels > MAX_PIXELS then
			warn("GIF exceeds maximum canvas dimensions")
		end

		local packed = data:byte(11)
		local backgroundIndex = data:byte(12)

		local hasGlobalTable = bit32.band(packed, 0x80) ~= 0
		local globalTableSize = 2 ^ (bit32.band(packed, 0x07) + 1)

		local pos = 14
		local globalColors

		if hasGlobalTable then
			globalColors, pos = ReadColorTable(data, pos, globalTableSize)
		end

		local gce = {
			Disposal = 0,
			Delay = 0,
			Transparent = false,
			TransparentIndex = nil,
		}

		local frames = {}
		local loopCount = nil

		local canvas = CreateCanvas(width, height)

		local previousFrame = nil
		local previousSnapshot = nil

		while pos <= #data do
			local introducer = data:byte(pos)
			pos += 1

			if introducer == 0x3B then
				break
			end

			if introducer == 0x21 then
				local label = data:byte(pos)
				pos += 1

				if not label then
					warn("Incomplete GIF extension")
				end

				if label == 0xF9 then
					local blockSize = data:byte(pos)
					pos += 1

					if blockSize ~= 4 then
						warn("Invalid GIF Graphic Control Extension")
					end

					local control = data:byte(pos)
					local delay = ReadU16(data, pos + 1)
					local transparent = data:byte(pos + 3)

					local terminator = data:byte(pos + 4)

					if terminator ~= 0 then
						warn("Invalid GIF GCE terminator")
					end

					gce.Disposal = bit32.band(bit32.rshift(control, 2), 0x07)

					gce.Delay = delay
					gce.Transparent = bit32.band(control, 1) ~= 0
					gce.TransparentIndex = transparent

					pos += 5
				elseif label == 0xFF then
					local blockSize = data:byte(pos)

					if not blockSize then
						warn("Incomplete GIF application extension")
					end

					pos += 1

					local identifier = data:sub(pos, pos + blockSize - 1)

					pos += blockSize

					local extensionData
					extensionData, pos = ReadSubBlocks(data, pos)

					if identifier == "NETSCAPE2.0" or identifier == "ANIMEXTS1.0" then
						if #extensionData >= 3 and extensionData:byte(1) == 1 then
							loopCount = ReadU16(extensionData, 2)
						end
					end
				else
					local _, newPos = ReadSubBlocks(data, pos)
					pos = newPos
				end

				continue
			end

			if introducer == 0x2C then
				if #frames >= MAX_FRAMES then
					warn("GIF exceeds maximum frame count")
				end

				if previousFrame then
					if previousFrame.Disposal == 2 then
						local backgroundColor = { 0, 0, 0, 0 }

						if not (previousFrame.Transparent and previousFrame.TransparentIndex == backgroundIndex) then
							local bg = globalColors and globalColors[backgroundIndex + 1]

							if bg then
								backgroundColor = {
									bg[1],
									bg[2],
									bg[3],
									255,
								}
							end
						end

						FillCanvasRect(
							canvas,
							width,
							previousFrame.Left,
							previousFrame.Top,
							previousFrame.Width,
							previousFrame.Height,
							backgroundColor
						)
					elseif previousFrame.Disposal == 3 then
						if previousSnapshot then
							canvas = previousSnapshot
						end
					end
				end

				local left = ReadU16(data, pos)
				local top = ReadU16(data, pos + 2)
				local frameWidth = ReadU16(data, pos + 4)
				local frameHeight = ReadU16(data, pos + 6)

				local imagePacked = data:byte(pos + 8)

				if not imagePacked then
					warn("Incomplete GIF image descriptor")
				end

				pos += 9

				if frameWidth == 0 or frameHeight == 0 then
					warn("Invalid GIF frame dimensions")
				end

				if frameWidth * frameHeight > MAX_PIXELS then
					warn("GIF frame exceeds maximum pixel count")
				end

				local localTablePresent = bit32.band(imagePacked, 0x80) ~= 0

				local interlaced = bit32.band(imagePacked, 0x40) ~= 0

				local localTableSize = 2 ^ (bit32.band(imagePacked, 0x07) + 1)

				local colors = globalColors

				if localTablePresent then
					colors, pos = ReadColorTable(data, pos, localTableSize)
				end

				if not colors then
					warn("GIF has no color table")
				end

				local minimumCodeSize = data:byte(pos)

				if not minimumCodeSize then
					warn("Missing GIF LZW minimum code size")
				end

				pos += 1

				local compressed
				compressed, pos = ReadSubBlocks(data, pos)

				local expectedPixels = frameWidth * frameHeight

				local pixels = DecodeLZW(compressed, minimumCodeSize, expectedPixels)

				local snapshot

				if gce.Disposal == 3 then
					snapshot = table.clone(canvas)
				end

				local frame = {
					Left = left,
					Top = top,
					Width = frameWidth,
					Height = frameHeight,

					Pixels = pixels,
					Interlaced = interlaced,

					Delay = gce.Delay / 100,

					Disposal = gce.Disposal,

					Transparent = gce.Transparent,
					TransparentIndex = gce.Transparent and gce.TransparentIndex or nil,
				}

				DrawGIFFrame(canvas, width, height, frame, colors, frame.TransparentIndex)

				frames[#frames + 1] = {
					Data = CanvasToRGBA(canvas, width, height, outputWidth, outputHeight),

					Width = outputWidth,
					Height = outputHeight,

					Delay = frame.Delay,
					Disposal = frame.Disposal,

					Left = left,
					Top = top,
				}

				if #frames == 1 or #frames % progressEvery == 0 then
					GIFProgress(string.format("Decoded %d frames...", #frames), progressEnabled)
				end

				previousFrame = frame
				previousSnapshot = snapshot

				gce = {
					Disposal = 0,
					Delay = 0,
					Transparent = false,
					TransparentIndex = nil,
				}

				continue
			end

			warn("Unknown GIF block introducer: " .. tostring(introducer))
		end

		if #frames == 0 then
			warn("GIF contains no image frames")
		end

		return {
			Width = outputWidth,
			Height = outputHeight,
			OriginalWidth = width,
			OriginalHeight = height,
			Scale = outputScale,

			Frames = frames,
			FrameCount = #frames,

			LoopCount = loopCount,

			Format = "RGBA8",
		}
	end)

	if not success then
		GIFProgress("Decoder failed: " .. tostring(result), progressEnabled)
		return nil, tostring(result)
	end

	GIFProgress(string.format("Decoding complete: %d frames.", result.FrameCount), progressEnabled)
	return result
end

--// DOWNLOAD AND DECODE GIF

function ImageService:GetGIF(url, limits)
	limits = limits or {}
	local progressEnabled = limits.Progress ~= false

	GIFProgress("Sending HTTP request...", progressEnabled)

	local requestOK, response = pcall(function()
		return request({
			Url = url,
			Method = "GET",
		})
	end)

	if not requestOK then
		local err = "HTTP request failed: " .. tostring(response)
		GIFProgress(err, progressEnabled)
		return nil, err
	end

	GIFProgress("HTTP request returned.", progressEnabled)

	if not response or type(response.Body) ~= "string" then
		local err = "Empty or invalid HTTP response"
		GIFProgress(err, progressEnabled)
		return nil, err
	end

	if response.StatusCode < 200 or response.StatusCode >= 300 then
		local err = "HTTP error: " .. tostring(response.StatusCode)
		GIFProgress(err, progressEnabled)
		return nil, err
	end

	GIFProgress(
		string.format("Downloaded %d bytes (HTTP %s).", #response.Body, tostring(response.StatusCode)),
		progressEnabled
	)
	local animation, err = self:DecodeGIF(response.Body, limits)

	if not animation then
		GIFProgress("GIF decoding failed: " .. tostring(err), progressEnabled)
		return nil, err
	end

	animation.StatusCode = response.StatusCode
	GIFProgress(
		string.format("GIF ready: %dx%d, %d frames.", animation.Width, animation.Height, animation.FrameCount),
		progressEnabled
	)

	return animation
end

--// GIF ANIMATION PLAYER

-- PrepareGIF encodes every frame before playback. This intentionally moves
-- the CPU cost to the preparation stage so playback only assigns PNG strings.
-- options:
--   ReleaseRGBA: clear the original decoded RGBA frame strings after encoding (default true)
--   YieldEveryFrames: yield after this many prepared frames (default 1)
function ImageService:PrepareGIF(animation, options)
	options = options or {}

	assert(animation and animation.Frames, "Invalid GIF animation")
	assert(#animation.Frames > 0, "GIF contains no frames")

	local progressEnabled = options.Progress ~= false
	local releaseRGBA = options.ReleaseRGBA ~= false
	local yieldEvery = math.max(1, math.floor(tonumber(options.YieldEveryFrames) or 1))
	local frameCount = #animation.Frames
	local progressEvery =
		math.max(1, math.floor(tonumber(options.ProgressEveryFrames) or math.max(1, math.ceil(frameCount / 10))))

	GIFProgress(string.format("Preparing %d frames as PNG...", frameCount), progressEnabled)

	local prepared = {
		Frames = table.create(#animation.Frames),
		Width = animation.Width,
		Height = animation.Height,
		OriginalWidth = animation.OriginalWidth or animation.Width,
		OriginalHeight = animation.OriginalHeight or animation.Height,
		LoopCount = animation.LoopCount,
		FrameCount = #animation.Frames,
		Format = "PNG",
		IsPrepared = true,
	}

	for i, frame in ipairs(animation.Frames) do
		if type(frame.Data) ~= "string" then
			local err = "GIF frame " .. i .. " has no RGBA Data"
			GIFProgress("Preparation failed: " .. err, progressEnabled)
			error(err)
		end

		local png, err = self:EncodePNG(frame.Data, frame.Width or animation.Width, frame.Height or animation.Height)

		if not png then
			local message = "Failed to encode GIF frame " .. i .. ": " .. tostring(err)
			GIFProgress("Preparation failed: " .. message, progressEnabled)
			error(message)
		end

		prepared.Frames[i] = {
			Data = png,
			Delay = math.max(tonumber(frame.Delay) or 0.1, 0.02),
		}

		-- Once encoded, the raw RGBA string is no longer needed for playback.
		-- Releasing it avoids retaining both full frame sets in memory.
		if releaseRGBA then
			frame.Data = nil
		end

		if i == 1 or i % progressEvery == 0 or i == frameCount then
			GIFProgress(
				string.format("Prepared %d/%d frames (%.0f%%).", i, frameCount, (i / frameCount) * 100),
				progressEnabled
			)
		end

		if i % yieldEvery == 0 then
			task.wait()
		end
	end

	if releaseRGBA then
		-- Drop the source frame array so its per-frame metadata can be collected too.
		animation.Frames = nil
	end

	GIFProgress(string.format("Preparation complete: %d PNG frames ready.", prepared.FrameCount), progressEnabled)
	return prepared
end

-- PlayGIF only assigns pre-encoded PNG data. No PNG encoding or cache management
-- occurs in the playback loop.
-- options:
--   MaxFPS: optional cap, e.g. 24 or 30
--   MinDelay: minimum frame delay (default 1/60)
--   PreserveAspect: fit the GIF proportionally inside the image's initial Size (default true)
function ImageService:PlayGIF(animation, image, options)
	options = options or {}

	assert(animation and animation.Frames, "Invalid prepared GIF animation")
	assert(image, "Missing Drawing image")

	local frames = animation.Frames
	local frameCount = #frames
	assert(frameCount > 0, "GIF contains no frames")

	local progressEnabled = options.Progress ~= false
	local progressEvery =
		math.max(1, math.floor(tonumber(options.ProgressEveryFrames) or math.max(1, math.ceil(frameCount / 10))))

	local minDelay = math.max(tonumber(options.MinDelay) or (1 / 60), 0.001)
	local maxFPS = tonumber(options.MaxFPS)
	if maxFPS and maxFPS <= 0 then
		maxFPS = nil
	end

	-- Fit the GIF's original proportions inside the requested bounding box.
	if options.PreserveAspect ~= false then
		self:FitGIF(image, animation, image.Size)
	end

	local playback = { Running = true, StopRequested = false }
	GIFProgress(string.format("Playback started: %d frames.", frameCount), progressEnabled)

	task.spawn(function()
		local index = 1
		local completedPlays = 0
		local loopCount = animation.LoopCount

		local function hasMorePlays()
			-- No loop extension: play once. Zero: infinite. Positive: repeats
			-- after the initial play, as specified by the NETSCAPE extension.
			if loopCount == nil then
				return false
			elseif loopCount == 0 then
				return true
			end
			return completedPlays <= loopCount
		end

		while playback.Running do
			local frame = frames[index]
			if not frame or type(frame.Data) ~= "string" then
				GIFProgress("Playback stopped: prepared frame " .. index .. " is missing PNG data.", progressEnabled)
				break
			end

			local assigned, assignError = pcall(function()
				image.Data = frame.Data
			end)

			if not assigned then
				GIFProgress("Playback image update failed: " .. tostring(assignError), progressEnabled)
				break
			end

			if index == 1 or index % progressEvery == 0 then
				GIFProgress(
					string.format("Playing frame %d/%d (play %d).", index, frameCount, completedPlays + 1),
					progressEnabled
				)
			end

			local delay = tonumber(frame.Delay) or 0.1
			if delay <= 0 then
				delay = 0.1
			end
			delay = math.max(delay, minDelay)
			if maxFPS then
				delay = math.max(delay, 1 / maxFPS)
			end

			task.wait(delay)
			if not playback.Running then
				break
			end

			index += 1
			if index > frameCount then
				completedPlays += 1
				if not hasMorePlays() then
					break
				end
				index = 1
			end
		end

		playback.Running = false
		if playback.StopRequested then
			GIFProgress("Playback stopped.", progressEnabled)
		else
			GIFProgress("Playback finished.", progressEnabled)
		end
	end)

	return function()
		if playback.Running then
			playback.StopRequested = true
			playback.Running = false
		end
	end
end

-- Releases all encoded PNG frames held by a prepared animation.
-- Call this after stopping playback when the GIF will not be reused.
function ImageService:ClearPreparedGIF(prepared, options)
	if not prepared then
		return
	end

	local progressEnabled = not (options and options.Progress == false)
	GIFProgress("Clearing prepared PNG frames...", progressEnabled)

	if prepared.Frames then
		for _, frame in ipairs(prepared.Frames) do
			frame.Data = nil
		end
		table.clear(prepared.Frames)
		prepared.Frames = nil
	end

	prepared.FrameCount = 0
	prepared.IsPrepared = false
	GIFProgress("Prepared frame data cleared.", progressEnabled)
end

local function UInt32BE(value)
	return string.char(
		bit32.band(bit32.rshift(value, 24), 0xFF),
		bit32.band(bit32.rshift(value, 16), 0xFF),
		bit32.band(bit32.rshift(value, 8), 0xFF),
		bit32.band(value, 0xFF)
	)
end

local function UInt16LE(value)
	return string.char(bit32.band(value, 0xFF), bit32.band(bit32.rshift(value, 8), 0xFF))
end

--// CRC32

local CRC_TABLE = table.create(256)

for i = 0, 255 do
	local crc = i

	for _ = 1, 8 do
		if bit32.band(crc, 1) ~= 0 then
			crc = bit32.bxor(bit32.rshift(crc, 1), 0xEDB88320)
		else
			crc = bit32.rshift(crc, 1)
		end
	end

	CRC_TABLE[i + 1] = crc
end

local function CRC32(data)
	local crc = 0xFFFFFFFF

	for i = 1, #data do
		if i % 65536 == 0 then
			task.wait()
		end

		local index = bit32.band(bit32.bxor(crc, data:byte(i)), 0xFF)

		crc = bit32.bxor(bit32.rshift(crc, 8), CRC_TABLE[index + 1])
	end

	return bit32.bnot(crc)
end

--// ADLER32

local function Adler32(data)
	local a = 1
	local b = 0

	local MOD = 65521

	for i = 1, #data do
		if i % 65536 == 0 then
			task.wait()
		end

		a = (a + data:byte(i)) % MOD
		b = (b + a) % MOD
	end

	return b * 65536 + a
end

--// PNG CHUNK

local function PNGChunk(chunkType, data)
	local chunk = chunkType .. data

	return UInt32BE(#data) .. chunk .. UInt32BE(CRC32(chunk))
end

--// ZLIB STORED DEFLATE

local function ZlibStore(data)
	local chunks = {}

	-- Zlib header:
	-- CMF = 0x78
	-- FLG = 0x01
	chunks[#chunks + 1] = "\x78\x01"

	local pos = 1
	local length = #data
	local blockCount = 0

	while pos <= length do
		blockCount += 1
		if blockCount % 4 == 0 then
			task.wait()
		end

		local blockSize = math.min(65535, length - pos + 1)

		local isFinal = pos + blockSize - 1 == length

		-- Stored DEFLATE block:
		-- BFINAL + BTYPE(00), padded to byte boundary.
		local header = isFinal and 0x01 or 0x00

		local block = data:sub(pos, pos + blockSize - 1)

		local inverseSize = 65535 - blockSize

		chunks[#chunks + 1] = string.char(header) .. UInt16LE(blockSize) .. UInt16LE(inverseSize) .. block

		pos += blockSize
	end

	-- Adler-32 checksum is big-endian.
	chunks[#chunks + 1] = UInt32BE(Adler32(data))

	return table.concat(chunks)
end

--// RGBA -> PNG

function ImageService:EncodePNG(rgba, width, height)
	local success, result = pcall(function()
		assert(type(rgba) == "string", "RGBA data must be a string")

		assert(type(width) == "number" and width > 0 and width % 1 == 0 and width <= 0x7FFFFFFF, "Invalid PNG width")

		assert(
			type(height) == "number" and height > 0 and height % 1 == 0 and height <= 0x7FFFFFFF,
			"Invalid PNG height"
		)

		local expectedSize = width * height * 4

		assert(#rgba == expectedSize, "RGBA byte count does not match dimensions")

		-- Each scanline starts with filter type 0.
		local scanlines = {}

		for y = 0, height - 1 do
			local start = y * width * 4 + 1
			local finish = start + width * 4 - 1

			scanlines[#scanlines + 1] = "\x00" .. rgba:sub(start, finish)
		end

		local rawData = table.concat(scanlines)

		-- Compress using valid Zlib stored DEFLATE blocks.
		local compressed = ZlibStore(rawData)

		-- PNG signature.
		local signature = "\x89PNG\r\n\x1A\n"

		-- IHDR:
		-- Width, Height, Bit Depth, Color Type,
		-- Compression, Filter, Interlace.
		local ihdr = UInt32BE(width)
			.. UInt32BE(height)
			.. string.char(
				8, -- Bit depth
				6, -- RGBA
				0, -- Compression
				0, -- Filter
				0 -- No interlacing
			)

		local png = signature .. PNGChunk("IHDR", ihdr) .. PNGChunk("IDAT", compressed) .. PNGChunk("IEND", "")

		return png
	end)

	if not success then
		return nil, tostring(result)
	end

	return result
end

return ImageService

--[[
FUNCTIONS:

    IMAGE SIZE & RETRIEVAL:
    * Read[type]Size(data)
        - Reads dimensions for PNG, JPEG, and WebP image bytes.

    * GetSizeFromBytes(bytes)
        - Detects PNG, JPEG, or WebP and returns width and height.

    * GetImage(url)
        - Downloads a regular image and returns Data, Width, Height,
          and StatusCode.

    IMAGE POSITIONING & ASPECT RATIOS:
    * CalculateNewSize(width, height, targetWidth)
        - Returns a Vector2 with the requested width and proportional height.

    * CalculateNewSizeFromHeight(width, height, targetHeight)
        - Returns a Vector2 with the requested height and proportional width.

    * GetGIFProportions(animation)
        - Returns original width, original height, and width/height ratio.

    * GetGIFSize(animation, targetWidth)
        - Returns the GIF's original size or its size at a requested width.

    * ScaleGIF(image, scale, keepCenter)
        - Multiplies the displayed image dimensions equally to preserve ratio.

    * ResizeGIF(image, animation, targetWidth, keepCenter)
        - Sets a specific width and calculates the proportional height.

    * FitGIF(image, animation, boundsSize)
        - Fits the GIF inside a bounding box without stretching it.

    * GetCenteredPosition(size)
        - Returns the top-left position needed to center an image on screen.

    * Create(url)
        - Downloads a regular image and creates a centered Drawing image.

    GIF DECODING:
    * DecodeGIF(data, limits)
        - Decodes GIF87a/GIF89a, including LZW, palettes, transparency,
          interlacing, frame delays, disposal, and loop metadata.
        - limits.Scale can downsample frames; MaxFrames and MaxPixels
          constrain decoded input size.
        - Returns composited RGBA frames in frame.Data.

    * GetGIF(url, limits)
        - Downloads a GIF and decodes it using the optional limits table.
        - Prints progress messages prefixed with [ImageService-GIF]:.
        - ProgressEveryFrames controls decoder log frequency (default 10).
        - Set limits.Progress = false to silence GIF download/decoding logs.

    GIF PREPARATION & PLAYBACK:
    * PrepareGIF(animation, options)
        - Encodes every decoded RGBA frame to PNG before playback.
        - This moves encoding work out of the playback loop.
        - ReleaseRGBA defaults to true, clearing the original RGBA frame
          data after each successful PNG encode to reduce retained memory.
          Set ReleaseRGBA = false to keep the source frames.
        - YieldEveryFrames controls how often preparation yields (default 1).
        - ProgressEveryFrames controls log frequency; Progress = false silences logs.

    * PlayGIF(prepared, image, options)
        - Playback only assigns pre-encoded PNG frames; it does no encoding.
        - MaxFPS and MinDelay can limit update frequency.
        - PreserveAspect defaults to true and fits the GIF inside the
          Drawing image's initial Size bounding box without stretching.
        - Returns a stop function.
        - Logs start, periodic frame progress, and stop/completion status.
        - ProgressEveryFrames controls log frequency; Progress = false silences logs.

    * ClearPreparedGIF(prepared)
        - Clears encoded PNG frame data when the prepared animation is
          no longer needed. Stop playback before calling this.

    PNG ENCODING:
    * EncodePNG(rgba, width, height)
        - Encodes raw RGBA pixels as an 8-bit RGBA PNG.
        - Uses filter type 0 and uncompressed DEFLATE blocks.

USAGE:

    local animation, err = ImageService:GetGIF(
        "https://example.com/animation.gif",
        { Scale = 0.5, MaxFrames = 300, MaxPixels = 4000000 }
    )

    if not animation then
        warn("GIF decode failed:", err)
        return
    end

    -- This is where PNG encoding happens, before playback starts.
    local prepared = ImageService:PrepareGIF(animation, {
        ReleaseRGBA = true,
        YieldEveryFrames = 1
    })

    local image = Drawing.new("Image")
    image.Position = Vector2.new(100, 100)
    image.Size = Vector2.new(300, 300) -- treated as a bounding box
    image.Visible = true

    local stopPlayback = ImageService:PlayGIF(prepared, image, {
        MaxFPS = 24,
        MinDelay = 1 / 30,
        PreserveAspect = true
    })

    -- Stop playback:
    stopPlayback()

    -- When finished with the animation, release its prepared PNG data:
    ImageService:ClearPreparedGIF(prepared)

PROPORTION & SCALING EXAMPLE:

    local animation = ImageService:GetGIF("https://example.com/animation.gif")
    local width, height, ratio = ImageService:GetGIFProportions(animation)
    print("Original dimensions:", width, height)
    print("Aspect ratio:", ratio)

    local image = Drawing.new("Image")
    image.Position = Vector2.new(100, 100)
    image.Size = Vector2.new(300, 300) -- bounding box for PlayGIF
    image.Visible = true

    -- PlayGIF fits the GIF inside this box without stretching it.
    local prepared = ImageService:PrepareGIF(animation)
    local stop = ImageService:PlayGIF(prepared, image)

    -- Set exact width (height is calculated from original proportions).
    ImageService:ResizeGIF(image, prepared, 400)

    -- Or scale the current image to 150% while keeping its center.
    ImageService:ScaleGIF(image, 1.5)

NOTES:
    * Lower Scale values reduce RGBA memory before preparation.
    * Preparing all PNG frames takes work up front, but playback avoids
      per-frame encoding stutters.
    * The PNG encoder uses stored (uncompressed) DEFLATE blocks, so PNG
      frames are larger than they would be with a compressed encoder.
    * Garbage collection reclaims released strings over time; setting
      references to nil does not guarantee immediate memory reduction.
    * Test against the target Luau runtime and Drawing implementation.
]]
