local ImageService = {}

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

local function GetSizeFromBytes(bytes)
    if type(bytes) ~= "string" or #bytes < 12 then
        return nil, nil, "Image data is empty or too small"
    end

    local w, h, err

    if bytes:sub(1, 8) == "\137PNG\r\n\26\n" then
        w, h = ReadPNGSize(bytes)

    elseif bytes:byte(1) == 0xFF
        and bytes:byte(2) == 0xD8 then

        w, h, err = ReadJPEGSize(bytes)

    elseif bytes:sub(1, 4) == "RIFF"
        and bytes:sub(9, 12) == "WEBP" then

        w, h, err = ReadWebPSize(bytes)

    else
        err = "Unsupported image format. Signature: "
            .. tostring(bytes:sub(1, 12):byte(1, 12))
    end

    if w and h then
        return w, h
    end

    return nil, nil, err or "Could not read image dimensions"
end

export type imageData = {
	Data: string,
	Width: number,
	Height: number,
	StatusCode: number,
}

local JPEG_ZIGZAG = {
	0, 1, 8, 16, 9, 2, 3, 10,
	17, 24, 32, 25, 18, 11, 4, 5,
	12, 19, 26, 33, 40, 48, 41, 34,
	27, 20, 13, 6, 7, 14, 21, 28,
	35, 42, 49, 56, 57, 50, 43, 36,
	29, 22, 15, 23, 30, 37, 44, 51,
	58, 59, 52, 45, 38, 31, 39, 46,
	53, 60, 61, 54, 47, 55, 62, 63,
}

local JPEG_COS = table.create(8)
local JPEG_C = { 1 / math.sqrt(2), 1, 1, 1, 1, 1, 1, 1 }

for x = 0, 7 do
	JPEG_COS[x + 1] = table.create(8)

	for u = 0, 7 do
		JPEG_COS[x + 1][u + 1] =
			math.cos(((2 * x + 1) * u * math.pi) / 16)
	end
end

local function JPEGClamp(value)
	return math.max(0, math.min(255, math.floor(value + 0.5)))
end

local function JPEGReadU16(data, pos)
	local a, b = data:byte(pos, pos + 1)

	if not a or not b then
		error("Unexpected end of JPEG data")
	end

	return a * 256 + b
end

local function JPEGBuildHuffman(counts, symbols)
	local tableByLength = {}
	local code = 0
	local symbolIndex = 1

	for length = 1, 16 do
		local count = counts[length]

		if count > 0 then
			local entries = {}

			for _ = 1, count do
				local symbol = symbols[symbolIndex]

				if symbol == nil then
					error("Incomplete JPEG Huffman table")
				end

				entries[code] = symbol
				code += 1
				symbolIndex += 1
			end

			tableByLength[length] = entries
		end

		code *= 2
	end

	return tableByLength
end

local function JPEGExtend(value, bitCount)
	if bitCount == 0 then
		return 0
	end

	local threshold = 2 ^ (bitCount - 1)

	if value < threshold then
		return value - (2 ^ bitCount) + 1
	end

	return value
end

local function JPEGIDCT(coefficients, quantization)
	local temporary = table.create(64)

	for v = 0, 7 do
		for x = 0, 7 do
			local sum = 0

			for u = 0, 7 do
				local index = v * 8 + u + 1
				local value = coefficients[index] * quantization[index]

				sum += JPEG_C[u + 1] * value * JPEG_COS[x + 1][u + 1]
			end

			temporary[v * 8 + x + 1] = sum
		end
	end

	local output = table.create(64)

	for y = 0, 7 do
		for x = 0, 7 do
			local sum = 0

			for v = 0, 7 do
				sum += JPEG_C[v + 1]
					* temporary[v * 8 + x + 1]
					* JPEG_COS[y + 1][v + 1]
			end

			output[y * 8 + x + 1] = JPEGClamp(sum / 4 + 128)
		end
	end

	return output
end

