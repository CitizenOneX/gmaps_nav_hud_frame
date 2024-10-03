local data = require('data.min')
local battery = require('battery.min')
local sprite = require('sprite.min')
local plain_text = require('plain_text.min')

-- Phone to Frame flags
TEXT_FLAG = 0x0a
IMAGE_FLAG = 0x0d

-- register the message parsers so they are automatically called when matching data comes in
data.parsers[TEXT_FLAG] = plain_text.parse_plain_text
data.parsers[IMAGE_FLAG] = sprite.parse_sprite

-- draw the current text on the display
function print_text()
    local i = 0
    for line in data.app_data[TEXT_FLAG].string:gmatch("([^\n]*)\n?") do
        if line ~= "" then
            frame.display.text(line, 1, i * 60 + 1)
            i = i + 1
        end
    end

end

-- draw the image on the display
-- TODO set palette
function print_image()
    local image = data.app_data[IMAGE_FLAG]
    frame.display.bitmap(500, 1, image.width, 2^image.bpp, 0, image.pixel_data)
end

-- Main app loop
function app_loop()
    local last_batt_update = 0
    while true do
        rc, err = pcall(
            function()
                -- process any raw items, if ready (parse into image or text, then clear raw)
                local items_ready = data.process_raw_items()

                -- TODO tune sleep durations to optimise for data handler and processing
                frame.sleep(0.005)

                -- only need to print it once when it's ready, it will stay there
                -- but if we print either, then we need to print both because a draw call and show
                -- will flip the buffer away from the already-drawn text/image
                if items_ready > 0 then
                    if (data.app_data[TEXT_FLAG] ~= nil and data.app_data[TEXT_FLAG].string ~= nil) then
                        print_text()
                    end
                    if (data.app_data[IMAGE_FLAG] ~= nil and data.app_data[IMAGE_FLAG].pixel_data ~= nil) then
                        print_image()
                    end
                    frame.display.show()
                end

                -- TODO tune sleep durations to optimise for data handler and processing
                frame.sleep(0.005)

                -- periodic battery level updates
                last_batt_update = battery.send_batt_if_elapsed(last_batt_update, 180)
                frame.sleep(0.1)

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

-- run the main app loop
app_loop()