-- we store the data from the host quickly from the data handler interrupt
-- and wait for the main loop to pick it up for processing/drawing
-- `app_data/_accum/_block`.`text` is the text of the turn-by-turn directions in the Google Maps notification
-- `app_data/_accum/_block`.`image` is the directional arrow icon

-- Frame to phone flags
BATTERY_LEVEL_FLAG = 0x0c

-- Phone to Frame flags
TEXT_FLAG = 0x0a
IMAGE_FLAG = 0x0d

local app_data_accum = {}
local app_data_block = {}
local app_data = {}

-- Data Handler: called when data arrives, must execute quickly.
-- Update the app_data_accum item based on the contents of the current packet
-- The first byte of the packet indicates the message type, and the item's key
-- If the key is not present, initialise a new app data item
-- Accumulate chunks of data of the specified type, for later processing
-- TODO add reliability features (packet acknowledgement or dropped packet retransmission requests, message and packet sequence numbers)
function update_app_data_accum(data)
    local msg_flag = string.byte(data, 1)
    local item = app_data_accum[msg_flag]
    if item == nil or next(item) == nil then
        item = { chunk_table = {}, num_chunks = 0, size = 0, recv_bytes = 0 }
        app_data_accum[msg_flag] = item
    end

    if item.num_chunks == 0 then
        -- first chunk of new data contains size (Uint16)
        item.size = string.byte(data, 2) << 8 | string.byte(data, 3)
        item.chunk_table[1] = string.sub(data, 4)
        item.num_chunks = 1
        item.recv_bytes = string.len(data) - 3

        if item.recv_bytes == item.size then
            app_data_block[msg_flag] = item.chunk_table[1]
            item.size = 0
            item.recv_bytes = 0
            item.num_chunks = 0
            item.chunk_table[1] = nil
            app_data_accum[msg_flag] = item
        end
    else
        item.chunk_table[item.num_chunks + 1] = string.sub(data, 2)
        item.num_chunks = item.num_chunks + 1
        item.recv_bytes = item.recv_bytes + string.len(data) - 1

        -- if all bytes are received, concat and move message to block
        -- but don't parse yet
        if item.recv_bytes == item.size then
            app_data_block[msg_flag] = table.concat(item.chunk_table)

            for k, v in pairs(item.chunk_table) do item.chunk_table[k] = nil end
            item.size = 0
            item.recv_bytes = 0
            item.num_chunks = 0
            app_data_accum[msg_flag] = item
        end
    end
end

-- Parse the text message raw data. If the message had more structure (layout etc.)
-- we would parse that out here. In this case the data only contains the string
function parse_text(data)
    local text = {}
    text.data = data
    return text
end

-- Parse the image message raw data. Unpack the header fields.
-- width(Uint16), height(Uint16), bpp(Uint8), numColors(Uint8), palette (Uint8 r, Uint8 g, Uint8 b)*numColors, data (length width x height x bpp/8)
function parse_image(data)
    local image = {}
    image.width = string.byte(data, 1) << 8 | string.byte(data, 2)
    image.height = string.byte(data, 3) << 8 | string.byte(data, 4)
    image.bpp = string.byte(data, 5)
    image.num_colors = string.byte(data, 6)
    image.palette = string.sub(data, 7, 7 + 3*image.num_colors - 1)
    -- add 7 and do truncating division to round up to next byte
    -- for partial byte totals on low bpp images
    image.size = (image.width * image.height * image.bpp + 7) // 8
    image.data = string.sub(data, 7 + 3*image.num_colors)
    return image
end

-- register the respective message parsers
local parsers = {}
parsers[TEXT_FLAG] = parse_text
parsers[IMAGE_FLAG] = parse_image

-- Works through app_data_block and if any items are ready, run the corresponding parser
function process_raw_items()
    local processed = 0

    for flag, block in pairs(app_data_block) do
        -- parse the app_data_block item into an app_data item
        app_data[flag] = parsers[flag](block)

        -- then clear out the raw data
        app_data_block[flag] = nil

        processed = processed + 1
    end

    return processed
end

-- draw the current text on the display
function print_text()
    local i = 0
    for line in app_data[TEXT_FLAG].data:gmatch("([^\n]*)\n?") do
        if line ~= "" then
            frame.display.text(line, 1, i * 60 + 1)
            i = i + 1
        end
    end

end

-- draw the image on the display
-- TODO set palette
function print_image()
    local image = app_data[IMAGE_FLAG]
    frame.display.bitmap(500, 1, image.width, image.num_colors, 0, image.data)
end

-- Main app loop
function app_loop()
    local last_batt_update = 0
    while true do
        rc, err = pcall(
            function()
                -- process any raw items, if ready (parse into image or text, then clear raw)
                local items_ready = process_raw_items()

                -- TODO tune sleep durations to optimise for data handler and processing
                frame.sleep(0.005)

                -- only need to print it once when it's ready, it will stay there
                -- but if we print either, then we need to print both because a draw call and show
                -- will flip the buffer away from the already-drawn text/image
                if items_ready > 0 then
                    if (app_data[TEXT_FLAG] ~= nil and app_data[TEXT_FLAG].data ~= nil) then
                        print_text()
                    end
                    if (app_data[IMAGE_FLAG] ~= nil and app_data[IMAGE_FLAG].data ~= nil) then
                        print_image()
                    end
                    frame.display.show()
                end

                -- TODO tune sleep durations to optimise for data handler and processing
                frame.sleep(0.005)

                -- periodic battery level updates
                local t = frame.time.utc()
                if (last_batt_update == 0 or (t - last_batt_update) > 180) then
                    pcall(frame.bluetooth.send, string.char(BATTERY_LEVEL_FLAG) .. string.char(math.floor(frame.battery_level())))
                    last_batt_update = t
                end

                -- TODO clear display after an amount of time?
            end
        )
        -- Catch the break signal here and clean up the display
        if rc == false then
            -- send the error back on the stdout stream
            print(err)
            frame.display.text(" ", 1, 1)
            frame.display.show()
            frame.sleep(0.04)
            break
        end
    end
end

-- register the handler as a callback for all data sent from the host
frame.bluetooth.receive_callback(update_app_data_accum)

-- run the main app loop
app_loop()