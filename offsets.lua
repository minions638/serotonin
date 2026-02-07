local version = package.cpath:match('version%-[%w]+')

local json = {}; do
    -- json.lua
    --
    -- Copyright (c) 2020 rxi
    --
    -- Permission is hereby granted, free of charge, to any person obtaining a copy of
    -- this software and associated documentation files (the "Software"), to deal in
    -- the Software without restriction, including without limitation the rights to
    -- use, copy, modify, merge, publish, distribute, sublicense, and/or sell copies
    -- of the Software, and to permit persons to whom the Software is furnished to do
    -- so, subject to the following conditions:
    --
    -- The above copyright notice and this permission notice shall be included in all
    -- copies or substantial portions of the Software.
    --
    -- THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
    -- IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
    -- FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
    -- AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
    -- LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
    -- OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
    -- SOFTWARE.

    local encode

    local escape_char_map = {
    [ "\\" ] = "\\",
    [ "\"" ] = "\"",
    [ "\b" ] = "b",
    [ "\f" ] = "f",
    [ "\n" ] = "n",
    [ "\r" ] = "r",
    [ "\t" ] = "t",
    }

    local escape_char_map_inv = { [ "/" ] = "/" }
    for k, v in pairs(escape_char_map) do
    escape_char_map_inv[v] = k
    end


    local function escape_char(c)
    return "\\" .. (escape_char_map[c] or string.format("u%04x", c:byte()))
    end


    local function encode_nil(val)
    return "null"
    end


    local function encode_table(val, stack)
    local res = {}
    stack = stack or {}

    -- Circular reference?
    if stack[val] then error("circular reference") end

    stack[val] = true

    if rawget(val, 1) ~= nil or next(val) == nil then
        -- Treat as array -- check keys are valid and it is not sparse
        local n = 0
        for k in pairs(val) do
        if type(k) ~= "number" then
            error("invalid table: mixed or invalid key types")
        end
        n = n + 1
        end
        if n ~= #val then
        error("invalid table: sparse array")
        end
        -- Encode
        for i, v in ipairs(val) do
        table.insert(res, encode(v, stack))
        end
        stack[val] = nil
        return "[" .. table.concat(res, ",") .. "]"

    else
        -- Treat as an object
        for k, v in pairs(val) do
        if type(k) ~= "string" then
            error("invalid table: mixed or invalid key types")
        end
        table.insert(res, encode(k, stack) .. ":" .. encode(v, stack))
        end
        stack[val] = nil
        return "{" .. table.concat(res, ",") .. "}"
    end
    end


    local function encode_string(val)
    return '"' .. val:gsub('[%z\1-\31\\"]', escape_char) .. '"'
    end


    local function encode_number(val)
    -- Check for NaN, -inf and inf
    if val ~= val or val <= -math.huge or val >= math.huge then
        error("unexpected number value '" .. tostring(val) .. "'")
    end
    return string.format("%.14g", val)
    end


    local type_func_map = {
    [ "nil"     ] = encode_nil,
    [ "table"   ] = encode_table,
    [ "string"  ] = encode_string,
    [ "number"  ] = encode_number,
    [ "boolean" ] = tostring,
    }


    encode = function(val, stack)
    local t = type(val)
    local f = type_func_map[t]
    if f then
        return f(val, stack)
    end
    error("unexpected type '" .. t .. "'")
    end


    function json.encode(val)
    return ( encode(val) )
    end


    -------------------------------------------------------------------------------
    -- Decode
    -------------------------------------------------------------------------------

    local parse

    local function create_set(...)
    local res = {}
    for i = 1, select("#", ...) do
        res[ select(i, ...) ] = true
    end
    return res
    end

    local space_chars   = create_set(" ", "\t", "\r", "\n")
    local delim_chars   = create_set(" ", "\t", "\r", "\n", "]", "}", ",")
    local escape_chars  = create_set("\\", "/", '"', "b", "f", "n", "r", "t", "u")
    local literals      = create_set("true", "false", "null")

    local literal_map = {
    [ "true"  ] = true,
    [ "false" ] = false,
    [ "null"  ] = nil,
    }


    local function next_char(str, idx, set, negate)
    for i = idx, #str do
        if set[str:sub(i, i)] ~= negate then
        return i
        end
    end
    return #str + 1
    end


    local function decode_error(str, idx, msg)
    local line_count = 1
    local col_count = 1
    for i = 1, idx - 1 do
        col_count = col_count + 1
        if str:sub(i, i) == "\n" then
        line_count = line_count + 1
        col_count = 1
        end
    end
    error( string.format("%s at line %d col %d", msg, line_count, col_count) )
    end


    local function codepoint_to_utf8(n)
    -- http://scripts.sil.org/cms/scripts/page.php?site_id=nrsi&id=iws-appendixa
    local f = math.floor
    if n <= 0x7f then
        return string.char(n)
    elseif n <= 0x7ff then
        return string.char(f(n / 64) + 192, n % 64 + 128)
    elseif n <= 0xffff then
        return string.char(f(n / 4096) + 224, f(n % 4096 / 64) + 128, n % 64 + 128)
    elseif n <= 0x10ffff then
        return string.char(f(n / 262144) + 240, f(n % 262144 / 4096) + 128,
                        f(n % 4096 / 64) + 128, n % 64 + 128)
    end
    error( string.format("invalid unicode codepoint '%x'", n) )
    end


    local function parse_unicode_escape(s)
    local n1 = tonumber( s:sub(1, 4),  16 )
    local n2 = tonumber( s:sub(7, 10), 16 )
    -- Surrogate pair?
    if n2 then
        return codepoint_to_utf8((n1 - 0xd800) * 0x400 + (n2 - 0xdc00) + 0x10000)
    else
        return codepoint_to_utf8(n1)
    end
    end


    local function parse_string(str, i)
    local res = ""
    local j = i + 1
    local k = j

    while j <= #str do
        local x = str:byte(j)

        if x < 32 then
        decode_error(str, j, "control character in string")

        elseif x == 92 then -- `\`: Escape
        res = res .. str:sub(k, j - 1)
        j = j + 1
        local c = str:sub(j, j)
        if c == "u" then
            local hex = str:match("^[dD][89aAbB]%x%x\\u%x%x%x%x", j + 1)
                    or str:match("^%x%x%x%x", j + 1)
                    or decode_error(str, j - 1, "invalid unicode escape in string")
            res = res .. parse_unicode_escape(hex)
            j = j + #hex
        else
            if not escape_chars[c] then
            decode_error(str, j - 1, "invalid escape char '" .. c .. "' in string")
            end
            res = res .. escape_char_map_inv[c]
        end
        k = j + 1

        elseif x == 34 then -- `"`: End of string
        res = res .. str:sub(k, j - 1)
        return res, j + 1
        end

        j = j + 1
    end

    decode_error(str, i, "expected closing quote for string")
    end


    local function parse_number(str, i)
    local x = next_char(str, i, delim_chars)
    local s = str:sub(i, x - 1)
    local n = tonumber(s)
    if not n then
        decode_error(str, i, "invalid number '" .. s .. "'")
    end
    return n, x
    end


    local function parse_literal(str, i)
    local x = next_char(str, i, delim_chars)
    local word = str:sub(i, x - 1)
    if not literals[word] then
        decode_error(str, i, "invalid literal '" .. word .. "'")
    end
    return literal_map[word], x
    end


    local function parse_array(str, i)
    local res = {}
    local n = 1
    i = i + 1
    while 1 do
        local x
        i = next_char(str, i, space_chars, true)
        -- Empty / end of array?
        if str:sub(i, i) == "]" then
        i = i + 1
        break
        end
        -- Read token
        x, i = parse(str, i)
        res[n] = x
        n = n + 1
        -- Next token
        i = next_char(str, i, space_chars, true)
        local chr = str:sub(i, i)
        i = i + 1
        if chr == "]" then break end
        if chr ~= "," then decode_error(str, i, "expected ']' or ','") end
    end
    return res, i
    end


    local function parse_object(str, i)
    local res = {}
    i = i + 1
    while 1 do
        local key, val
        i = next_char(str, i, space_chars, true)
        -- Empty / end of object?
        if str:sub(i, i) == "}" then
        i = i + 1
        break
        end
        -- Read key
        if str:sub(i, i) ~= '"' then
        decode_error(str, i, "expected string for key")
        end
        key, i = parse(str, i)
        -- Read ':' delimiter
        i = next_char(str, i, space_chars, true)
        if str:sub(i, i) ~= ":" then
        decode_error(str, i, "expected ':' after key")
        end
        i = next_char(str, i + 1, space_chars, true)
        -- Read value
        val, i = parse(str, i)
        -- Set
        res[key] = val
        -- Next token
        i = next_char(str, i, space_chars, true)
        local chr = str:sub(i, i)
        i = i + 1
        if chr == "}" then break end
        if chr ~= "," then decode_error(str, i, "expected '}' or ','") end
    end
    return res, i
    end


    local char_func_map = {
    [ '"' ] = parse_string,
    [ "0" ] = parse_number,
    [ "1" ] = parse_number,
    [ "2" ] = parse_number,
    [ "3" ] = parse_number,
    [ "4" ] = parse_number,
    [ "5" ] = parse_number,
    [ "6" ] = parse_number,
    [ "7" ] = parse_number,
    [ "8" ] = parse_number,
    [ "9" ] = parse_number,
    [ "-" ] = parse_number,
    [ "t" ] = parse_literal,
    [ "f" ] = parse_literal,
    [ "n" ] = parse_literal,
    [ "[" ] = parse_array,
    [ "{" ] = parse_object,
    }


    parse = function(str, idx)
    local chr = str:sub(idx, idx)
    local f = char_func_map[chr]
    if f then
        return f(str, idx)
    end
    decode_error(str, idx, "unexpected character '" .. chr .. "'")
    end


    function json.decode(str)
    if type(str) ~= "string" then
        error("expected argument of type string, got " .. type(str))
    end
    local res, idx = parse(str, next_char(str, 1, space_chars, true))
    idx = next_char(str, idx, space_chars, true)
    if idx <= #str then
        decode_error(str, idx, "trailing garbage")
    end
    return res
    end
