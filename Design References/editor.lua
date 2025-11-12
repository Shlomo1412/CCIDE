-- PixelUI V2 Generated Code
local pixelui = require("pixelui")

-- Create the application
local app = pixelui.create()
local root = app:getRoot()

-- TextBox element
local textbox1 = app:createTextBox({
    x = 1,
    y = 2,
    width = 51,
    height = 17,
    text = "TextBox",
    border = false,
})
root:addChild(textbox1)

-- Button element
local button2 = app:createButton({
    x = 43,
    y = 19,
    width = 9,
    height = 1,
    label = "? Help",
    border = {color = "white", thickness = 1},
})
root:addChild(button2)

-- Label element
local label3 = app:createLabel({
    x = 1,
    y = 19,
    width = 43,
    height = 1,
    text = "Name.lua \7 Ln 201 \7 char 33",
    align = "center",
})
root:addChild(label3)

-- Button element
local button4 = app:createButton({
    x = 1,
    y = 1,
    width = 9,
    height = 1,
    label = "File",
    border = {color = "white", thickness = 1},
})
root:addChild(button4)

-- Button element
local button5 = app:createButton({
    x = 10,
    y = 1,
    width = 8,
    height = 1,
    label = "View",
    border = {color = "white", thickness = 1},
})
root:addChild(button5)

-- Button element
local button6 = app:createButton({
    x = 18,
    y = 1,
    width = 8,
    height = 1,
    label = "Edit",
    border = {color = "white", thickness = 1},
})
root:addChild(button6)

-- Button element
local button7 = app:createButton({
    x = 26,
    y = 1,
    width = 10,
    height = 1,
    label = "Settings",
    border = {color = "white", thickness = 1},
})
root:addChild(button7)

-- Button element
local button8 = app:createButton({
    x = 36,
    y = 1,
    width = 6,
    height = 1,
    label = "Run",
    border = {color = "white", thickness = 1},
})
root:addChild(button8)

-- Button element
local button9 = app:createButton({
    x = 42,
    y = 1,
    width = 10,
    height = 1,
    label = "\183 Exit",
    bg = colors.red,
    border = {color = "white", thickness = 1},
})
root:addChild(button9)

-- Run the application
app:run()