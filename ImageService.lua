local ImageService = {}

function ImageService.ReadPNGSize(data): ( number, number )
    local byte = {data:byte(17, 24)}

    local width =
        byte[1] * 16777216 +
        byte[2] * 65536 +
        byte[3] * 256 +
        byte[4]

    local height =
        byte[5] * 16777216 +
        byte[6] * 65536 +
        byte[7] * 256 +
        byte[8]

    return width, height
end

function ImageService.ReadWebPSize(data): (number?, number?, string?)
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

        return 
            w1 + bit32.lshift(bit32.band(w2, 0x3F), 8),
            h1 + bit32.lshift(bit32.band(h2, 0x3F), 8)
    end

    local VP8LPos = data:find("VP8L", 1, true)
    if VP8LPos then
        local signature = data:byte(VP8LPos + 8)

        if signature ~= 0x2F then
            return nil, nil, "Invalid VP8L signature"
        end

        local b1, b2, b3, b4 =
            data:byte(VP8LPos + 9, VP8LPos + 12)
        
        local width =
            1 +
            b1 +
            bit32.lshift(bit32.band(b2, 0x3F), 8)

        local height =
            1 +
            bit32.rshift(bit32.band(b2, 0xC0), 6) +
            bit32.lshift(b3, 2) +
            bit32.lshift(bit32.band(b4, 0x0F), 10)

        return width, height
    end

    local VP8XPos = data:find("VP8X", 1, true)
    if VP8XPos then
        local w1, w2, w3 =
            data:byte(VP8XPos + 12, VP8XPos + 14)

        local h1, h2, h3 =
            data:byte(VP8XPos + 15, VP8XPos + 17)

        local width =
            1 +
            w1 +
            bit32.lshift(w2, 8) +
            bit32.lshift(w3, 16)

        local height =
            1 +
            h1 +
            bit32.lshift(h2, 8) +
            bit32.lshift(h3, 16)
        
        return height and width, height
    end
    
    return nil, nil, "Unsupported WebP variant"
end

function ImageService.ReadJPEGSize(data)
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

        if (
            marker == 0xC0 or
            marker == 0xC1 or
            marker == 0xC2 or
            marker == 0xC3 or
            marker == 0xC5 or
            marker == 0xC6 or
            marker == 0xC7 or
            marker == 0xC9 or
            marker == 0xCA or
            marker == 0xCB or
            marker == 0xCD or
            marker == 0xCE or
            marker == 0xCF
        ) then
            local h1, h2 = data:byte(pos + 5, pos + 6)
            local w1, w2 = data:byte(pos + 7, pos + 8)

            return
                w1 * 256 + w2,
                h1 * 256 + h2
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

function ImageService:GetSizeFromBytes(bytes): (number?, number?, string?)
    local w, h, err
    
    if bytes:sub(1, 4) == "RIFF" 
        and bytes:sub(9, 12) == "WEBP"
    then
        w, h, err = self.ReadWebPSize(bytes)
    
    elseif bytes:sub(1) == 0xFF
        and bytes:sub(2) == 0xD8
    then
        w, h, err = self.ReadJPEGSize(bytes)
    
    elseif bytes:sub(1, 8) == "\137PNG\r\n\26\n"
    then
        w, h = self.ReadPNGSize(bytes)
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
    StatusCode: number
}

function ImageService:GetImage(url): imageData
    local response = request({
        Url = url,
        Method = "GET"
    })

    local width, height = self:GetSizeFromBytes(response.Body)

    local dataTable: imageData = {
        Data = response.Body,
        Width = width,
        Height = height,
        StatusCode = response.StatusCode
    }

    return dataTable
end

function ImageService:CalculateNewSize(width, height, targetWidth): Vector2
    local aspectRatio = height / width
    local targetW = targetWidth or 500
    local targetHeight = targetW * aspectRatio

    return Vector2.new(
        targetWidth,
        targetHeight
    )
end

function ImageService:GetCenteredPosition(size: Vector2)
    local viewport = workspace.CurrentCamera.ViewportSize

    return (viewport - size) / 2
end

function ImageService:Create(url)
    local imageInfo = ImageService:GetImage(url)

    local size = Vector2.new(
        imageInfo.Width,
        imageInfo.Height
    )

    local image = Drawing.new("Image")
    image.Data = imageInfo.Data
    image.Size = size
    image.Position = ImageService:GetCenteredPosition(size)

    image.Visible = true

    return image
end

return ImageService