end

local classes = {}; do
    local storage = game.GetService('ReplicatedStorage')
    local workspace = game.GetService('Workspace')
    local screen_gui = game.LocalPlayer.PlayerGui:FindFirstChild('ScreenGui')

    classes.Bone = {
        TransformPosition = {workspace:FindFirstChild('BonePart'):FindFirstChildOfClass('Bone'), 'float', 292, 'Vector3'}
    }

    classes.Attachment = {
        Position = {storage:FindFirstChildOfClass('Attachment'), 'float', 3411, 'Vector3'},
        TransformPosition = {workspace:FindFirstChild('Part1'):FindFirstChildOfClass('Attachment'), 'float', 3722, 'Vector3'}
    }

    local humanoid = workspace:FindFirstChild('Rig'):FindFirstChildOfClass('Humanoid')
    classes.Humanoid = {
        WalkToPoint = {humanoid, 'float', 5732, 'Vector3'}
    }

    local surface_appearance = workspace:FindFirstChild('SurfacePart'):FindFirstChild('SurfaceAppearance')
    classes.SurfaceAppearance = {
        Color = {surface_appearance, 'float', 0.36, 'Vector3'},
        ColorMap = {surface_appearance, 'string', 'rbxassetid://ColorMap'},
        NormalMap = {surface_appearance, 'string', 'rbxassetid://NormalMap'},
        MetalnessMap = {surface_appearance, 'string', 'rbxassetid://MetalnessMap'},
        RoughnessMap = {surface_appearance, 'string', 'rbxassetid://RoughnessMap'},
    }

    local frame1, frame2 = screen_gui:FindFirstChild('Frame1'), screen_gui:FindFirstChild('Frame2')
    classes.GuiObject = {
        Size = {frame2, 'float', 5462, 'Vector2'},
        Position = {frame2, 'float', 4232, 'Vector2'},
        AbsoluteSize = {frame1, 'float', 213, 'Vector2'},
        AbsolutePosition = {frame1, 'float', 232, 'Vector2'},
        BackgroundColor3 = {frame1, 'float', 0.36, 'Vector3'},
        BackgroundTransparency = {frame1, 'float', 3722}
    }

    classes.ScrollingFrame = {
        CanvasPosition = {screen_gui:FindFirstChildOfClass('ScrollingFrame'), 'float', 11}
    }

    classes.TextBox = {
        Text = {screen_gui:FindFirstChildOfClass('TextBox'), 'string', 'TextBoxText'},
        TextColor3 = {screen_gui:FindFirstChildOfClass('TextBox'), 'float', 0.36, 'Vector3'}
    }

    local image_label = screen_gui:FindFirstChildOfClass('ImageLabel')
    classes.ImageLabel = {
        Image = {image_label, 'string', 'rbxassetid://ImageLabelImage'},
        ImageColor3 = {image_label, 'float', 0.36, 'Vector3'},
        ImageTransparency = {image_label, 'float', 0.58}
    }

    local image_button = screen_gui:FindFirstChildOfClass('ImageButton')
    classes.ImageButton = {
        Image = {image_button, 'string', 'rbxassetid://ImageLabelImage'},
        ImageColor3 = {image_button, 'float', 0.36, 'Vector3'},
        ImageTransparency = {image_button, 'float', 0.58}
    }

    local smoke = storage:FindFirstChildOfClass('Smoke')
    classes.Smoke = {
        Color = {smoke, 'float', 0.36, 'Vector3'},
        Opacity = {smoke, 'float', 0.64},
        Size = {smoke, 'float', 76},
        TimeScale = {smoke, 'float', 4722},
        RiseVelocity = {smoke, 'float', 17}
    }

    local sound = storage:FindFirstChildOfClass('Sound')
    classes.Sound = {
        Volume = {sound, 'float', 3.2},
        PlaybackSpeed = {sound, 'float', 5.4},
        SoundId = {sound, 'string', 'rbxassetid://SoundId'}
    }

    local texture = storage:FindFirstChildOfClass('Texture')
    classes.Texture = {
        Color3 = {texture, 'float', 0.36, 'Vector3'},
        OffsetStudsU = {texture, 'float', 8123},
        OffsetStudsV = {texture, 'float', 2712},
        StudsPerTileU = {texture, 'float', 6221},
        StudsPerTileV = {texture, 'float', 4812},
        Transparency = {texture, 'float', 635},
        Texture = {texture, 'string', 'rbxassetid://Texture'}
    }

    classes.Animation = {
        AnimationId = {storage:FindFirstChildOfClass('Animation'), 'string', 'rbxassetid://AnimationId'}
    }

    local special_mesh = storage:FindFirstChildOfClass('SpecialMesh')
    classes.SpecialMesh = {
        Scale = {special_mesh, 'float', 6723, 'Vector3'},
        Offset = {special_mesh, 'float', 5723, 'Vector3'},
        MeshId = {special_mesh, 'string', 'rbxassetid://MeshId'},
        TextureId = {special_mesh, 'string', 'rbxassetid://TextureId'}
    }

    local spot_light = storage:FindFirstChildOfClass('SpotLight')
    classes.Light = {
        Color = {spot_light, 'float', 0.36, 'Vector3'},
        Angle = {spot_light, 'float', 162},
        Range = {spot_light, 'float', 75.3},
        Brightness = {spot_light, 'float', 23}
    }

    local trail = storage:FindFirstChildOfClass('Trail')
    classes.Trail = {
        Color = {trail, 'float', 0.36, 'Vector3'},
        Brightness = {trail, 'float', 563},
        Texture = {trail, 'string', 'rbxassetid://Texture'},
        TextureLength = {trail, 'float', 231},
        Attachment0 = {trail, 'pointer', trail:FindFirstChild('0').Address},
        Attachment1 = {trail, 'pointer', trail:FindFirstChild('1').Address},
        Lifetime = {trail, 'float', 13.4},
        MinLength = {trail, 'float', 245},
        MaxLength = {trail, 'float', 473},
        WidthScale = {trail, 'float', 34},
        LightEmission = {trail, 'float', 0.67},
        LightInfluence = {trail, 'float', 0.75}
    }

    local beam = storage:FindFirstChildOfClass('Beam')
    classes.Beam = {
        Color = {beam, 'float', 0.36, 'Vector3'},
        Brightness = {beam, 'float', 563},
        Texture = {beam, 'string', 'rbxassetid://Texture'},
        TextureLength = {beam, 'float', 231},
        TextureSpeed = {beam, 'float', 472},
        Transparency = {beam, 'float', 532},
        LightEmission = {beam, 'float', 0.67},
        LightInfluence = {beam, 'float', 0.75},
        Attachment0 = {beam, 'pointer', beam:FindFirstChild('0').Address},
        Attachment1 = {beam, 'pointer', beam:FindFirstChild('1').Address},
        CurveSize0 = {beam, 'float', 653},
        CurveSize1 = {beam, 'float', 522},
        Segments = {beam, 'int', 832},
        Width0 = {beam, 'float', 432},
        Width1 = {beam, 'float', 845}
    }