local function DecodeJPEG(data, options)
    options = options or {}

    assert(type(data) == "string", "JPEG data must be a string")
    assert(data:byte(1) == 0xFF and data:byte(2) == 0xD8, "Invalid JPEG signature")

    local maxPixels = math.floor(tonumber(options.MaxPixels) or 8000000)
    local maxBlocks = math.floor(tonumber(options.MaxBlocks) or 400000)
    assert(maxPixels > 0, "MaxPixels must be positive")
    assert(maxBlocks > 0, "MaxBlocks must be positive")

    local bufferLib = buffer
    local useBuffer = type(bufferLib) == "table"
        and type(bufferLib.create) == "function"
        and type(bufferLib.readi32) == "function"
        and type(bufferLib.writei32) == "function"
        and type(bufferLib.readu8) == "function"
        and type(bufferLib.writeu8) == "function"

    local function NewIntArray(length)
        if useBuffer then
            return { Buffer = bufferLib.create(length * 4), Length = length }
        end
        return { Values = table.create(length, 0), Length = length }
    end

    local function GetInt(array, index)
        if index < 0 or index >= array.Length then
            error("JPEG coefficient index is out of range")
        end
        if array.Buffer then
            return bufferLib.readi32(array.Buffer, index * 4)
        end
        return array.Values[index + 1] or 0
    end

    local function SetInt(array, index, value)
        if index < 0 or index >= array.Length then
            error("JPEG coefficient index is out of range")
        end
        if array.Buffer then
            bufferLib.writei32(array.Buffer, index * 4, value)
        else
            array.Values[index + 1] = value
        end
    end

    local function NewByteArray(length)
        if useBuffer then
            return { Buffer = bufferLib.create(length), Length = length }
        end
        return { Values = table.create(length, 0), Length = length }
    end

    local function GetByte(array, index)
        if index < 0 or index >= array.Length then
            error("JPEG sample index is out of range")
        end
        if array.Buffer then
            return bufferLib.readu8(array.Buffer, index)
        end
        return array.Values[index + 1] or 0
    end

    local function SetByte(array, index, value)
        if index < 0 or index >= array.Length then
            error("JPEG sample index is out of range")
        end
        if array.Buffer then
            bufferLib.writeu8(array.Buffer, index, value)
        else
            array.Values[index + 1] = value
        end
    end

    local pos = 3
    local width, height
    local components = nil
    local componentByID = {}
    local frameMode = nil
    local maxH, maxV
    local mcuColumns, mcuRows
    local quantizationTables = {}
    local huffmanTables = { [0] = {}, [1] = {} }
    local restartInterval = 0
    local sawScan = false
    local sawEOI = false
    local decodedUnits = 0

    local function InitializeFrame()
        maxH, maxV = 1, 1

        for _, component in ipairs(components) do
            maxH = math.max(maxH, component.H)
            maxV = math.max(maxV, component.V)
        end

        mcuColumns = math.ceil(width / (maxH * 8))
        mcuRows = math.ceil(height / (maxV * 8))

        local totalBlocks = 0

        for _, component in ipairs(components) do
            component.BlocksWide = mcuColumns * component.H
            component.BlocksHigh = mcuRows * component.V
            component.PlaneWidth = component.BlocksWide * 8
            component.PlaneHeight = component.BlocksHigh * 8

            local blockCount = component.BlocksWide * component.BlocksHigh
            totalBlocks += blockCount

            if totalBlocks > maxBlocks then
                error("JPEG exceeds the configured coefficient block limit")
            end

            component.Coefficients = NewIntArray(blockCount * 64)
            component.Progression = table.create(64)
            component.DC = 0
        end
    end

    local function GetCoefficient(component, blockIndex, naturalIndex)
        return GetInt(component.Coefficients, blockIndex * 64 + naturalIndex)
    end

    local function SetCoefficient(component, blockIndex, naturalIndex, value)
        SetInt(component.Coefficients, blockIndex * 64 + naturalIndex, value)
    end

    local function BuildEntropyReader(startPosition)
        local bytePosition = startPosition
        local bitBuffer = 0
        local bitsLeft = 0

        local function ReadBit()
            if bitsLeft == 0 then
                local value = data:byte(bytePosition)
                if value == nil then
                    error("JPEG entropy stream ended unexpectedly")
                end
                bytePosition += 1

                if value == 0xFF then
                    local following = data:byte(bytePosition)
                    if following ~= 0x00 then
                        error("Unexpected marker inside JPEG entropy data")
                    end
                    bytePosition += 1
                end

                bitBuffer = value
                bitsLeft = 8
            end

            local result = bit32.band(bit32.rshift(bitBuffer, bitsLeft - 1), 1)
            bitsLeft -= 1
            return result
        end

        local function ReadBits(count)
            local value = 0
            for _ = 1, count do
                value = value * 2 + ReadBit()
            end
            return value
        end

        local function ReadHuffman(tableData)
            if not tableData then
                error("JPEG scan references a missing Huffman table")
            end

            local code = 0
            for length = 1, 16 do
                code = code * 2 + ReadBit()
                local entries = tableData[length]
                local symbol = entries and entries[code]
                if symbol ~= nil then
                    return symbol
                end
            end

            error("Invalid JPEG Huffman code")
        end

        local function ConsumeRestart(expectedMarker)
            bitBuffer = 0
            bitsLeft = 0

            if data:byte(bytePosition) ~= 0xFF then
                error("JPEG restart marker is missing")
            end

            while data:byte(bytePosition) == 0xFF do
                bytePosition += 1
            end

            local marker = data:byte(bytePosition)
            bytePosition += 1

            if marker ~= expectedMarker then
                error("Unexpected JPEG restart marker")
            end
        end

        local function GetPosition()
            return bytePosition
        end

        return ReadBit, ReadBits, ReadHuffman, ConsumeRestart, GetPosition
    end

    local function DecodeScan(scanComponents, spectralStart, spectralEnd, ah, al, entropyStart)
        local isDCScan = spectralStart == 0
        local isSequential = frameMode == "baseline"

        if isSequential then
            if spectralStart ~= 0 or spectralEnd ~= 63 or ah ~= 0 or al ~= 0 then
                error("Invalid sequential JPEG scan parameters")
            end
        else
            if ah > 0 and al ~= ah - 1 then
                error("Invalid progressive JPEG successive-approximation order")
            end

            if isDCScan then
                if spectralEnd ~= 0 then
                    error("Progressive DC scans must use spectral range 0..0")
                end
            else
                if spectralStart < 1 or spectralStart > spectralEnd or spectralEnd > 63 then
                    error("Invalid progressive JPEG AC spectral range")
                end
                if #scanComponents ~= 1 then
                    error("Progressive JPEG AC scans must contain exactly one component")
                end
            end
        end

        for _, scanComponent in ipairs(scanComponents) do
            local component = scanComponent.Component
            local firstCoefficient = isSequential and 0 or spectralStart
            local lastCoefficient = isSequential and 63 or spectralEnd

            if not isSequential then
                if ah == 0 then
                    for k = firstCoefficient, lastCoefficient do
                        if component.Progression[k + 1] ~= nil then
                            error("Progressive JPEG repeats an initial coefficient scan")
                        end
                    end
                else
                    for k = firstCoefficient, lastCoefficient do
                        if component.Progression[k + 1] ~= ah then
                            error("Progressive JPEG refinement scan is out of order")
                        end
                    end
                end

                if spectralStart > 0 and component.Progression[1] == nil then
                    error("Progressive JPEG AC scan appears before its DC scan")
                end
            else
                if component.SequentialSeen then
                    error("Sequential JPEG component was scanned more than once")
                end
            end

            component.DC = 0
        end

        for _, scanComponent in ipairs(scanComponents) do
            if isSequential then
                if not scanComponent.DC or not scanComponent.AC then
                    error("Sequential JPEG scan references a missing Huffman table")
                end
            elseif isDCScan and ah == 0 then
                if not scanComponent.DC then
                    error("Progressive DC scan references a missing DC Huffman table")
                end
            elseif not isDCScan then
                if not scanComponent.AC then
                    error("Progressive AC scan references a missing AC Huffman table")
                end
            end
        end

        local interleaved = #scanComponents > 1
        local unitsWide
        local unitsHigh
        local totalUnits

        if interleaved then
            unitsWide = mcuColumns
            unitsHigh = mcuRows
        else
            local component = scanComponents[1].Component
            unitsWide = math.ceil((width * component.H) / (maxH * 8))
            unitsHigh = math.ceil((height * component.V) / (maxV * 8))
        end

        totalUnits = unitsWide * unitsHigh

        local ReadBit, ReadBits, ReadHuffman, ConsumeRestart, GetPosition =
            BuildEntropyReader(entropyStart)

        local eobRun = 0
        local restartNumber = 0
        local unitIndex = 0
        local p1 = 2 ^ al

        local function RefineExistingCoefficient(component, blockIndex, naturalIndex)
            local coefficient = GetCoefficient(component, blockIndex, naturalIndex)
            if coefficient ~= 0 then
                if ReadBit() ~= 0 and bit32.band(coefficient, p1) == 0 then
                    if coefficient > 0 then
                        coefficient += p1
                    else
                        coefficient -= p1
                    end
                    SetCoefficient(component, blockIndex, naturalIndex, coefficient)
                end
            end
        end

        local function DecodeSequentialBlock(component, blockIndex, dcTable, acTable)
            local dcLength = ReadHuffman(dcTable)
            if dcLength > 11 then
                error("Invalid JPEG DC coefficient length")
            end

            component.DC += JPEGExtend(ReadBits(dcLength), dcLength)
            SetCoefficient(component, blockIndex, 0, component.DC)

            local k = 1
            while k <= 63 do
                local symbol = ReadHuffman(acTable)
                local run = bit32.rshift(symbol, 4)
                local size = bit32.band(symbol, 0x0F)

                if size == 0 then
                    if run == 0 then
                        break
                    elseif run == 15 then
                        k += 16
                    else
                        error("Invalid sequential JPEG AC run")
                    end
                else
                    if size > 10 then
                        error("Invalid sequential JPEG AC coefficient size")
                    end

                    k += run
                    if k > 63 then
                        error("Sequential JPEG AC coefficient exceeds block")
                    end

                    local value = JPEGExtend(ReadBits(size), size)
                    SetCoefficient(component, blockIndex, JPEG_ZIGZAG[k + 1], value)
                    k += 1
                end
            end
        end

        local function DecodeDCFirst(component, blockIndex, dcTable)
            local dcLength = ReadHuffman(dcTable)
            if dcLength > 11 then
                error("Invalid progressive JPEG DC coefficient length")
            end

            component.DC += JPEGExtend(ReadBits(dcLength), dcLength)
            SetCoefficient(component, blockIndex, 0, component.DC * p1)
        end

        local function DecodeDCRefinement(component, blockIndex)
            if ReadBit() ~= 0 then
                local value = GetCoefficient(component, blockIndex, 0)
                if bit32.band(value, p1) == 0 then
                    SetCoefficient(component, blockIndex, 0, value + p1)
                end
            end
        end

        local function DecodeACFirst(component, blockIndex, acTable)
            if eobRun > 0 then
                eobRun -= 1
                return
            end

            local k = spectralStart
            while k <= spectralEnd do
                local symbol = ReadHuffman(acTable)
                local run = bit32.rshift(symbol, 4)
                local size = bit32.band(symbol, 0x0F)

                if size == 0 then
                    if run == 15 then
                        k += 16
                    else
                        eobRun = 2 ^ run + ReadBits(run) - 1
                        break
                    end
                else
                    if size > 10 then
                        error("Invalid progressive JPEG AC coefficient size")
                    end

                    k += run
                    if k > spectralEnd then
                        error("Progressive JPEG AC run exceeds spectral band")
                    end

                    local value = JPEGExtend(ReadBits(size), size) * p1
                    SetCoefficient(component, blockIndex, JPEG_ZIGZAG[k + 1], value)
                    k += 1
                end
            end
        end

        local function DecodeACRefinement(component, blockIndex, acTable)
            local k = spectralStart

            if eobRun == 0 then
                while k <= spectralEnd do
                    local symbol = ReadHuffman(acTable)
                    local run = bit32.rshift(symbol, 4)
                    local size = bit32.band(symbol, 0x0F)
                    local newValue = nil
                    local isZRL = false

                    if size ~= 0 then
                        if size ~= 1 then
                            error("Progressive JPEG AC refinement size must be 1")
                        end

                        newValue = ReadBit() ~= 0 and p1 or -p1
                    elseif run ~= 15 then
                        eobRun = 2 ^ run + ReadBits(run)
                        break
					else
                        run = 16
                        isZRL = true
                    end

                    while k <= spectralEnd do
                        local naturalIndex = JPEG_ZIGZAG[k + 1]
                        local coefficient = GetCoefficient(component, blockIndex, naturalIndex)

                        if coefficient ~= 0 then
                            RefineExistingCoefficient(component, blockIndex, naturalIndex)
                            k += 1
                        else
                            if run == 0 then
                                break
                            end

                            run -= 1
                            k += 1

                            if isZRL and run == 0 then
                                break
                            end
                        end
                    end

                    if newValue ~= nil then
                        if k > spectralEnd then
                            error("Progressive JPEG refinement run exceeds spectral band")
                        end
                        SetCoefficient(component, blockIndex, JPEG_ZIGZAG[k + 1], newValue)
                        k += 1
                    end
                end
            end

            if eobRun > 0 then
                while k <= spectralEnd do
                    RefineExistingCoefficient(component, blockIndex, JPEG_ZIGZAG[k + 1])
                    k += 1
                end
                eobRun -= 1
            end
        end

        local function DecodeOneBlock(scanComponent, blockX, blockY)
            local component = scanComponent.Component
            if blockX < 0 or blockX >= component.BlocksWide
                or blockY < 0 or blockY >= component.BlocksHigh then
                error("JPEG scan addresses a block outside the component plane")
            end

            local blockIndex = blockY * component.BlocksWide + blockX

            if isSequential then
                DecodeSequentialBlock(component, blockIndex, scanComponent.DC, scanComponent.AC)
            elseif isDCScan then
                if ah == 0 then
                    DecodeDCFirst(component, blockIndex, scanComponent.DC)
                else
                    DecodeDCRefinement(component, blockIndex)
                end
            elseif ah == 0 then
                DecodeACFirst(component, blockIndex, scanComponent.AC)
            else
                DecodeACRefinement(component, blockIndex, scanComponent.AC)
            end
        end

        for unitY = 0, unitsHigh - 1 do
            for unitX = 0, unitsWide - 1 do
                unitIndex += 1

                if interleaved then
                    for _, scanComponent in ipairs(scanComponents) do
                        local component = scanComponent.Component

                        for blockY = 0, component.V - 1 do
                            for blockX = 0, component.H - 1 do
                                DecodeOneBlock(
                                    scanComponent,
                                    unitX * component.H + blockX,
                                    unitY * component.V + blockY
                                )
                            end
                        end
                    end
                else
                    DecodeOneBlock(scanComponents[1], unitX, unitY)
                end

                if restartInterval > 0 and unitIndex < totalUnits
                    and unitIndex % restartInterval == 0 then
                    ConsumeRestart(0xD0 + restartNumber)
                    restartNumber = (restartNumber + 1) % 8
                    eobRun = 0

                    for _, scanComponent in ipairs(scanComponents) do
                        scanComponent.Component.DC = 0
                    end
                end

                if unitIndex % 256 == 0 then
                    task.wait()
                end
            end
        end

        if eobRun ~= 0 then
            error("Progressive JPEG EOB run extends beyond its scan")
        end

        return GetPosition()
    end

    while pos <= #data do
        if data:byte(pos) ~= 0xFF then
            error("Invalid JPEG marker alignment")
        end

        while data:byte(pos) == 0xFF do
            pos += 1
        end

        local marker = data:byte(pos)
        pos += 1
        if marker == nil then
            error("Unexpected end of JPEG markers")
        end

        if marker == 0xD9 then
            sawEOI = true
            break
        elseif marker == 0xD8 or marker == 0x01 then
            continue
        elseif marker >= 0xD0 and marker <= 0xD7 then
            error("Unexpected restart marker outside JPEG entropy data")
        end

        local length = JPEGReadU16(data, pos)
        if length < 2 or pos + length - 1 > #data then
            error("Invalid JPEG segment length")
        end

        local payload = pos + 2
        local payloadEnd = pos + length - 1
        local nextSegment = pos + length

        if marker == 0xC0 or marker == 0xC2 then
            if components then
                error("JPEG contains multiple frame headers")
            end

            local precision = data:byte(payload)
            height = JPEGReadU16(data, payload + 1)
            width = JPEGReadU16(data, payload + 3)
            local count = data:byte(payload + 5)

            if precision ~= 8 then
                error("Only 8-bit JPEG images are supported")
            end
            if not width or not height or width < 1 or height < 1 then
                error("Invalid JPEG dimensions")
            end
            if width * height > maxPixels then
                error("JPEG exceeds the configured pixel limit")
            end
            if count ~= 1 and count ~= 3 then
                error("Only grayscale and three-component JPEGs are supported")
            end
            if length ~= 8 + count * 3 then
                error("Invalid JPEG frame header length")
            end

            frameMode = marker == 0xC2 and "progressive" or "baseline"
            components = {}
            componentByID = {}

            for i = 1, count do
                local offset = payload + 6 + (i - 1) * 3
                local id = data:byte(offset)
                local sampling = data:byte(offset + 1)
                local quantID = data:byte(offset + 2)

                if componentByID[id] then
                    error("Duplicate JPEG component identifier")
                end

                local horizontal = bit32.rshift(sampling, 4)
                local vertical = bit32.band(sampling, 0x0F)
                if horizontal < 1 or horizontal > 4 or vertical < 1 or vertical > 4 then
                    error("Invalid JPEG sampling factors")
                end
                if quantID > 3 then
                    error("Invalid JPEG quantization table selector")
                end

                local component = {
                    ID = id,
                    H = horizontal,
                    V = vertical,
                    QuantID = quantID,
                    DC = 0,
                }

                components[i] = component
                componentByID[id] = component
            end

            InitializeFrame()
        elseif marker == 0xC1 or marker == 0xC3 or marker == 0xC5 or marker == 0xC6
            or marker == 0xC7 or marker == 0xC9 or marker == 0xCA or marker == 0xCB
            or marker == 0xCD or marker == 0xCE or marker == 0xCF then
            error("Unsupported JPEG frame type; only SOF0 and SOF2 are supported")
        elseif marker == 0xDB then -- DQT
            local cursor = payload
            while cursor <= payloadEnd do
                local info = data:byte(cursor)
                if not info then
                    error("Incomplete JPEG quantization table")
                end
                cursor += 1

                local precision = bit32.rshift(info, 4)
                local tableID = bit32.band(info, 0x0F)
                if precision ~= 0 then
                    error("16-bit JPEG quantization tables are not supported")
                end
                if tableID > 3 then
                    error("Invalid JPEG quantization table identifier")
                end

                local quant = table.create(64)
                for i = 1, 64 do
                    local value = data:byte(cursor)
                    if value == nil or value == 0 then
                        error("Invalid or incomplete JPEG quantization table")
                    end
                    quant[JPEG_ZIGZAG[i] + 1] = value
                    cursor += 1
                end
                quantizationTables[tableID] = quant
            end
        elseif marker == 0xC4 then
            local cursor = payload
            while cursor <= payloadEnd do
                local info = data:byte(cursor)
                if not info then
                    error("Incomplete JPEG Huffman table")
                end
                cursor += 1

                local tableClass = bit32.rshift(info, 4)
                local tableID = bit32.band(info, 0x0F)
                if tableClass > 1 or tableID > 3 then
                    error("Invalid JPEG Huffman table selector")
                end

                local counts = table.create(16)
                local total = 0
                for i = 1, 16 do
                    local count = data:byte(cursor)
                    if count == nil then
                        error("Incomplete JPEG Huffman table counts")
                    end
                    counts[i] = count
                    total += count
                    cursor += 1
                end

                if cursor + total - 1 > payloadEnd then
                    error("Incomplete JPEG Huffman symbols")
                end

                local symbols = table.create(total)
                for i = 1, total do
                    symbols[i] = data:byte(cursor)
                    cursor += 1
                end

                huffmanTables[tableClass][tableID] = JPEGBuildHuffman(counts, symbols)
            end
        elseif marker == 0xDD then
            if length ~= 4 then
                error("Invalid JPEG restart interval segment")
            end
            restartInterval = JPEGReadU16(data, payload)
        elseif marker == 0xDA then
            if not components then
                error("JPEG scan appears before its frame header")
            end

            local count = data:byte(payload)
            if not count or count < 1 or count > #components then
                error("Invalid JPEG scan component count")
            end
            if length ~= 6 + count * 2 then
                error("Invalid JPEG scan header length")
            end

            local scanComponents = {}
            local seenInScan = {}

            for i = 1, count do
                local offset = payload + 1 + (i - 1) * 2
                local id = data:byte(offset)
                local selector = data:byte(offset + 1)
                local component = componentByID[id]

                if not component then
                    error("JPEG scan references an unknown component")
                end
                if seenInScan[id] then
                    error("JPEG scan contains a duplicate component")
                end
                seenInScan[id] = true

                local dcID = bit32.rshift(selector, 4)
                local acID = bit32.band(selector, 0x0F)
                if dcID > 3 or acID > 3 then
                    error("Invalid JPEG scan Huffman table selector")
                end

                scanComponents[i] = {
                    Component = component,
                    DC = huffmanTables[0][dcID],
                    AC = huffmanTables[1][acID],
                }
            end

            local spectralStart = data:byte(payload + 1 + count * 2)
            local spectralEnd = data:byte(payload + 2 + count * 2)
            local successive = data:byte(payload + 3 + count * 2)
            local ah = bit32.rshift(successive, 4)
            local al = bit32.band(successive, 0x0F)

            if spectralStart == nil or spectralEnd == nil or successive == nil then
                error("Incomplete JPEG scan header")
            end

            if ah > 13 or al > 13 then
                error("Invalid JPEG successive-approximation value")
            end

            local entropyStart = nextSegment
            pos = DecodeScan(scanComponents, spectralStart, spectralEnd, ah, al, entropyStart)
            sawScan = true

            for _, scanComponent in ipairs(scanComponents) do
                local component = scanComponent.Component
                if frameMode == "baseline" then
                    component.SequentialSeen = true
                    for k = 0, 63 do
                        component.Progression[k + 1] = 0
                    end
                else
                    for k = spectralStart, spectralEnd do
                        component.Progression[k + 1] = al
                    end
                end
            end

            decodedUnits += 1
            if decodedUnits % 8 == 0 then
                task.wait()
            end

            continue
        end

        pos = nextSegment
    end

    if not sawEOI then
        error("JPEG end-of-image marker was not found")
    end
    if not sawScan or not components then
        error("JPEG is missing required frame or scan information")
    end

    for _, component in ipairs(components) do
        local quantization = quantizationTables[component.QuantID]
        if not quantization then
            error("JPEG component references a missing quantization table")
        end

        component.Plane = NewByteArray(component.PlaneWidth * component.PlaneHeight)
        local processedBlocks = 0

        for blockY = 0, component.BlocksHigh - 1 do
            for blockX = 0, component.BlocksWide - 1 do
                local blockIndex = blockY * component.BlocksWide + blockX
                local coefficients = table.create(64)
                local base = blockIndex * 64

                for i = 0, 63 do
                    coefficients[i + 1] = GetInt(component.Coefficients, base + i)
                end

                local pixels = JPEGIDCT(coefficients, quantization)
                local startX = blockX * 8
                local startY = blockY * 8

                for y = 0, 7 do
                    local destination = (startY + y) * component.PlaneWidth + startX
                    local source = y * 8
                    for x = 0, 7 do
                        SetByte(component.Plane, destination + x, pixels[source + x + 1])
                    end
                end

                processedBlocks += 1
                if processedBlocks % 256 == 0 then
                    task.wait()
                end
            end
        end

        component.Coefficients = nil
    end

    local yComponent = components[1]
    local cbComponent = components[2]
    local crComponent = components[3]

    local function GetPlaneSample(component, x, y)
        local sampleX = math.floor(x * component.H / maxH)
        local sampleY = math.floor(y * component.V / maxV)
        sampleX = math.min(sampleX, component.PlaneWidth - 1)
        sampleY = math.min(sampleY, component.PlaneHeight - 1)
        return GetByte(component.Plane, sampleY * component.PlaneWidth + sampleX)
    end

    local outputChunks = {}
    local outputChunk = {}
    local pixelCount = 0

    for y = 0, height - 1 do
        for x = 0, width - 1 do
            local red, green, blue

            if #components == 1 then
                local gray = GetPlaneSample(yComponent, x, y)
                red, green, blue = gray, gray, gray
            else
                local luminance = GetPlaneSample(yComponent, x, y)
                local cb = GetPlaneSample(cbComponent, x, y) - 128
                local cr = GetPlaneSample(crComponent, x, y) - 128

                red = JPEGClamp(luminance + 1.402 * cr)
                green = JPEGClamp(luminance - 0.344136 * cb - 0.714136 * cr)
                blue = JPEGClamp(luminance + 1.772 * cb)
            end

            outputChunk[#outputChunk + 1] = red
            outputChunk[#outputChunk + 1] = green
            outputChunk[#outputChunk + 1] = blue
            outputChunk[#outputChunk + 1] = 255
            pixelCount += 1

            if #outputChunk >= 4096 then
                outputChunks[#outputChunks + 1] = string.char(table.unpack(outputChunk))
                table.clear(outputChunk)
            end
        end

        if y % 32 == 0 then
            task.wait()
        end
    end

    if #outputChunk > 0 then
        outputChunks[#outputChunks + 1] = string.char(table.unpack(outputChunk))
    end

    if pixelCount ~= width * height then
        error("JPEG decoder produced an incorrect pixel count")
    end

    return table.concat(outputChunks), width, height
end

function ImageService:GetImage(url, options): imageData
	options = options or {}

	assert(type(url) == "string" and url ~= "", "Invalid image URL")

	local success, response = pcall(function()
		return request({
			Url = url,
			Method = "GET",
			Headers = {
				["User-Agent"] = "Mozilla/5.0",
				["Accept"] = "image/png,image/jpeg,image/webp,*/*;q=0.8",
			},
		})
	end)

	if not success then
		error("Image download failed: " .. tostring(response))
	end

	if type(response) ~= "table" then
		error("Invalid HTTP response")
	end

	if response.StatusCode ~= 200 then
		error("Image download HTTP error: " .. tostring(response.StatusCode))
	end

	local data = response.Body

	if type(data) ~= "string" or #data == 0 then
		error("Image response was empty")
	end

	local isPNG = data:sub(1, 8) == "\137PNG\r\n\26\n"
	local isJPEG = data:byte(1) == 0xFF and data:byte(2) == 0xD8
	local isWebP = data:sub(1, 4) == "RIFF"
		and data:sub(9, 12) == "WEBP"

	local width
	local height

	if isJPEG then
		local decoded, jpegWidth, jpegHeight = DecodeJPEG(data, {
			MaxPixels = options.MaxPixels or 8000000,
		})

		width = jpegWidth
		height = jpegHeight

		local png, encodeError = self:EncodePNG(decoded, width, height)

		if not png then
			error("JPEG PNG encoding failed: " .. tostring(encodeError))
		end

		data = png

	elseif isPNG or isWebP then
		local sizeError
		width, height, sizeError = GetSizeFromBytes(data)

		if not width or not height then
			error("Could not read image dimensions: " .. tostring(sizeError))
		end

	else
		error("Unsupported image format")
	end

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

function ImageService:CalculateNewSizeFromHeight(width, height, targetHeight): Vector2
	assert(type(width) == "number" and width > 0, "Invalid image width")
	assert(type(height) == "number" and height > 0, "Invalid image height")
	assert(type(targetHeight) == "number" and targetHeight > 0, "Invalid target height")

	local targetWidth = targetHeight * (width / height)
	return Vector2.new(targetWidth, targetHeight)
end

function ImageService:GetGIFProportions(animation)
	assert(type(animation) == "table", "Invalid GIF animation")

	local width = tonumber(animation.OriginalWidth) or tonumber(animation.Width)
	local height = tonumber(animation.OriginalHeight) or tonumber(animation.Height)
	assert(width and width > 0, "GIF has an invalid width")
	assert(height and height > 0, "GIF has an invalid height")

	return width, height, width / height
end

function ImageService:GetGIFSize(animation, targetWidth): Vector2
	local width, height = self:GetGIFProportions(animation)

	if targetWidth ~= nil then
		return self:CalculateNewSize(width, height, targetWidth)
	end

	return Vector2.new(width, height)
end

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

		blockCount += 1
		blocks[blockCount] = block
		pos += size
	end

	return table.concat(blocks), pos
end

local function DecodeLZW(data, minimumCodeSize, expectedPixels)
	if minimumCodeSize < 2 or minimumCodeSize > 8 then
		error("Invalid GIF LZW minimum code size")
	end

	local clearCode = 2 ^ minimumCodeSize
	local endCode = clearCode + 1
	local nextCode = endCode + 1
	local codeSize = minimumCodeSize + 1
	local prefix = table.create(4096)
	local suffix = table.create(4096)
	local stack = table.create(4096)
	local output = table.create(expectedPixels)
	local outputCount = 0
	local bitPosition = 0
	local dataLength = #data
	local oldCode, oldFirst

	local function ResetDictionary()
		table.clear(prefix)
		table.clear(suffix)
		codeSize = minimumCodeSize + 1
		nextCode = endCode + 1
	end

	local function ReadCode()
		local bytePosition = bitPosition // 8 + 1
		local shift = bitPosition % 8
		if bytePosition > dataLength then
			return nil
		end

		local b1, b2, b3 = data:byte(bytePosition, bytePosition + 2)
		b2 = b2 or 0
		b3 = b3 or 0
		local combined = b1 + b2 * 256 + b3 * 65536
		local code = bit32.band(bit32.rshift(combined, shift), (2 ^ codeSize) - 1)
		bitPosition += codeSize
		return code
	end

	local function ExpandCode(code)
		local count = 0
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

			count += 1
			stack[count] = value
			code = previous
		end

		if code < 0 or code >= clearCode then
			error("Invalid GIF LZW literal")
		end

		count += 1
		stack[count] = code
		return count, code
	end

	ResetDictionary()

	while true do
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

		local stackCount
		local first

		if code < nextCode then
			stackCount, first = ExpandCode(code)
		elseif code == nextCode and oldCode ~= nil then
			stackCount = ExpandCode(oldCode)
			first = oldFirst
		else
			error("Invalid GIF LZW code")
		end

		for i = stackCount, 1, -1 do
			outputCount += 1
			if outputCount > expectedPixels then
				error("GIF frame exceeds expected dimensions")
			end
			output[outputCount] = stack[i]
		end

		if code == nextCode and oldCode ~= nil then
			outputCount += 1
			if outputCount > expectedPixels then
				error("GIF frame exceeds expected dimensions")
			end
			output[outputCount] = first
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
	local pixelIndex = 1
	local frameWidth = frame.Width
	local frameHeight = frame.Height
	local left = frame.Left
	local top = frame.Top
	local canvasLimit = canvasWidth * canvasHeight * 4

	local function DrawRow(sourceY)
		local destinationY = top + sourceY
		local rowVisible = destinationY >= 0 and destinationY < canvasHeight
		local destinationBase = destinationY * canvasWidth * 4 + left * 4 + 1

		for x = 0, frameWidth - 1 do
			local paletteIndex = frame.Pixels[pixelIndex]
			pixelIndex += 1

			if paletteIndex ~= transparentIndex and rowVisible then
				local color = colors[paletteIndex + 1]
				if not color then
					error("GIF references missing palette color")
				end

				local destinationX = left + x
				if destinationX >= 0 and destinationX < canvasWidth then
					local index = destinationBase + x * 4
					if index >= 1 and index + 3 <= canvasLimit then
						canvas[index] = color[1]
						canvas[index + 1] = color[2]
						canvas[index + 2] = color[3]
						canvas[index + 3] = 255
					end
				end
			end
		end
	end

	if frame.Interlaced then
		local rows = GetInterlacedRows(frameHeight)
		for i = 1, #rows do
			DrawRow(rows[i])
		end
	else
		for y = 0, frameHeight - 1 do
			DrawRow(y)
		end
	end
end

local function CanvasToRGBA(canvas, sourceWidth, sourceHeight, outputWidth, outputHeight)
	outputWidth = outputWidth or sourceWidth
	outputHeight = outputHeight or sourceHeight

	local chunks = table.create(math.ceil(outputWidth * outputHeight * 4 / 4096))
	local chunk = table.create(4096)
	local chunkCount = 0
	local scaleX = sourceWidth / outputWidth
	local scaleY = sourceHeight / outputHeight

	for y = 0, outputHeight - 1 do
		local sourceY = math.min(sourceHeight - 1, math.floor(y * scaleY))
		local sourceRow = sourceY * sourceWidth * 4

		for x = 0, outputWidth - 1 do
			local sourceX = math.min(sourceWidth - 1, math.floor(x * scaleX))
			local sourceIndex = sourceRow + sourceX * 4 + 1

			chunkCount += 1
			chunk[chunkCount] = canvas[sourceIndex]
			chunkCount += 1
			chunk[chunkCount] = canvas[sourceIndex + 1]
			chunkCount += 1
			chunk[chunkCount] = canvas[sourceIndex + 2]
			chunkCount += 1
			chunk[chunkCount] = canvas[sourceIndex + 3]

			if chunkCount == 4096 then
				chunks[#chunks + 1] = string.char(table.unpack(chunk, 1, chunkCount))
				chunk = table.create(4096)
				chunkCount = 0
			end
		end
	end

	if chunkCount > 0 then
		chunks[#chunks + 1] = string.char(table.unpack(chunk, 1, chunkCount))
	end

	return table.concat(chunks)
end

function ImageService:DecodeGIF(data, limits)
	limits = limits or {}

	local progressEnabled = limits.Progress == true
	local progressEvery = math.max(1, math.floor(tonumber(limits.ProgressEveryFrames) or 10))
	local yieldEveryFrames = math.max(0, math.floor(tonumber(limits.YieldEveryFrames) or 1))
	GIFProgress("Starting decoder...", progressEnabled)

	local MAX_PIXELS = math.max(1, math.floor(tonumber(limits.MaxPixels) or 4000000))
	local MAX_FRAMES = math.max(1, math.floor(tonumber(limits.MaxFrames) or 500))
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
			error(string.format("GIF canvas is too large (%d pixels; limit is %d)", totalPixels, MAX_PIXELS))
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
		local truncated = false

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
					truncated = true
					break
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
					error(string.format("GIF frame is too large (%d pixels; limit is %d)", frameWidth * frameHeight, MAX_PIXELS))
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

				if yieldEveryFrames > 0 and #frames % yieldEveryFrames == 0 then
					task.wait()
				end

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
			Truncated = truncated,

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

function ImageService:GetGIF(url, limits)
	limits = limits or {}
	local progressEnabled = limits.Progress == true

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

function ImageService:PrepareGIF(animation, options)
	options = options or {}

	assert(animation and animation.Frames, "Invalid GIF animation")
	assert(#animation.Frames > 0, "GIF contains no frames")

	local progressEnabled = options.Progress == true
	local releaseRGBA = options.ReleaseRGBA ~= false
	local yieldEvery = math.max(0, math.floor(tonumber(options.YieldEveryFrames) or 1))
	local frameCount = #animation.Frames
	local progressEvery = math.max(1, math.floor(
		type(options.ProgressEveryFrames) == "number"
			and options.ProgressEveryFrames
			or math.max(1, math.ceil(frameCount / 10))
	))

	GIFProgress(string.format("Preparing %d frames as PNG...", frameCount), progressEnabled)

	local prepared = {
		Frames = table.create(frameCount),
		Width = animation.Width,
		Height = animation.Height,
		OriginalWidth = animation.OriginalWidth or animation.Width,
		OriginalHeight = animation.OriginalHeight or animation.Height,
		LoopCount = animation.LoopCount,
		FrameCount = frameCount,
		Format = "PNG",
		IsPrepared = true,
	}

	local encode = self.EncodePNG
	for i = 1, frameCount do
		local frame = animation.Frames[i]
		local rgba = frame.Data
		if type(rgba) ~= "string" then
			error("GIF frame " .. i .. " has no RGBA Data")
		end

		local png, err = encode(self, rgba, frame.Width or animation.Width, frame.Height or animation.Height)
		if not png then
			error("Failed to encode GIF frame " .. i .. ": " .. tostring(err))
		end

		local delay = tonumber(frame.Delay) or 0.1
		if delay <= 0 then
			delay = 0.1
		end

		prepared.Frames[i] = {
			Data = png,
			Delay = math.max(delay, 0.02),
		}

		if releaseRGBA then
			frame.Data = nil
		end

		if progressEnabled and (i == 1 or i % progressEvery == 0 or i == frameCount) then
			GIFProgress(string.format("Prepared %d/%d frames (%.0f%%).", i, frameCount, i / frameCount * 100), true)
		end

		if yieldEvery > 0 and i % yieldEvery == 0 then
			task.wait()
		end
	end

	if releaseRGBA then
		animation.Frames = nil
	end

	GIFProgress(string.format("Preparation complete: %d PNG frames ready.", frameCount), progressEnabled)
	return prepared
end

function ImageService:PlayGIF(animation, image, options)
	options = options or {}

	assert(animation and animation.Frames, "Invalid prepared GIF animation")
	assert(image, "Missing Drawing image")

	local frames = animation.Frames
	local frameCount = #frames
	assert(frameCount > 0, "GIF contains no frames")

	local progressEnabled = options.Progress == true
	local minDelay = math.max(tonumber(options.MinDelay) or 0, 0)

	local maxFPS = tonumber(options.MaxFPS)
	if maxFPS == nil then
		maxFPS = 24
	end
	maxFPS = math.clamp(maxFPS, 1, 120)
	local updateInterval = 1 / maxFPS

	if options.PreserveAspect ~= false then
		self:FitGIF(image, animation, image.Size)
	end

	local frameEnds = table.create(frameCount)
	local totalDuration = 0
	for i = 1, frameCount do
		local delay = tonumber(frames[i].Delay) or 0.1
		if delay <= 0 then
			delay = 0.1
		end
		delay = math.max(delay, minDelay)
		totalDuration += delay
		frameEnds[i] = totalDuration
	end

	local loopCount = animation.LoopCount
	local totalPlays = loopCount == nil and 1 or (loopCount == 0 and math.huge or loopCount + 1)
	local totalTime = totalDuration * totalPlays
	local playback = { Running = true, StopRequested = false }

	GIFProgress(string.format("Playback started: %d frames at up to %d updates/sec.", frameCount, maxFPS), progressEnabled)

	task.spawn(function()
		local startTime = os.clock()
		local lastIndex = 0

		while playback.Running do
			local now = os.clock()
			local elapsed = now - startTime
			if elapsed >= totalTime then
				break
			end

			local playNumber = math.floor(elapsed / totalDuration)
			local withinPlay = elapsed - playNumber * totalDuration

			local low, high = 1, frameCount
			while low < high do
				local mid = (low + high) // 2
				if withinPlay < frameEnds[mid] then
					high = mid
				else
					low = mid + 1
				end
			end

			local index = low
			if index ~= lastIndex then
				local frameData = frames[index].Data
				if type(frameData) ~= "string" then
					GIFProgress("Playback stopped: prepared frame " .. index .. " is missing PNG data.", progressEnabled)
					break
				end

				image.Data = frameData
				lastIndex = index
			end

			local nextTickNumber = math.floor(elapsed * maxFPS) + 1
			local nextTick = startTime + nextTickNumber * updateInterval
			local playbackEnd = startTime + totalTime
			if nextTick > playbackEnd then
				nextTick = playbackEnd
			end

			local remaining = nextTick - os.clock()
			if remaining > 0 then
				task.wait(remaining)
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
		local index = bit32.band(bit32.bxor(crc, data:byte(i)), 0xFF)

		crc = bit32.bxor(bit32.rshift(crc, 8), CRC_TABLE[index + 1])
	end

	return bit32.bnot(crc)
end

local function Adler32(data)
	local a = 1
	local b = 0

	local MOD = 65521

	local length = #data
	local pos = 1
	while pos <= length do
		local finish = math.min(pos + 5551, length)
		for i = pos, finish do
			a += data:byte(i)
			b += a
		end
		a %= MOD
		b %= MOD
		pos = finish + 1
	end

	return b * 65536 + a
end

local function PNGChunk(chunkType, data)
	local chunk = chunkType .. data

	return UInt32BE(#data) .. chunk .. UInt32BE(CRC32(chunk))
end

local function ZlibStore(data)
	local chunks = {}

	chunks[#chunks + 1] = "\x78\x01"

	local pos = 1
	local length = #data
	local blockCount = 0

	while pos <= length do
		blockCount += 1
		local blockSize = math.min(65535, length - pos + 1)

		local isFinal = pos + blockSize - 1 == length

		local header = isFinal and 0x01 or 0x00

		local block = data:sub(pos, pos + blockSize - 1)

		local inverseSize = 65535 - blockSize

		chunks[#chunks + 1] = string.char(header) .. UInt16LE(blockSize) .. UInt16LE(inverseSize) .. block

		pos += blockSize
	end

	chunks[#chunks + 1] = UInt32BE(Adler32(data))

	return table.concat(chunks)
end

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

		local scanlines = {}

		for y = 0, height - 1 do
			local start = y * width * 4 + 1
			local finish = start + width * 4 - 1

			scanlines[#scanlines + 1] = "\x00" .. rgba:sub(start, finish)
		end

		local rawData = table.concat(scanlines)

		local compressed = ZlibStore(rawData)

		local signature = "\x89PNG\r\n\x1A\n"

		local ihdr = UInt32BE(width)
			.. UInt32BE(height)
			.. string.char(
				8,
				6,
				0,
				0,
				0
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
          constrain decoded input size. YieldEveryFrames defaults to 1
          to let the scheduler run between decoded frames (0 disables it).
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
        - YieldEveryFrames controls how often preparation yields (default 1;
          0 disables yielding).
        - ProgressEveryFrames controls log frequency; Progress = false silences logs.

    * PlayGIF(prepared, image, options)
        - Playback only assigns pre-encoded PNG frames; it does no encoding.
        - MaxFPS caps actual image updates (default 24) and skips overdue
          frames without slowing the GIF's original timeline. Use a lower
          value such as 15 to reduce CPU load further. MinDelay optionally
          floors frame durations.
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
        { Scale = 0.5, MaxFrames = 180, MaxPixels = 2000000, YieldEveryFrames = 1 }
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
        MaxFPS = 20,
        MinDelay = 0,
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
