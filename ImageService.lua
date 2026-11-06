local ImageService = {}

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

	while (pos < #data) and task.wait() do
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
	elseif bytes:sub(1) == 0xFF and bytes:sub(2) == 0xD8 then
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

	local width, height = GetSizeFromBytes(response.Body)

	local dataTable: imageData = {
		Data = response.Body,
		Width = width,
		Height = height,
		StatusCode = response.StatusCode,
	}

	return dataTable
end

function ImageService:CalculateNewSize(width, height, targetWidth): Vector2
	local aspectRatio = height / width
	local targetW = targetWidth or 500
	local targetHeight = targetW * aspectRatio

	return Vector2.new(targetWidth, targetHeight)
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

        colors[i] = {r, g, b}
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

        if not size then
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
        warn("Invalid GIF LZW minimum code size")
    end

    local clearCode = 2 ^ minimumCodeSize
    local endCode = clearCode + 1

    local nextCode
    local codeSize

    local prefix = {}
    local suffix = {}

    local bitPosition = 0
    local output = {}
	local processedCodes = 0

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

        local combined =
            b1 +
            b2 * 256 +
            b3 * 65536

        local code = bit32.band(
            bit32.rshift(combined, shift),
            (2 ^ codeSize) - 1
        )

        bitPosition += codeSize

        return code
    end

    local function ExpandCode(code)
        local stack = {}
        local depth = 0

        while code >= clearCode do
            if code >= nextCode then
                warn("Invalid GIF LZW dictionary reference")
            end

            depth += 1

            if depth > 4096 then
                warn("GIF LZW dictionary cycle detected")
            end

            local index = code + 1
            local previous = prefix[index]
            local value = suffix[index]

            if previous == nil or value == nil then
                warn("Invalid GIF LZW dictionary entry")
            end

            stack[#stack + 1] = value
            code = previous
        end

        if code < 0 or code >= clearCode then
            warn("Invalid GIF LZW literal")
        end

        stack[#stack + 1] = code

        return stack, code
    end

    ResetDictionary()

    local oldCode = nil
    local oldFirst = nil

    while true do
		processedCodes += 1

		if processedCodes % 2048 == 0 then
			task.wait()
		end

		local code = ReadCode()

        if code == nil then
            warn("GIF LZW stream ended unexpectedly")
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
            warn("Invalid GIF LZW code")
        end

        for i = #stack, 1, -1 do
            output[#output + 1] = stack[i]

            if #output > expectedPixels then
                warn("GIF frame exceeds expected dimensions")
            end
        end

        if code == nextCode and oldCode ~= nil then
            output[#output + 1] = first

            if #output > expectedPixels then
                warn("GIF frame exceeds expected dimensions")
            end
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

        if #output == expectedPixels then
            break
        end
    end

    if #output ~= expectedPixels then
        warn("GIF frame contains an incorrect pixel count")
    end

    return output
end

--// INTERLACE DECODER

local function GetInterlacedRows(height)
    local rows = {}

    local passes = {
        {0, 8},
        {4, 8},
        {2, 4},
        {1, 2}
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

local function FillCanvasRect(
    canvas,
    canvasWidth,
    left,
    top,
    width,
    height,
    color
)
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

local function DrawGIFFrame(
    canvas,
    canvasWidth,
    canvasHeight,
    frame,
    colors,
    transparentIndex
)
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

    for _, sourceY in ipairs(rows) do
        local destinationY = frame.Top + sourceY

        for x = 0, frame.Width - 1 do
            local paletteIndex = frame.Pixels[pixelIndex]
            pixelIndex += 1

            if paletteIndex == nil then
                warn("Missing GIF frame pixel")
            end

            if paletteIndex ~= transparentIndex then
                local color = colors[paletteIndex + 1]

                if not color then
                    warn("GIF references missing palette color")
                end

                local destinationX = frame.Left + x

                if destinationX >= 0
                    and destinationX < canvasWidth
                    and destinationY >= 0
                    and destinationY < canvasHeight
                then
                    local index =
                        (destinationY * canvasWidth + destinationX) * 4 + 1

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

local function CanvasToRGBA(canvas)
    local chunks = {}
    local chunk = {}

    for i = 1, #canvas do
        chunk[#chunk + 1] = canvas[i]

        if #chunk >= 4096 then
            chunks[#chunks + 1] = string.char(table.unpack(chunk))
            table.clear(chunk)
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

    local MAX_PIXELS = limits.MaxPixels or 4000000
    local MAX_FRAMES = limits.MaxFrames or 500

    local success, result = pcall(function()
        if #data < 13 then
            warn("GIF file is too small")
        end

        local signature = data:sub(1, 6)

        if signature ~= "GIF87a"
            and signature ~= "GIF89a"
        then
            warn("Invalid GIF signature")
        end

        local width = ReadU16(data, 7)
        local height = ReadU16(data, 9)

        if width == 0 or height == 0 then
            warn("Invalid GIF dimensions")
        end

        local totalPixels = width * height

        if totalPixels > MAX_PIXELS then
            warn("GIF exceeds maximum canvas dimensions")
        end

        local packed = data:byte(11)
        local backgroundIndex = data:byte(12)

        local hasGlobalTable = bit32.band(packed, 0x80) ~= 0
        local globalTableSize = 2 ^ (
            bit32.band(packed, 0x07) + 1
        )

        local pos = 14
        local globalColors

        if hasGlobalTable then
            globalColors, pos = ReadColorTable(
                data,
                pos,
                globalTableSize
            )
        end

        local gce = {
            Disposal = 0,
            Delay = 0,
            Transparent = false,
            TransparentIndex = nil
        }

        local frames = {}
        local loopCount = nil

        local canvas = CreateCanvas(width, height)

        local previousFrame = nil
        local previousSnapshot = nil

        while (pos <= #data) and task.wait() do
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

                    gce.Disposal = bit32.band(
                        bit32.rshift(control, 2),
                        0x07
                    )

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

                    local identifier = data:sub(
                        pos,
                        pos + blockSize - 1
                    )

                    pos += blockSize

                    local extensionData
                    extensionData, pos = ReadSubBlocks(data, pos)

                    if identifier == "NETSCAPE2.0"
                        or identifier == "ANIMEXTS1.0"
                    then
                        if #extensionData >= 3
                            and extensionData:byte(1) == 1
                        then
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
                        local backgroundColor = {0, 0, 0, 0}

                        if not (
                            previousFrame.Transparent
                            and previousFrame.TransparentIndex
                                == backgroundIndex
                        ) then
                            local bg = globalColors
                                and globalColors[backgroundIndex + 1]

                            if bg then
                                backgroundColor = {
                                    bg[1], bg[2], bg[3], 255
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

                local localTablePresent =
                    bit32.band(imagePacked, 0x80) ~= 0

                local interlaced =
                    bit32.band(imagePacked, 0x40) ~= 0

                local localTableSize = 2 ^ (
                    bit32.band(imagePacked, 0x07) + 1
                )

                local colors = globalColors

                if localTablePresent then
                    colors, pos = ReadColorTable(
                        data,
                        pos,
                        localTableSize
                    )
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

                local pixels = DecodeLZW(
                    compressed,
                    minimumCodeSize,
                    expectedPixels
                )

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
                    TransparentIndex = gce.Transparent
                        and gce.TransparentIndex or nil
                }

                DrawGIFFrame(
                    canvas,
                    width,
                    height,
                    frame,
                    colors,
                    frame.TransparentIndex
                )

                frames[#frames + 1] = {
                    Data = CanvasToRGBA(canvas),

                    Width = width,
                    Height = height,

                    Delay = frame.Delay,
                    Disposal = frame.Disposal,

                    Left = left,
                    Top = top
                }

                previousFrame = frame
                previousSnapshot = snapshot

                gce = {
                    Disposal = 0,
                    Delay = 0,
                    Transparent = false,
                    TransparentIndex = nil
                }

                continue
            end

            warn("Unknown GIF block introducer: " .. tostring(introducer))
        end

        if #frames == 0 then
            warn("GIF contains no image frames")
        end

        return {
            Width = width,
            Height = height,

            Frames = frames,
            FrameCount = #frames,

            LoopCount = loopCount,

            Format = "RGBA8"
        }
    end)

    if not success then
        return nil, tostring(result)
    end

    return result
end

--// DOWNLOAD AND DECODE GIF

function ImageService:GetGIF(url)
    warn("[GIF] Sending HTTP request...")

    local requestSuccess, response = pcall(function()
        return request({
            Url = url,
            Method = "GET"
        })
    end)

    if not requestSuccess then
        return nil, "HTTP request failed: " .. tostring(response)
    end

    warn("[GIF] HTTP request returned")

    if not response or type(response.Body) ~= "string" then
        return nil, "Empty or invalid HTTP response"
    end

    warn("[GIF] Downloaded bytes:", #response.Body)
    warn("[GIF] Signature:", response.Body:sub(1, 6))
    warn("[GIF] Starting decoder...")

    local animation, err = self:DecodeGIF(response.Body)

    warn("[GIF] Decoder finished")

    if not animation then
        return nil, err
    end

    animation.StatusCode = response.StatusCode

    warn("[GIF] Frames decoded:", animation.FrameCount)

    return animation
end

--// GIF ANIMATION PLAYER

function ImageService:PrepareGIF(animation)
    assert(animation and animation.Frames, "Invalid GIF animation")

    local prepared = {
        Frames = {},
        Width = animation.Width,
        Height = animation.Height,
        LoopCount = animation.LoopCount
    }

    for i, frame in ipairs(animation.Frames) do
        local png, err = self:EncodePNG(
            frame.Data,
            frame.Width or animation.Width,
            frame.Height or animation.Height
        )

        if not png then
            error("Failed to encode GIF frame " .. i .. ": " .. tostring(err))
        end

        prepared.Frames[i] = {
            Data = png,
            Delay = math.max(frame.Delay or 0.1, 0.02)
        }
    end

    return prepared
end

function ImageService:PlayGIF(animation, image)
    assert(animation and animation.Frames, "Invalid animation")
    assert(image, "Missing Drawing image")

    local frames = animation.Frames
    local frameCount = #frames

    assert(frameCount > 0, "GIF contains no frames")

    local playback = {
        Running = true
    }

    task.spawn(function()
        local index = 1
        local loops = 0

        while playback.Running do
            local frame = frames[index]

            if not frame then
                break
            end

            local success, err = pcall(function()
                image.Data = frame.Data
            end)

            if not success then
                warn("GIF playback error:", err)
                break
            end

            task.wait(frame.Delay)

            if not playback.Running then
                break
            end

            index += 1

            if index > frameCount then
                index = 1
                loops += 1

                if animation.LoopCount
                    and animation.LoopCount > 0
                    and loops >= animation.LoopCount then
                    break
                end
            end
        end

        playback.Running = false
    end)

    return function()
        playback.Running = false
    end
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
    return string.char(
        bit32.band(value, 0xFF),
        bit32.band(bit32.rshift(value, 8), 0xFF)
    )
end

--// CRC32

local CRC_TABLE = table.create(256)

for i = 0, 255 do
    local crc = i

    for _ = 1, 8 do
        if bit32.band(crc, 1) ~= 0 then
            crc = bit32.bxor(
                bit32.rshift(crc, 1),
                0xEDB88320
            )
        else
            crc = bit32.rshift(crc, 1)
        end
    end

    CRC_TABLE[i + 1] = crc
end

local function CRC32(data)
    local crc = 0xFFFFFFFF

    for i = 1, #data do
        local index = bit32.band(
            bit32.bxor(crc, data:byte(i)),
            0xFF
        )

        crc = bit32.bxor(
            bit32.rshift(crc, 8),
            CRC_TABLE[index + 1]
        )
    end

    return bit32.bnot(crc)
end

--// ADLER32

local function Adler32(data)
    local a = 1
    local b = 0

    local MOD = 65521

    for i = 1, #data do
        a = (a + data:byte(i)) % MOD
        b = (b + a) % MOD
    end

    return b * 65536 + a
end

--// PNG CHUNK

local function PNGChunk(chunkType, data)
    local chunk =
        chunkType .. data

    return
        UInt32BE(#data) ..
        chunk ..
        UInt32BE(CRC32(chunk))
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

    while (pos <= length) and task.wait() do
        local blockSize = math.min(
            65535,
            length - pos + 1
        )

        local isFinal = pos + blockSize - 1 == length

        -- Stored DEFLATE block:
        -- BFINAL + BTYPE(00), padded to byte boundary.
        local header = isFinal and 0x01 or 0x00

        local block = data:sub(
            pos,
            pos + blockSize - 1
        )

        local inverseSize = 65535 - blockSize

        chunks[#chunks + 1] =
            string.char(header) ..
            UInt16LE(blockSize) ..
            UInt16LE(inverseSize) ..
            block

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

        assert(
            type(width) == "number"
                and width > 0
                and width % 1 == 0
                and width <= 0x7FFFFFFF,
            "Invalid PNG width"
        )

        assert(
            type(height) == "number"
                and height > 0
                and height % 1 == 0
                and height <= 0x7FFFFFFF,
            "Invalid PNG height"
        )

        local expectedSize = width * height * 4

        assert(
            #rgba == expectedSize,
            "RGBA byte count does not match dimensions"
        )

        -- Each scanline starts with filter type 0.
        local scanlines = {}

        for y = 0, height - 1 do
            local start = y * width * 4 + 1
            local finish = start + width * 4 - 1

            scanlines[#scanlines + 1] =
                "\x00" .. rgba:sub(start, finish)
        end

        local rawData = table.concat(scanlines)

        -- Compress using valid Zlib stored DEFLATE blocks.
        local compressed = ZlibStore(rawData)

        -- PNG signature.
        local signature = "\x89PNG\r\n\x1A\n"

        -- IHDR:
        -- Width, Height, Bit Depth, Color Type,
        -- Compression, Filter, Interlace.
        local ihdr =
            UInt32BE(width) ..
            UInt32BE(height) ..
            string.char(
                8, -- Bit depth
                6, -- RGBA
                0, -- Compression
                0, -- Filter
                0  -- No interlacing
            )

        local png =
            signature ..
            PNGChunk("IHDR", ihdr) ..
            PNGChunk("IDAT", compressed) ..
            PNGChunk("IEND", "")

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
        - Gets the dimensions of an image from its binary data.
        - Supported types: PNG, JPEG, WebP.

    * GetSizeFromBytes(bytes)
        - Automatically detects the image type and retrieves its
          width and height.
        - Supports PNG, JPEG, and WebP.
        - Warns if the image type is unsupported or its dimensions
          cannot be read.

    * GetImage(url)
        - Downloads image data from the given URL.
        - Retrieves the image's width and height.
        - Returns the image data, dimensions, and HTTP status code.

    IMAGE POSITIONING:
    * CalculateNewSize(width, height, targetWidth)
        - Calculates the new height while preserving the image's
          aspect ratio at the specified target width.

    * GetCenteredPosition(width, height)
        - Calculates the screen position needed to center an image
          using the current camera's viewport dimensions.

    IMAGE CREATION:
    * Create(url)
        - Downloads an image and creates a Drawing image object.
        - Uses the image's original dimensions.
        - Positions the image in the center of the screen.

    GIF DECODING:
    * DecodeGIF(data, limits)
        - Decodes GIF87a and GIF89a binary data.
        - Supports GIF LZW decompression, global and local color
          tables, transparency, frame delays, and interlacing.
        - Handles frame disposal methods 0 through 3.
        - Composites frames onto a canvas and returns full RGBA
          frame data.
        - Reads GIF looping information when available.
        - Supports optional limits to help control frame count
          and image dimensions.

    * GetGIF(url)
        - Downloads GIF data from the given URL.
        - Passes the downloaded data to DecodeGIF.
        - Returns the decoded animation information.

    GIF PLAYBACK:
    * PlayGIF(animation, image, encodeFrame)
        - Plays a decoded GIF using an existing Drawing image.
        - Updates the image with each animation frame.
        - Uses the frame delays and looping information.
        - Accepts an encodeFrame callback to convert each RGBA
          frame into a format supported by the Drawing image.
        - Returns a function that can be called to stop playback.

    PNG ENCODING:
    * EncodePNG(rgba, width, height)
        - Encodes raw RGBA pixel data into PNG binary data.
        - Uses 8-bit RGBA color and PNG filter type 0.
        - Generates PNG chunks, CRC-32 checksums, and a zlib
          stream using uncompressed DEFLATE blocks.
        - Returns the resulting PNG data as a string.

USAGE:

    local ImageService = loadstring(game:HttpGet(
        `https://raw.githubusercontent.com/rebornspy/ImageService/refs/heads/main/ImageService.lua?cachebust={tick()}`,
        true
    ))()

    -- Create and center a regular image:
    local image = ImageService:Create(
        "https://static.wikia.nocookie.net/charlie-the-steak/images/c/c9/Charlie.png"
    )

    -- Decode a GIF:
    local animation = ImageService:GetGIF("https://example.com/animation.gif")

    -- Play the GIF using an existing Drawing image:
    local stopPlayback = ImageService:PlayGIF(
        animation,
        image,
        function(rgba, width, height)
            return ImageService:EncodePNG(rgba, width, height)
        end
    )

    -- Stop GIF playback:
    stopPlayback()

NOTES:
    * GIF decoding and PNG encoding operate on binary image data.
    * GIF playback requires a Drawing image object and an encoder
      callback that returns image data supported by the Drawing API.
    * The PNG encoder currently uses uncompressed DEFLATE blocks.
      This produces valid PNG structure but larger files than
      compressed PNG encoders.
    * Large GIFs can consume significant memory. Use decoding limits
      when processing untrusted or high-resolution images.
    * GIF decoding and encoding should be tested against the target
      Luau runtime and Drawing implementation.
]]