end

local offsets = {
    version = version
}

local success, failed = {}, {}
for name, properties in pairs(classes) do
    offsets[name] = {}

    for property_name, property in pairs(properties) do
        local value = property[3]
        local address = type(property[1]) == 'number' and property[1] or property[1].Address
        for i = 0, 10000 do
            local memory_value = memory.read(property[2], address + i)

            if memory_value == value or type(value) == 'number' and memory_value > value - 0.025 and memory_value < value + 0.025 then
                offsets[name][property_name] = {string.format('0x%X', i), property[2], property[4]}
                success[#success+1] = name .. "." .. property_name
                break
            elseif property[2] ~= 'string' and string.match(tostring(memory_value), '^(%d+%.%d%d)') == tostring(value) then
                offsets[name][property_name] = {string.format('0x%X', i), property[2], property[4]}
                success[#success+1] = name .. "." .. property_name
                break
            end
        end

        if not offsets[name][property_name] then
            failed[#failed+1] = name .. "." .. property_name
        end
    end
end

local function table_to_lua(tbl, indent) -- made by chatgpt
    local function is_leaf_table(t)
        for _, v in pairs(t) do
            if type(v) == "table" then
                return false
            end
        end
        return true
    end

    indent = indent or 0
    local pad = string.rep("    ", indent)
    local lines = {"{"}

    if tbl.version ~= nil then
        table.insert(lines, string.format("%s    ['version'] = '%s',", pad, tbl.version))
        table.insert(lines, '')
    end

    local count = 0
    local indexes = {}
    for k, v in pairs(tbl) do
        count = count + 1
        indexes[k] = count
    end

    for k, v in pairs(tbl) do
        if k == "version" then
            goto continue
        end

        local key = string.format("['%s']", tostring(k))

        if type(v) == "table" and is_leaf_table(v) then
            local values = {}
            for _, val in pairs(v) do
                if type(val) == "string" then
                    table.insert(values, string.format("'%s'", val))
                else
                    table.insert(values, tostring(val))
                end
            end
            table.insert(
                lines,
                string.format("%s    %s = {%s},", pad, key, table.concat(values, ", "))
            )
        elseif type(v) == "table" then
            local nested = table_to_lua(v, indent + 1)
            table.insert(
                lines,
                string.format("%s    %s = %s,", pad, key, nested)
            )

            if indexes[k] ~= count then
                table.insert(lines, '')
            end
        end

        ::continue::
    end

    table.insert(lines, pad .. "}")
    return table.concat(lines, "\n")
end

file.write(version .. '.json', json.encode(offsets))
file.write(version .. '.lua', 'local offsets = ' .. table_to_lua(offsets))
utility.set_clipboard('local offsets = ' .. table_to_lua(offsets))

print('Success: ' .. table.concat(success, ', '))
print('Failed: ' .. table.concat(failed, ', '))
