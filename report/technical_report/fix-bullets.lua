-- Lua filter to make lists non-tight (fixes "Compact" style in docx)
function Pandoc(doc)
  local function fix_list(el)
    if el.t == "BulletList" or el.t == "OrderedList" then
      local new_items = {}
      for _, item in ipairs(el.content) do
        local new_item = {}
        for _, block in ipairs(item) do
          if block.t == "Plain" then
            table.insert(new_item, pandoc.Para(block.content))
          else
            table.insert(new_item, block)
          end
        end
        table.insert(new_items, new_item)
      end
      el.content = new_items
    end
    return el
  end

  return doc:walk({
    BulletList = fix_list,
    OrderedList = fix_list
  })
end
